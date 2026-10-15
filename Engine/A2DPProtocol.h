// AVDTP and aptX protocol constants (source noted next to each value).

#import <Foundation/Foundation.h>

// AVDTP: BlueZ profiles/audio/avdtp.c L45-75 (PSM, signal IDs, packet types, message types)
static const uint16_t kAVDTPPSM = 25;
enum {
    kSigDiscover = 0x01,
    kSigGetCapabilities = 0x02,
    kSigSetConfiguration = 0x03,
    kSigGetConfiguration = 0x04,
    kSigReconfigure = 0x05,
    kSigOpen = 0x06,
    kSigStart = 0x07,
    kSigClose = 0x08,
    kSigSuspend = 0x09,
    kSigAbort = 0x0A,
    kSigSecurityControl = 0x0B,
    kSigGetAllCapabilities = 0x0C,
    kSigDelayReport = 0x0D,
};
enum { kPktSingle = 0, kPktStart = 1, kPktContinue = 2, kPktEnd = 3 };
enum { kMsgCommand = 0, kMsgGeneralReject = 1, kMsgAccept = 2, kMsgReject = 3 };

// AVDTP: BlueZ profiles/audio/avdtp.h L32-68 (service categories, error codes, SEP types, media types)
enum {
    kCatMediaTransport = 0x01,
    kCatContentProtection = 0x04,
    kCatMediaCodec = 0x07,
    kCatDelayReporting = 0x08,
};
enum {
    kErrBadAcpSeid = 0x12,
    kErrSepInUse = 0x13,
    kErrNotSupportedCommand = 0x19,
    kErrBadState = 0x31,
};
enum { kSepSource = 0x00, kSepSink = 0x01 };
enum { kMediaAudio = 0x00 };

// A2DP codec types: PipeWire spa/plugins/bluez5/a2dp-codec-caps.h L31-35
enum { kCodecSBC = 0x00, kCodecMPEG24 = 0x02, kCodecVendor = 0xFF };

// aptX: PipeWire a2dp-codec-caps.h L148-168;
// configuration byte: see a2dp_aptx_t in the same file (little-endian bit fields: low 4 bits channel mode, high 4 bits sample rate)
static const uint32_t kAptxVendorID = 0x0000004F;
static const uint16_t kAptxCodecID = 0x0001;
static const uint32_t kAptxHDVendorID = 0x000000D7;
static const uint16_t kAptxHDCodecID = 0x0024;
enum {
    kAptxChannelMono = 0x1,
    kAptxChannelStereo = 0x2,
    kAptxFreq16000 = 0x8,
    kAptxFreq32000 = 0x4,
    kAptxFreq44100 = 0x2,
    kAptxFreq48000 = 0x1,
};
// aptX payload: no RTP header, filled with 4-byte aptX frames up to the MTU (PipeWire a2dp-codec-aptx.c L342-348, L382;
// bluez-alsa src/a2dp-aptx.c a2dp_aptx_enc_thread). Each frame = 4 PCM samples per channel (LLRR).
static const size_t kAptxFrameBytes = 4;
static const size_t kAptxSamplesPerFrame = 4;
// Standard aptX is a 16-bit codec (4:1 compression); bitrate = sample rate × bitstream bits per sample instant = 384 kbps at 48k, 352.8 kbps at 44.1k
static const int kAptxBitsPerSample = 16;
static inline double AptxBitrateKbps(double rate) { return rate * kAptxFrameBytes * 8 / kAptxSamplesPerFrame / 1000; }
