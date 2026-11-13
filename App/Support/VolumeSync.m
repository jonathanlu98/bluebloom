#import "VolumeSync.h"
#import <CoreAudio/CoreAudio.h>
#include <math.h>
#include "VirtualDeviceProtocol.h"
#import "BBLog.h"

static AudioObjectID FindVirtualDevice(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR(kBBDeviceUID);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid), &uid, &size, &device);
    return device;
}

// Find the output volume control among the objects the device owns
static AudioObjectID FindVolumeControl(AudioObjectID device) {
    AudioObjectPropertyAddress address = { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr || size == 0) return kAudioObjectUnknown;
    AudioObjectID objects[16];
    size = MIN(size, (UInt32)sizeof(objects));
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, objects) != noErr) return kAudioObjectUnknown;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
        AudioObjectPropertyAddress classAddress = { kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioClassID objectClass = 0;
        UInt32 classSize = sizeof(objectClass);
        if (AudioObjectGetPropertyData(objects[i], &classAddress, 0, NULL, &classSize, &objectClass) == noErr && objectClass == kAudioVolumeControlClassID) {
            return objects[i];
        }
    }
    return kAudioObjectUnknown;
}

@implementation VolumeSync {
    AudioObjectID _device;
    AudioObjectID _control;
    AudioObjectPropertyListenerBlock _listener;
    BOOL _hardwareMode;
    BOOL _synced;           // whether the Mac volume has been sent over this AVRCP channel yet
    int _lastVolume;        // last volume known to match the headphones (0–127); change notifications caused by writing back to the virtual device equal it, which prevents feedback loops
}

- (instancetype)init {
    if ((self = [super init])) _lastVolume = -1;
    return self;
}

- (BOOL)attach {
    AudioObjectID device = FindVirtualDevice();
    if (device == kAudioObjectUnknown) return NO;
    if (device == _device && _control != kAudioObjectUnknown) return YES;
    BOOL wanted = _hardwareMode;
    [self detach];
    _device = device;
    _control = FindVolumeControl(device);
    if (_control == kAudioObjectUnknown) return NO;
    // A different device object (first use, or coreaudiod restarted): the driver's flag is whatever it was left at, not what
    // this object last wrote. Left off while the headphones' amplifier follows the volume, the volume would be applied twice
    [self setHardwareMode:wanted];
    __weak typeof(self) weakSelf = self;
    _listener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) { [weakSelf localVolumeChanged]; };
    AudioObjectPropertyAddress address = { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(_control, &address, dispatch_get_main_queue(), _listener);
    return YES;
}

- (void)detach {
    if (_listener && _control != kAudioObjectUnknown) {
        AudioObjectPropertyAddress address = { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectRemovePropertyListenerBlock(_control, &address, dispatch_get_main_queue(), _listener);
    }
    _listener = nil;
    _control = kAudioObjectUnknown;
    _device = kAudioObjectUnknown;
}

- (Float32)scalar {
    AudioObjectPropertyAddress address = { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float32 value = 0;
    UInt32 size = sizeof(value);
    AudioObjectGetPropertyData(_control, &address, 0, NULL, &size, &value);
    return value;
}

- (void)setScalar:(Float32)value {
    AudioObjectPropertyAddress address = { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectSetPropertyData(_control, &address, 0, NULL, sizeof(value), &value);
}

// The driver's own flag. It outlives this object (the app can be force-quit in hardware mode) and starts out off again when
// the driver is reloaded, so it is read from the driver rather than remembered
- (BOOL)driverHardwareMode {
    AudioObjectPropertyAddress address = { kBBPropertyHardwareVolume, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFPropertyListRef value = NULL;
    UInt32 size = sizeof(value);
    int enabled = 0;
    if (AudioObjectGetPropertyData(_device, &address, 0, NULL, &size, &value) != noErr || !value) return NO;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &enabled);
    CFRelease(value);
    return enabled != 0;
}

- (void)setHardwareMode:(BOOL)enabled {
    if (_device == kAudioObjectUnknown) return;
    if ([self driverHardwareMode] == enabled) {
        _hardwareMode = enabled;
        return;
    }
    AudioObjectPropertyAddress address = { kBBPropertyHardwareVolume, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    int value = enabled ? 1 : 0;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &value);
    OSStatus status = AudioObjectSetPropertyData(_device, &address, 0, NULL, sizeof(number), &number);
    CFRelease(number);
    // If the write failed the driver is still in the other mode; keep track of that so volumes are not also sent to the headphones
    _hardwareMode = status == noErr ? enabled : !enabled;
    BBLog(@"%@ (status %d)", enabled ? @"Volume now handled by the headphones' amplifier, synced with the headphones" : @"Volume back to software attenuation", (int)status);
}

static int ScalarToVolume(Float32 scalar) {
    return (int)lroundf(MAX(0, MIN(1, scalar)) * 127);
}

- (void)remoteVolumeChanged:(int)volume {
    if (volume < 0) {
        // AVRCP channel is gone: fall back to software volume
        _synced = NO;
        _lastVolume = -1;
        if ([self attach]) [self setHardwareMode:NO];
        return;
    }
    if (![self attach]) return;
    if (!_synced) {
        // Just connected: send the Mac's current volume to the headphones instead of adopting theirs, avoiding a volume jump the moment we switch to hardware volume
        _synced = YES;
        int local = ScalarToVolume([self scalar]);
        _lastVolume = local;
        [self setHardwareMode:YES];
        if (_sendVolumeHandler) _sendVolumeHandler(local);
        BBLog(@"Volume sync: headphones were at %d/127, set to %d/127 from the Mac's current volume", volume, local);
        return;
    }
    [self setHardwareMode:YES];
    if (volume == _lastVolume) return;
    // The headphones' buttons changed the volume: update the virtual device's volume display
    _lastVolume = volume;
    [self setScalar:volume / 127.0f];
}

- (void)localVolumeChanged {
    if (!_hardwareMode || !_synced) return;
    [self setHardwareMode:YES];
    if (!_hardwareMode) return;
    int volume = ScalarToVolume([self scalar]);
    if (volume == _lastVolume) return;
    _lastVolume = volume;
    if (_sendVolumeHandler) _sendVolumeHandler(volume);
}

- (void)stepVolume:(int)direction {
    if (![self attach]) return;
    // Step by 1/16, same as the macOS volume keys
    [self setScalar:MAX(0, MIN(1, [self scalar] + direction / 16.0f))];
}

- (void)dealloc {
    [self detach];
}

@end
