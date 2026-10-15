#import "HeadsetAudioGuard.h"
#import <CoreAudio/CoreAudio.h>

// The three system default devices to guard: output, input, alert sound output (observed: macOS switches all three to the headphones at once)
static const AudioObjectPropertySelector kDefaultSelectors[] = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice,
};
#define kDefaultCount (sizeof(kDefaultSelectors) / sizeof(kDefaultSelectors[0]))

static NSString *DefaultName(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioHardwarePropertyDefaultOutputDevice: return @"default output";
        case kAudioHardwarePropertyDefaultInputDevice: return @"default input";
        default: return @"alert sound output";
    }
}

static AudioObjectPropertyAddress GlobalAddress(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){ selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
}

static NSString *DeviceString(AudioObjectID device, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = GlobalAddress(selector);
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr || !value) return nil;
    return (__bridge_transfer NSString *)value;
}

static BOOL HasStreams(AudioObjectID device, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, scope, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    return AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) == noErr && size > 0;
}

@implementation HeadsetAudioGuard {
    NSString *_uidPrefix;
    AudioObjectID _preferred[kDefaultCount];
    NSMutableSet<NSNumber *> *_announced;
    NSMutableArray *_listeners;   // @[address data, block], removed one by one on stop
    BOOL _running;
}

- (instancetype)initWithAddress:(NSString *)address {
    if ((self = [super init])) {
        // coreaudiod device UIDs look like "AA-BB-CC-DD-EE-01:output"
        _uidPrefix = [[address uppercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        _announced = [NSMutableSet set];
        _listeners = [NSMutableArray array];
    }
    return self;
}

- (void)log:(NSString *)message {
    if (_logHandler) _logHandler(message);
}

- (BOOL)isHeadsetDevice:(AudioObjectID)device {
    NSString *uid = [[DeviceString(device, kAudioDevicePropertyDeviceUID) uppercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    return [uid hasPrefix:_uidPrefix];
}

- (NSString *)describe:(AudioObjectID)device {
    return [NSString stringWithFormat:@"%@ (%@)", DeviceString(device, kAudioObjectPropertyName) ?: @"?",
            DeviceString(device, kAudioDevicePropertyDeviceUID) ?: @"?"];
}

- (AudioObjectID)currentDefault:(AudioObjectPropertySelector)selector {
    AudioObjectPropertyAddress address = GlobalAddress(selector);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    return device;
}

- (NSArray<NSNumber *> *)allDevices {
    AudioObjectPropertyAddress address = GlobalAddress(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, data.mutableBytes) != noErr) return @[];
    const AudioObjectID *ids = data.bytes;
    NSMutableArray *devices = [NSMutableArray array];
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [devices addObject:@(ids[i])];
    return devices;
}

// The default device is already the headphones at start: fall back to the built-in device
- (AudioObjectID)fallbackFor:(AudioObjectPropertySelector)selector {
    AudioObjectPropertyScope scope = selector == kAudioHardwarePropertyDefaultInputDevice ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
    for (NSNumber *number in [self allDevices]) {
        AudioObjectID device = number.unsignedIntValue;
        AudioObjectPropertyAddress address = GlobalAddress(kAudioDevicePropertyTransportType);
        UInt32 transport = 0, size = sizeof(transport);
        AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport);
        if (transport == kAudioDeviceTransportTypeBuiltIn && HasStreams(device, scope)) return device;
    }
    return kAudioObjectUnknown;
}

- (void)addListener:(AudioObjectPropertySelector)selector block:(dispatch_block_t)block {
    AudioObjectPropertyAddress address = GlobalAddress(selector);
    AudioObjectPropertyListenerBlock listener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) { block(); };
    if (AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, dispatch_get_main_queue(), listener) == noErr) {
        [_listeners addObject:@[[NSData dataWithBytes:&address length:sizeof(address)], listener]];
    }
}

- (void)start {
    if (_running) return;
    _running = YES;
    __weak typeof(self) weakSelf = self;
    for (size_t i = 0; i < kDefaultCount; i++) {
        AudioObjectPropertySelector selector = kDefaultSelectors[i];
        AudioObjectID current = [self currentDefault:selector];
        _preferred[i] = [self isHeadsetDevice:current] ? [self fallbackFor:selector] : current;
        [self addListener:selector block:^{ [weakSelf defaultChanged:i]; }];
    }
    [self addListener:kAudioHardwarePropertyDevices block:^{ [weakSelf devicesChanged]; }];
    [self devicesChanged];
    for (size_t i = 0; i < kDefaultCount; i++) [self defaultChanged:i];
}

- (void)devicesChanged {
    if (!_running) return;
    NSMutableSet<NSNumber *> *present = [NSMutableSet set];
    for (NSNumber *number in [self allDevices]) {
        if (![self isHeadsetDevice:number.unsignedIntValue]) continue;
        [present addObject:number];
        if (![_announced containsObject:number]) {
            [self log:[NSString stringWithFormat:@"macOS published the headphones call device %@: SCO will open if any program uses it", [self describe:number.unsignedIntValue]]];
        }
    }
    _announced = present;
}

- (void)defaultChanged:(size_t)index {
    if (!_running) return;
    AudioObjectPropertySelector selector = kDefaultSelectors[index];
    AudioObjectID current = [self currentDefault:selector];
    if (current == kAudioObjectUnknown) return;
    if (![self isHeadsetDevice:current]) {
        // The user changed the device themselves: switch back to this one from now on
        _preferred[index] = current;
        return;
    }
    AudioObjectID target = _preferred[index];
    if (target == kAudioObjectUnknown) {
        [self log:[NSString stringWithFormat:@"The %@ was switched to the headphones call device, but there is no device to switch back to", DefaultName(selector)]];
        return;
    }
    AudioObjectPropertyAddress address = GlobalAddress(selector);
    OSStatus status = AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(target), &target);
    [self log:[NSString stringWithFormat:@"macOS switched the %@ to the headphones call device, %@ %@", DefaultName(selector),
               status == noErr ? @"switched back to" : [NSString stringWithFormat:@"switching back failed (status %d):", (int)status], [self describe:target]]];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    for (NSArray *entry in _listeners) {
        AudioObjectPropertyAddress address;
        [entry[0] getBytes:&address length:sizeof(address)];
        AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, dispatch_get_main_queue(), entry[1]);
    }
    [_listeners removeAllObjects];
}

- (void)dealloc {
    [self stop];
}

@end
