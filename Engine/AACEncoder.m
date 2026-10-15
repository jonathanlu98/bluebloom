// AACEncoder: AudioConverter encodes 24-bit PCM into raw AAC-LC AUs (one per 1024 frames, starting with the first AU), each then wrapped into a LATM AudioMuxElement.
//
// LATM values match Android and PipeWire: both use FDK with TT_MP4_LATM_MCP1, AACENC_HEADER_PERIOD=1, AACENC_AUDIOMUXVER=2,
// AACENC_SIGNALING_MODE=1 (AOSP a2dp_aac_encoder.cc a2dp_aac_encoder_update; PipeWire a2dp-codec-aac.c codec_init).
// The bitstream FDK writes from these (external/aac libMpegTPEnc/src/tpenc_latm.cpp):
// - StreamMuxConfig in every frame: useSameStreamMux=0 (HEADER_PERIOD=1, AdvanceAudioMuxElement)
// - audioMuxVersion=1 (transportEnc_Latm_Init passes audioMuxVersion ? 1 : 0), audioMuxVersionA=0, taraBufferFullness=0xFF
// - allStreamsSameTimeFraming=1, numSubFrames=0, numProgram=0, numLayer=0
// - ascLen = ASC bits + fill bits; the fill byte-aligns "ascLen field + ASC + fill" (CreateStreamMuxConfig writes once to measure the length, then backfills)
// - frameLengthType=0, latmBufferFullness=0xC0: with AUDIOMUXVER=2 FDK counts the bit reservoir as full (libAACenc aacenc.cpp
//   FDKaacEnc_EncBitresToTpBitres: 6144×channels), then the transport layer divides by channels and by 32 (tpenc_lib.cpp transportEnc_WriteAccessUnit) = 192
// - otherDataPresent=0, crcCheckPresent=0; PayloadLengthInfo: one 0xFF per full 255 bytes, then the remainder (WriteAuPayloadLengthInfo)
// - ASC is 16 bits: AOT 2, sample rate index, channel configuration 2, GASpecificConfig three 0 bits; SIGNALING_MODE=1 affects only SBR/PS, LC gets no extension (tpenc_asc.cpp)
// So the element header is a fixed 9 bytes: 47 FC 00 00 B0 90 80 03 00 at 44.1k, 47 FC 00 00 B0 8C 80 03 00 at 48k, followed by the length bytes and the AU.

#import "AACEncoder.h"

#import <AudioToolbox/AudioToolbox.h>

enum {
    kAACChannels = 2,
    kPCMBytesPerFrame = 6,
    kMaxPacketsPerFill = 8,   // Each 1024 frames yield at most 1-2 AUs; extra headroom so the encoder returns only after consuming all input
};
static const OSStatus kInputDrained = 'aacD';         // Used by the input callback: this call's PCM is all handed over, make FillComplexBuffer return (not end of stream)
static const uint32_t kLATMTaraBufferFullness = 0xFF;
static const uint32_t kLATMBufferFullness = 0xC0;
static const int kAOTAACLC = 2;
// ISO/IEC 14496-3 table 1.18 samplingFrequencyIndex 0-12
static const double kSamplingFrequencies[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};

// ---- Bit writing (MSB first) ----
typedef struct {
    uint8_t *bytes;
    size_t bits;
} AACBitWriter;

static inline void AACPutBits(AACBitWriter *w, uint32_t value, int count) {
    for (int i = count - 1; i >= 0; i--) {
        size_t index = w->bits >> 3;
        int shift = 7 - (int)(w->bits & 7);
        if (shift == 7) w->bytes[index] = 0;
        w->bytes[index] |= (uint8_t)(((value >> i) & 1) << shift);
        w->bits++;
    }
}

static inline void AACPutBytes(AACBitWriter *w, const uint8_t *p, size_t n) {
    if ((w->bits & 7) == 0) {
        memcpy(w->bytes + (w->bits >> 3), p, n);
        w->bits += n * 8;
    } else {
        for (size_t i = 0; i < n; i++) AACPutBits(w, p[i], 8);
    }
}

// LatmGetValue encoding: 2 bits of "byte count−1", then the value big-endian (ISO/IEC 14496-3 table 1.42; FDK transportEnc_LatmWriteValue)
static inline void AACPutLatmValue(AACBitWriter *w, uint32_t value) {
    int bytes = value < (1u << 8) ? 1 : value < (1u << 16) ? 2 : value < (1u << 24) ? 3 : 4;
    AACPutBits(w, (uint32_t)(bytes - 1), 2);
    for (int i = bytes - 1; i >= 0; i--) AACPutBits(w, (value >> (8 * i)) & 0xFF, 8);
}

// ---- Encoder input callback: hand over all of this call's PCM at once, return kInputDrained when asked again ----
typedef struct {
    const uint8_t *pcm;
    UInt32 framesLeft;
} AACInputState;

static OSStatus AACInputProc(AudioConverterRef converter, UInt32 *ioPackets, AudioBufferList *data,
                             AudioStreamPacketDescription **descriptions, void *user) {
    AACInputState *state = user;
    if (state->framesLeft == 0) {
        *ioPackets = 0;
        return kInputDrained;
    }
    data->mNumberBuffers = 1;
    data->mBuffers[0].mNumberChannels = kAACChannels;
    data->mBuffers[0].mData = (void *)state->pcm;
    data->mBuffers[0].mDataByteSize = state->framesLeft * (UInt32)kPCMBytesPerFrame;
    *ioPackets = state->framesLeft;
    state->pcm += state->framesLeft * kPCMBytesPerFrame;
    state->framesLeft = 0;
    return noErr;
}

@implementation AACEncoder {
    AudioConverterRef _converter;
    uint8_t _asc[2];
    size_t _ascBits;
    uint8_t _pcm[1024 * kPCMBytesPerFrame];   // The encoder reads input only after the callback returns, so copy the PCM into our own buffer first
    AACInputState _input;
    uint8_t *_packets;
    size_t _packetCapacity;
    AudioStreamPacketDescription _descriptions[kMaxPacketsPerFill];
    double _rate;
    BOOL _vbr;
    UInt32 _maxPacket;
}

- (nullable instancetype)initWithSampleRate:(double)rate bitrate:(int)bitrate vbr:(BOOL)vbr error:(NSString **)error {
    if (!(self = [super init])) return nil;
    _framesPerCall = kAACFrameSamples;
    int frequencyIndex = -1;
    for (int i = 0; i < (int)(sizeof kSamplingFrequencies / sizeof kSamplingFrequencies[0]); i++) {
        if (kSamplingFrequencies[i] == rate) frequencyIndex = i;
    }
    if (frequencyIndex < 0) return [self failWith:[NSString stringWithFormat:@"AAC does not support sample rate %.0f", rate] error:error];
    // ASC: AOT(5) sample rate index(4) channel configuration(4) frameLengthFlag=0 dependsOnCoreCoder=0 extensionFlag=0 (ISO/IEC 14496-3 1.6.2.1, 4.4.1)
    AACBitWriter ascWriter = {_asc, 0};
    AACPutBits(&ascWriter, kAOTAACLC, 5);
    AACPutBits(&ascWriter, (uint32_t)frequencyIndex, 4);
    AACPutBits(&ascWriter, kAACChannels, 4);
    AACPutBits(&ascWriter, 0, 3);
    _ascBits = ascWriter.bits;

    AudioStreamBasicDescription input = {
        .mSampleRate = rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = (UInt32)kPCMBytesPerFrame,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = (UInt32)kPCMBytesPerFrame,
        .mChannelsPerFrame = kAACChannels,
        .mBitsPerChannel = 24,
    };
    AudioStreamBasicDescription output = {
        .mSampleRate = rate,
        .mFormatID = kAudioFormatMPEG4AAC,
        .mFormatFlags = kMPEG4Object_AAC_LC,
        .mFramesPerPacket = (UInt32)kAACFrameSamples,
        .mChannelsPerFrame = kAACChannels,
    };
    OSStatus status = AudioConverterNew(&input, &output, &_converter);
    if (status != noErr) return [self failWith:[NSString stringWithFormat:@"Failed to create AAC encoder (%d, sample rate %.0f)", (int)status, rate] error:error];

    // Set the bitrate control mode first; the allowed bitrate range depends on the mode
    UInt32 mode = vbr ? kAudioCodecBitRateControlMode_Variable : kAudioCodecBitRateControlMode_Constant;
    status = AudioConverterSetProperty(_converter, kAudioCodecPropertyBitRateControlMode, sizeof mode, &mode);
    if (status != noErr) return [self failWith:[NSString stringWithFormat:@"Failed to set AAC bitrate mode (%d)", (int)status] error:error];
    UInt32 quality = kAudioConverterQuality_Max;
    status = AudioConverterSetProperty(_converter, kAudioConverterCodecQuality, sizeof quality, &quality);
    if (status != noErr) return [self failWith:[NSString stringWithFormat:@"Failed to set AAC encoder quality (%d)", (int)status] error:error];

    UInt32 size = sizeof(UInt32);
    UInt32 maxPacket = 0;
    AudioConverterGetProperty(_converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket);
    if (maxPacket == 0) maxPacket = 768 * kAACChannels;   // AAC limit is 6144 bits per channel per frame
    _rate = rate;
    _sampleRate = rate;
    _vbr = vbr;
    _maxPacket = maxPacket;
    if (![self setBitrate:bitrate error:error]) return nil;

    AudioConverterPrimeInfo prime = {0};
    size = sizeof prime;
    if (AudioConverterGetProperty(_converter, kAudioConverterPrimeInfo, &size, &prime) == noErr) _primingFrames = prime.leadingFrames;
    NSString *cookieError = [self checkMagicCookie];
    if (cookieError) return [self failWith:cookieError error:error];

    _packetCapacity = (size_t)maxPacket * kMaxPacketsPerFill;
    _packets = malloc(_packetCapacity);
    if (!_packets) return [self failWith:@"Out of memory" error:error];
    return self;
}

- (void)dealloc {
    if (_converter) AudioConverterDispose(_converter);
    free(_packets);
}

- (BOOL)setBitrate:(int)bitrate error:(NSString **)error {
    OSStatus status;
    if (_vbr) {
        // The A2DP VBR bitrate field is the peak measured per frame (A2DP v1.4 §4.5.2.5): the whole LATM element ≤ peak bitrate × 1024 / sample rate / 8.
        // Subtract the LATM header (StreamMuxConfig + length bytes) to get the AU cap, passed to the encoder's PacketSizeLimitForVBR (in bits, cap inclusive)
        size_t muxBytes = [self muxHeaderBytes];
        size_t element = (size_t)floor((double)bitrate * kAACFrameSamples / _rate / 8);
        size_t au = 0;
        while (au + 1 + muxBytes + (au + 1) / 255 + 1 <= element) au++;
        if (au >= _maxPacket) au = _maxPacket - 1;   // The cap must be below MaximumPacketByteSize (AudioCodec.h)
        if (au * 8 * _rate / kAACFrameSamples < kAACMinBitrate * 0.9) {
            if (error) *error = [NSString stringWithFormat:@"AAC peak bitrate %d is too low", bitrate];
            return NO;
        }
        UInt32 limitBits = (UInt32)(au * 8);
        status = AudioConverterSetProperty(_converter, kAudioCodecPropertyPacketSizeLimitForVBR, sizeof limitBits, &limitBits);
        if (status != noErr) {
            if (error) *error = [NSString stringWithFormat:@"Failed to set AAC per-frame cap (%d)", (int)status];
            return NO;
        }
        _maxElementBytes = au + muxBytes + au / 255 + 1;
        _bitrate = (int)MIN((double)bitrate, ceil(_maxElementBytes * 8.0 * _rate / kAACFrameSamples));
    } else {
        UInt32 rateValue = (UInt32)MAX(bitrate, 0);
        if (![self clampBitrate:&rateValue]) {
            if (error) *error = @"Failed to read applicable AAC bitrates";
            return NO;
        }
        status = AudioConverterSetProperty(_converter, kAudioConverterEncodeBitRate, sizeof rateValue, &rateValue);
        if (status != noErr) {
            if (error) *error = [NSString stringWithFormat:@"Failed to set AAC bitrate %u (%d)", rateValue, (int)status];
            return NO;
        }
        UInt32 size = sizeof rateValue;
        AudioConverterGetProperty(_converter, kAudioConverterEncodeBitRate, &size, &rateValue);
        _bitrate = (int)rateValue;
    }
    return YES;
}

- (nullable instancetype)failWith:(NSString *)message error:(NSString **)error {
    if (error) *error = message;
    return nil;
}

// CBR: clamp the bitrate to the range the encoder currently allows (64k–320k for 44.1k/48k stereo; any value within the range is encoded as is)
- (BOOL)clampBitrate:(UInt32 *)value {
    UInt32 size = 0;
    if (AudioConverterGetPropertyInfo(_converter, kAudioConverterApplicableEncodeBitRates, &size, NULL) != noErr || size < sizeof(AudioValueRange)) return NO;
    NSMutableData *buffer = [NSMutableData dataWithLength:size];
    AudioValueRange *ranges = buffer.mutableBytes;
    if (AudioConverterGetProperty(_converter, kAudioConverterApplicableEncodeBitRates, &size, ranges) != noErr) return NO;
    double low = ranges[0].mMinimum, high = ranges[0].mMaximum;
    for (size_t i = 1; i < size / sizeof(AudioValueRange); i++) {
        low = MIN(low, ranges[i].mMinimum);
        high = MAX(high, ranges[i].mMaximum);
    }
    *value = (UInt32)MIN(MAX((double)*value, low), high);
    return YES;
}

// The encoder's magic cookie is an ES_Descriptor (ISO/IEC 14496-1 7.2.6.5) whose DecoderSpecificInfo (tag 5) is the ASC it uses.
// LATM carries our own 16-bit ASC built the FDK way; check here that the encoder's actual configuration matches it; do not block if the cookie cannot be read
- (nullable NSString *)checkMagicCookie {
    UInt32 size = 0;
    if (AudioConverterGetPropertyInfo(_converter, kAudioConverterCompressionMagicCookie, &size, NULL) != noErr || size == 0) return nil;
    NSMutableData *cookie = [NSMutableData dataWithLength:size];
    if (AudioConverterGetProperty(_converter, kAudioConverterCompressionMagicCookie, &size, cookie.mutableBytes) != noErr) return nil;
    NSData *asc = [self.class decoderSpecificInfoIn:cookie.bytes length:size depth:0];
    if (!asc) return nil;
    if (asc.length < 2 || memcmp(asc.bytes, _asc, 2) != 0) {
        return [NSString stringWithFormat:@"AAC encoder ASC %@ does not match expected %02X%02X", asc, _asc[0], _asc[1]];
    }
    return nil;
}

+ (nullable NSData *)decoderSpecificInfoIn:(const uint8_t *)p length:(size_t)n depth:(int)depth {
    size_t i = 0;
    while (depth < 4 && i + 2 <= n) {
        uint8_t tag = p[i++];
        size_t length = 0;
        for (int k = 0; k < 4 && i < n; k++) {   // Length: 7 bits per byte, top bit is the continuation bit
            uint8_t b = p[i++];
            length = length << 7 | (b & 0x7F);
            if (!(b & 0x80)) break;
        }
        if (length > n - i) return nil;
        const uint8_t *body = p + i;
        if (tag == 0x05) return [NSData dataWithBytes:body length:length];
        size_t skip = 0;
        if (tag == 0x03 && length >= 3) {          // ES_Descriptor: ES_ID(2) flags(1) [depends-on ES_ID(2)] [URL] [OCR ES_ID(2)]
            uint8_t flags = body[2];
            skip = 3;
            if (flags & 0x80) skip += 2;
            if ((flags & 0x40) && skip < length) skip += 1 + body[skip];
            if (flags & 0x20) skip += 2;
        } else if (tag == 0x04) {                  // DecoderConfigDescriptor: 13-byte fixed-length part
            skip = 13;
        }
        if ((tag == 0x03 || tag == 0x04) && skip <= length) {
            NSData *found = [self decoderSpecificInfoIn:body + skip length:length - skip depth:depth + 1];
            if (found) return found;
        }
        i += length;
    }
    return nil;
}

// StreamMuxConfig (ISO/IEC 14496-3 1.7.3 table 1.42); values described in the file header
- (void)writeStreamMuxConfig:(AACBitWriter *)w {
    AACPutBits(w, 1, 1);                         // audioMuxVersion
    AACPutBits(w, 0, 1);                         // audioMuxVersionA
    AACPutLatmValue(w, kLATMTaraBufferFullness);
    AACPutBits(w, 1, 1);                         // allStreamsSameTimeFraming
    AACPutBits(w, 0, 6);                         // numSubFrames
    AACPutBits(w, 0, 4);                         // numProgram
    AACPutBits(w, 0, 3);                         // numLayer
    size_t fill = (8 - (10 + _ascBits) % 8) % 8;  // 10 = ascLen field (when the value is <256)
    AACPutLatmValue(w, (uint32_t)(_ascBits + fill));
    for (size_t bit = 0; bit < _ascBits; bit++) AACPutBits(w, (_asc[bit >> 3] >> (7 - (bit & 7))) & 1, 1);
    AACPutBits(w, 0, (int)fill);
    AACPutBits(w, 0, 3);                         // frameLengthType
    AACPutBits(w, kLATMBufferFullness, 8);       // latmBufferFullness
    AACPutBits(w, 0, 1);                         // otherDataPresent
    AACPutBits(w, 0, 1);                         // crcCheckPresent
}

// Byte count of useSameStreamMux + StreamMuxConfig (rounded up)
- (size_t)muxHeaderBytes {
    uint8_t scratch[32];
    AACBitWriter w = {scratch, 0};
    AACPutBits(&w, 0, 1);
    [self writeStreamMuxConfig:&w];
    return (w.bits + 7) / 8;
}

// AudioMuxElement(muxConfigPresent=1) (ISO/IEC 14496-3 1.7.3 table 1.41): one subframe, one AU, no otherData, byte-aligned at the end
- (NSData *)elementForAU:(const uint8_t *)au length:(size_t)length {
    NSMutableData *element = [NSMutableData dataWithLength:32 + length / 255 + 1 + length];
    AACBitWriter w = {element.mutableBytes, 0};
    AACPutBits(&w, 0, 1);                        // useSameStreamMux=0: StreamMuxConfig in every frame
    [self writeStreamMuxConfig:&w];
    size_t rest = length;                        // PayloadLengthInfo
    while (rest >= 255) {
        AACPutBits(&w, 255, 8);
        rest -= 255;
    }
    AACPutBits(&w, (uint32_t)rest, 8);
    AACPutBytes(&w, au, length);                 // PayloadMux
    element.length = (w.bits + 7) / 8;
    return element;
}

- (nullable NSArray<NSData *> *)encodePCM24:(const uint8_t *)pcm error:(NSString **)error {
    memcpy(_pcm, pcm, sizeof _pcm);
    _input.pcm = _pcm;
    _input.framesLeft = (UInt32)kAACFrameSamples;
    NSMutableArray<NSData *> *elements = [NSMutableArray array];
    // When the encoder wants more input the callback returns kInputDrained and FillComplexBuffer returns with the AUs produced so far;
    // if it returns early because the output is full (noErr), run another round until all input is handed over
    for (int round = 0; round < 4; round++) {
        AudioBufferList buffers = {.mNumberBuffers = 1};
        buffers.mBuffers[0].mNumberChannels = kAACChannels;
        buffers.mBuffers[0].mDataByteSize = (UInt32)_packetCapacity;
        buffers.mBuffers[0].mData = _packets;
        UInt32 packets = kMaxPacketsPerFill;
        OSStatus status = AudioConverterFillComplexBuffer(_converter, AACInputProc, &_input, &packets, &buffers, _descriptions);
        if (status != noErr && status != kInputDrained) {
            if (error) *error = [NSString stringWithFormat:@"AAC encoding failed (%d)", (int)status];
            return nil;
        }
        for (UInt32 i = 0; i < packets; i++) {
            const AudioStreamPacketDescription *d = &_descriptions[i];
            if (d->mDataByteSize == 0 || d->mStartOffset + d->mDataByteSize > buffers.mBuffers[0].mDataByteSize) continue;
            [elements addObject:[self elementForAU:_packets + d->mStartOffset length:d->mDataByteSize]];
        }
        if (status == kInputDrained) return elements;
    }
    if (error) *error = @"AAC encoder did not consume all input";
    return nil;
}

@end
