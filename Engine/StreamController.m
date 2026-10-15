#import "StreamController.h"
#import "BBLog.h"

// After a session ends, wait this long before reconnecting
static const double kRetrySeconds = 5;
// When the headphones keep refusing to set up the stream (SourceExitHeadsetBusy), the reconnect interval doubles each time, up to this long; reset after streaming succeeds.
// Observed (2026-10-13 20:34–20:36): with a WH-1000XM4 also connected to an iPhone, a "connect → refused → disconnect" round every 5 seconds made the headphones power themselves off after a dozen-odd rounds
static const double kBusyRetryMaxSeconds = 60;

@implementation StreamController {
    BOOL _virtualDevice;
    A2DPSource *_session;
    NSMutableArray<dispatch_block_t> *_stopCompletions;  // completions from stop calls made while already stopping are queued and called together once the session really ends
    NSUInteger _generation;
    // Capabilities found by the last session: the UI can still show them between sessions (while waiting to reconnect)
    NSArray<RemoteCodec *> *_lastRemoteCodecs;
    NSUInteger _busyStreak;
    NSUInteger _retryToken;  // incremented for each scheduled reconnect; retry now cancels the one already scheduled
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
    if (status == LinkStatusStreaming) _busyStreak = 0;
    _status = status;
    if (_statusHandler) _statusHandler(status, rate, battery);
}

- (void)start {
    if (_running) return;
    _running = YES;
    _busyStreak = 0;
    [self launch];
}

- (void)launch {
    if (!_running) return;
    _nextAttempt = nil;
    A2DPSource *session = [[A2DPSource alloc] initWithDevice:_device mode:SourceModePlay rate:0 file:nil seconds:0 systemAudio:!_virtualDevice];
    session.useVirtualDevice = _virtualDevice;
    if (_optionsProvider) session.options = _optionsProvider();
    session.desiredSampleRate = _desiredSampleRate;
    __weak typeof(self) weakSelf = self;
    session.statusHandler = ^(LinkStatus status, double rate, int battery) {
        [weakSelf report:status rate:rate battery:battery];
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
    NSUInteger generation = ++_generation;
    session.terminationHandler = ^(int exitCode) { [weakSelf session:generation endedWithCode:exitCode]; };
    _session = session;
    [session start];
}

- (void)session:(NSUInteger)generation endedWithCode:(int)exitCode {
    if (generation != _generation) return;
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
    double delay = kRetrySeconds;
    LinkStatus status = LinkStatusRetrying;
    if (exitCode == SourceExitHeadsetBusy) {
        delay = MIN(kRetrySeconds * (double)(1u << MIN(_busyStreak, 4u)), kBusyRetryMaxSeconds);
        _busyStreak++;
        status = LinkStatusBusy;
        BBLog(@"Headphones refused to set up the stream (attempt %lu): most likely in use by another device, retrying in %.0f s", (unsigned long)_busyStreak, delay);
    } else {
        BBLog(@"Session ended (code %d), reconnecting in %.0f s", exitCode, delay);
    }
    _nextAttempt = [NSDate dateWithTimeIntervalSinceNow:delay];
    NSUInteger token = ++_retryToken;
    [self report:status rate:0 battery:-1];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_running && !self->_session && generation == self->_generation && token == self->_retryToken) [self launch];
    });
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

- (void)retryNow {
    if (!_running) return;
    BBLog(@"Retry now");
    _busyStreak = 0;
    if (_session) {
        [_session stopWithReason:@"retry now" exitCode:SourceExitRetryNow];
        return;
    }
    _retryToken++;
    [self launch];
}

- (void)stopWithCompletion:(dispatch_block_t)completion {
    _nextAttempt = nil;
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
