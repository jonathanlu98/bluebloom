#import "A2DPCodec.h"
#import "A2DPProtocol.h"
#import "BBLog.h"
#include <math.h>

CodecID const CodecIDSBC = @"sbc";
CodecID const CodecIDAAC = @"aac";
CodecID const CodecIDAptX = @"aptx";
CodecID const CodecIDAptXHD = @"aptx-hd";
CodecID const CodecIDLDAC = @"ldac";

uint32_t A2DPReadLE32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

uint16_t A2DPReadLE16(const uint8_t *p) {
    return (uint16_t)(p[0] | p[1] << 8);
}

BOOL A2DPIsVendorElement(NSData *element, uint32_t vendor, uint16_t codec, size_t minimumLength) {
    const uint8_t *bytes = element.bytes;
    return element.length >= MAX(minimumLength, (size_t)8) && bytes[1] == kCodecVendor &&
           A2DPReadLE32(bytes + 2) == vendor && A2DPReadLE16(bytes + 6) == codec;
}

void A2DPWriteRTPHeader(uint8_t *p, uint16_t sequence, uint32_t timestamp, uint32_t ssrc, BOOL marker) {
    p[0] = 0x80;
    p[1] = (uint8_t)((marker ? 0x80 : 0) | kRTPPayloadType);
    p[2] = (uint8_t)(sequence >> 8);
    p[3] = (uint8_t)sequence;
    p[4] = (uint8_t)(timestamp >> 24);
    p[5] = (uint8_t)(timestamp >> 16);
    p[6] = (uint8_t)(timestamp >> 8);
    p[7] = (uint8_t)timestamp;
    p[8] = (uint8_t)(ssrc >> 24);
    p[9] = (uint8_t)(ssrc >> 16);
    p[10] = (uint8_t)(ssrc >> 8);
    p[11] = (uint8_t)ssrc;
}

double A2DPBestSampleRate(NSArray<NSNumber *> *rates, double desired, BOOL strict) {
    if ([rates containsObject:@(desired)]) return desired;
    double family = fmod(desired, 44100) == 0 ? 44100 : 48000;
    double below = 0, above = 0;
    for (NSNumber *value in rates) {
        double rate = value.doubleValue;
        if (fmod(rate, family) != 0) continue;
        if (rate <= desired) below = MAX(below, rate);
        else if (!above || rate < above) above = rate;
    }
    if (below) return below;
    if (above) return above;
    if (strict || rates.count == 0) return 0;
    return [rates containsObject:@48000] ? 48000 : rates.lastObject.doubleValue;
}

@implementation CodecPreset

+ (instancetype)presetWithID:(NSInteger)identifier kbps:(double)kbps kbps44:(double)kbps44 {
    CodecPreset *preset = [self new];
    preset->_identifier = identifier;
    preset->_kbps = kbps;
    preset->_kbps44 = kbps44;
    preset->_minimumKbps = kbps;
    return preset;
}

+ (instancetype)adaptivePresetWithID:(NSInteger)identifier kbps:(double)kbps kbps44:(double)kbps44 minimumKbps:(double)minimumKbps {
    CodecPreset *preset = [self presetWithID:identifier kbps:kbps kbps44:kbps44];
    preset->_adaptive = YES;
    preset->_minimumKbps = minimumKbps;
    return preset;
}

- (double)kbpsAtSampleRate:(double)rate {
    return rate > 0 && fmod(rate, 44100) == 0 ? _kbps44 : _kbps;
}

@end

@implementation CodecOptions

+ (NSArray<CodecID> *)defaultPriority {
    NSMutableArray<CodecID> *priority = [NSMutableArray array];
    for (A2DPCodec *codec in [A2DPCodec allCodecs]) [priority addObject:codec.identifier];
    return priority;
}

- (instancetype)init {
    if ((self = [super init])) {
        _priority = [CodecOptions defaultPriority];
        _presets = @{};
        _maxKbps = @{};
        _aacVBR = YES;
        _sbcAdaptive = YES;
        _aacAdaptive = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    CodecOptions *copy = [CodecOptions new];
    copy.priority = _priority;
    copy.preferredCodec = _preferredCodec;
    copy.presets = _presets;
    copy.maxKbps = _maxKbps;
    copy.aacBitrate = _aacBitrate;
    copy.aacVBR = _aacVBR;
    copy.sbcXQ = _sbcXQ;
    copy.sbcAdaptive = _sbcAdaptive;
    copy.aacAdaptive = _aacAdaptive;
    copy.maxSampleRate = _maxSampleRate;
    return copy;
}

@end

@implementation CodecConfiguration

- (instancetype)initWithCodec:(CodecID)codec element:(NSData *)element sampleRate:(double)rate bitsPerSample:(int)bits
                   nominalKbps:(double)kbps summary:(NSString *)summary parameters:(NSDictionary *)parameters {
    if ((self = [super init])) {
        _codec = [codec copy];
        _element = [element copy];
        _sampleRate = rate;
        _bitsPerSample = bits;
        _nominalKbps = kbps;
        _summary = [summary copy];
        _parameters = [parameters copy];
    }
    return self;
}

@end

@implementation RemoteCodec

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCodec:(CodecID)codec name:(NSString *)name sampleRates:(NSArray<NSNumber *> *)rates element:(NSData *)element {
    if ((self = [super init])) {
        _codec = [codec copy];
        _name = [name copy];
        _sampleRates = [rates copy];
        _element = [element copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    // With a codec information element, re-recognize it against the current registry: codec plugins linked in later are recognized
    // and selectable right away; codecs not built into this build show as the codec ID
    NSData *element = [coder decodeObjectOfClass:NSData.class forKey:@"element"];
    if (element.length >= 2) return [A2DPCodec remoteCodecForElement:element];
    return [self initWithCodec:[coder decodeObjectOfClass:NSString.class forKey:@"codec"]
                          name:[coder decodeObjectOfClass:NSString.class forKey:@"name"] ?: @"?"
                   sampleRates:[coder decodeArrayOfObjectsOfClass:NSNumber.class forKey:@"rates"] ?: @[]
                       element:[coder decodeObjectOfClass:NSData.class forKey:@"element"] ?: [NSData data]];
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_codec forKey:@"codec"];
    [coder encodeObject:_name forKey:@"name"];
    [coder encodeObject:_sampleRates forKey:@"rates"];
    [coder encodeObject:_element forKey:@"element"];
}

@end

@implementation A2DPCodec

// Subclasses register in their own +load (at process start, before main, single-threaded); codecs not built in do not appear
static NSMutableArray<Class> *gCodecClasses;

+ (void)registerCodecClass:(Class)codecClass {
    @autoreleasepool {
        if (!gCodecClasses) gCodecClasses = [[NSMutableArray alloc] init];
        if (![gCodecClasses containsObject:codecClass]) [gCodecClasses addObject:codecClass];
    }
}

+ (NSArray<A2DPCodec *> *)allCodecs {
    static NSArray<A2DPCodec *> *codecs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<A2DPCodec *> *list = [NSMutableArray array];
        for (Class cls in gCodecClasses) [list addObject:[cls new]];
        [list sortUsingComparator:^NSComparisonResult(A2DPCodec *a, A2DPCodec *b) { return [@(a.rank) compare:@(b.rank)]; }];
        codecs = list;
    });
    return codecs;
}

+ (A2DPCodec *)codecWithID:(CodecID)identifier {
    for (A2DPCodec *codec in [self allCodecs]) {
        if ([codec.identifier isEqualToString:identifier]) return codec;
    }
    return nil;
}

+ (A2DPCodec *)codecForElement:(NSData *)element {
    for (A2DPCodec *codec in [self allCodecs]) {
        if ([codec matchesElement:element]) return codec;
    }
    return nil;
}

// Implemented codecs use their own name; others get only the codec ID (hex, no zero padding): "vendor ID/codec ID" for vendor
// codecs, e.g. D7/AD, the type byte for other codec types. Unknown codecs are not given names
+ (NSString *)nameForElement:(NSData *)element {
    const uint8_t *info = element.bytes;
    if (element.length < 2) return @"?";
    A2DPCodec *codec = [self codecForElement:element];
    if (codec) return codec.displayName;
    if (info[1] == kCodecVendor && element.length >= 8) {
        return [NSString stringWithFormat:@"%X/%X", A2DPReadLE32(info + 2), A2DPReadLE16(info + 6)];
    }
    return [NSString stringWithFormat:@"%02X", info[1]];
}

+ (RemoteCodec *)remoteCodecForElement:(NSData *)element {
    A2DPCodec *codec = [self codecForElement:element];
    return [[RemoteCodec alloc] initWithCodec:codec.identifier name:[self nameForElement:element]
                                  sampleRates:codec ? [codec sampleRatesInCapability:element] : @[] element:element];
}

+ (NSString *)describeElement:(NSData *)element {
    const uint8_t *info = element.bytes;
    if (element.length < 2) return @"(invalid length)";
    const uint8_t *data = info + 2;
    size_t length = element.length - 2;
    A2DPCodec *codec = [self codecForElement:element];
    NSString *name = [self nameForElement:element];
    if (!codec) name = [name stringByAppendingString:@" (not implemented here)"];
    NSString *rates = @"";
    if (codec) {
        NSMutableArray *list = [NSMutableArray array];
        for (NSNumber *rate in [codec sampleRatesInCapability:element]) [list addObject:[NSString stringWithFormat:@"%g", rate.doubleValue / 1000]];
        rates = list.count ? [NSString stringWithFormat:@" (can stream %@ kHz)", [list componentsJoinedByString:@"/"]] : @" (no sample rate we support)";
    }
    return [NSString stringWithFormat:@"%@%@ [%@]", name, rates, BBHex(data, length)];
}

- (CodecID)identifier {
    [self doesNotRecognizeSelector:_cmd];
    return @"";
}

- (NSString *)displayName {
    [self doesNotRecognizeSelector:_cmd];
    return @"";
}

- (NSString *)vendorName {
    return @"";
}

- (NSInteger)rank {
    return 1000;
}

- (BOOL)isPremium {
    return NO;
}

- (NSArray<CodecPreset *> *)presets {
    return @[];
}

- (NSInteger)defaultPresetID {
    return self.presets.firstObject.identifier;
}

- (NSString *)credit {
    return nil;
}

- (NSURL *)creditURL {
    return nil;
}

- (NSString *)trademark {
    return nil;
}

- (NSArray<NSNumber *> *)badgeColors {
    return @[@0x8C8C8C, @0x6B6B6B];
}

- (NSData *)fullCapabilityElement {
    return [NSData data];
}

- (CodecPreset *)presetWithID:(NSInteger)identifier {
    for (CodecPreset *preset in self.presets) {
        if (preset.identifier == identifier) return preset;
    }
    return nil;
}

- (CodecPreset *)presetForOptions:(CodecOptions *)options {
    NSNumber *chosen = options.presets[self.identifier];
    CodecPreset *preset = chosen ? [self presetWithID:chosen.integerValue] : nil;
    return preset ?: [self presetWithID:self.defaultPresetID] ?: self.presets.firstObject;
}

- (BOOL)matchesElement:(NSData *)element {
    return NO;
}

- (NSArray<NSNumber *> *)sampleRatesInCapability:(NSData *)element {
    return @[];
}

- (CodecConfiguration *)configurationForCapability:(NSData *)element sampleRate:(double)rate options:(CodecOptions *)options {
    return nil;
}

- (BOOL)prepareWithError:(NSString **)error {
    return YES;
}

- (id<A2DPEncoder>)encoderForConfiguration:(CodecConfiguration *)configuration outMTU:(uint16_t)outMTU options:(CodecOptions *)options error:(NSString **)error {
    if (error) *error = @"Not implemented";
    return nil;
}

@end
