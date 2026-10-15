#import "SystemAudio.h"
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include "VirtualDeviceProtocol.h"

// Ring buffer capacity and maximum queue duration: when the queue exceeds the limit the oldest data is dropped, keeping latency to the headphones bounded
static const double kRingSeconds = 2.0;
static const double kMaxQueueSeconds = 0.25;

static NSString *StatusText(OSStatus status) {
    UInt32 code = CFSwapInt32HostToBig((UInt32)status);
    char text[5] = {0};
    memcpy(text, &code, 4);
    BOOL printable = YES;
    for (int i = 0; i < 4; i++) printable = printable && text[i] >= 32 && text[i] < 127;
    return printable ? [NSString stringWithFormat:@"%d ('%s')", (int)status, text] : [NSString stringWithFormat:@"%d", (int)status];
}

@implementation SystemAudioSource {
    AudioObjectID _tapID;
    AudioObjectID _aggregateID;
    AudioDeviceIOProcID _procID;
    AudioStreamBasicDescription _format;
    float *_ring;          // interleaved stereo float
    size_t _capacity;      // in frames
    _Atomic uint64_t _written;
    _Atomic uint64_t _read;
    _Atomic uint64_t _overflow;
    uint64_t _dropped;
    uint64_t _silentReads;
    Float64 _tapNominalRate;
    BOOL _running;
    BOOL _ownsDevice;
    NSString *_sourceName;
    _Atomic uint64_t _lastSoundTicks;
    AudioObjectPropertyListenerBlock _rateListener;
    // Virtual device mode: periodically read a custom property to fetch sound (no input is opened, so macOS does not show the microphone as in use)
    BOOL _pollMode;
    dispatch_queue_t _pollQueue;
    dispatch_source_t _pollTimer;
    int64_t _cursor;
    uint64_t _generation;
}

- (instancetype)initWithError:(NSString **)error {
    if (!(self = [super init])) return nil;
    CATapDescription *description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    description.name = @"Blue Bloom";
    description.privateTap = YES;
    // Not sent to the local output device while being read: the Mac speakers are muted while streaming to the headphones and restored automatically when it stops
    description.muteBehavior = CATapMutedWhenTapped;
    OSStatus status = AudioHardwareCreateProcessTap(description, &_tapID);
    if (status != noErr) {
        if (error) *error = [NSString stringWithFormat:@"Failed to create the system audio tap: %@", StatusText(status)];
        return nil;
    }

    AudioObjectPropertyAddress address = { kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 size = sizeof(_format);
    status = AudioObjectGetPropertyData(_tapID, &address, 0, NULL, &size, &_format);
    if (status != noErr || _format.mFormatID != kAudioFormatLinearPCM || !(_format.mFormatFlags & kAudioFormatFlagIsFloat) ||
        _format.mBitsPerChannel != 32 || _format.mChannelsPerFrame < 1) {
        if (error) *error = [NSString stringWithFormat:@"Unsupported tap format (%@, flags 0x%x, %u bit, %u channels)", StatusText(status),
                             (unsigned)_format.mFormatFlags, (unsigned)_format.mBitsPerChannel, (unsigned)_format.mChannelsPerFrame];
        [self stop];
        return nil;
    }

    NSString *outputUID = [self defaultOutputUID];
    if (!outputUID) {
        if (error) *error = @"Cannot read the default output device";
        [self stop];
        return nil;
    }
    // Put the tap into a private aggregate device clocked by the default output device, and read data from its input
    NSDictionary *aggregate = @{
        @kAudioAggregateDeviceNameKey: @"Blue Bloom System Audio",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceIsStackedKey: @NO,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceSubDeviceListKey: @[@{ @kAudioSubDeviceUIDKey: outputUID }],
        @kAudioAggregateDeviceTapListKey: @[@{ @kAudioSubTapUIDKey: description.UUID.UUIDString, @kAudioSubDeviceDriftCompensationKey: @YES }],
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &_aggregateID);
    if (status != noErr) {
        if (error) *error = [NSString stringWithFormat:@"Failed to create the aggregate device: %@", StatusText(status)];
        [self stop];
        return nil;
    }
    // Observed: the tap reports a nominal 48000, but data arrives on the clock of the aggregate device (i.e. the default output device); with the speakers at 44100 it really is 44100.
    // Use the aggregate device's actual sample rate; otherwise the rate configured on the headphones is too high and their buffer keeps underrunning, causing dropouts
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 deviceRate = 0;
    size = sizeof(deviceRate);
    status = AudioObjectGetPropertyData(_aggregateID, &rateAddress, 0, NULL, &size, &deviceRate);
    if (status != noErr || deviceRate <= 0) {
        if (error) *error = [NSString stringWithFormat:@"Cannot read the aggregate device sample rate: %@", StatusText(status)];
        [self stop];
        return nil;
    }
    _tapNominalRate = _format.mSampleRate;
    _format.mSampleRate = deviceRate;
    _ownsDevice = YES;
    _sourceName = [NSString stringWithFormat:@"system audio tap (nominal %.0f Hz, actual output device clock used)", _tapNominalRate];

    _capacity = (size_t)(_format.mSampleRate * kRingSeconds);
    _ring = calloc(_capacity * 2, sizeof(float));
    return self;
}

- (instancetype)initWithDeviceUID:(NSString *)uid error:(NSString **)error {
    if (!(self = [super init])) return nil;
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef qualifier = (__bridge CFStringRef)uid;
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(qualifier), &qualifier, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) {
        if (error) *error = [NSString stringWithFormat:@"Virtual device %@ not found; install BlueBloom.driver and restart coreaudiod first", uid];
        return nil;
    }
    AudioObjectPropertyAddress dataAddress = { kBBPropertyAudioData, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(device, &dataAddress)) {
        if (error) *error = @"Virtual device driver is outdated (no property for fetching sound); update the virtual device from the menu";
        return nil;
    }
    Float64 rate = 0;
    address = (AudioObjectPropertyAddress){ kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    size = sizeof(rate);
    status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &rate);
    if (status != noErr || rate <= 0) {
        if (error) *error = [NSString stringWithFormat:@"Cannot read the virtual device sample rate: %@", StatusText(status)];
        return nil;
    }
    // Data from the driver is always float32 interleaved stereo (VirtualDeviceProtocol.h)
    _format = (AudioStreamBasicDescription){
        .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
    _aggregateID = device;
    _ownsDevice = NO;
    _pollMode = YES;
    // When the user changes the sample rate in Audio MIDI Setup, or a player changes it, notify the upper layer to reconfigure aptX at the new rate
    __weak typeof(self) weakSelf = self;
    _rateListener = ^(UInt32 count, const AudioObjectPropertyAddress *addresses) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_sampleRateChangedHandler) return;
        AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Float64 rate = 0;
        UInt32 rateSize = sizeof(rate);
        if (AudioObjectGetPropertyData(device, &rateAddress, 0, NULL, &rateSize, &rate) == noErr) strongSelf->_sampleRateChangedHandler(rate);
    };
    AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(device, &rateAddress, dispatch_get_main_queue(), _rateListener);
    _sourceName = [NSString stringWithFormat:@"virtual device %@", uid];
    _capacity = (size_t)(_format.mSampleRate * kRingSeconds);
    _ring = calloc(_capacity * 2, sizeof(float));
    return self;
}

- (NSString *)defaultOutputUID {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) return nil;
    address.mSelector = kAudioDevicePropertyDeviceUID;
    CFStringRef uid = NULL;
    size = sizeof(uid);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &uid) != noErr || !uid) return nil;
    return (__bridge_transfer NSString *)uid;
}

- (double)sampleRate {
    return _format.mSampleRate;
}

- (NSString *)formatDescription {
    return [NSString stringWithFormat:@"%.0f Hz × %u channels float32%@, from %@", _format.mSampleRate,
            (unsigned)_format.mChannelsPerFrame, (_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? @", non-interleaved" : @"", _sourceName];
}

- (double)deviceSampleRate {
    if (!_pollMode) return _format.mSampleRate;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    return AudioObjectGetPropertyData(_aggregateID, &address, 0, NULL, &size, &rate) == noErr ? rate : _format.mSampleRate;
}

- (BOOL)setDeviceSampleRate:(double)rate {
    if (!_pollMode) return NO;
    AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    Float64 value = rate;
    return AudioObjectSetPropertyData(_aggregateID, &address, 0, NULL, sizeof(value), &value) == noErr;
}

- (uint64_t)capturedFrames {
    return atomic_load(&_written) + atomic_load(&_overflow);
}

- (uint64_t)droppedFrames {
    return _dropped + atomic_load(&_overflow);
}

- (uint64_t)silentReads {
    return _silentReads;
}

- (double)secondsSinceSound {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    uint64_t last = atomic_load_explicit(&_lastSoundTicks, memory_order_relaxed);
    return (double)(mach_absolute_time() - last) * timebase.numer / timebase.denom / 1e9;
}

- (BOOL)start:(NSString **)error {
    if (_running) return YES;
    if (_pollMode) {
        [self startPolling];
        return YES;
    }
    float *ring = _ring;
    size_t capacity = _capacity;
    UInt32 channels = _format.mChannelsPerFrame;
    BOOL nonInterleaved = (_format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    _Atomic uint64_t *written = &_written;
    _Atomic uint64_t *read = &_read;
    _Atomic uint64_t *overflow = &_overflow;
    _Atomic uint64_t *lastSound = &_lastSoundTicks;
    atomic_store(&_lastSoundTicks, mach_absolute_time());
    // IO thread: copy only; single-producer single-consumer ring buffer
    OSStatus status = AudioDeviceCreateIOProcIDWithBlock(&_procID, _aggregateID, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime) {
        if (!input || input->mNumberBuffers == 0) return;
        UInt32 frames = nonInterleaved ? input->mBuffers[0].mDataByteSize / sizeof(float)
                                       : input->mBuffers[0].mDataByteSize / (UInt32)(sizeof(float) * channels);
        const float *left = input->mBuffers[0].mData;
        const float *right = nonInterleaved && input->mNumberBuffers > 1 ? input->mBuffers[1].mData : NULL;
        // Check for sound before checking whether the buffer is full: the buffer fills up while the upper layer has streaming paused, and sound must still be detected then so streaming can resume
        BOOL sound = NO;
        UInt32 samples = nonInterleaved ? frames : frames * channels;
        for (UInt32 i = 0; i < samples && !sound; i++) sound = left[i] != 0 || (right && right[i] != 0);
        if (sound) atomic_store_explicit(lastSound, mach_absolute_time(), memory_order_relaxed);
        uint64_t head = atomic_load_explicit(written, memory_order_relaxed);
        uint64_t tail = atomic_load_explicit(read, memory_order_acquire);
        if (head - tail + frames > capacity) {
            atomic_fetch_add_explicit(overflow, frames, memory_order_relaxed);
            return;
        }
        for (UInt32 i = 0; i < frames; i++) {
            size_t slot = (size_t)((head + i) % capacity) * 2;
            if (nonInterleaved) {
                ring[slot] = left[i];
                ring[slot + 1] = right ? right[i] : left[i];
            } else {
                ring[slot] = left[i * channels];
                ring[slot + 1] = channels > 1 ? left[i * channels + 1] : left[i * channels];
            }
        }
        atomic_store_explicit(written, head + frames, memory_order_release);
    });
    if (status == noErr) status = AudioDeviceStart(_aggregateID, _procID);
    if (status != noErr) {
        if (error) *error = [NSString stringWithFormat:@"Failed to start capture: %@", StatusText(status)];
        return NO;
    }
    _running = YES;
    return YES;
}

- (size_t)availableFrames {
    uint64_t head = atomic_load_explicit(&_written, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&_read, memory_order_relaxed);
    size_t available = (size_t)(head - tail);
    size_t limit = (size_t)(_format.mSampleRate * kMaxQueueSeconds);
    if (available > limit) {
        // Streaming cannot keep up (link congested): drop the oldest data and bring the queue back down to half the limit
        size_t skip = available - limit / 2;
        atomic_store_explicit(&_read, tail + skip, memory_order_release);
        _dropped += skip;
        available -= skip;
    }
    return available;
}

- (void)keepRecentOnly {
    uint64_t head = atomic_load_explicit(&_written, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&_read, memory_order_relaxed);
    size_t keep = (size_t)(_format.mSampleRate * kMaxQueueSeconds / 2);
    if (head - tail > keep) atomic_store_explicit(&_read, head - keep, memory_order_release);
}

- (size_t)read:(uint8_t *)output frames:(size_t)frames {
    uint64_t head = atomic_load_explicit(&_written, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&_read, memory_order_relaxed);
    size_t available = MIN((size_t)(head - tail), frames);
    BOOL silent = YES;
    for (size_t i = 0; i < available; i++) {
        size_t slot = (size_t)((tail + i) % _capacity) * 2;
        float left = _ring[slot], right = _ring[slot + 1];
        if (left != 0 || right != 0) silent = NO;
        PutS24(output + i * kPCMBytesPerSample, left);
        PutS24(output + i * kPCMBytesPerSample + 3, right);
    }
    atomic_store_explicit(&_read, tail + available, memory_order_release);
    // A capture source never "ends": pad with silence when data runs short and always return the requested count
    memset(output + available * kPCMBytesPerSample, 0, (frames - available) * kPCMBytesPerSample);
    if (silent) _silentReads++;
    return frames;
}

// Every 10ms, fetch newly written sound from the driver's ring buffer (the headphones buffer about 220ms, so a 10ms fetch interval does not affect continuity)
- (void)startPolling {
    _cursor = -1;
    _generation = 0;
    atomic_store(&_lastSoundTicks, mach_absolute_time());
    _pollQueue = dispatch_queue_create("aptx.device-poll", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pollQueue);
    dispatch_source_set_timer(_pollTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{ [weakSelf poll]; });
    dispatch_resume(_pollTimer);
    _running = YES;
}

- (void)poll {
    CFNumberRef cursor = CFNumberCreate(NULL, kCFNumberSInt64Type, &_cursor);
    AudioObjectPropertyAddress address = { kBBPropertyAudioData, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef data = NULL;
    UInt32 size = sizeof(data);
    OSStatus status = AudioObjectGetPropertyData(_aggregateID, &address, sizeof(cursor), &cursor, &size, &data);
    CFRelease(cursor);
    if (status != noErr || !data) return;
    BBAudioChunkHeader header;
    if ((size_t)CFDataGetLength(data) < sizeof(header)) {
        CFRelease(data);
        return;
    }
    memcpy(&header, CFDataGetBytePtr(data), sizeof(header));
    size_t expected = sizeof(header) + (size_t)header.frames * header.channels * sizeof(float);
    if (header.channels == 2 && (size_t)CFDataGetLength(data) >= expected) {
        _generation = header.generation;
        _cursor = (int64_t)(header.startSample + header.frames);
        [self appendInterleaved:(const float *)(CFDataGetBytePtr(data) + sizeof(header)) frames:header.frames];
    }
    CFRelease(data);
}

// The fetch thread writes into the ring buffer (single producer), the same way the IOProc does
- (void)appendInterleaved:(const float *)samples frames:(UInt32)frames {
    if (frames == 0) return;
    BOOL sound = NO;
    for (UInt32 i = 0; i < frames * 2 && !sound; i++) sound = samples[i] != 0;
    if (sound) atomic_store_explicit(&_lastSoundTicks, mach_absolute_time(), memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&_written, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&_read, memory_order_acquire);
    if (head - tail + frames > _capacity) {
        atomic_fetch_add_explicit(&_overflow, frames, memory_order_relaxed);
        return;
    }
    for (UInt32 i = 0; i < frames; i++) {
        size_t slot = (size_t)((head + i) % _capacity) * 2;
        _ring[slot] = samples[i * 2];
        _ring[slot + 1] = samples[i * 2 + 1];
    }
    atomic_store_explicit(&_written, head + frames, memory_order_release);
}

- (void)stop {
    if (_pollTimer) {
        dispatch_source_cancel(_pollTimer);
        // Wait for a fetch that may be running on the fetch thread to finish; only then can the buffer be freed safely
        dispatch_sync(_pollQueue, ^{});
        _pollTimer = nil;
        _running = NO;
    }
    if (_running) {
        AudioDeviceStop(_aggregateID, _procID);
        _running = NO;
    }
    if (_procID) {
        AudioDeviceDestroyIOProcID(_aggregateID, _procID);
        _procID = NULL;
    }
    if (_rateListener && _aggregateID != kAudioObjectUnknown) {
        AudioObjectPropertyAddress rateAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectRemovePropertyListenerBlock(_aggregateID, &rateAddress, dispatch_get_main_queue(), _rateListener);
        _rateListener = nil;
    }
    if (_aggregateID != kAudioObjectUnknown) {
        if (_ownsDevice) AudioHardwareDestroyAggregateDevice(_aggregateID);
        _aggregateID = kAudioObjectUnknown;
    }
    if (_tapID != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(_tapID);
        _tapID = kAudioObjectUnknown;
    }
}

- (void)dealloc {
    [self stop];
    free(_ring);
}

@end
