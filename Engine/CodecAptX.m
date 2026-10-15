// Classic aptX and aptX HD (libfreeaptx).
// aptX: no RTP header, filled with 4-byte frames up to the MTU (PipeWire a2dp-codec-aptx.c L342-348, L382; bluez-alsa src/a2dp-aptx.c).
// aptX HD: 12-byte RTP header + 6-byte frames (PipeWire a2dp-codec-aptx.c codec_start_encode writes an RTP header only for HD); timestamp advances by sample count.
// Each aptX/aptX HD frame covers 4 samples per channel.

#import "A2DPCodec.h"
#import "A2DPProtocol.h"
#import "BBLog.h"
#import "PCMSource.h"
#include "freeaptx.h"

static const size_t kSamplesPerAptxFrame = 4;
static const size_t kAptxHDFrameBytes = 6;
// The aptX HD codec information element has 4 more reserved bytes than aptX (PipeWire a2dp-codec-caps.h a2dp_aptx_hd_t)
static const size_t kAptxHDReservedBytes = 4;

static NSArray<NSNumber *> *AptxRates(uint8_t frequencies) {
    NSMutableArray *rates = [NSMutableArray array];
    if (frequencies & kAptxFreq44100) [rates addObject:@44100];
    if (frequencies & kAptxFreq48000) [rates addObject:@48000];
    return rates;
}

static uint8_t AptxFrequencyBit(double rate) {
    return rate == 44100 ? kAptxFreq44100 : rate == 48000 ? kAptxFreq48000 : 0;
}

#pragma mark - Encoder

@interface AptxEncoder : NSObject <A2DPEncoder>
- (instancetype)initWithHD:(BOOL)hd rate:(double)rate outMTU:(uint16_t)outMTU;
@end

@implementation AptxEncoder {
    BOOL _hd;
    struct aptx_context *_aptx;
    size_t _frameBytes;
    size_t _payloadOffset;
    size_t _aptxFrames;
    uint16_t _sequence;
    uint32_t _timestamp;
    double _rate;
}

@synthesize framesPerCall = _framesPerCall;

- (instancetype)initWithHD:(BOOL)hd rate:(double)rate outMTU:(uint16_t)outMTU {
    if ((self = [super init])) {
        _hd = hd;
        _rate = rate;
        _aptx = aptx_init(hd ? 1 : 0);
        _frameBytes = hd ? kAptxHDFrameBytes : kAptxFrameBytes;
        _payloadOffset = hd ? kRTPHeaderBytes : 0;
        _aptxFrames = (outMTU - _payloadOffset) / _frameBytes;
        _framesPerCall = _aptxFrames * kSamplesPerAptxFrame;
    }
    return self;
}

- (void)dealloc {
    if (_aptx) aptx_finish(_aptx);
}

- (double)bitrateKbps {
    return _rate * _frameBytes * 8 / kSamplesPerAptxFrame / 1000;
}

- (NSArray<NSData *> *)encode:(const uint8_t *)pcm error:(NSString **)error {
    size_t pcmBytes = _framesPerCall * kPCMBytesPerSample;
    NSMutableData *packet = [NSMutableData dataWithLength:_payloadOffset + _aptxFrames * _frameBytes];
    uint8_t *bytes = packet.mutableBytes;
    size_t written = 0;
    size_t consumed = aptx_encode(_aptx, pcm, pcmBytes, bytes + _payloadOffset, _aptxFrames * _frameBytes, &written);
    if (consumed != pcmBytes || written != _aptxFrames * _frameBytes) {
        if (error) *error = [NSString stringWithFormat:@"aptX encoded length mismatch: input %zu/%zu, output %zu/%zu", consumed, pcmBytes, written, _aptxFrames * _frameBytes];
        return nil;
    }
    if (_hd) {
        A2DPWriteRTPHeader(bytes, _sequence++, _timestamp, 1, NO);
        _timestamp += (uint32_t)_framesPerCall;
    }
    return @[packet];
}

@end

#pragma mark - Codec

@interface AptXCodec : A2DPCodec
@end

@implementation AptXCodec

+ (void)load { [A2DPCodec registerCodecClass:self]; }

- (CodecID)identifier { return CodecIDAptX; }
- (NSString *)displayName { return @"aptX"; }
- (NSString *)vendorName { return @"Qualcomm"; }
- (NSInteger)rank { return 40; }
- (BOOL)isPremium { return YES; }
- (NSArray<NSNumber *> *)badgeColors { return @[@0xFABF33, @0xF7872E]; }
// aptX HD inherits the credit, link and trademark (same library); merged into one line on the About page
- (NSString *)credit { return @"libfreeaptx — Aurelien Jacobs, Pali Rohár, Hunter Wardlaw · LGPL 2.1"; }
- (NSString *)trademark { return @"aptX is a trademark of Qualcomm Technologies, Inc."; }
- (NSURL *)creditURL { return [NSURL URLWithString:@"https://github.com/regularhunter/libfreeaptx"]; }

- (NSData *)fullCapabilityElement {
    static const uint8_t element[] = { 0x00, 0xFF, 0x4F, 0x00, 0x00, 0x00, 0x01, 0x00, 0x32 };
    return [NSData dataWithBytes:element length:sizeof(element)];
}

- (BOOL)hd { return NO; }

- (BOOL)matchesElement:(NSData *)element {
    return self.hd ? A2DPIsVendorElement(element, kAptxHDVendorID, kAptxHDCodecID, 9)
                   : A2DPIsVendorElement(element, kAptxVendorID, kAptxCodecID, 9);
}

- (NSArray<NSNumber *> *)sampleRatesInCapability:(NSData *)element {
    const uint8_t *info = (const uint8_t *)element.bytes + 8;
    if (!(info[0] & kAptxChannelStereo)) return @[];
    return AptxRates(info[0] >> 4);
}

- (CodecConfiguration *)configurationForCapability:(NSData *)element sampleRate:(double)rate options:(CodecOptions *)options {
    const uint8_t *info = (const uint8_t *)element.bytes + 8;
    uint8_t frequency = AptxFrequencyBit(rate);
    if (!frequency || !((info[0] >> 4) & frequency) || !(info[0] & kAptxChannelStereo)) return nil;
    NSMutableData *config = [NSMutableData dataWithBytes:element.bytes length:8];
    uint8_t value = (uint8_t)(frequency << 4 | kAptxChannelStereo);
    [config appendBytes:&value length:1];
    if (self.hd) [config increaseLengthBy:kAptxHDReservedBytes];
    ((uint8_t *)config.mutableBytes)[0] = kMediaAudio << 4;
    int bits = self.hd ? 24 : 16;
    double kbps = rate * (self.hd ? kAptxHDFrameBytes : kAptxFrameBytes) * 8 / kSamplesPerAptxFrame / 1000;
    NSString *summary = [NSString stringWithFormat:@"%@ %g kHz/%d-bit stereo, %.0f kbps, configuration byte 0x%02X", self.displayName, rate / 1000, bits, kbps, value];
    return [[CodecConfiguration alloc] initWithCodec:self.identifier element:config sampleRate:rate bitsPerSample:bits nominalKbps:kbps summary:summary parameters:nil];
}

- (id<A2DPEncoder>)encoderForConfiguration:(CodecConfiguration *)configuration outMTU:(uint16_t)outMTU options:(CodecOptions *)options error:(NSString **)error {
    AptxEncoder *encoder = [[AptxEncoder alloc] initWithHD:self.hd rate:configuration.sampleRate outMTU:outMTU];
    if (encoder.framesPerCall == 0) {
        if (error) *error = [NSString stringWithFormat:@"Media channel MTU %u is too small", outMTU];
        return nil;
    }
    BBLog(@"%@ stream parameters: %zu samples per packet (%.2f ms), theoretical bitrate %.1f kbps", self.displayName, encoder.framesPerCall,
        encoder.framesPerCall * 1000.0 / configuration.sampleRate, encoder.bitrateKbps);
    return encoder;
}

@end

@interface AptXHDCodec : AptXCodec
@end

@implementation AptXHDCodec

+ (void)load { [A2DPCodec registerCodecClass:self]; }

- (CodecID)identifier { return CodecIDAptXHD; }
- (NSString *)displayName { return @"aptX HD"; }
- (BOOL)hd { return YES; }
- (NSInteger)rank { return 30; }
- (NSArray<NSNumber *> *)badgeColors { return @[@0xFC9E2E, @0xF76633]; }

- (NSData *)fullCapabilityElement {
    static const uint8_t element[] = { 0x00, 0xFF, 0xD7, 0x00, 0x00, 0x00, 0x24, 0x00, 0x32, 0, 0, 0, 0 };
    return [NSData dataWithBytes:element length:sizeof(element)];
}

@end
