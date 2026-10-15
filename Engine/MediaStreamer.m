#import "MediaStreamer.h"
#import "BBLog.h"
#import "SystemAudio.h"
#include <mach/mach_time.h>
#include <math.h>
#include <poll.h>
#include <sys/socket.h>

// The media socket is SOCK_STREAM and bluetoothd reads at most outgoing-MTU bytes at a time as one SDU: only one packet may sit in the buffer at a time for each read to be exactly one whole packet
// (observed 2026-10-13: with room for 3 packets, SDU boundaries drift after a backlog). Limiting the buffer size alone is not enough: several small packets (AAC silent stretches are a few dozen bytes) get squeezed together and read as one SDU.
// So the send low-water mark is set to the buffer size: when poll reports writable the buffer is empty (verified with socketpair 2026-10-13), and only then is the next packet written.
// Queuing is left to the upstream PCM queue (SystemAudioSource 250ms); nothing more needs to be held here
static const int kMediaSendBufferPackets = 1;

static BOOL SendBufferEmpty(int fd) {
    struct pollfd p = { .fd = fd, .events = POLLOUT };
    return poll(&p, 1, 0) > 0 && (p.revents & POLLOUT);
}
// Test tone, file: send about 2 encode calls' worth ahead to fill the headphones' buffer; when more than 300ms behind, drop PCM before encoding to catch up with the clock
static const double kPrefillCalls = 2;
static const double kMaxLagSeconds = 0.3;
// If nothing can be written into the media channel for this long, it counts as stuck: the headphones stopped accepting (observed 2026-10-13 23:57: some headphones' audio path locks up after a frame longer than their limit,
// the send buffer stays full, not one packet goes out over the next 70 seconds, and switching back to small frames does not recover it); the stream will not heal on its own
static const double kStallSeconds = 3;
// For this long after the stream opens or resumes from pause, report no queue depth: the capture buffer backlog is left over from the pause (observed 9 packets backlogged at the moment of resume), not a slow link;
// reporting it to adaptive bitrate would make it wrongly drop a tier and also lock out the tier it just tried (2026-10-14 00:41:05)
static const double kDepthWarmupSeconds = 1;

@implementation MediaStreamer {
    L2CAPSocket *_socket;
    double _rate;
    id<PCMSource> _source;
    NSString *_label;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSMutableData *_pcm;
    NSMutableArray<NSData *> *_pending;
    BOOL _capture;
    BOOL _sourceEnded;
    BOOL _failed;
    uint64_t _startTicks;
    uint64_t _framesConsumed;
    uint64_t _packets;
    uint64_t _bytes;
    uint64_t _droppedFrames;
    uint64_t _blockedWrites;
    uint64_t _failedWrites;
    uint64_t _emptyCalls;
    double _encodeSeconds;
    double _encodeMax;
    uint64_t _encodeCount;
    double _lastStatsTime;
    uint64_t _lastStatsBytes;
    uint64_t _lastCapturedFrames;
    double _rateSeconds;
    uint64_t _rateFrames;
    double _kbpsTime;
    uint64_t _kbpsBytes;
    _Atomic double _recentKbps;
    double _lastSendTime;
    BOOL _stallReported;
    double _depthWarmupUntil;
}

- (instancetype)initWithSocket:(L2CAPSocket *)socket rate:(double)rate source:(id<PCMSource>)source
                       encoder:(id<A2DPEncoder>)encoder label:(NSString *)label {
    if ((self = [super init])) {
        _socket = socket;
        _rate = rate;
        _source = source;
        _encoder = encoder;
        _label = [label copy];
        _capture = [source respondsToSelector:@selector(availableFrames)];
        _pcm = [NSMutableData dataWithLength:encoder.framesPerCall * kPCMBytesPerSample];
        _pending = [NSMutableArray array];
        _queue = dispatch_queue_create("bluebloom.media", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        int bufferSize = (int)socket.outMTU * kMediaSendBufferPackets;
        setsockopt(socket.fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(bufferSize));
        setsockopt(socket.fd, SOL_SOCKET, SO_SNDLOWAT, &bufferSize, sizeof(bufferSize));
        BBLog(@"%@ streaming: %.0f Hz, %zu samples per encode (%.2f ms), media channel MTU %u, send buffer %d bytes", _label, rate, encoder.framesPerCall,
            encoder.framesPerCall * 1000.0 / rate, socket.outMTU, bufferSize);
    }
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}

- (double)recentKbps {
    return _recentKbps;
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_timer || self->_failed) return;
        self->_startTicks = mach_absolute_time() - BBSecondsToTicks((double)self->_framesConsumed / self->_rate);
        self->_lastStatsTime = BBTicksToSeconds(mach_absolute_time() - self->_startTicks);
        self->_lastStatsBytes = self->_bytes;
        self->_kbpsTime = self->_lastStatsTime;
        self->_kbpsBytes = self->_bytes;
        self->_lastSendTime = self->_lastStatsTime;
        self->_depthWarmupUntil = self->_lastStatsTime + kDepthWarmupSeconds;
        self->_stallReported = NO;
        self->_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, self->_queue);
        dispatch_source_set_timer(self->_timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC, NSEC_PER_MSEC / 2);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self->_timer, ^{ [weakSelf pump]; });
        dispatch_resume(self->_timer);
    });
}

- (void)pause {
    dispatch_sync(_queue, ^{ [self stopTimer]; });
}

- (BOOL)replaceEncoderWith:(id<A2DPEncoder> _Nullable (^)(void))factory {
    __block BOOL replaced = NO;
    dispatch_sync(_queue, ^{
        id<A2DPEncoder> previous = self->_encoder;
        id<A2DPEncoder> encoder = factory();
        if (!encoder) return;
        if ([previous respondsToSelector:@selector(rtpSequence)] && [encoder respondsToSelector:@selector(setRtpSequence:)]) {
            encoder.rtpSequence = previous.rtpSequence;
            encoder.rtpTimestamp = previous.rtpTimestamp;
        }
        self->_encoder = encoder;
        if (encoder.framesPerCall != previous.framesPerCall) {
            self->_pcm = [NSMutableData dataWithLength:encoder.framesPerCall * kPCMBytesPerSample];
        }
        replaced = YES;
    });
    return replaced;
}

- (BOOL)applyConfiguration:(CodecConfiguration *)configuration {
    __block BOOL applied = NO;
    dispatch_sync(_queue, ^{
        if ([self->_encoder respondsToSelector:@selector(applyConfiguration:)]) applied = [self->_encoder applyConfiguration:configuration];
    });
    return applied;
}

- (void)stopTimer {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)fail:(NSString *)reason {
    if (_failed) return;
    _failed = YES;
    [self stopTimer];
    BBLog(@"%@ encoder error: %@", _label, reason);
    void (^handler)(NSString *) = _failureHandler;
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(reason); });
}

- (void)finish {
    [self stopTimer];
    void (^handler)(void) = _finishedHandler;
    if (handler) dispatch_async(dispatch_get_main_queue(), handler);
}

- (void)pump {
    double elapsed = BBTicksToSeconds(mach_absolute_time() - _startTicks);
    size_t perCall = _encoder.framesPerCall;
    if (!_capture) {
        // Too far behind (link congested): drop PCM before encoding to catch up with the clock, keeping the bitstream itself continuous
        double target = elapsed * _rate + kPrefillCalls * perCall;
        while (!_sourceEnded && _pending.count == 0 && target - (double)_framesConsumed > _rate * kMaxLagSeconds) {
            if ([_source read:_pcm.mutableBytes frames:perCall] < perCall) _sourceEnded = YES;
            _framesConsumed += perCall;
            _droppedFrames += perCall;
        }
    }
    while (!_failed) {
        if (_pending.count == 0) {
            BOOL due = _capture ? [_source availableFrames] >= perCall
                                : (double)(_framesConsumed + perCall) <= elapsed * _rate + kPrefillCalls * perCall;
            if (!due) break;
            if (_sourceEnded) {
                [self finish];
                return;
            }
            if (![self encodeNext:elapsed]) break;
            if (_pending.count == 0) continue;  // encoder is still accumulating frames
        }
        NSData *packet = _pending.firstObject;
        if (!SendBufferEmpty(_socket.fd)) {
            _blockedWrites++;
            [self checkStall:elapsed];
            break;
        }
        if (![_socket send:packet]) {
            // Send buffer full: keep this packet for the next write; the encoder state has already advanced, so it must not be dropped
            if (errno == EAGAIN) _blockedWrites++;
            else if (++_failedWrites <= 3) BBLog(@"Media packet write failed: errno %d", errno);
            [self checkStall:elapsed];
            break;
        }
        _lastSendTime = elapsed;
        _stallReported = NO;
        if (_packets == 0) BBLog(@"First %@ packet written: %lu bytes %@ …", _label, (unsigned long)packet.length, BBHex(packet.bytes, MIN(16, packet.length)));
        _packets++;
        _bytes += packet.length;
        [_pending removeObjectAtIndex:0];
    }
    if (elapsed - _kbpsTime >= 1) {
        _recentKbps = (_bytes - _kbpsBytes) * 8 / (elapsed - _kbpsTime) / 1000;
        _kbpsTime = elapsed;
        _kbpsBytes = _bytes;
    }
    if (elapsed - _lastStatsTime >= (_capture ? 10 : 2)) [self logStats:elapsed];
}

- (void)checkStall:(double)elapsed {
    if (_stallReported || elapsed - _lastSendTime < kStallSeconds) return;
    _stallReported = YES;
    BBLog(@"%@ media channel: nothing written for %.0f s, headphones no longer accepting", _label, elapsed - _lastSendTime);
    double maxKbps = [_encoder respondsToSelector:@selector(mediaStalled)] ? [_encoder mediaStalled] : 0;
    void (^handler)(double) = _stallHandler;
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(maxKbps); });
}

// Send queue depth (packets): packets not yet written into the media channel, plus the PCM backlogged in live capture and not yet encoded, converted to packets.
// When streaming cannot keep up we stop encoding first, so the backlog sits in the capture buffer and counting only pending packets would always give 0–1; subtract 12ms of fetch jitter (the virtual device is fetched every 10ms)
- (NSUInteger)queueDepth {
    NSUInteger depth = _pending.count;
    if (!_capture || _packets == 0) return depth;
    double framesPerPacket = (double)_framesConsumed / (double)(_packets + _pending.count);
    double backlog = (double)[_source availableFrames] - _rate * 0.012;
    if (backlog > 0 && framesPerPacket > 0) depth += (NSUInteger)(backlog / framesPerPacket);
    return depth;
}

- (BOOL)encodeNext:(double)elapsed {
    size_t perCall = _encoder.framesPerCall;
    if ([_encoder respondsToSelector:@selector(reportQueueDepth:)]) {
        [_encoder reportQueueDepth:elapsed < _depthWarmupUntil ? 0 : [self queueDepth]];
    }
    uint8_t *pcm = _pcm.mutableBytes;
    size_t got = [_source read:pcm frames:perCall];
    if (got < perCall) {
        memset(pcm + got * kPCMBytesPerSample, 0, (perCall - got) * kPCMBytesPerSample);
        _sourceEnded = YES;
    }
    _framesConsumed += perCall;
    uint64_t begin = mach_absolute_time();
    NSString *error = nil;
    NSArray<NSData *> *packets = [_encoder encode:pcm error:&error];
    double seconds = BBTicksToSeconds(mach_absolute_time() - begin);
    if (!packets) {
        [self fail:error ?: @"encoder gave no reason"];
        return NO;
    }
    _encodeSeconds += seconds;
    _encodeMax = MAX(_encodeMax, seconds);
    _encodeCount++;
    if (packets.count == 0) _emptyCalls++;
    [_pending addObjectsFromArray:packets];
    return YES;
}

- (void)logStats:(double)elapsed {
    double interval = elapsed - _lastStatsTime;
    double kbps = (_bytes - _lastStatsBytes) * 8 / interval / 1000;
    NSString *captureInfo = @"";
    SystemAudioSource *capture = [_source isKindOfClass:SystemAudioSource.class] ? (SystemAudioSource *)_source : nil;
    if (capture) {
        // The measured capture rate should match the sample rate configured on the headphones; the cumulative average only counts windows where data kept coming (the virtual device produces no data when no app is playing)
        double captureRate = (capture.capturedFrames - _lastCapturedFrames) / interval;
        if (fabs(captureRate - _rate) < _rate * 0.05) {
            _rateSeconds += interval;
            _rateFrames += capture.capturedFrames - _lastCapturedFrames;
        }
        double averageRate = _rateSeconds >= 60 ? _rateFrames / _rateSeconds : 0;
        captureInfo = [NSString stringWithFormat:@", measured capture %.0f Hz%@, capture dropped %llu frames, silent packets %llu", captureRate,
                       averageRate ? [NSString stringWithFormat:@" (cumulative average %.1f Hz)", averageRate] : @"", capture.droppedFrames, capture.silentReads];
        _lastCapturedFrames = capture.capturedFrames;
    }
    BBLog(@"%@ streamed %.0f s: %.1f s of audio, %llu packets, recent bitrate %.1f kbps (encoder target %.0f), encode avg %.2f ms, max %.2f ms, no packet out %llu times, buffer full %llu times, dropped %llu samples, write failures %llu%@",
        _label, elapsed, _framesConsumed / _rate, _packets, kbps, _encoder.bitrateKbps, _encodeCount ? _encodeSeconds / _encodeCount * 1000 : 0,
        _encodeMax * 1000, _emptyCalls, _blockedWrites, _droppedFrames, _failedWrites, captureInfo);
    _lastStatsTime = elapsed;
    _lastStatsBytes = _bytes;
    _encodeMax = 0;
}

- (void)logTotals {
    dispatch_sync(_queue, ^{
        if (!self->_packets) return;
        BBLog(@"%@ streaming totals: %llu packets, %.1f KB, %.1f s of audio, encode avg %.2f ms, buffer full %llu times, dropped %llu samples, write failures %llu", self->_label,
            self->_packets, self->_bytes / 1024.0, self->_framesConsumed / self->_rate,
            self->_encodeCount ? self->_encodeSeconds / self->_encodeCount * 1000 : 0, self->_blockedWrites, self->_droppedFrames, self->_failedWrites);
    });
}

@end
