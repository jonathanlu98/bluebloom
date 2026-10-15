// Source abbreviations used in comments (encoder.cc, ldac.cc, constants.h) are listed at the top of ldac_a2dp.h
#include "ldac_a2dp.h"

#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ldacBT.h"
#include "ldacBT_abr.h"
#include "src/ldacBT_ex.h"  // LDACBT_EQMID_Q0/Q1: the two tiers only ABR switches to

// ABR tick: Android's encode timer ticks every 20 ms, and ldac_ABR_Init is passed 20 as well (encoder.cc L56, L248)
static const unsigned kAbrIntervalMs = 20;
// ldac_ABR_Proc stores the queue depth in an unsigned char history but accumulates the original value
// (abr/src/ldacBT_abr.c L197-201); above 255 the sliding sum goes out of sync
static const int kAbrMaxQueueDepth = 255;
// Step-up backoff (see ldac_abr_guard in ldac_a2dp.h)
static const double kProbeFailSeconds = 3;
static const double kProbeHoldSeconds = 30;
static const double kBackoffInitial = 30;
static const double kBackoffMax = 300;

static int rank_of(int eqmid);

struct ldac_a2dp {
    HANDLE_LDAC_BT bt;
    HANDLE_LDAC_ABR abr;  // only present in ABR mode
    int sample_rate;
    int channel_mode;
    size_t frame_samples;  // per-channel samples per LDAC frame
    unsigned queue_depth;
    size_t abr_interval_frames, abr_elapsed_frames;
    double clock;              // encoded audio duration (seconds)
    int ceiling;               // step-up backoff, see ldac_abr_guard
    double ceiling_until, backoff;
    int probe_rank;            // tier being tried (-1 none)
    double probe_start;
    int failed_rank;           // tier of the most recent failed step-up (-1 none): only holding steady at it or a higher tier
                               // counts as the link improving and resets the backoff
    int last_rank;
    int blocked_kbps;          // tier just blocked, for ldac_a2dp_take_abr_block
    double blocked_seconds;
    uint8_t mono[LDACBT_ENC_LSU * 3];
    uint8_t stream[LDACBT_MAX_NBYTES];
};

static void fail(char *error, size_t error_size, const char *format, ...) {
    if (!error || error_size == 0) return;
    va_list args;
    va_start(args, format);
    vsnprintf(error, error_size, format, args);
    va_end(args);
}

static void fail_ldac(char *error, size_t error_size, const char *what, HANDLE_LDAC_BT bt) {
    int code = ldacBT_get_error_code(bt);
    fail(error, error_size, "%s (LDAC error code api=%d handle=%d block=%d)", what, LDACBT_API_ERR(code),
         LDACBT_HANDLE_ERR(code), LDACBT_BLOCK_ERR(code));
}

ldac_a2dp *ldac_a2dp_open(int sample_rate, int channel_mode, int quality, size_t max_payload, char *error,
                          size_t error_size) {
    // LDAC frame length: 128 samples at 44.1k/48k, 256 at 88.2k/96k (inc/ldacBT.h L78-91; encoder.cc L411-425)
    size_t frame_samples;
    switch (sample_rate) {
        case 44100:
        case 48000:
            frame_samples = 128;
            break;
        case 88200:
        case 96000:
            frame_samples = 256;
            break;
        default:
            fail(error, error_size, "LDAC does not support sample rate %d (only 44.1/48/88.2/96 kHz)", sample_rate);
            return NULL;
    }
    if (channel_mode != kLdacChannelStereo && channel_mode != kLdacChannelDual && channel_mode != kLdacChannelMono) {
        fail(error, error_size, "Invalid LDAC channel mode 0x%02x (a configuration must set exactly 1 bit)", channel_mode);
        return NULL;
    }
    if (quality < kLdacQualityABR || quality > kLdacQualityMQ) {
        fail(error, error_size, "Invalid LDAC quality tier %d", quality);
        return NULL;
    }
    // The MTU Android passes to ldacBT_init_handle_encode is the outgoing L2CAP MTU: TxAaMtuSize + AVDT_MEDIA_HDR_SIZE(12)
    // (encoder.cc L295-298), TxAaMtuSize = min(buffer limit ~4000, stream_mtu), stream_mtu = L2CAP MTU − 12
    // (encoder.cc L540-547, system/bta/av/bta_av_aact.cc L1172). libldac only checks that it is ≥ 679 (src/ldacBT_internal.c L189-195)
    size_t mtu = max_payload > 0xFFFF ? 0xFFFF : max_payload + kLdacRTPHeaderSize;
    if (mtu < (size_t)kLdacMinL2CAPMTU) {
        fail(error, error_size, "L2CAP MTU %zu is below the %d that LDAC requires", mtu, kLdacMinL2CAPMTU);
        return NULL;
    }

    ldac_a2dp *codec = calloc(1, sizeof(*codec));
    if (!codec) {
        fail(error, error_size, "Out of memory");
        return NULL;
    }
    codec->sample_rate = sample_rate;
    codec->channel_mode = channel_mode;
    codec->frame_samples = frame_samples;
    codec->bt = ldacBT_get_handle();
    if (!codec->bt) {
        fail(error, error_size, "ldacBT_get_handle failed");
        free(codec);
        return NULL;
    }
    // ABR starts at SQ, like Android and PipeWire (encoder.cc L53). It used to start at HQ; observed (2026-10-13 20:12:22,
    // WH-1000XM4, link about 103 packets/s) it fell from 990 all the way to 330 within 0.3 s of opening the stream and only
    // got back to 492 after 20 s; on a good link, stepping up from SQ to HQ takes only a few seconds
    int eqmid = quality == kLdacQualityABR ? LDACBT_EQMID_SQ : quality;
    if (ldacBT_init_handle_encode(codec->bt, (int)mtu, eqmid, channel_mode, LDACBT_SMPL_FMT_S24, sample_rate) != 0) {
        fail_ldac(error, error_size, "ldacBT_init_handle_encode failed", codec->bt);
        ldac_a2dp_close(codec);
        return NULL;
    }
    if (quality == kLdacQualityABR) {
        // Same as Android: default thresholds, ldac_ABR_set_thresholds is not called (encoder.cc L243-248).
        codec->abr = ldac_ABR_get_handle();
        if (!codec->abr || ldac_ABR_Init(codec->abr, kAbrIntervalMs) != 0) {
            fail(error, error_size, "LDAC ABR initialization failed");
            ldac_a2dp_close(codec);
            return NULL;
        }
        codec->abr_interval_frames = (size_t)sample_rate * kAbrIntervalMs / 1000;
        codec->abr_elapsed_frames = codec->abr_interval_frames;  // run once on the first tick, as Android does
        codec->ceiling = -1;
        codec->backoff = kBackoffInitial;
        codec->failed_rank = -1;
        codec->last_rank = rank_of(eqmid);
        codec->probe_rank = codec->last_rank;  // opening the stream also counts as an attempt
        codec->probe_start = 0;
    }
    return codec;
}

size_t ldac_a2dp_frames_per_call(const ldac_a2dp *codec) {
    (void)codec;
    return LDACBT_ENC_LSU;
}

// EQMID → tier index ordered by bitrate (0 HQ 990, 1 SQ 660, 2 Q0 492, 3 Q1 396, 4 MQ 330; src/ldacBT_ex.h L22-25)
static int rank_of(int eqmid) {
    switch (eqmid) {
        case LDACBT_EQMID_HQ: return 0;
        case LDACBT_EQMID_SQ: return 1;
        case LDACBT_EQMID_Q0: return 2;
        case LDACBT_EQMID_Q1: return 3;
        case LDACBT_EQMID_MQ: return 4;
        default: return -1;
    }
}

static int current_rank(const ldac_a2dp *codec) {
    return rank_of(ldacBT_get_eqmid(codec->bt));
}

// When the current tier is above the highest allowed tier, pull it down (one tier per step, in bitrate order, through the
// same interface ABR uses to step down)
static int clamp_to_ceiling(ldac_a2dp *codec) {
    int rank = current_rank(codec);
    while (rank >= 0 && rank < codec->ceiling && ldacBT_alter_eqmid_priority(codec->bt, LDACBT_EQMID_INC_CONNECTION) == 0) {
        rank = current_rank(codec);
    }
    return rank;
}

// After each ldac_ABR_Proc: while blocked, do not allow stepping above the ceiling; if a step-up drops back soon, block that
// tier; once stable, reset the backoff
static void guard_after_abr(ldac_a2dp *codec) {
    int rank = current_rank(codec);
    if (rank < 0) return;
    double now = codec->clock;
    bool blocking = codec->ceiling >= 0 && now < codec->ceiling_until;
    if (!blocking) codec->ceiling = -1;
    if (rank < codec->last_rank) {
        if (blocking && rank < codec->ceiling) {
            rank = clamp_to_ceiling(codec);
        } else {
            codec->probe_rank = rank;
            codec->probe_start = now;
        }
    } else if (rank > codec->last_rank) {
        if (codec->probe_rank >= 0 && rank > codec->probe_rank && now - codec->probe_start < kProbeFailSeconds) {
            int probed = codec->probe_rank;
            codec->failed_rank = probed;
            codec->ceiling = probed + 1;
            codec->ceiling_until = now + codec->backoff;
            // Bitrate of the blocked tier: working back from the current tier is awkward, so compute it directly from the
            // frame length table (see ldac_a2dp_bitrate_kbps)
            static const int kRankToEqmid[] = { LDACBT_EQMID_HQ, LDACBT_EQMID_SQ, LDACBT_EQMID_Q0, LDACBT_EQMID_Q1, LDACBT_EQMID_MQ };
            static const int kFrameBytesPerChannel[] = { 165, 110, 55, 82, 66 };  // indexed by EQMID, same as ldac_a2dp_bitrate_kbps
            int channels = codec->channel_mode == kLdacChannelMono ? 1 : 2;
            codec->blocked_kbps = channels * kFrameBytesPerChannel[kRankToEqmid[probed]] * codec->sample_rate /
                                  (int)codec->frame_samples / (1000 / 8);
            codec->blocked_seconds = codec->backoff;
            codec->backoff = codec->backoff * 2 > kBackoffMax ? kBackoffMax : codec->backoff * 2;
        }
        codec->probe_rank = -1;
    }
    if (codec->probe_rank >= 0 && now - codec->probe_start >= kProbeHoldSeconds) {
        // Observed (2026-10-13 20:09:29–20:10:27): after the attempt at 660 failed it fell to 396, then came back to 492 and
        // held for 30 s; that does not show 660 can hold, so do not reset
        if (codec->failed_rank < 0 || codec->probe_rank <= codec->failed_rank) {
            codec->backoff = kBackoffInitial;
            codec->failed_rank = -1;
        }
        codec->probe_rank = -1;
    }
    codec->last_rank = rank;
}

void ldac_a2dp_get_abr_guard(const ldac_a2dp *codec, ldac_abr_guard *guard) {
    bool blocking = codec->abr && codec->ceiling >= 0 && codec->clock < codec->ceiling_until;
    guard->ceiling = blocking ? codec->ceiling : -1;
    guard->remaining = blocking ? codec->ceiling_until - codec->clock : 0;
    guard->backoff = codec->abr ? codec->backoff : 0;
    guard->failed_rank = codec->abr ? codec->failed_rank : -1;
}

void ldac_a2dp_set_abr_guard(ldac_a2dp *codec, const ldac_abr_guard *guard) {
    if (!codec->abr) return;
    codec->backoff = guard->backoff > 0 ? guard->backoff : kBackoffInitial;
    codec->failed_rank = guard->backoff > 0 ? guard->failed_rank : -1;
    if (guard->ceiling < 0 || guard->remaining <= 0) return;
    codec->ceiling = guard->ceiling;
    codec->ceiling_until = codec->clock + guard->remaining;
    // Start below the blocked tier; the start no longer counts as an attempt
    codec->last_rank = clamp_to_ceiling(codec);
    codec->probe_rank = -1;
}

int ldac_a2dp_take_abr_block(ldac_a2dp *codec, int *blocked_kbps, double *seconds) {
    if (!codec->blocked_kbps) return 0;
    if (blocked_kbps) *blocked_kbps = codec->blocked_kbps;
    if (seconds) *seconds = codec->blocked_seconds;
    codec->blocked_kbps = 0;
    return 1;
}

static int32_t read_s24(const uint8_t *p) {
    return (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8;
}

int ldac_a2dp_encode(ldac_a2dp *codec, const uint8_t *pcm24, uint8_t *out, size_t capacity, size_t *packet_pcm_frames,
                     char *error, size_t error_size) {
    if (packet_pcm_frames) *packet_pcm_frames = 0;
    if (codec->abr) {
        if (codec->abr_elapsed_frames >= codec->abr_interval_frames) {
            codec->abr_elapsed_frames -= codec->abr_interval_frames;
            // flagEnable=1: allow ABR to change tier (encoder.cc L353-357)
            if (ldac_ABR_Proc(codec->bt, codec->abr, codec->queue_depth, 1) < 0) {
                fail_ldac(error, error_size, "ldac_ABR_Proc failed", codec->bt);
                return -1;
            }
            guard_after_abr(codec);
        }
        codec->abr_elapsed_frames += LDACBT_ENC_LSU;
        codec->clock += (double)LDACBT_ENC_LSU / codec->sample_rate;
    }

    const uint8_t *input = pcm24;
    if (codec->channel_mode == kLdacChannelMono) {
        // In mono the encoder wants 1-channel input (src/ldacBT_api.c L176-181); use (L+R)/2 here
        for (size_t i = 0; i < LDACBT_ENC_LSU; i++) {
            int32_t m = (read_s24(pcm24 + 6 * i) + read_s24(pcm24 + 6 * i + 3)) / 2;
            codec->mono[3 * i] = (uint8_t)m;
            codec->mono[3 * i + 1] = (uint8_t)(m >> 8);
            codec->mono[3 * i + 2] = (uint8_t)(m >> 16);
        }
        input = codec->mono;
    }

    int used = 0, written = 0, frames = 0;
    // Each call feeds LDACBT_ENC_LSU frames; the output is a number of LDAC frames, each with a 3-byte frame header
    // (encoder.cc L455-457)
    if (ldacBT_encode(codec->bt, (void *)input, &used, codec->stream, &written, &frames) != 0) {
        fail_ldac(error, error_size, "ldacBT_encode failed", codec->bt);
        return -1;
    }
    if (used <= 0) {
        // Only happens when the internal PCM ring buffer is full after a previous encode failure (src/ldacBT_api.c L407-411)
        fail(error, error_size, "LDAC encoder did not accept the PCM and needs to be reopened");
        return -1;
    }
    if (written <= 0) return 0;
    if (frames <= 0 || frames > (int)kLdacHeaderFrameCountMask) {
        fail(error, error_size, "Unexpected LDAC packet frame count: %d", frames);
        return -1;
    }
    size_t length = kLdacPayloadHeaderSize + (size_t)written;
    if (length > capacity) {
        fail(error, error_size, "LDAC packet is %zu bytes, but the output buffer is only %zu", length, capacity);
        return -1;
    }
    out[0] = (uint8_t)(frames & kLdacHeaderFrameCountMask);  // F/S/L = 0 (ldac.cc L464)
    memcpy(out + kLdacPayloadHeaderSize, codec->stream, (size_t)written);
    // RTP timestamp step = frames × samples per frame (encoder.cc L494-496)
    if (packet_pcm_frames) *packet_pcm_frames = (size_t)frames * codec->frame_samples;
    return (int)length;
}

void ldac_a2dp_set_queue_depth(ldac_a2dp *codec, int depth) {
    codec->queue_depth = depth < 0 ? 0 : depth > kAbrMaxQueueDepth ? kAbrMaxQueueDepth : (unsigned)depth;
}

int ldac_a2dp_bitrate_kbps(const ldac_a2dp *codec) {
    // Tier → frame bytes per channel (including the frame header): src/ldacBT_internal.c L29-44 (tier → 2-DH5 configuration),
    // L49-69 (frmlen_1ch). Indexed by EQMID: 0 HQ, 1 SQ, 2 MQ, 3 Q0, 4 Q1 (Q0/Q1 are only used by ABR, src/ldacBT_ex.h L22-25)
    static const int kFrameBytesPerChannel[] = { 165, 110, 55, 82, 66 };
    int eqmid = ldacBT_get_eqmid(codec->bt);
    if (eqmid < 0 || eqmid >= (int)(sizeof(kFrameBytesPerChannel) / sizeof(kFrameBytesPerChannel[0]))) {
        return ldacBT_get_bitrate(codec->bt);
    }
    int channels = codec->channel_mode == kLdacChannelMono ? 1 : 2;
    // Same as ldacBT_frmlen_to_bitrate (src/ldacBT_internal.c L420-431)
    return channels * kFrameBytesPerChannel[eqmid] * codec->sample_rate / (int)codec->frame_samples / (1000 / 8);
}

void ldac_a2dp_close(ldac_a2dp *codec) {
    if (!codec) return;
    if (codec->abr) ldac_ABR_free_handle(codec->abr);
    if (codec->bt) ldacBT_free_handle(codec->bt);
    free(codec);
}
