// AACEncoder: A2DP AAC encoder (AAC-LC stereo). Uses the system AudioToolbox AAC encoder to produce raw AUs and
// wraps them itself into LATM AudioMuxElements (muxConfigPresent=1, StreamMuxConfig in every frame), ready to follow the RTP header.
// Requires linking AudioToolbox (-framework AudioToolbox). Not thread-safe; call a given instance from one thread only.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---- A2DP AAC codec information element (the 6 bytes after media type and codec type kCodecMPEG24=0x02) ----
// A2DP v1.4 §4.5.2 tables 4.14-4.20; AOSP system/stack/include/a2dp_aac_constants.h;
// PipeWire spa/plugins/bluez5/a2dp-codec-caps.h a2dp_aac_t.
// Byte 0: object type; byte 1 + high 4 bits of byte 2: 12-bit sample rate bitmap; low 4 bits of byte 2: channels;
// byte 3 b7: VBR; low 7 bits of byte 3 + byte 4 + byte 5: 23-bit bitrate (big-endian, bit/s)
enum {
    kAACObjectMPEG2LC = 0x80,        // Byte 0: MPEG-2 AAC LC, mandatory on both sides; the AOSP default configuration picks it
    kAACObjectMPEG4LC = 0x40,
    kAACObjectMPEG4LTP = 0x20,
    kAACObjectMPEG4Scalable = 0x10,
    kAACObjectMPEG4HEAAC = 0x08,     // HE-AAC/HE-AACv2/ELDv2 are new in A2DP 1.4
    kAACObjectMPEG4HEAACv2 = 0x04,
    kAACObjectMPEG4ELDv2 = 0x02,
    kAACObjectMPEGDDRC = 0x01,       // b0 is the MPEG-D DRC support bit, not an object type; must be 0 when only MPEG-2 LC is set
};
enum {                               // Byte 1: sample rates (44.1k and 48k mandatory on the headphone side)
    kAACFreq1_8000 = 0x80,
    kAACFreq1_11025 = 0x40,
    kAACFreq1_12000 = 0x20,
    kAACFreq1_16000 = 0x10,
    kAACFreq1_22050 = 0x08,
    kAACFreq1_24000 = 0x04,
    kAACFreq1_32000 = 0x02,
    kAACFreq1_44100 = 0x01,
};
enum {                               // Byte 2: high 4 bits sample rates, low 4 bits channels
    kAACFreq2_48000 = 0x80,
    kAACFreq2_64000 = 0x40,
    kAACFreq2_88200 = 0x20,
    kAACFreq2_96000 = 0x10,
    kAACChannels1 = 0x08,
    kAACChannels2 = 0x04,
    kAACChannels5_1 = 0x02,          // New in A2DP 1.4
    kAACChannels7_1 = 0x01,
};
enum {                               // Byte 3
    kAACVBR = 0x80,                  // In a capability: VBR supported (mandatory on the headphone side); in a configuration: this stream is VBR
    kAACBitrateHighMask = 0x7F,      // Bitrate b22-b16
};
// Bitrate field: the bitrate for CBR; for VBR the "peak bitrate measured per frame"; 0 means unknown (A2DP v1.4 §4.5.2.5).
// AOSP and PipeWire both treat values <64k as unknown and use the default 320k instead (a2dp_aac.cc A2DP_AAC_DEFAULT_BITRATE/MIN_BITRATE; a2dp-codec-aac.c)
static const int kAACDefaultBitrate = 320000;
static const int kAACMinBitrate = 64000;
static inline int AACInfoBitrate(const uint8_t *info) { return (info[3] & kAACBitrateHighMask) << 16 | info[4] << 8 | info[5]; }

// ---- Media packets ----
// Payload format: RFC 6416 MP4A-LATM, muxConfigPresent=1 (A2DP v1.4 §4.5.4); when the configuration picks MPEG-2 LC the bitstream is still sent as MPEG-4 AAC LC (AOT 2).
// One AudioMuxElement per RTP packet; timestamp = index of the first sample, +1024 per AU (AOSP a2dp_aac_encoder.cc a2dp_aac_encode_frames;
// PipeWire media-sink.c uses sample_count); payload type 96 (kRTPPayloadType); marker bit set to 1 (AOSP A2dpCodecConfigAacSource::useRtpHeaderMarkerBit,
// PipeWire codec_encode). When an element exceeds the MTU, AOSP splits it into several RTP packets by MTU with the same timestamp, and only the last fragment has the marker bit set (bta_av_aact.cc bta_av_data_path).
static const size_t kAACFrameSamples = 1024;     // Samples per channel per AU = RTP timestamp step
static const size_t kAACMediaHeaderBytes = 12;   // RTP header (AOSP avdt_api.h AVDT_MEDIA_HDR_SIZE)
static const size_t kAAC2MbpsMaxPayload = 663;   // Headphones that support only 2M EDR: 2-DH5 679 − 12 − 4 (AOSP avdt_api.h MAX_2MBPS_AVDTP_MTU)
// MTU → bitrate cap: ensures one AU (including the LATM header) fits in one packet. AOSP A2DP_ComputeMaxBitRateAac: 8 × (L2CAP MTU − 12) × sample rate / 1024,
// used as FDK's peak bitrate (AACENC_PEAK_BITRATE); the bitrate is min(configured bitrate, that); PipeWire a2dp-codec-aac.c codec_init uses the same formula.
// This encoder can cap per frame only in VBR mode (see maxElementBytes); CBR AUs float with the bit reservoir, observed peaks reach 1.5× the average.
static inline int AACMaxBitrateForMTU(size_t l2capMTU, double rate) {
    return l2capMTU > kAACMediaHeaderBytes ? (int)(8.0 * (double)(l2capMTU - kAACMediaHeaderBytes) * rate / kAACFrameSamples) : 0;
}

@interface AACEncoder : NSObject
// AAC-LC stereo. bitrate in bit/s.
// vbr=NO: CBR, bitrate is the average bitrate (clamped to the range the encoder allows, 64k–320k at 44.1k/48k).
// vbr=YES: per-frame capped VBR, bitrate is the peak bitrate in the A2DP sense: each LATM element ≤ bitrate×1024/sample rate/8 bytes,
// and the encoder takes the highest quality within that limit (Apple's VariableConstrained mode has no per-frame cap; observed single frames reach 1.5–1.9× the nominal bitrate, so it is not used).
- (nullable instancetype)initWithSampleRate:(double)rate bitrate:(int)bitrate vbr:(BOOL)vbr error:(NSString *_Nullable *_Nullable)error;
@property (nonatomic, readonly) size_t framesPerCall;   // 1024
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) int bitrate;            // Actual configuration (bit/s): average bitrate for CBR; for VBR the peak rounded to whole bytes, possibly slightly below the requested value
@property (nonatomic, readonly) size_t maxElementBytes; // VBR: hard cap per LATM element (bytes); CBR: 0 (not guaranteed)
@property (nonatomic, readonly) uint32_t primingFrames; // Encoder delay (samples per channel, 2112 for Apple AAC); decoded output lags by this much overall
// Change the bitrate (same meaning as bitrate in init), effective from the next AU; can be changed while streaming (for adaptive bitrate). Keeps the old bitrate on failure
- (BOOL)setBitrate:(int)bitrate error:(NSString *_Nullable *_Nullable)error;
// pcm24: framesPerCall frames of 24-bit little-endian packed interleaved stereo (6 bytes per frame).
// Returns zero or more LATM AudioMuxElements, one per AU (placed after the RTP header); returns nil with a reason on error.
- (nullable NSArray<NSData *> *)encodePCM24:(const uint8_t *)pcm error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
