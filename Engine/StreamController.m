#import "StreamController.h"
#import "BBLog.h"
#include <mach/mach_time.h>

@implementation StreamController {
    BOOL _virtualDevice;
    A2DPSource *_session;
    NSMutableArray<dispatch_block_t> *_stopCompletions;  // completions from stop calls made while already stopping are queued and called together once the session really ends
    NSUInteger _generation;
    // Capabilities found by the last session: the UI can still show them between sessions (while waiting to reconnect)
    NSArray<RemoteCodec *> *_lastRemoteCodecs;
    BOOL _connectRequested;   // The next session is an attempt the user asked for (connectNow)
    LinkStatus _outcome;      // How the last attempt ended, shown while waiting for the headphones; LinkStatusStandby when there is nothing to report
    LinkStatus _sessionStatus;  // Last status the current session reported
    BOOL _releaseNextLink;      // The last session's headphones left (powered off) with the link still up
    uint64_t _launchTicks;
}

- (instancetype)initWithDevice:(IOBluetoothDevice *)device virtualDevice:(BOOL)virtualDevice {
    if ((self = [super init])) {
        _device = device;
        _virtualDevice = virtualDevice;
        _status = LinkStatusStopped;
        _stopCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)report:(LinkStatus)status rate:(double)rate battery:(int)battery {
    _status = status;
    if (_statusHandler) _statusHandler(status, rate, battery);
}

// While a session only waits for the headphones, keep showing how the last attempt ended
- (void)session:(NSUInteger)generation reported:(LinkStatus)status rate:(double)rate battery:(int)battery {
    if (generation != _generation) return;
    _sessionStatus = status;
    if (status == LinkStatusStandby) {
        [self report:_outcome rate:0 battery:-1];
        return;
    }
    _outcome = LinkStatusStandby;
    [self report:status rate:rate battery:battery];
}

- (void)start {
    if (_running) return;
    _running = YES;
    _outcome = LinkStatusStandby;
    [self launch];
}

- (void)connectNow {
    _connectRequested = YES;
    if (!_running) {
        [self start];
        return;
    }
    BBLog(@"Connecting at the user's request");
    if (_session) {
        [_session stopWithReason:@"connect requested" exitCode:SourceExitRetryNow];
        return;
    }
    [self launch];
}

- (void)launch {
    if (!_running) return;
    BOOL requested = _connectRequested;
    _connectRequested = NO;
    A2DPSource *session = [[A2DPSource alloc] initWithDevice:_device mode:SourceModePlay rate:0 file:nil seconds:0 systemAudio:!_virtualDevice];
    session.useVirtualDevice = _virtualDevice;
    session.waitForLink = !requested;
    session.releaseLingeringLink = !requested && _releaseNextLink;
    _releaseNextLink = NO;
    _launchTicks = mach_absolute_time();
    if (_optionsProvider) session.options = _optionsProvider();
    session.desiredSampleRate = _desiredSampleRate;
    __weak typeof(self) weakSelf = self;
    NSUInteger generation = ++_generation;
    session.statusHandler = ^(LinkStatus status, double rate, int battery) {
        [weakSelf session:generation reported:status rate:rate battery:battery];
    };
    session.capabilitiesHandler = ^BOOL(NSArray<RemoteCodec *> *codecs) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return YES;
        strongSelf->_lastRemoteCodecs = codecs;
        return strongSelf->_capabilitiesHandler ? strongSelf->_capabilitiesHandler(codecs) : YES;
    };
    session.remoteControlBlockedHandler = ^(BOOL blocked) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_remoteControlBlockedHandler) strongSelf->_remoteControlBlockedHandler(blocked);
    };
    session.codecLimitHandler = ^(CodecID codec, double maxKbps) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_codecLimitHandler) strongSelf->_codecLimitHandler(codec, maxKbps);
    };
    session.remoteVolumeHandler = ^(int volume) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_remoteVolumeHandler) strongSelf->_remoteVolumeHandler(volume);
    };
    session.remoteOperationHandler = ^(uint8_t operation) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_remoteOperationHandler) strongSelf->_remoteOperationHandler(operation);
    };
    session.terminationHandler = ^(int exitCode) { [weakSelf session:generation endedWithCode:exitCode]; };
    _session = session;
    [session start];
}

- (void)session:(NSUInteger)generation endedWithCode:(int)exitCode {
    if (generation != _generation) return;
    A2DPSource *ended = _session;
    _session = nil;
    if (!_running) {
        [self report:LinkStatusStopped rate:0 battery:-1];
        NSArray<dispatch_block_t> *completions = [_stopCompletions copy];
        [_stopCompletions removeAllObjects];
        for (dispatch_block_t completion in completions) completion();
        return;
    }
    if (exitCode == SourceExitHandedToSystem) {
        BBLog(@"Headphones handed to macOS to connect, not reconnecting (re-enabled when settings change)");
        [self report:LinkStatusSystem rate:0 battery:-1];
        return;
    }
    if (exitCode == SourceExitRetryNow) {
        [self launch];
        return;
    }
    // Never retry on our own (each attempt is another contest with macOS for the headphones, and pages that find no headphones
    // hold up the radio): wait for the headphones to connect by themselves right away, which also catches bluetoothd reconnecting
    // within a second after the link dropped (observed 0.3 s after link timeouts, 2026-10-18). A session that was streaming
    // ended normally (dropped link, headphones powered off); otherwise show why the attempt ended until the next one starts
    BOOL streamed = _sessionStatus == LinkStatusStreaming || _sessionStatus == LinkStatusIdle;
    if (streamed || _sessionStatus == LinkStatusStandby) _outcome = LinkStatusStandby;
    else if (exitCode == SourceExitHeadsetBusy) _outcome = LinkStatusBusy;
    else if (_sessionStatus == LinkStatusWaitingHeadset) _outcome = LinkStatusWaitingHeadset;
    else _outcome = LinkStatusFailed;
    _releaseNextLink = ended.headphonesLeft;
    BBLog(@"Session ended (code %d), waiting for the headphones to connect by themselves", exitCode);
    // A waiting session that ended without streaming within 2 s: wait as long before the next, so nothing can cycle quickly
    if (ended.waitForLink && !streamed && BBTicksToSeconds(mach_absolute_time() - _launchTicks) < 2) {
        NSUInteger current = _generation;
        [self report:_outcome rate:0 battery:-1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self->_running && !self->_session && self->_generation == current) [self launch];
        });
        return;
    }
    [self launch];
}

- (BOOL)setRemoteVolume:(int)volume {
    return [_session setRemoteVolume:volume];
}

- (void)updateOptions:(CodecOptions *)options {
    [_session updateOptions:options];
}

- (void)setDesiredSampleRate:(double)rate {
    _desiredSampleRate = rate;
    _session.desiredSampleRate = rate;
}

- (CodecConfiguration *)configuration {
    return _session.configuration;
}

- (NSArray<RemoteCodec *> *)remoteCodecs {
    return _session.remoteCodecs ?: _lastRemoteCodecs;
}

- (CodecID)fallbackCodec {
    return _session.fallbackCodec;
}

- (CodecFallbackReason)fallbackReason {
    return _session.fallbackReason;
}

- (double)recentKbps {
    return _session.recentKbps;
}

- (double)headsetDelayMs {
    return _session.headsetDelayMs;
}

- (NSUUID *)deviceIdentifier {
    return _session.deviceIdentifier;
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    _connectRequested = NO;
    if (!_running) {
        // Stopping in progress (the session has not ended yet): call back once it ends; if already stopped, call back right away
        if (_session && completion) [_stopCompletions addObject:[completion copy]];
        else if (completion) completion();
        return;
    }
    _running = NO;
    if (_session) {
        if (completion) [_stopCompletions addObject:[completion copy]];
        [_session stopWithReason:@"disabled" exitCode:0];
    } else {
        [self report:LinkStatusStopped rate:0 battery:-1];
        if (completion) completion();
    }
}

@end
