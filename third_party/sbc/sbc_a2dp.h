// sbc_a2dp: A2DP wrapper (encode + packetize) around the AOSP SBC encoder (Broadcom fixed-point implementation, encoder/),
// copied from Android's SBC source.
// Source abbreviations (AOSP packages/modules/Bluetooth main 745ee92, 2025-03-17; PipeWire master 7d6224c6; PulseAudio master 77d25a1e):
//   constants.h = AOSP system/stack/include/a2dp_sbc_constants.h
//   sbc.cc      = AOSP system/stack/a2dp/a2dp_sbc.cc
//   encoder.cc  = AOSP system/stack/a2dp/a2dp_sbc_encoder.cc
//   aact.cc     = AOSP system/bta/av/bta_av_aact.cc
//   pw-sbc.c    = PipeWire spa/plugins/bluez5/a2dp-codec-sbc.c (pw-caps.h, pw-sink.c = a2dp-codec-caps.h, media-sink.c in the same directory)
//   pa-codecs.h = PulseAudio src/modules/bluetooth/a2dp-codecs.h (pa-sbc.c = a2dp-codec-sbc.c in the same directory)
// encoder/ and decoder/ hold upstream code; line numbers refer to the commit in VERSION.
// Only one instance can be open at a time: the AOSP encoder keeps its analysis filter state in globals
// (encoder/srce/sbc_analysis.c L168-170, L971, sbc_encoder.c L31-35), so a second sbc_a2dp_open fails; to change the
// configuration, close first and then open again. An instance may only be used from one thread.
#ifndef SBC_A2DP_H
#define SBC_A2DP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Codec information element: the 4 bytes of the AVDTP Media Codec capability after LOSC(6), media type (0x00<<4) and
// codec type (0x00) (sbc.cc L155-165):
// [sample rate bits | channel mode bits] [block count bits | subband count bits | allocation method bits] [min bitpool] [max bitpool]
// A capability may set several bits per group; a configuration sets exactly 1 bit per group (sbc.cc L239-253). Bit values
// are in constants.h L36-63 (they match pw-caps.h L43-65, L358-367).
enum {
    kSbcInfoSize = 4,                // constants.h L33 A2DP_SBC_INFO_LEN=6, minus the media type and codec type bytes
    // Byte 0 high 4 bits: sample rate (constants.h L36-40)
    kSbcFreqMask = 0xF0,
    kSbcFreq16000 = 0x80,
    kSbcFreq32000 = 0x40,
    kSbcFreq44100 = 0x20,
    kSbcFreq48000 = 0x10,
    // Byte 0 low 4 bits: channel mode (constants.h L42-46)
    kSbcChannelMask = 0x0F,
    kSbcChannelMono = 0x08,
    kSbcChannelDual = 0x04,
    kSbcChannelStereo = 0x02,
    kSbcChannelJoint = 0x01,
    // Byte 1 high 4 bits: block count (constants.h L48-52)
    kSbcBlocksMask = 0xF0,
    kSbcBlocks4 = 0x80,
    kSbcBlocks8 = 0x40,
    kSbcBlocks12 = 0x20,
    kSbcBlocks16 = 0x10,
    // Byte 1 b3-b2: subband count (constants.h L54-56)
    kSbcSubbandsMask = 0x0C,
    kSbcSubbands4 = 0x08,
    kSbcSubbands8 = 0x04,
    // Byte 1 b1-b0: allocation method (constants.h L58-60)
    kSbcAllocationMask = 0x03,
    kSbcAllocationSNR = 0x02,
    kSbcAllocationLoudness = 0x01,
    // Bytes 2/3: valid bitpool range (constants.h L62-63). SBC itself also has an upper limit: 16×subbands for mono/dual
    // channel, 32×subbands for stereo/joint stereo (encoder/include/sbc_encoder.h L170-171); sbc_a2dp_open checks both
    kSbcMinBitpool = 2,
    kSbcMaxBitpool = 250,
};

// Recommended bitpools (8 subbands, 16 blocks, loudness allocation). Dual channel and mono bitpools are per channel, so dual
// channel at the same bitpool has roughly twice the bitrate.
enum {
    // Middle/high quality recommended by the A2DP spec (pa-codecs.h L59-71). Android as source uses 44.1k joint stereo with
    // max bitpool 53 (sbc.cc L50, L98-111); middle quality 35 is in constants.h L64
    kSbcBitpoolMQMono44100 = 19,
    kSbcBitpoolMQMono48000 = 18,
    kSbcBitpoolMQJoint44100 = 35,
    kSbcBitpoolMQJoint48000 = 33,
    kSbcBitpoolHQMono44100 = 31,
    kSbcBitpoolHQMono48000 = 29,
    kSbcBitpoolHQJoint44100 = 53,
    kSbcBitpoolHQJoint48000 = 51,
    // PipeWire's default upper limits for plain SBC (pw-sbc.c L69-103)
    kSbcBitpoolPWJoint44100 = 64,
    kSbcBitpoolPWJoint48000 = 58,
    // SBC XQ: dual channel (pw-sbc.c L128-133 prefers DUAL), per-channel bitpool. PipeWire's XQ values (pw-sbc.c L79-100)
    // equal the largest value PulseAudio xq_512kbps picks within ≤512 kbps (pa-sbc.c L304-339, L793-798), about 507/504 kbps
    kSbcBitpoolXQDual44100 = 43,
    kSbcBitpoolXQDual48000 = 39,
    // The commonly cited "SBC XQ 452 kbps" (44.1k dual channel 2×38): PulseAudio's xq_453kbps tier computes exactly 38 at
    // 44.1k (pa-sbc.c L785-790, L304-339; 34 at 48k)
    kSbcBitpoolXQ452Dual44100 = 38,
};

// Media packet = 12-byte RTP header + 1-byte SBC payload header + a number of complete SBC frames (frames never span packets).
// Payload header: bit7 F fragmented, bit6 S start, bit5 L last, bit4 reserved, bit3-0 frame count in this packet
// (constants.h L67-70; sbc.cc L265-282; pw rtp.h L39-45). Neither Android nor PipeWire fragments, so F/S/L are always 0
// and the low 4 bits = frame count (sbc.cc L659-677; pw-sbc.c L519, L542).
// Frames per packet = min(15, (max_payload − 1) / frame length) (encoder.cc L696-747, L498-499; pw-sbc.c L330-340),
// max_payload = outgoing L2CAP MTU − 12 (aact.cc L1172 stream_mtu = peer_mtu − AVDT_MEDIA_HDR_SIZE).
// RTP: V=2, PT=96, fixed SSRC (PipeWire uses 1, pw-sbc.c L517-524), sequence number incremented by 1 per packet.
// The RTP timestamp is clocked at the sample rate and starts at 0; each packet advances it by that packet's per-channel
// sample count = frames × blocks × subbands (encoder.cc L506-513; pw-sink.c L678, L816), i.e. by
// sbc_a2dp_pcm_frames_per_packet() per packet.
enum {
    kSbcRTPHeaderSize = 12,
    kSbcPayloadHeaderSize = 1,       // constants.h L30
    kSbcHeaderFragmented = 0x80,     // constants.h L67-70
    kSbcHeaderStart = 0x40,
    kSbcHeaderLast = 0x20,
    kSbcHeaderFrameCountMask = 0x0F,
    kSbcMaxFramesPerPacket = 15,     // the frame count field is 4 bits (encoder.cc L499 layer_specific < 0x0F; pw-sbc.c L337-338)
};

typedef struct {
    int sample_rate;   // 16000/32000/44100/48000
    int channel_mode;  // kSbcChannel* (channel mode bit from the configuration byte; exactly 1 bit set)
    int block_length;  // 4/8/12/16
    int subbands;      // 4/8
    int allocation;    // kSbcAllocationSNR / kSbcAllocationLoudness (allocation method bit from the configuration byte)
    int bitpool;       // bitpool actually used for encoding; must be within the negotiated [min, max]; per channel for mono/dual channel
} sbc_a2dp_config;

typedef struct sbc_a2dp sbc_a2dp;

// max_payload: bytes available after the RTP header (outgoing L2CAP MTU − 12). Must fit at least the 1-byte payload header
// + 1 frame (fragmentation is not implemented).
// On failure (invalid parameters, a frame does not fit, an instance already open) returns NULL and writes the reason to error.
sbc_a2dp *sbc_a2dp_open(const sbc_a2dp_config *config, size_t max_payload, char *error, size_t error_size);
// PCM frames to feed per sbc_a2dp_encode call = SBC frames per packet × blocks × subbands (each call produces exactly one
// media packet)
size_t sbc_a2dp_pcm_frames_per_packet(const sbc_a2dp *codec);
// Size of one SBC frame in bytes (every frame has the same length at a fixed bitpool)
size_t sbc_a2dp_frame_bytes(const sbc_a2dp *codec);
// SBC frame bitrate (kbps) = frame length × 8 × sample rate / (blocks × subbands) / 1000, excluding the payload header and
// RTP header
double sbc_a2dp_bitrate_kbps(const sbc_a2dp *codec);
// Changes the bitpool (used for adaptive bitrate while streaming); takes effect from the next frame. Only values at or below
// the bitpool used at open are allowed: frames per packet were computed at open and shorter frames still fit, and the
// number of PCM frames per call stays the same (PipeWire pw-sbc.c codec_set_bitpool recomputes frames per packet; we do
// not, so the streamer's PCM buffer does not have to change with it).
// The encoder reads the bitpool from the parameters every frame (encoder/srce/sbc_enc_bit_alloc_*.c, sbc_packing.c L91);
// the decoder derives the frame length from the bitpool in the frame header.
// Must not go below the minimum bitpool declared by the headphones (the caller ensures this). Returns 0 on success
int sbc_a2dp_set_bitpool(sbc_a2dp *codec, int bitpool);
// pcm24: pcm_frames_per_packet frames of 24-bit little-endian packed interleaved stereo (6 bytes per frame); a mono
// configuration feeds (L+R)/2 to the encoder.
// 24-bit samples are rounded to 16 bits (the encoder only accepts 16-bit input).
// Writes everything after the RTP header (1-byte payload header + SBC frames) to out and returns the length; <0 on error
// (reason written to error).
int sbc_a2dp_encode(sbc_a2dp *codec, const uint8_t *pcm24, uint8_t *out, size_t capacity, char *error,
                    size_t error_size);
void sbc_a2dp_close(sbc_a2dp *codec);
// For choosing a configuration: frame length (bytes) from the A2DP spec formula, matching BlueZ sbc_get_frame_length
// (rounded up):
//   mono/dual channel: 4 + 4×subbands×channels/8 + ⌈blocks×channels×bitpool/8⌉
//   stereo:            4 + 4×subbands×2/8        + ⌈blocks×bitpool/8⌉
//   joint stereo:      4 + 4×subbands×2/8        + ⌈(subbands + blocks×bitpool)/8⌉
// (encoder.cc L761-807 uses the same formula but rounds down; the two agree at 16 blocks, 8 subbands). Returns 0 for
// invalid fields (the bitpool upper limit is not checked).
size_t sbc_a2dp_frame_length(const sbc_a2dp_config *config);

#ifdef __cplusplus
}
#endif

#endif
