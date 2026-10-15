// ldac_a2dp: A2DP wrapper (encode + packetize + ABR) around Sony's libldac encoder, copied from Android's LDAC source.
// Source abbreviations (AOSP packages/modules/Bluetooth main 745ee92, 2025-03-17):
//   constants.h = system/stack/include/a2dp_vendor_ldac_constants.h
//   ldac.cc     = system/stack/a2dp/a2dp_vendor_ldac.cc
//   encoder.cc  = system/stack/a2dp/a2dp_vendor_ldac_encoder.cc
// libldac files (inc/ldacBT.h etc.) refer to the upstream code in this directory; line numbers refer to the commit in VERSION.
// Several instances may be open (the only global is the set of MDCT table pointers at src/tables_sigproc_ldac.c L22, and
// every open writes the same values); a single instance is not thread-safe and may only be used from one thread.
#ifndef LDAC_A2DP_H
#define LDAC_A2DP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Codec information element: the 8 bytes of the AVDTP Media Codec capability after LOSC(10), media type (0x00<<4) and
// codec type (0xFF):
// vendor ID (4, little-endian) | codec ID (2, little-endian) | sample rate bits (low 6 bits) | channel mode bits (low 3 bits)
// See ldac.cc L109-140 A2DP_BuildInfoLdac, L148-206 A2DP_ParseInfoLdac; inc/ldacBT.h L466-475.
// A capability may set several bits; a configuration sets exactly 1 bit each for sample rate and channel mode (ldac.cc L198-203).
enum {
    kLdacVendorID = 0x0000012D,      // constants.h L44 (Sony)
    kLdacCodecID = 0x00AA,           // constants.h L46
    kLdacInfoSize = 8,               // constants.h L42 A2DP_LDAC_CODEC_LEN=10, minus the media type and codec type bytes
    kLdacInfoFreqIndex = 6,          // index into the 8 bytes above
    kLdacInfoChannelIndex = 7,
    // Sample rate bits: constants.h L48-54 (same as inc/ldacBT.h L506-516). 176.4k/192k have bit definitions, but the
    // libldac encoder does not support them
    kLdacFreqMask = 0x3F,
    kLdacFreq44100 = 0x20,
    kLdacFreq48000 = 0x10,
    kLdacFreq88200 = 0x08,
    kLdacFreq96000 = 0x04,
    kLdacFreq176400 = 0x02,
    kLdacFreq192000 = 0x01,
    // Channel mode bits: constants.h L56-59 (same as inc/ldacBT.h L531-535). Android as source only advertises DUAL|STEREO
    // (ldac.cc L67)
    kLdacChannelMask = 0x07,
    kLdacChannelMono = 0x04,
    kLdacChannelDual = 0x02,
    kLdacChannelStereo = 0x01,
};

// Media packet = 12-byte RTP header + 1-byte LDAC payload header + a number of complete LDAC frames (frames never span packets).
// Payload header: bit7 F fragmented, bit6 S start, bit5 L last, bit3-0 frame count in this packet (constants.h L33-39;
// ldac.cc L215-232). Android never fragments, so F/S/L are always 0 and the low 4 bits = frame count in this packet
// (ldac.cc L464; the count comes from out_frames accumulated at encoder.cc L472).
// No SCMS-T byte is added (encoder.cc L162 use_SCMS_T = false).
enum {
    kLdacRTPHeaderSize = 12,
    kLdacPayloadHeaderSize = 1,      // constants.h L33
    kLdacHeaderFragmented = 0x80,    // constants.h L36-39
    kLdacHeaderStart = 0x40,
    kLdacHeaderLast = 0x20,
    kLdacHeaderFrameCountMask = 0x0F,
    // LDAC frame header, 3 bytes: sync word 0xAA(8) sample rate index(3) channel config index(2) frame length−1(9)
    // frame status(2) (src/ldaclib.h L29, src/ldac.h L31-58); total frame size = frame length + 3
    kLdacFrameHeaderSize = 3,
    kLdacSyncWord = 0xAA,
    // Minimum outgoing L2CAP MTU is 679 (2-DH5, src/ldacBT_internal.h L56); LDAC frames in a packet take at most
    // 679−18 = 661 bytes (src/ldacBT_api.c L165-174: packed this way however large the MTU is, so the payload is at most 662 bytes)
    kLdacMinL2CAPMTU = 679,
    kLdacMaxPayload = 662,
};

// Quality tiers (inc/ldacBT.h L120-145; encoder.cc L230-266)
enum {
    kLdacQualityHQ = 0,    // 990 kbps (909 at 44.1k/88.2k)
    kLdacQualitySQ = 1,    // 660 (606)
    kLdacQualityMQ = 2,    // 330 (303)
    kLdacQualityABR = -1,  // adaptive: switches among 990/660/492/396/330 (909/606/452/363/303 for the 44.1k family), starting at SQ
};

typedef struct ldac_a2dp ldac_a2dp;

// sample_rate: 44100/48000/88200/96000.
// channel_mode: channel mode bit from the A2DP configuration byte (kLdacChannel*). Input is always interleaved stereo; for
// MONO this wrapper feeds (L+R)/2 to the encoder.
// quality: kLdacQuality*.
// max_payload: bytes available after the RTP header (outgoing L2CAP MTU − 12). LDAC requires MTU ≥ 679, i.e.
// max_payload ≥ 667, otherwise open fails.
// Returns NULL on failure and writes the reason to error.
ldac_a2dp *ldac_a2dp_open(int sample_rate, int channel_mode, int quality, size_t max_payload, char *error, size_t error_size);
// PCM frames to feed per ldac_a2dp_encode call: 128 at every sample rate (LDACBT_ENC_LSU, inc/ldacBT.h L93; encoder.cc L515-516).
// At 88.2k/96k an LDAC frame is 256 samples, so then it takes two calls to produce one frame.
size_t ldac_a2dp_frames_per_call(const ldac_a2dp *codec);
// pcm24: frames_per_call frames of 24-bit little-endian packed interleaved stereo (6 bytes per frame).
// Once a packet is complete, writes everything after the RTP header (1-byte payload header + LDAC frames) to out and returns
// the length (≤ kLdacMaxPayload); *packet_pcm_frames receives the per-channel sample count this packet represents =
// frames × samples per frame (128; 256 at 88.2k/96k).
// The RTP timestamp is clocked at the sample rate (Android starts at 0) and advances by the packet's packet_pcm_frames for
// every packet sent (encoder.cc L489-496).
// At most one packet per call; returns 0 if a packet is not complete yet; <0 on error (reason written to error; reopen afterwards).
// After a frame is encoded, if another frame of the same size would not fit, the packet is emitted immediately
// (src/ldacBT_api.c L604-622) without holding back an extra packet.
int ldac_a2dp_encode(ldac_a2dp *codec, const uint8_t *pcm24, uint8_t *out, size_t capacity, size_t *packet_pcm_frames,
                     char *error, size_t error_size);
// ABR only: reports the number of media packets in our send queue that have not gone out yet; call once before each encode
// (only the latest value is kept).
// encode calls ldac_ABR_Proc with the latest value every 20 ms of PCM duration, the same as Android calling it once at the
// start of each 20 ms encode tick (encoder.cc L56, L248, L351-357). Android reports the packets in the btif send queue not
// yet handed to L2CAP (btif_a2dp_source.cc L946-953); we should likewise count only packets not yet handed off: the
// thresholds are low, and 3 or more packets constantly sitting in the queue keep it below SQ all the time.
// Default thresholds (abr/src/ldacBT_abr.c L39-41, L212-269): ≥6 packets drops one tier (two from HQ/SQ); >4 and more than
// last time drops one tier; >2 at HQ/SQ drops one tier; a 0.5 s average >1.5 drops one tier; it steps up one tier only after
// the queue stays completely empty for 2-6 s (longer at higher bitrates, multiplied by up to 4 after consecutive drops);
// observed recovery from 330 back to 990 after congestion ends takes about 27 s. No effect when not in ABR mode.
void ldac_a2dp_set_queue_depth(ldac_a2dp *codec, int depth);
// Current target bitrate (kbps, including the LDAC frame header, excluding the payload header and RTP header); changes as
// soon as ABR switches tier, while the actual frame length switches by the next packet at the latest.
int ldac_a2dp_bitrate_kbps(const ldac_a2dp *codec);

// ABR step-up backoff (our addition; Android does not have it). When link throughput is stuck between two tiers, libldac's
// ABR tries to step up one tier every 8–16 s and drops back a fraction of a second later (observed 2026-10-13
// Mac → WH-1000XM4: ceiling about 103 packets/s, bouncing between 492↔660); every attempt builds up a chunk of audio in
// the send queue, the headphones' buffer runs dry and audio stutters, and the fallback often drops further to 396/330.
// Rule: dropping back within 3 s of a step-up means that tier cannot hold, so block it (and every tier above it) for 30 s;
// each further failure doubles the block time, up to 300 s; holding steady for 30 s at the failed tier or higher means the
// link has improved and the backoff resets (falling down and climbing back to the original tier does not count).
// While blocked, an ABR step-up is pulled back within the same tick, so no high-bitrate packet is actually encoded.
// Opening the stream also counts as an attempt: a tier drop within the first 3 s blocks the starting tier the same way.
// Time is measured in encoded audio duration.
typedef struct {
    int ceiling;       // highest allowed tier (ordered by bitrate: 0 HQ, 1 SQ, 2 Q0, 3 Q1, 4 MQ); < 0 means no limit
    double remaining;  // seconds left to block
    double backoff;    // seconds to block on the next failure; 0 means use the initial value
    int failed_rank;   // tier of the most recent failed step-up; < 0 means none
} ldac_abr_guard;

// Get / set the backoff state, used to carry it across encoder instances (a new stream continues from the previous
// stream's conclusion and starts below the blocked tier). No effect when not in ABR mode
void ldac_a2dp_get_abr_guard(const ldac_a2dp *codec, ldac_abr_guard *guard);
void ldac_a2dp_set_abr_guard(ldac_a2dp *codec, const ldac_abr_guard *guard);
// Whether the last encode blocked a tier because a step-up failed: if so returns 1 and gives the blocked bitrate (kbps) and
// the block duration in seconds; cleared once read
int ldac_a2dp_take_abr_block(ldac_a2dp *codec, int *blocked_kbps, double *seconds);
void ldac_a2dp_close(ldac_a2dp *codec);

#ifdef __cplusplus
}
#endif

#endif
