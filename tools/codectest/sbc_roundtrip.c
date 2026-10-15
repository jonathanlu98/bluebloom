// SBC round-trip test: test signal → sbc_a2dp encode and packetize → parse packet by packet, frame by frame per the A2DP payload header, check the bitstream structure →
// decode with the AOSP SBC decoder (third_party/sbc/decoder, an implementation independent of the encoder; it checks the frame header CRC while decoding) →
// after alignment compute per-channel SNR, actual bitrate, encode time.
// Covers 44.1/48 kHz × several configurations (joint stereo 35/53/PipeWire default, dual channel XQ, dual channel 76 per channel, stereo, mono,
// 4-subband SNR allocation) × max_payload 895−12 / 667−12; also tests the frame length formula, parameter checks, the single-instance limit. Exits non-zero if any item fails.
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "oi_codec_sbc.h"
#include "sbc_a2dp.h"

enum { kSeconds = 10, kMaxDelay = 1024 };

static int failures = 0;
#define CHECK(cond, ...)                      \
    do {                                      \
        if (!(cond)) {                        \
            printf("  FAIL: " __VA_ARGS__);   \
            printf("\n");                     \
            failures++;                       \
        }                                     \
    } while (0)

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t rng_state;
static double noise(void) {  // uniform in [-1, 1)
    rng_state = rng_state * 1664525u + 1013904223u;
    return (double)(rng_state >> 8) / (1 << 23) - 1.0;
}

// Test signal (24-bit integers). Normal: left 1 kHz (−8 dBFS), right 3.15 kHz (−10 dBFS), each with independent white noise (about −35 dBFS RMS).
// Full scale: left 997 Hz sine 0.96 + noise 0.035 (peak −0.04 dBFS), right the inverted sine + independent noise; checks for fixed-point overflow
static void make_signal(int rate, size_t frames, bool full_scale, int32_t *left, int32_t *right) {
    rng_state = 0x12345678;
    for (size_t n = 0; n < frames; n++) {
        double t = (double)n / rate, l, r;
        if (full_scale) {
            double s = 0.96 * sin(2 * M_PI * 997 * t);
            l = s + 0.035 * noise();
            r = -s + 0.035 * noise();
        } else {
            l = 0.4 * sin(2 * M_PI * 1000 * t) + 0.03 * noise();
            r = 0.3 * sin(2 * M_PI * 3150 * t + 0.7) + 0.03 * noise();
        }
        left[n] = (int32_t)lrint(l * 8388607.0);
        right[n] = (int32_t)lrint(r * 8388607.0);
    }
}

static void write24(uint8_t *p, int32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
}

// Find the delay (in samples) of the decoded output relative to the reference: the maximum cross-correlation over seconds 2-3
static int find_delay(const double *ref, const int16_t *dec, int stride, size_t frames, int rate) {
    size_t start = (size_t)rate * 2, len = (size_t)rate;
    if (start + len + kMaxDelay > frames) return -1;
    int best = -1;
    double best_corr = -1e300;
    for (int d = 0; d < kMaxDelay; d++) {
        double c = 0;
        for (size_t i = start; i < start + len; i++) c += ref[i] * dec[(i + d) * stride];
        if (c > best_corr) {
            best_corr = c;
            best = d;
        }
    }
    return best;
}

// SNR (dB) over [0.5 s, 9.5 s], aligned by delay d. The reference is the 24-bit original signal scaled to the 16-bit range
static double snr_db(const double *ref, const int16_t *dec, int stride, int d, int rate) {
    size_t start = (size_t)rate / 2, end = (size_t)rate * (kSeconds - 1) + rate / 2;
    double sig = 0, err = 0;
    for (size_t i = start; i < end; i++) {
        double e = dec[(i + d) * stride] - ref[i];
        sig += ref[i] * ref[i];
        err += e * e;
    }
    return 10 * log10(sig / (err > 0 ? err : 1e-30));
}

typedef struct {
    const char *name;
    int channel_mode, block_length, subbands, allocation;
    int bitpool44, bitpool48;
    double min_snr;  // per-channel SNR minimum (dB), with margin below the observed values
} TestConfig;

typedef struct {
    double snr[2], kbps, air_kbps, encode_ms_per_s;
} Result;

// Encode → parse → decode → align → SNR. Returns false on a structural failure (already counted in failures)
static bool run(const TestConfig *tc, int rate, size_t mtu, const int32_t *left, const int32_t *right, size_t frames,
                Result *res) {
    char error[256] = "";
    sbc_a2dp_config cfg = {
        .sample_rate = rate,
        .channel_mode = tc->channel_mode,
        .block_length = tc->block_length,
        .subbands = tc->subbands,
        .allocation = tc->allocation,
        .bitpool = rate == 44100 ? tc->bitpool44 : tc->bitpool48,
    };
    size_t max_payload = mtu - kSbcRTPHeaderSize;
    sbc_a2dp *codec = sbc_a2dp_open(&cfg, max_payload, error, sizeof(error));
    if (!codec) {
        CHECK(false, "%s %d Hz open failed: %s", tc->name, rate, error);
        return false;
    }
    size_t per_packet = sbc_a2dp_pcm_frames_per_packet(codec);
    size_t frame_bytes = sbc_a2dp_frame_bytes(codec);
    size_t frame_samples = (size_t)cfg.block_length * cfg.subbands;
    size_t sbc_per_packet = per_packet / frame_samples;
    size_t packets = (frames + per_packet - 1) / per_packet;
    bool mono = cfg.channel_mode == kSbcChannelMono;

    CHECK(per_packet % frame_samples == 0, "%s PCM frames per packet %zu is not a multiple of the SBC frame sample count", tc->name, per_packet);
    CHECK(sbc_per_packet >= 1 && sbc_per_packet <= kSbcMaxFramesPerPacket, "%s %zu frames per packet is out of range", tc->name,
          sbc_per_packet);
    CHECK(frame_bytes == sbc_a2dp_frame_length(&cfg), "%s frame length does not match the formula", tc->name);
    // Rule: one more frame would not fit (or it is already at 15 frames)
    CHECK(1 + sbc_per_packet * frame_bytes <= max_payload &&
              (sbc_per_packet == kSbcMaxFramesPerPacket || 1 + (sbc_per_packet + 1) * frame_bytes > max_payload),
          "%s frames per packet %zu is not the most that fits", tc->name, sbc_per_packet);

    uint8_t *pcm = calloc(per_packet, 6);
    uint8_t *payload = malloc(max_payload);
    int16_t *decoded = calloc((packets * per_packet + frame_samples) * 2, sizeof(int16_t));
    OI_CODEC_SBC_DECODER_CONTEXT ctx;
    static uint32_t ctx_data[CODEC_DATA_WORDS(2, SBC_CODEC_FAST_FILTER_BUFFERS)];
    OI_STATUS st = OI_CODEC_SBC_DecoderReset(&ctx, ctx_data, sizeof(ctx_data), 2, 2, FALSE);
    CHECK(st == OI_OK, "decoder init failed %d", st);

    double encode_seconds = 0;
    size_t total_payload = 0, total_frame_bytes = 0, out_samples = 0;
    bool ok = true;
    for (size_t p = 0; p < packets && ok; p++) {
        for (size_t i = 0; i < per_packet; i++) {
            size_t n = p * per_packet + i;
            write24(pcm + 6 * i, n < frames ? left[n] : 0);
            write24(pcm + 6 * i + 3, n < frames ? right[n] : 0);
        }
        double t0 = now_seconds();
        int len = sbc_a2dp_encode(codec, pcm, payload, max_payload, error, sizeof(error));
        encode_seconds += now_seconds() - t0;
        if (len < 0) {
            CHECK(false, "%s encode failed: %s", tc->name, error);
            ok = false;
            break;
        }
        CHECK((size_t)len == 1 + sbc_per_packet * frame_bytes && (size_t)len <= max_payload, "%s packet length %d is wrong",
              tc->name, len);
        // Payload header: not fragmented, the low 4 bits are the frame count
        uint8_t hdr = payload[0];
        if ((hdr & (kSbcHeaderFragmented | kSbcHeaderStart | kSbcHeaderLast | 0x10)) != 0 ||
            (size_t)(hdr & kSbcHeaderFrameCountMask) != sbc_per_packet) {
            CHECK(false, "%s packet %zu payload header 0x%02x is wrong", tc->name, p, hdr);
            ok = false;
            break;
        }
        total_payload += (size_t)len;
        const OI_BYTE *data = payload + 1;
        uint32_t remaining = (uint32_t)len - 1;
        for (int f = 0; f < (hdr & kSbcHeaderFrameCountMask); f++) {
            // Frame header: sync word 0x9C, bitpool byte matches the configuration
            if (data[0] != 0x9C || data[2] != cfg.bitpool) {
                CHECK(false, "%s packet %zu frame %d header is wrong (%02x %02x %02x)", tc->name, p, f, data[0], data[1],
                      data[2]);
                ok = false;
                break;
            }
            uint32_t before = remaining;
            uint32_t pcm_bytes = (uint32_t)(frame_samples * 2 * sizeof(int16_t));
            st = OI_CODEC_SBC_DecodeFrame(&ctx, &data, &remaining, decoded + out_samples * 2, &pcm_bytes);
            if (st != OI_OK || before - remaining != frame_bytes || pcm_bytes != frame_samples * 4) {
                CHECK(false, "%s packet %zu frame %d decode failed: status %d, consumed %u bytes (expected %zu), output %u bytes",
                      tc->name, p, f, st, before - remaining, frame_bytes, pcm_bytes);
                ok = false;
                break;
            }
            total_frame_bytes += frame_bytes;
            out_samples += frame_samples;
        }
        if (ok && remaining != 0) {
            CHECK(false, "%s packet %zu has %u bytes left after decoding", tc->name, p, remaining);
            ok = false;
        }
    }
    sbc_a2dp_close(codec);

    if (ok) {
        double duration = (double)out_samples / rate;
        res->kbps = total_frame_bytes * 8 / duration / 1000;
        res->air_kbps = (total_payload + packets * kSbcRTPHeaderSize) * 8 / duration / 1000;
        res->encode_ms_per_s = encode_seconds * 1000 / duration;
        // Reference signal (16-bit range): mono is (L+R)/2; the decoder copies mono to both outputs
        double *ref = malloc(frames * sizeof(double));
        for (int ch = 0; ch < 2; ch++) {
            for (size_t n = 0; n < frames; n++) {
                ref[n] = (mono ? (left[n] + right[n]) / 2.0 : (ch == 0 ? left[n] : right[n])) / 256.0;
            }
            int d = find_delay(ref, decoded + ch, 2, frames, rate);
            res->snr[ch] = d < 0 ? -1e9 : snr_db(ref, decoded + ch, 2, d, rate);
            // The 8-subband SBC codec delay is 73 samples, 4-subband 37 (the encoder delay in PipeWire a2dp-codec-sbc.c L453-457)
            int expect = cfg.subbands == 8 ? 73 : 37;
            CHECK(d == expect, "%s %d Hz channel %d delay %d, expected %d", tc->name, rate, ch, d, expect);
        }
        free(ref);
        double nominal = (double)frame_bytes * 8 * rate / frame_samples / 1000;
        CHECK(fabs(res->kbps - nominal) < 0.01, "%s measured bitrate %.2f does not match nominal %.2f", tc->name, res->kbps, nominal);
        for (int ch = 0; ch < 2; ch++) {
            CHECK(res->snr[ch] >= tc->min_snr, "%s %d Hz MTU %zu channel %d SNR %.1f dB below %.1f", tc->name, rate, mtu,
                  ch, res->snr[ch], tc->min_snr);
        }
        printf("%-14s %5d %4zu %3d %4zu %2zu %5zu %5.1f %7.1f %7.1f %6.1f %6.1f %6.2f\n", tc->name, rate, mtu,
               cfg.bitpool, frame_bytes, sbc_per_packet, per_packet, per_packet * 1000.0 / rate, res->kbps,
               res->air_kbps, res->snr[0], res->snr[1], res->encode_ms_per_s);
    }
    free(pcm);
    free(payload);
    free(decoded);
    return ok;
}

static void test_frame_length(void) {
    // Known frame lengths: Android high quality 44.1k bitpool 53 = 119 bytes, 48k bitpool 51 = 115 bytes
    // (a2dp_sbc_encoder.cc L57-58 A2DP_SBC_MAX_HQ_FRAME_SIZE_44_1/48)
    sbc_a2dp_config c = {44100, kSbcChannelJoint, 16, 8, kSbcAllocationLoudness, 53};
    CHECK(sbc_a2dp_frame_length(&c) == 119, "joint stereo 53 frame length %zu ≠ 119", sbc_a2dp_frame_length(&c));
    c.bitpool = 51;
    CHECK(sbc_a2dp_frame_length(&c) == 115, "joint stereo 51 frame length %zu ≠ 115", sbc_a2dp_frame_length(&c));
    c.channel_mode = kSbcChannelDual;
    c.bitpool = 38;  // 4 + 8 + 16×2×38/8 = 164
    CHECK(sbc_a2dp_frame_length(&c) == 164, "dual channel 38 frame length %zu ≠ 164", sbc_a2dp_frame_length(&c));
    c.channel_mode = kSbcChannelMono;
    c.bitpool = 31;  // 4 + 4 + 16×31/8 = 70
    CHECK(sbc_a2dp_frame_length(&c) == 70, "mono 31 frame length %zu ≠ 70", sbc_a2dp_frame_length(&c));
    c.channel_mode = kSbcChannelJoint;
    c.subbands = 4;
    c.block_length = 4;
    c.bitpool = 7;  // 4 + 4 + ⌈(4 + 28)/8⌉ = 12
    CHECK(sbc_a2dp_frame_length(&c) == 12, "joint stereo 4 subbands 4 blocks 7 frame length %zu ≠ 12", sbc_a2dp_frame_length(&c));
    c.bitpool = 8;  // 4 + 4 + ⌈(4 + 32)/8⌉ = 13 (rounding down would give 12)
    CHECK(sbc_a2dp_frame_length(&c) == 13, "joint stereo 4 subbands 4 blocks 8 frame length %zu ≠ 13", sbc_a2dp_frame_length(&c));
    c.channel_mode = 0x03;
    CHECK(sbc_a2dp_frame_length(&c) == 0, "invalid channel mode should return 0");
}

static void test_errors(void) {
    char error[256];
    sbc_a2dp_config c = {44100, kSbcChannelDual, 16, 8, kSbcAllocationLoudness, 129};
    CHECK(!sbc_a2dp_open(&c, 883, error, sizeof(error)), "dual channel 8 subbands bitpool 129 should be rejected");
    c.bitpool = 128;
    sbc_a2dp *a = sbc_a2dp_open(&c, 883, error, sizeof(error));
    CHECK(a != NULL, "dual channel bitpool 128 should open: %s", error);
    sbc_a2dp_close(a);
    c.channel_mode = kSbcChannelJoint;
    c.subbands = 4;
    c.bitpool = 129;
    CHECK(!sbc_a2dp_open(&c, 883, error, sizeof(error)), "joint stereo 4 subbands bitpool 129 should be rejected");
    c.subbands = 8;
    c.bitpool = 251;
    CHECK(!sbc_a2dp_open(&c, 883, error, sizeof(error)), "bitpool 251 should be rejected");
    c.bitpool = 1;
    CHECK(!sbc_a2dp_open(&c, 883, error, sizeof(error)), "bitpool 1 should be rejected");
    c.bitpool = 53;
    c.channel_mode = kSbcChannelJoint | kSbcChannelStereo;
    CHECK(!sbc_a2dp_open(&c, 883, error, sizeof(error)), "channel mode with more than one bit set should be rejected");
    c.channel_mode = kSbcChannelJoint;
    c.sample_rate = 96000;
    CHECK(!sbc_a2dp_open(&c, 883, error, sizeof(error)), "96 kHz should be rejected");
    c.sample_rate = 44100;
    CHECK(!sbc_a2dp_open(&c, 119, error, sizeof(error)), "a 119-byte payload cannot hold a 1-byte header + 119-byte frame, should be rejected");
    a = sbc_a2dp_open(&c, 120, error, sizeof(error));
    CHECK(a && sbc_a2dp_pcm_frames_per_packet(a) == 128, "a 120-byte payload should hold exactly 1 frame");
    // Single instance
    sbc_a2dp *b = sbc_a2dp_open(&c, 883, error, sizeof(error));
    CHECK(!b, "a second open while an instance exists should fail");
    if (b) sbc_a2dp_close(b);
    if (a) {
        uint8_t pcm[128 * 6] = {0}, out[200];
        CHECK(sbc_a2dp_encode(a, pcm, out, 119, error, sizeof(error)) < 0, "should fail when the output buffer is too small");
        CHECK(sbc_a2dp_encode(a, pcm, out, sizeof(out), error, sizeof(error)) == 120, "silence should encode to 120 bytes");
    }
    sbc_a2dp_close(a);
    // Very large MTU: frame count capped at 15
    c.bitpool = 2;
    a = sbc_a2dp_open(&c, 4000, error, sizeof(error));
    CHECK(a && sbc_a2dp_pcm_frames_per_packet(a) == 15 * 128, "frames per packet should be capped at 15");
    sbc_a2dp_close(a);
}

// Silence: the decoded output must be all 0 (rounding without dither, so digital silence stays silent)
static void test_silence(void) {
    char error[256];
    const int modes[] = {kSbcChannelJoint, kSbcChannelStereo, kSbcChannelDual, kSbcChannelMono};
    for (size_t m = 0; m < 4; m++) {
        sbc_a2dp_config c = {48000, modes[m], 16, 8, kSbcAllocationLoudness, 40};
        sbc_a2dp *codec = sbc_a2dp_open(&c, 883, error, sizeof(error));
        if (!codec) {
            CHECK(false, "silence test open failed: %s", error);
            continue;
        }
        OI_CODEC_SBC_DECODER_CONTEXT ctx;
        static uint32_t ctx_data[CODEC_DATA_WORDS(2, SBC_CODEC_FAST_FILTER_BUFFERS)];
        OI_CODEC_SBC_DecoderReset(&ctx, ctx_data, sizeof(ctx_data), 2, 2, FALSE);
        size_t per_packet = sbc_a2dp_pcm_frames_per_packet(codec);
        uint8_t *pcm = calloc(per_packet, 6), payload[883];
        int nonzero = 0, bad = 0;
        for (int p = 0; p < 50; p++) {
            int len = sbc_a2dp_encode(codec, pcm, payload, sizeof(payload), error, sizeof(error));
            const OI_BYTE *data = payload + 1;
            uint32_t remaining = len > 0 ? (uint32_t)len - 1 : 0;
            for (int f = 0; len > 0 && f < (payload[0] & kSbcHeaderFrameCountMask); f++) {
                int16_t out[16 * 8 * 2];
                uint32_t pcm_bytes = sizeof(out);
                if (OI_CODEC_SBC_DecodeFrame(&ctx, &data, &remaining, out, &pcm_bytes) != OI_OK) bad++;
                for (size_t i = 0; i < pcm_bytes / 2; i++) nonzero += out[i] != 0;
            }
            if (len < 0) bad++;
        }
        CHECK(!bad && !nonzero, "silence (channel mode 0x%02x): %d errors, %d nonzero samples", modes[m], bad, nonzero);
        free(pcm);
        sbc_a2dp_close(codec);
    }
}

// Change bitpool while streaming (used by adaptive bitrate): switch tier every second, finally going back up to the opening value; every frame header's bitpool matches the current one, frame length follows the new bitpool,
// frames and PCM per packet stay the same, decoding is continuous throughout with unchanged delay; a bitpool above the opening value should be rejected
static void test_bitpool_switch(void) {
    char error[256];
    const int rate = 48000, pools[] = {51, 43, 36, 29, 51};
    const int count = sizeof(pools) / sizeof(pools[0]);
    sbc_a2dp_config cfg = {rate, kSbcChannelJoint, 16, 8, kSbcAllocationLoudness, pools[0]};
    sbc_a2dp *codec = sbc_a2dp_open(&cfg, 883, error, sizeof(error));
    if (!codec) {
        CHECK(false, "bitpool switch test open failed: %s", error);
        return;
    }
    CHECK(sbc_a2dp_set_bitpool(codec, pools[0] + 1) != 0, "a bitpool above the opening value should be rejected");
    size_t per_packet = sbc_a2dp_pcm_frames_per_packet(codec), frame_samples = 128;
    size_t packets_per_segment = (size_t)rate / per_packet, packets = packets_per_segment * count;
    size_t frames = packets * per_packet;
    int32_t *left = malloc(frames * sizeof(int32_t)), *right = malloc(frames * sizeof(int32_t));
    make_signal(rate, frames, false, left, right);
    uint8_t *pcm = calloc(per_packet, 6), payload[883];
    int16_t *decoded = calloc((frames + frame_samples) * 2, sizeof(int16_t));
    OI_CODEC_SBC_DECODER_CONTEXT ctx;
    static uint32_t ctx_data[CODEC_DATA_WORDS(2, SBC_CODEC_FAST_FILTER_BUFFERS)];
    OI_CODEC_SBC_DecoderReset(&ctx, ctx_data, sizeof(ctx_data), 2, 2, FALSE);
    size_t out_samples = 0;
    int bad = 0;
    for (size_t p = 0; p < packets; p++) {
        int pool = pools[p / packets_per_segment];
        if (p % packets_per_segment == 0) CHECK(sbc_a2dp_set_bitpool(codec, pool) == 0, "setting bitpool %d failed", pool);
        CHECK(sbc_a2dp_pcm_frames_per_packet(codec) == per_packet, "PCM frames per packet changed after changing bitpool");
        for (size_t i = 0; i < per_packet; i++) {
            write24(pcm + 6 * i, left[p * per_packet + i]);
            write24(pcm + 6 * i + 3, right[p * per_packet + i]);
        }
        int len = sbc_a2dp_encode(codec, pcm, payload, sizeof(payload), error, sizeof(error));
        size_t frame_bytes = sbc_a2dp_frame_bytes(codec);
        if (len < 0 || (size_t)len != 1 + (payload[0] & kSbcHeaderFrameCountMask) * frame_bytes ||
            frame_bytes != sbc_a2dp_frame_length(&(sbc_a2dp_config){rate, kSbcChannelJoint, 16, 8, kSbcAllocationLoudness, pool})) {
            bad++;
            continue;
        }
        const OI_BYTE *data = payload + 1;
        uint32_t remaining = (uint32_t)len - 1;
        for (int f = 0; f < (payload[0] & kSbcHeaderFrameCountMask); f++) {
            uint32_t before = remaining, pcm_bytes = (uint32_t)(frame_samples * 4);
            if (data[2] != pool) bad++;
            if (OI_CODEC_SBC_DecodeFrame(&ctx, &data, &remaining, decoded + out_samples * 2, &pcm_bytes) != OI_OK ||
                before - remaining != frame_bytes) {
                bad++;
                break;
            }
            out_samples += frame_samples;
        }
    }
    CHECK(bad == 0, "bitpool switch: %d wrong frame headers, frame lengths or decodes", bad);
    double *ref = malloc(frames * sizeof(double));
    for (size_t n = 0; n < frames; n++) ref[n] = left[n] / 256.0;
    int d = find_delay(ref, decoded, 2, frames, rate);
    double snr = d < 0 ? -1e9 : snr_db(ref, decoded, 2, d, rate);
    // The lowest tier, bitpool 29, is roughly below MQ; the whole-run SNR minimum leaves margin below the observed value
    printf("Bitpool switch %d→%d→%d→%d→%d: %zu PCM frames per packet unchanged, delay %d, left channel whole-run SNR %.1f dB\n", pools[0], pools[1], pools[2],
           pools[3], pools[4], per_packet, d, snr);
    CHECK(d == 73, "delay %d after changing bitpool, expected 73", d);
    CHECK(snr >= 15, "bitpool switch whole-run SNR %.1f dB too low", snr);
    free(ref);
    free(left);
    free(right);
    free(pcm);
    free(decoded);
    sbc_a2dp_close(codec);
}

int main(void) {
    const int L = kSbcAllocationLoudness;
    // SNR minimums: observed 2026-10-13 (the minimum across sample rates and channels) minus about 3 dB
    const TestConfig configs[] = {
        {"joint-MQ", kSbcChannelJoint, 16, 8, L, kSbcBitpoolMQJoint44100, kSbcBitpoolMQJoint48000, 20},
        {"joint-HQ", kSbcChannelJoint, 16, 8, L, kSbcBitpoolHQJoint44100, kSbcBitpoolHQJoint48000, 23},
        {"joint-53", kSbcChannelJoint, 16, 8, L, 53, 53, 23},
        {"joint-PW", kSbcChannelJoint, 16, 8, L, kSbcBitpoolPWJoint44100, kSbcBitpoolPWJoint48000, 27},
        {"stereo-53", kSbcChannelStereo, 16, 8, L, 53, 53, 22},
        {"dual-XQ452", kSbcChannelDual, 16, 8, L, kSbcBitpoolXQ452Dual44100, 37, 32},
        {"dual-XQ", kSbcChannelDual, 16, 8, L, kSbcBitpoolXQDual44100, kSbcBitpoolXQDual48000, 34},
        {"dual-76", kSbcChannelDual, 16, 8, L, 76, 76, 55},
        {"joint-XQ86", kSbcChannelJoint, 16, 8, L, 86, 78, 34},
        {"mono-HQ", kSbcChannelMono, 16, 8, L, kSbcBitpoolHQMono44100, kSbcBitpoolHQMono48000, 27},
        // 4 subbands are tested only in stereo: the AOSP decoder is broken for 4-subband joint stereo (it also misdecodes 4-subband joint stereo encoded by ffmpeg;
        // our 4-subband joint stereo decodes fine with ffmpeg; cross-checked 2026-10-13, recorded in third_party/sbc/VERSION)
        {"stereo4-SNR", kSbcChannelStereo, 8, 4, kSbcAllocationSNR, 30, 30, 29},
    };
    // Full-scale input (checks for fixed-point overflow): observed joint stereo 53 at 40 dB, dual channel 76 at 64-68 dB
    const TestConfig full_scale[] = {
        {"fs-joint-53", kSbcChannelJoint, 16, 8, L, 53, 53, 37},
        {"fs-dual-76", kSbcChannelDual, 16, 8, L, 76, 76, 60},
    };
    const int rates[] = {44100, 48000};
    const size_t mtus[] = {895, 667};

    printf("== Frame length formula and parameter checks ==\n");
    test_frame_length();
    test_errors();
    test_silence();
    test_bitpool_switch();

    printf("== Round trip (10 s, SNR against the 24-bit original; air = including the 1-byte payload header and 12-byte RTP header) ==\n");
    printf("%-14s %5s %4s %3s %4s %2s %5s %5s %7s %7s %6s %6s %6s\n", "config", "rate", "mtu", "bp", "fl", "n",
           "pcm", "ms", "kbps", "air", "snrL", "snrR", "ms/s");
    double slowest = 0;
    for (size_t r = 0; r < sizeof(rates) / sizeof(rates[0]); r++) {
        int rate = rates[r];
        size_t frames = (size_t)rate * kSeconds;
        int32_t *left = malloc(frames * sizeof(int32_t)), *right = malloc(frames * sizeof(int32_t));
        for (int fs = 0; fs < 2; fs++) {
            make_signal(rate, frames, fs, left, right);
            const TestConfig *list = fs ? full_scale : configs;
            size_t count = fs ? sizeof(full_scale) / sizeof(full_scale[0]) : sizeof(configs) / sizeof(configs[0]);
            for (size_t c = 0; c < count; c++) {
                for (size_t m = 0; m < sizeof(mtus) / sizeof(mtus[0]); m++) {
                    Result res;
                    if (run(&list[c], rate, mtus[m], left, right, frames, &res) && res.encode_ms_per_s > slowest) {
                        slowest = res.encode_ms_per_s;
                    }
                }
            }
        }
        free(left);
        free(right);
    }
    printf("Encode time: slowest %.2f ms per second of audio (about %.0fx real time, single thread)\n", slowest, 1000 / slowest);
    if (failures) {
        printf("FAILED: %d failures in total\n", failures);
        return 1;
    }
    printf("ALL PASSED\n");
    return 0;
}
