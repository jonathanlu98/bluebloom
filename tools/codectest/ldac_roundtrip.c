// LDAC round-trip test: test signal → ldac_a2dp encode and packetize → parse packet by packet, frame by frame per the A2DP payload header, check the bitstream structure →
// decode with the open-source decoder libldacdec (tools/codectest/ldacdec, MIT) → after alignment compute per-channel SNR, actual bitrate, encode time.
// Covers 44.1/48/88.2/96 kHz × HQ/SQ/MQ/ABR × MTU 895/679, plus mono (decoded output compared with (L+R)/2) and dual channel (the decoder does not support it, only the structure is checked).
// ABR is driven by a simulated link: the link drops to 450 kbps at 3-6 s, to see how the queue and bitrate react (plus a 60 s run to see the recovery,
// and a 180 s run with the link fixed at 103 packets/s to see the tier-up backoff). Exits non-zero if any item fails.
// The noise makes the alignment unique (a pure sine has periodic ambiguity); without noise HQ/SQ reach 90 dB (the limit of the decoder's 16-bit output), MQ about 66 dB.
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ldac_a2dp.h"
#include "ldacdec.h"

enum { kSeconds = 10, kMaxDelay = 2048 };

// The decoder's sample rate index (libldacdec.c sampleRateIdToFrequency) and channel config index (0 mono, 1 dual, 2 stereo)
static int rate_id(int rate) { return rate == 44100 ? 0 : rate == 48000 ? 1 : rate == 88200 ? 2 : 3; }
static int channel_config_id(int mode) { return mode == kLdacChannelMono ? 0 : mode == kLdacChannelDual ? 1 : 2; }
static const char *quality_name(int q) { return q == 0 ? "HQ" : q == 1 ? "SQ" : q == 2 ? "MQ" : "ABR"; }
static const char *mode_name(int m) { return m == kLdacChannelMono ? "mono" : m == kLdacChannelDual ? "dual" : "stereo"; }

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint32_t rng_state = 0x12345678;
static double noise(void) {  // uniform in [-1, 1)
    rng_state = rng_state * 1664525u + 1013904223u;
    return (double)(rng_state >> 8) / (1 << 23) - 1.0;
}

// Test signal: left 1 kHz + 6 kHz, right 440 Hz + 3.15 kHz, each with about −71 dBFS (RMS) of white noise added; 24-bit integers
static void make_signal(int rate, size_t frames, int32_t *left, int32_t *right) {
    rng_state = 0x12345678;
    for (size_t n = 0; n < frames; n++) {
        double t = (double)n / rate;
        double l = 0.45 * sin(2 * M_PI * 1000 * t) + 0.2 * sin(2 * M_PI * 6000 * t) + 0.0005 * noise();
        double r = 0.35 * sin(2 * M_PI * 440 * t) + 0.25 * sin(2 * M_PI * 3150 * t) + 0.0005 * noise();
        left[n] = (int32_t)lrint(l * 8388607.0);
        right[n] = (int32_t)lrint(r * 8388607.0);
    }
}

static void put_s24(uint8_t *p, int32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
}

// Simulated link (ABR only): every packet produced is enqueued; dequeued at the link rate. 0-3 s 1100 kbps, 3-6 s 450 kbps, then 1100 kbps.
// With packet_cap > 0 it instead sends at most that many packets per second regardless of size: observed 2026-10-13, the Mac → WH-1000XM4 media channel carries about 103 packets/s,
// stuck right between Q0 (492 kbps, 94 packets/s) and SQ (660, 125 packets/s)
typedef struct {
    size_t sizes[4096];
    size_t head, count, max_count;
    double credit, packet_cap;
} Link;

static double link_kbps(double t) { return (t >= 3.0 && t < 6.0) ? 450.0 : 1100.0; }

static void link_advance(Link *link, double t, double dt) {
    if (link->packet_cap > 0) {
        link->credit += link->packet_cap * dt;
        while (link->count && link->credit >= 1) {
            link->credit -= 1;
            link->head++;
            link->count--;
        }
        if (!link->count && link->credit > 1) link->credit = 1;
        return;
    }
    link->credit += link_kbps(t) * 1000.0 / 8.0 * dt;
    while (link->count && link->credit >= (double)link->sizes[link->head % 4096]) {
        link->credit -= (double)link->sizes[link->head % 4096];
        link->head++;
        link->count--;
    }
    if (!link->count && link->credit > 1000.0) link->credit = 1000.0;  // do not bank credit while idle
}

typedef struct {
    int rate, mode, quality;
    size_t max_payload;
    int seconds;
    double packet_cap;  // see Link
} Case;

typedef struct {
    bool ok;
    size_t packets, frames;
    double kbps, nominal_kbps, snr[2], ms_per_second;
    int delay, min_kbps, final_kbps;
    char abr_trace[200];
    size_t max_queue;
    int raises, dips;   // number of tier-ups; number of times the bitrate fell below Q0 (492/452) after 20 s
    double above_seconds;  // total time above Q0 after 20 s
} Result;

static int failures = 0;
#define CHECK(cond, ...)                                     \
    do {                                                     \
        if (!(cond)) {                                       \
            fprintf(stderr, "  FAIL [%s:%d] ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                    \
            fprintf(stderr, "\n");                           \
            failures++;                                      \
            goto done;                                       \
        }                                                    \
    } while (0)

// Find the d in [0, kMaxDelay) that minimizes the total error between decoded[n+d] and reference[n] over all channels (using the 0.5-1.5 s segment)
static int find_delay(double *const *reference, size_t ref_len, double *const *decoded, size_t dec_len, int channels,
                      int rate) {
    size_t start = (size_t)rate / 2, len = (size_t)rate;
    int best = -1;
    double best_err = INFINITY;
    for (int d = 0; d < kMaxDelay; d++) {
        if (start + len + (size_t)d > dec_len || start + len > ref_len) break;
        double err = 0;
        for (int ch = 0; ch < channels; ch++) {
            for (size_t n = start; n < start + len; n++) {
                double e = decoded[ch][n + (size_t)d] - reference[ch][n];
                err += e * e;
            }
        }
        if (err < best_err) {
            best_err = err;
            best = d;
        }
    }
    return best;
}

static double snr_db(const double *reference, const double *decoded, size_t from, size_t to, int delay) {
    double signal = 0, error = 0;
    for (size_t n = from; n < to; n++) {
        double e = decoded[n + (size_t)delay] - reference[n];
        signal += reference[n] * reference[n];
        error += e * e;
    }
    return 10 * log10(signal / (error > 0 ? error : 1e-30));
}

static Result run_case(const Case *c) {
    Result res = { 0 };
    char error[256] = "";
    size_t total = (size_t)c->rate * (size_t)c->seconds;
    int32_t *left = malloc(total * sizeof(int32_t)), *right = malloc(total * sizeof(int32_t));
    make_signal(c->rate, total, left, right);
    bool decodable = c->mode != kLdacChannelDual;
    int out_channels = c->mode == kLdacChannelMono ? 1 : 2;

    // Encode
    ldac_a2dp *codec = ldac_a2dp_open(c->rate, c->mode, c->quality, c->max_payload, error, sizeof(error));
    uint8_t *stream = NULL;
    size_t *lengths = NULL, *pcm_frames = NULL;
    double *ref[2] = { NULL, NULL }, *dec[2] = { NULL, NULL };
    Link *link = calloc(1, sizeof(Link));
    link->packet_cap = c->packet_cap;
    if (!codec) {
        fprintf(stderr, "  open failed: %s\n", error);
        failures++;
        goto done;
    }
    size_t per_call = ldac_a2dp_frames_per_call(codec);
    CHECK(per_call == 128, "frames_per_call = %zu", per_call);
    size_t calls = total / per_call, max_packets = calls + 1;
    stream = malloc(max_packets * kLdacMaxPayload);
    lengths = calloc(max_packets, sizeof(size_t));
    pcm_frames = calloc(max_packets, sizeof(size_t));
    uint8_t pcm[128 * 6];
    double encode_time = 0;
    int trace_len = 0, last_rate = -1, prev_kbps = -1;
    res.min_kbps = ldac_a2dp_bitrate_kbps(codec);
    for (size_t i = 0; i < calls; i++) {
        for (size_t k = 0; k < per_call; k++) {
            put_s24(pcm + 6 * k, left[i * per_call + k]);
            put_s24(pcm + 6 * k + 3, right[i * per_call + k]);
        }
        double t = (double)(i * per_call) / c->rate, dt = (double)per_call / c->rate;
        if (c->quality == kLdacQualityABR) ldac_a2dp_set_queue_depth(codec, (int)link->count);
        size_t frames_in_packet = 0;
        uint8_t *out = stream + res.packets * kLdacMaxPayload;
        double t0 = now_seconds();
        int n = ldac_a2dp_encode(codec, pcm, out, kLdacMaxPayload, &frames_in_packet, error, sizeof(error));
        encode_time += now_seconds() - t0;
        CHECK(n >= 0, "encode failed: %s", error);
        if (n > 0) {
            CHECK((size_t)n <= c->max_payload, "packet of %d bytes exceeds max_payload %zu", n, c->max_payload);
            lengths[res.packets] = (size_t)n;
            pcm_frames[res.packets] = frames_in_packet;
            res.packets++;
            if (c->quality == kLdacQualityABR) {
                link->sizes[(link->head + link->count) % 4096] = (size_t)n + kLdacRTPHeaderSize;
                link->count++;
                if (link->count > link->max_count) link->max_count = link->count;
            }
        }
        if (c->quality == kLdacQualityABR) {
            link_advance(link, t, dt);
            int kbps = ldac_a2dp_bitrate_kbps(codec);
            if (kbps < res.min_kbps) res.min_kbps = kbps;
            int q0 = c->rate % 44100 == 0 ? 452 : 492;
            if (prev_kbps >= 0 && kbps > prev_kbps) res.raises++;
            if (t >= 20 && kbps < q0 && prev_kbps >= q0) res.dips++;
            if (t >= 20 && kbps > q0) res.above_seconds += dt;
            prev_kbps = kbps;
            if (kbps != last_rate && trace_len < (int)sizeof(res.abr_trace) - 20) {
                trace_len += snprintf(res.abr_trace + trace_len, sizeof(res.abr_trace) - (size_t)trace_len, "%s%.1fs:%d",
                                      last_rate < 0 ? "" : " ", t, kbps);
                last_rate = kbps;
            }
        }
    }
    res.max_queue = link->max_count;
    res.nominal_kbps = res.final_kbps = ldac_a2dp_bitrate_kbps(codec);
    res.ms_per_second = encode_time * 1000 / c->seconds;

    // Parse + decode
    int expected_frame_samples = c->rate > 48000 ? 256 : 128;
    size_t max_out = calls * per_call + 4096;
    for (int ch = 0; ch < out_channels; ch++) dec[ch] = calloc(max_out, sizeof(double));
    ldacdec_t decoder;
    ldacdecInit(&decoder);
    size_t decoded = 0, ts_sum = 0, frame_bytes = 0;
    for (size_t p = 0; p < res.packets; p++) {
        const uint8_t *pkt = stream + p * kLdacMaxPayload;
        size_t len = lengths[p];
        CHECK(len > kLdacPayloadHeaderSize, "packet %zu too short", p);
        CHECK((pkt[0] & ~kLdacHeaderFrameCountMask) == 0, "packet %zu payload header 0x%02x has fragmentation bits set", p, pkt[0]);
        int count = pkt[0] & kLdacHeaderFrameCountMask;
        CHECK(count >= 1, "packet %zu has 0 frames", p);
        CHECK(pcm_frames[p] == (size_t)count * (size_t)expected_frame_samples, "packet %zu timestamp step %zu ≠ %d frames × %d", p,
              pcm_frames[p], count, expected_frame_samples);
        ts_sum += pcm_frames[p];
        size_t off = kLdacPayloadHeaderSize;
        for (int f = 0; f < count; f++) {
            CHECK(off + kLdacFrameHeaderSize <= len, "packet %zu frame %d out of bounds", p, f);
            const uint8_t *fh = pkt + off;
            CHECK(fh[0] == kLdacSyncWord, "packet %zu frame %d sync word 0x%02x", p, f, fh[0]);
            int rid = fh[1] >> 5, cci = (fh[1] >> 3) & 3, flen = ((fh[1] & 7) << 6 | fh[2] >> 2) + 1;
            CHECK(rid == rate_id(c->rate), "packet %zu frame %d sample rate index %d", p, f, rid);
            CHECK(cci == channel_config_id(c->mode), "packet %zu frame %d channel config %d", p, f, cci);
            size_t frame_total = (size_t)flen + kLdacFrameHeaderSize;
            CHECK(off + frame_total <= len, "packet %zu frame %d length %zu runs past the end of the packet", p, f, frame_total);
            frame_bytes += frame_total;
            res.frames++;
            if (decodable) {
                uint8_t scratch[1100] = { 0 };  // the decoder's bit reader reads a few bytes past the end of the frame, pad with 0
                memcpy(scratch, fh, frame_total);
                int16_t out16[256 * 2];
                int used = 0;
                CHECK(ldacDecode(&decoder, scratch, out16, &used) == 0, "packet %zu frame %d decode failed", p, f);
                CHECK((size_t)used == frame_total, "packet %zu frame %d decode consumed %d bytes, frame length %zu", p, f, used, frame_total);
                CHECK(decoder.frame.frameSamples == expected_frame_samples, "decoded frame sample count %d", decoder.frame.frameSamples);
                for (int s = 0; s < expected_frame_samples && decoded + (size_t)s < max_out; s++) {
                    for (int ch = 0; ch < out_channels; ch++) dec[ch][decoded + (size_t)s] = out16[s * out_channels + ch] / 32768.0;
                }
            }
            decoded += (size_t)expected_frame_samples;
            off += frame_total;
        }
        CHECK(off == len, "packet %zu total frame length %zu ≠ payload %zu", p, off, len);
    }
    CHECK(ts_sum == decoded, "sum of timestamp steps %zu ≠ total frame samples %zu", ts_sum, decoded);
    res.kbps = frame_bytes * 8.0 / ((double)decoded / c->rate) / 1000.0;

    if (decodable) {
        size_t n_ref = calls * per_call;
        for (int ch = 0; ch < out_channels; ch++) ref[ch] = malloc(n_ref * sizeof(double));
        for (size_t n = 0; n < n_ref; n++) {
            if (out_channels == 1) {
                ref[0][n] = ((left[n] + right[n]) / 2) / 8388608.0;
            } else {
                ref[0][n] = left[n] / 8388608.0;
                ref[1][n] = right[n] / 8388608.0;
            }
        }
        res.delay = find_delay(ref, n_ref, dec, decoded, out_channels, c->rate);
        CHECK(res.delay >= 0, "no alignment found");
        size_t from = (size_t)c->rate / 2, to = decoded - (size_t)res.delay - (size_t)c->rate / 2;
        if (to > n_ref) to = n_ref;
        CHECK(to > from + (size_t)c->rate * 5, "too few samples to compare");
        for (int ch = 0; ch < out_channels; ch++) res.snr[ch] = snr_db(ref[ch], dec[ch], from, to, res.delay);
    }
    res.ok = true;

done:
    ldac_a2dp_close(codec);
    free(left);
    free(right);
    free(stream);
    free(lengths);
    free(pcm_frames);
    free(link);
    for (int ch = 0; ch < 2; ch++) {
        free(ref[ch]);
        free(dec[ch]);
    }
    return res;
}

// Minimum SNR per tier (dB). Observed 2026-10-13 (stereo, 44.1/48k | 88.2/96k): HQ 74 | 68, SQ 70 | 64, MQ 63 | 61, ABR 66 | 63; leaves 5 dB or more of margin
static double min_snr(int quality) { return quality == kLdacQualityHQ ? 62 : quality == kLdacQualitySQ ? 58 : 55; }

static void check_open_errors(void) {
    char error[256];
    struct { int rate, mode, quality; size_t max_payload; const char *what; } bad[] = {
        { 48000, kLdacChannelStereo, kLdacQualityHQ, 679 - 13, "MTU 678" },
        { 32000, kLdacChannelStereo, kLdacQualityHQ, 883, "32 kHz" },
        { 48000, kLdacChannelStereo | kLdacChannelDual, kLdacQualityHQ, 883, "two channel bits" },
        { 48000, kLdacChannelStereo, 3, 883, "quality 3" },
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        error[0] = 0;
        ldac_a2dp *codec = ldac_a2dp_open(bad[i].rate, bad[i].mode, bad[i].quality, bad[i].max_payload, error, sizeof(error));
        if (codec) {
            fprintf(stderr, "  FAIL: %s should not open\n", bad[i].what);
            failures++;
            ldac_a2dp_close(codec);
        } else {
            printf("  rejected %-10s → %s\n", bad[i].what, error);
        }
    }
}

int main(void) {
    static const int rates[] = { 44100, 48000, 88200, 96000 };
    static const int qualities[] = { kLdacQualityHQ, kLdacQualitySQ, kLdacQualityMQ, kLdacQualityABR };
    static const size_t payloads[] = { 895 - 12, 679 - 12 };
    printf("Parameter checks\n");
    check_open_errors();
    printf("\n%-6s %-6s %-4s %4s %4s %6s %5s %7s %7s %7s %7s %5s %8s\n", "rate", "mode", "q", "mtu", "dur", "pkts", "f/pkt",
           "kbps", "target", "snrL", "snrR", "delay", "ms/s");
    Case cases[49];
    size_t n_cases = 0;
    for (size_t r = 0; r < 4; r++)
        for (size_t q = 0; q < 4; q++)
            for (size_t m = 0; m < 2; m++)
                cases[n_cases++] = (Case){ rates[r], kLdacChannelStereo, qualities[q], payloads[m], kSeconds };
    cases[n_cases++] = (Case){ 48000, kLdacChannelMono, kLdacQualityHQ, 883, kSeconds };
    cases[n_cases++] = (Case){ 96000, kLdacChannelMono, kLdacQualitySQ, 883, kSeconds };
    cases[n_cases++] = (Case){ 48000, kLdacChannelDual, kLdacQualityHQ, 883, kSeconds };
    cases[n_cases++] = (Case){ 48000, kLdacChannelStereo, kLdacQualityABR, 883, 60 };  // see whether it steps back up after congestion
    cases[n_cases++] = (Case){ 96000, kLdacChannelStereo, kLdacQualityABR, 883, 180, 103 };  // link stuck between Q0 and SQ
    for (size_t i = 0; i < n_cases; i++) {
        const Case *c = &cases[i];
        Result res = run_case(c);
        if (!res.ok) {
            printf("%-6d %-6s %-4s %4zu  FAIL\n", c->rate, mode_name(c->mode), quality_name(c->quality), c->max_payload + 12);
            continue;
        }
        bool decodable = c->mode != kLdacChannelDual;
        printf("%-6d %-6s %-4s %4zu %3ds %6zu %5.2f %7.1f %7.0f", c->rate, mode_name(c->mode), quality_name(c->quality),
               c->max_payload + 12, c->seconds, res.packets, (double)res.frames / (double)res.packets, res.kbps, res.nominal_kbps);
        if (!decodable) printf(" %7s %7s %5s", "-", "-", "-");
        else if (c->mode == kLdacChannelMono) printf(" %7.1f %7s %5d", res.snr[0], "-", res.delay);
        else printf(" %7.1f %7.1f %5d", res.snr[0], res.snr[1], res.delay);
        printf(" %8.2f\n", res.ms_per_second);
        if (c->quality == kLdacQualityABR) {
            printf("       ABR bitrate changes %s; longest simulated queue %zu packets\n", res.abr_trace, res.max_queue);
            if (c->packet_cap > 0) {
                printf("       link %.0f packets/s: %d tier-ups; after 20 s fell below Q0 %d times, above Q0 for %.1f s in total\n", c->packet_cap, res.raises, res.dips,
                       res.above_seconds);
            }
        }

        // Verdict
        if (c->quality != kLdacQualityABR && fabs(res.kbps - res.nominal_kbps) > res.nominal_kbps * 0.01) {
            fprintf(stderr, "  FAIL: actual bitrate %.1f differs from target %.0f by more than 1%%\n", res.kbps, res.nominal_kbps);
            failures++;
        }
        if (decodable) {
            for (int ch = 0; ch < (c->mode == kLdacChannelMono ? 1 : 2); ch++) {
                if (!(res.snr[ch] >= min_snr(c->quality))) {
                    fprintf(stderr, "  FAIL: channel %d SNR %.1f dB below the %s tier minimum %.0f\n", ch, res.snr[ch], quality_name(c->quality),
                            min_snr(c->quality));
                    failures++;
                }
            }
        }
        if (c->quality == kLdacQualityABR) {
            // While the link is down to 450 kbps it should drop a tier and the queue must not run away; in the long case it should step back up after congestion
            int start_kbps = c->rate % 44100 == 0 ? 606 : 660;  // ABR starts at SQ
            if (res.min_kbps >= start_kbps) {
                fprintf(stderr, "  FAIL: ABR did not drop a tier\n");
                failures++;
            }
            if (c->packet_cap > 0) {
                // Link stuck between Q0 and SQ the whole time: it should stay at Q0, trying a tier-up now and then (tier-up backoff, see ldac_a2dp.h), never dropping lower
                int q0 = c->rate % 44100 == 0 ? 452 : 492;
                if (res.raises > 4 || res.dips > 0 || res.final_kbps != q0) {
                    fprintf(stderr, "  FAIL: %d tier-ups, fell below Q0 %d times, final %d kbps\n", res.raises, res.dips, res.final_kbps);
                    failures++;
                }
            } else if (c->seconds > kSeconds && res.final_kbps <= res.min_kbps) {
                fprintf(stderr, "  FAIL: %d s after congestion ended the bitrate is still %d\n", c->seconds - 6, res.final_kbps);
                failures++;
            }
            if (res.max_queue > 20) {
                fprintf(stderr, "  FAIL: longest simulated queue %zu packets\n", res.max_queue);
                failures++;
            }
        }
        if (res.ms_per_second > 500) {
            fprintf(stderr, "  FAIL: encoding 1 s of audio took %.1f ms\n", res.ms_per_second);
            failures++;
        }
    }
    printf("\n%s (%d failed)\n", failures ? "FAILED" : "ALL PASSED", failures);
    return failures ? 1 : 0;
}
