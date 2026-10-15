#include "sbc_a2dp.h"

#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sbc_encoder.h"

// SBC_Encode returns the frame length as "bytes written"; the longest frame is 524 bytes (dual channel, 8 subbands,
// 16 blocks, bitpool 128); leave plenty of headroom
enum { kScratchBytes = 1024 };

// The encoder's analysis filter state is global (see the header); this flag ensures only one instance exists at a time
static atomic_flag gInUse = ATOMIC_FLAG_INIT;

struct sbc_a2dp {
    SBC_ENC_PARAMS params;
    sbc_a2dp_config config;
    int channels;
    size_t frame_bytes;        // bytes per SBC frame
    size_t frame_samples;      // per-channel samples per SBC frame = blocks × subbands
    size_t frames_per_packet;  // SBC frames per packet (computed from the bitpool at open)
    int open_bitpool;          // bitpool at open: the upper limit for sbc_a2dp_set_bitpool
    int16_t pcm[SBC_MAX_NUM_OF_BLOCKS * SBC_MAX_NUM_OF_SUBBANDS * SBC_MAX_NUM_OF_CHANNELS];
    uint8_t frame[kScratchBytes];
};

static void fail(char *error, size_t error_size, const char *format, ...) {
    if (!error || error_size == 0) return;
    va_list args;
    va_start(args, format);
    vsnprintf(error, error_size, format, args);
    va_end(args);
}

// Channel mode bit from the configuration byte → channel count; 0 if invalid
static int channel_count(int channel_mode) {
    switch (channel_mode) {
        case kSbcChannelMono:
            return 1;
        case kSbcChannelDual:
        case kSbcChannelStereo:
        case kSbcChannelJoint:
            return 2;
        default:
            return 0;
    }
}

size_t sbc_a2dp_frame_length(const sbc_a2dp_config *config) {
    if (!config) return 0;
    int channels = channel_count(config->channel_mode);
    int sb = config->subbands, blocks = config->block_length, bitpool = config->bitpool;
    if (!channels || (sb != 4 && sb != 8) || (blocks != 4 && blocks != 8 && blocks != 12 && blocks != 16) ||
        bitpool < 0) {
        return 0;
    }
    size_t length = 4 + (size_t)(4 * sb * channels) / 8;
    switch (config->channel_mode) {
        case kSbcChannelMono:
        case kSbcChannelDual:
            return length + ((size_t)blocks * channels * bitpool + 7) / 8;
        case kSbcChannelStereo:
            return length + ((size_t)blocks * bitpool + 7) / 8;
        default:  // joint stereo: 1 join flag bit per subband
            return length + ((size_t)sb + (size_t)blocks * bitpool + 7) / 8;
    }
}

sbc_a2dp *sbc_a2dp_open(const sbc_a2dp_config *config, size_t max_payload, char *error, size_t error_size) {
    if (!config) {
        fail(error, error_size, "SBC configuration is null");
        return NULL;
    }
    // Encoder parameters use the codes from encoder/include/sbc_encoder.h L46-60 (the same codes as in the SBC frame header)
    int16_t freq_code;
    switch (config->sample_rate) {
        case 16000: freq_code = SBC_sf16000; break;
        case 32000: freq_code = SBC_sf32000; break;
        case 44100: freq_code = SBC_sf44100; break;
        case 48000: freq_code = SBC_sf48000; break;
        default:
            fail(error, error_size, "SBC does not support sample rate %d (only 16/32/44.1/48 kHz)", config->sample_rate);
            return NULL;
    }
    int16_t mode_code;
    switch (config->channel_mode) {
        case kSbcChannelMono: mode_code = SBC_MONO; break;
        case kSbcChannelDual: mode_code = SBC_DUAL; break;
        case kSbcChannelStereo: mode_code = SBC_STEREO; break;
        case kSbcChannelJoint: mode_code = SBC_JOINT_STEREO; break;
        default:
            fail(error, error_size, "Invalid SBC channel mode 0x%02x (a configuration must set exactly 1 bit)", config->channel_mode);
            return NULL;
    }
    int16_t alloc_code;
    switch (config->allocation) {
        case kSbcAllocationLoudness: alloc_code = SBC_LOUDNESS; break;
        case kSbcAllocationSNR: alloc_code = SBC_SNR; break;
        default:
            fail(error, error_size, "Invalid SBC allocation method 0x%02x (a configuration must set exactly 1 bit)", config->allocation);
            return NULL;
    }
    int sb = config->subbands, blocks = config->block_length;
    if (sb != 4 && sb != 8) {
        fail(error, error_size, "Invalid SBC subband count %d (must be 4 or 8)", sb);
        return NULL;
    }
    if (blocks != 4 && blocks != 8 && blocks != 12 && blocks != 16) {
        fail(error, error_size, "Invalid SBC block count %d (must be 4/8/12/16)", blocks);
        return NULL;
    }
    int channels = channel_count(config->channel_mode);
    int per_channel = config->channel_mode == kSbcChannelMono || config->channel_mode == kSbcChannelDual;
    int max_bitpool = (per_channel ? 16 : 32) * sb;
    if (max_bitpool > kSbcMaxBitpool) max_bitpool = kSbcMaxBitpool;
    if (config->bitpool < kSbcMinBitpool || config->bitpool > max_bitpool) {
        fail(error, error_size, "SBC bitpool %d out of range [%d, %d]", config->bitpool, kSbcMinBitpool, max_bitpool);
        return NULL;
    }
    size_t frame_bytes = sbc_a2dp_frame_length(config);
    size_t frames = max_payload > kSbcPayloadHeaderSize ? (max_payload - kSbcPayloadHeaderSize) / frame_bytes : 0;
    if (frames > kSbcMaxFramesPerPacket) frames = kSbcMaxFramesPerPacket;
    if (frames == 0) {
        fail(error, error_size, "A %zu-byte SBC frame does not fit in a %zu-byte payload (fragmentation not supported)", frame_bytes, max_payload);
        return NULL;
    }
    if (atomic_flag_test_and_set(&gInUse)) {
        fail(error, error_size, "An SBC encoder is already in use (the AOSP encoder state is global, so only one can be open)");
        return NULL;
    }
    sbc_a2dp *codec = calloc(1, sizeof(*codec));
    if (!codec) {
        atomic_flag_clear(&gInUse);
        fail(error, error_size, "Out of memory");
        return NULL;
    }
    codec->config = *config;
    codec->channels = channels;
    codec->frame_bytes = frame_bytes;
    codec->frame_samples = (size_t)blocks * sb;
    codec->frames_per_packet = frames;
    codec->open_bitpool = config->bitpool;

    SBC_ENC_PARAMS *p = &codec->params;
    p->s16SamplingFreq = freq_code;
    p->s16ChannelMode = mode_code;
    p->s16NumOfSubBands = (int16_t)sb;
    p->s16NumOfBlocks = (int16_t)blocks;
    p->s16AllocationMethod = alloc_code;
    p->Format = SBC_FORMAT_GENERAL;
    p->u16BitRate = (uint16_t)lround(sbc_a2dp_bitrate_kbps(codec));
    // SBC_Encoder_Init recomputes the bitpool from u16BitRate (encoder/srce/sbc_encoder.c L196-248) and clears the filter
    // state. Android sets u16BitRate first and then calls Init, letting Init pick the bitpool (encoder.cc L227-312); we want
    // an exact bitpool, so we write it directly after Init (EncPacking reads it from here every frame)
    SBC_Encoder_Init(p);
    p->s16BitPool = (int16_t)config->bitpool;
    return codec;
}

size_t sbc_a2dp_pcm_frames_per_packet(const sbc_a2dp *codec) {
    return codec ? codec->frames_per_packet * codec->frame_samples : 0;
}

size_t sbc_a2dp_frame_bytes(const sbc_a2dp *codec) { return codec ? codec->frame_bytes : 0; }

double sbc_a2dp_bitrate_kbps(const sbc_a2dp *codec) {
    if (!codec) return 0;
    return (double)codec->frame_bytes * 8 * codec->config.sample_rate / (double)codec->frame_samples / 1000;
}

int sbc_a2dp_set_bitpool(sbc_a2dp *codec, int bitpool) {
    if (!codec || bitpool < kSbcMinBitpool || bitpool > codec->open_bitpool) return -1;
    codec->config.bitpool = bitpool;
    codec->params.s16BitPool = (int16_t)bitpool;
    codec->frame_bytes = sbc_a2dp_frame_length(&codec->config);
    return 0;
}

// 24-bit little-endian signed → sign-extended int32
static inline int32_t read24(const uint8_t *p) {
    return (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24) >> 8;
}

// Shift right by shift bits with rounding and saturate to 16 bits. No dither: SBC's own quantization noise is tens of dB
// above 16-bit quantization noise, so dither makes no audible difference, and it would turn digital silence into noise
static inline int16_t round_to_16(int32_t x, int shift) {
    int32_t r = (x + (1 << (shift - 1))) >> shift;
    if (r > INT16_MAX) r = INT16_MAX;
    if (r < INT16_MIN) r = INT16_MIN;
    return (int16_t)r;
}

int sbc_a2dp_encode(sbc_a2dp *codec, const uint8_t *pcm24, uint8_t *out, size_t capacity, char *error,
                    size_t error_size) {
    if (!codec || !pcm24 || !out) {
        fail(error, error_size, "SBC encode argument is null");
        return -1;
    }
    size_t length = kSbcPayloadHeaderSize + codec->frames_per_packet * codec->frame_bytes;
    if (capacity < length) {
        fail(error, error_size, "Output buffer of %zu bytes is too small (need %zu)", capacity, length);
        return -1;
    }
    // Payload header: no fragmentation, low 4 bits = frame count (sbc.cc L265-282, L674)
    out[0] = (uint8_t)(codec->frames_per_packet & kSbcHeaderFrameCountMask);
    uint8_t *dst = out + kSbcPayloadHeaderSize;
    const uint8_t *src = pcm24;
    for (size_t f = 0; f < codec->frames_per_packet; f++) {
        // The encoder wants 16-bit interleaved PCM (a single channel for mono), blocks×subbands sample instants per frame
        // (encoder.cc L527-534)
        int16_t *pcm = codec->pcm;
        if (codec->channels == 1) {
            for (size_t i = 0; i < codec->frame_samples; i++, src += 6) {
                pcm[i] = round_to_16(read24(src) + read24(src + 3), 9);
            }
        } else {
            for (size_t i = 0; i < codec->frame_samples; i++, src += 6) {
                pcm[2 * i] = round_to_16(read24(src), 8);
                pcm[2 * i + 1] = round_to_16(read24(src + 3), 8);
            }
        }
        uint32_t written = SBC_Encode(&codec->params, pcm, codec->frame);
        // SBC_Encode returns the number of bytes actually written. When the allocation does not use up the bitpool it can be
        // shorter than the frame length computed from the bitpool; the decoder derives the frame length from the bitpool in
        // the frame header, so pad with zeros to the required length
        if (written == 0 || written > codec->frame_bytes) {
            fail(error, error_size, "SBC encoder wrote %u bytes, which does not match the frame length %zu", written, codec->frame_bytes);
            return -1;
        }
        memcpy(dst, codec->frame, written);
        memset(dst + written, 0, codec->frame_bytes - written);
        dst += codec->frame_bytes;
    }
    return (int)length;
}

void sbc_a2dp_close(sbc_a2dp *codec) {
    if (!codec) return;
    free(codec);
    atomic_flag_clear(&gInUse);
}
