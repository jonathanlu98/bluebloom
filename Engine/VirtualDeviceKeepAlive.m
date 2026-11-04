#import "VirtualDeviceKeepAlive.h"
#import "BBLog.h"
#import <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stdlib.h>
#include "VirtualDeviceProtocol.h"

// How long pausePlaybackAndWait waits for the device to go silent. Apple Music fell silent 60–110 ms after the pause command
// (2026-11-04, sampled every 50 ms) and kept its IO running afterwards, so silence is judged by the samples, not by IO stopping
static const double kPauseWaitSeconds = 0.5;
static const useconds_t kPausePollMicroseconds = 30000;

static dispatch_source_t gTimer;
static id<NSObject> gActivity;
static BOOL gAtExitRegistered;

static AudioObjectID PlugInObject(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateBundleIDToPlugIn, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef bundleID = CFSTR(kBBPlugInBundleID);
    AudioObjectID plugIn = kAudioObjectUnknown;
    UInt32 size = sizeof(plugIn);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(bundleID), &bundleID, &size, &plugIn);
    return status == noErr ? plugIn : kAudioObjectUnknown;
}

static AudioObjectID DeviceObject(void) {
    AudioObjectPropertyAddress address = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef uid = CFSTR(kBBDeviceUID);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid), &uid, &size, &device);
    return status == noErr ? device : kAudioObjectUnknown;
}

// Whether the driver took the beat; NO when it is missing or predates kBBPropertyClientAlive
static BOOL Beat(int alive) {
    AudioObjectID plugIn = PlugInObject();
    if (plugIn == kAudioObjectUnknown) return NO;
    AudioObjectPropertyAddress address = { kBBPropertyClientAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(plugIn, &address)) return NO;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &alive);
    OSStatus status = AudioObjectSetPropertyData(plugIn, &address, 0, NULL, sizeof(number), &number);
    CFRelease(number);
    return status == noErr;
}

static BOOL RunningSomewhere(AudioObjectID device) {
    AudioObjectPropertyAddress address = { kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 running = 0;
    UInt32 size = sizeof(running);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &running) == noErr && running != 0;
}

// Fetches the frames written into the device from *cursor on (the driver hands the most recent kBBMaxChunkFrames when *cursor is
// further back, so 0 means "the last ~0.34 s at 48 kHz") and advances *cursor; returns how many came, and in *sound whether any
// sample was nonzero. The ring keeps old samples once IO stops, so callers check RunningSomewhere first
static UInt32 FetchFrames(AudioObjectID device, int64_t *cursor, BOOL *sound) {
    *sound = NO;
    CFNumberRef qualifier = CFNumberCreate(NULL, kCFNumberSInt64Type, cursor);
    AudioObjectPropertyAddress address = { kBBPropertyAudioData, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFDataRef data = NULL;
    UInt32 size = sizeof(data);
    OSStatus status = AudioObjectGetPropertyData(device, &address, sizeof(qualifier), &qualifier, &size, &data);
    CFRelease(qualifier);
    if (status != noErr || !data) return 0;
    BBAudioChunkHeader header;
    UInt32 frames = 0;
    if ((size_t)CFDataGetLength(data) >= sizeof(header)) {
        memcpy(&header, CFDataGetBytePtr(data), sizeof(header));
        size_t count = (size_t)header.frames * header.channels;
        if ((size_t)CFDataGetLength(data) >= sizeof(header) + count * sizeof(float)) {
            const float *samples = (const float *)(CFDataGetBytePtr(data) + sizeof(header));
            for (size_t i = 0; i < count && !*sound; i++) *sound = samples[i] != 0;
            frames = header.frames;
            *cursor = (int64_t)(header.startSample + header.frames);
        }
    }
    CFRelease(data);
    return frames;
}

// MediaRemote is a private framework; MRMediaRemoteSendCommand and kMRPause = 1 as in the app's MediaKeys
// (App/Sources/Services/Services.swift). The command goes to the Now Playing app, and does nothing when it is not playing
static BOOL SendPause(void) {
    static bool (*send)(uint32_t, CFDictionaryRef);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (handle) send = (bool (*)(uint32_t, CFDictionaryRef))dlsym(handle, "MRMediaRemoteSendCommand");
    });
    return send && send(1, NULL);
}

// The command-line tool ends with exit(); pause what it played and say goodbye then too (the app calls stop itself before quitting)
static void BeatGoneAtExit(void) {
    if (!gTimer) return;
    [VirtualDeviceKeepAlive pausePlaybackAndWait];
    Beat(0);
}

@implementation VirtualDeviceKeepAlive

+ (void)start {
    @synchronized (self) {
        if (gTimer) return;
        // A menu bar app without windows can be App Napped, which delays timers by many seconds; a late beat would make the
        // driver withdraw the device while Blue Bloom is running
        gActivity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                                                                 reason:@"Keeping the Blue Bloom audio device published"];
        dispatch_queue_t queue = dispatch_queue_create("bluebloom.keepalive", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        uint64_t interval = (uint64_t)(kBBClientAliveInterval * NSEC_PER_SEC);
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, interval / 8);
        dispatch_source_set_event_handler(gTimer, ^{ Beat(1); });
        dispatch_resume(gTimer);
        if (!gAtExitRegistered) {
            gAtExitRegistered = YES;
            atexit(BeatGoneAtExit);
        }
    }
    if (Beat(1)) {
        BBLog(@"Virtual device kept published while Blue Bloom runs (beat every %.0f s)", kBBClientAliveInterval);
    } else {
        BBLog(@"Virtual device driver does not take presence beats (missing, or older than version 6): the device stays published");
    }
}

+ (void)stop {
    BOOL wasRunning;
    @synchronized (self) {
        wasRunning = gTimer != nil;
        if (gTimer) {
            dispatch_source_cancel(gTimer);
            gTimer = nil;
        }
        if (gActivity) {
            [NSProcessInfo.processInfo endActivity:gActivity];
            gActivity = nil;
        }
    }
    if (!wasRunning) return;
    // Withdrawing the device moves whatever still plays into it to the speakers
    [self pausePlaybackAndWait];
    if (Beat(0)) BBLog(@"Told the virtual device driver that Blue Bloom is quitting");
}

+ (BOOL)waitForDevice:(double)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    for (;;) {
        if (DeviceObject() != kAudioObjectUnknown) return YES;
        if (deadline.timeIntervalSinceNow <= 0) return NO;
        // The HAL may deliver the device list change on the main run loop, so keep it running while waiting there
        if (NSThread.isMainThread) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        } else {
            usleep(50000);
        }
    }
}

+ (BOOL)pausePlaybackAndWait {
    AudioObjectID device = DeviceObject();
    if (device == kAudioObjectUnknown || !RunningSomewhere(device)) return NO;
    int64_t cursor = 0;
    BOOL sound = NO;
    FetchFrames(device, &cursor, &sound);
    if (!sound) return NO;
    BOOL sent = SendPause();
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    BOOL silent = NO;
    while (!silent && CFAbsoluteTimeGetCurrent() - start < kPauseWaitSeconds) {
        usleep(kPausePollMicroseconds);
        // IO stopping counts as silent too; nothing new written yet (between two IO cycles) does not
        if (!RunningSomewhere(device)) {
            silent = YES;
        } else {
            silent = FetchFrames(device, &cursor, &sound) > 0 && !sound;
        }
    }
    double waited = (CFAbsoluteTimeGetCurrent() - start) * 1000;
    if (!sent) {
        BBLog(@"Sound is playing into the Blue Bloom device, but the pause command could not be sent");
    } else if (silent) {
        BBLog(@"Sound was playing into the Blue Bloom device: asked the Now Playing app to pause, silent after %.0f ms", waited);
    } else {
        BBLog(@"Sound was playing into the Blue Bloom device: asked the Now Playing app to pause, still playing after %.0f ms (another program, or one that ignores the command)", waited);
    }
    return sent;
}

+ (void)pausePlaybackThen:(void (^)(void))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self pausePlaybackAndWait];
        dispatch_async(dispatch_get_main_queue(), done);
    });
}

@end
