#import "BitrateAdapter.h"
#include <stdatomic.h>
#import "BBExperiments.h"
#import "BBLog.h"
#include <os/lock.h>

static const NSUInteger kDropDepth = 3;
static const NSUInteger kDropTwoDepth = 6;
static const double kDropInterval = 0.5;     // after dropping a tier, wait this long before looking again (even at a lower bitrate the backlog takes a while to drain)
static const double kRaiseSeconds = 4;
static const double kProbeFailSeconds = 3;
static const double kProbeHoldSeconds = 30;
static const double kBackoffInitial = 30;
static const double kBackoffMax = 300;

// Experiment (BBExperiments slowABR): wait longer before trying a higher tier, and much longer after a failed attempt,
// so the bitrate does not bounce between two tiers at the edge of what the link carries. Not evaluated yet
static double RaiseSeconds(void) { return [BBExperiments shared].slowABR ? 15 : kRaiseSeconds; }
static double ProbeHoldSeconds(void) { return [BBExperiments shared].slowABR ? 60 : kProbeHoldSeconds; }
static double BackoffInitial(void) { return [BBExperiments shared].slowABR ? 120 : kBackoffInitial; }
static double BackoffMax(void) { return [BBExperiments shared].slowABR ? 600 : kBackoffMax; }

typedef struct {
    int ceiling;        // highest tier allowed while locked out (-1 not locked)
    double remaining;   // how much longer to stay locked
    double backoff;
    int failedTier;
    CFAbsoluteTime savedAt;
} Guard;

static NSMutableDictionary<NSString *, NSValue *> *gGuards;
static os_unfair_lock gGuardLock = OS_UNFAIR_LOCK_INIT;

@implementation BitrateAdapter {
    NSString *_name;
    NSString *_key;
    NSArray<NSNumber *> *_tierKbps;
    int _tierCount;
    double _clock;      // duration of audio encoded so far (seconds)
    double _calmSince, _lastDrop;
    int _ceiling;
    double _ceilingUntil, _backoff;
    int _probeTier;     // tier just raised to and still under observation (-1 none)
    double _probeStart;
    int _failedTier;    // tier of the most recent failed trial raise: only holding at it or a higher tier counts as the link improving and resets the backoff
    _Atomic(double) _bracePending;  // braceFor: seconds requested, taken at the next update
    double _braceUntil;
    int _braceTier;     // highest tier allowed until _braceUntil
}

- (instancetype)initWithName:(NSString *)name tierKbps:(NSArray<NSNumber *> *)tierKbps startTier:(int)start key:(NSString *)key {
    if ((self = [super init])) {
        _name = [name copy];
        _key = [key copy];
        _tierKbps = [tierKbps copy];
        _tierCount = (int)tierKbps.count;
        _tier = MAX(0, MIN(start, _tierCount - 1));
        _ceiling = -1;
        _probeTier = -1;
        _failedTier = -1;
        _backoff = BackoffInitial();
        os_unfair_lock_lock(&gGuardLock);
        NSValue *saved = gGuards[key];
        os_unfair_lock_unlock(&gGuardLock);
        if (saved) {
            Guard guard;
            [saved getValue:&guard size:sizeof guard];
            _backoff = guard.backoff;
            _failedTier = guard.failedTier;
            double remaining = guard.remaining - (CFAbsoluteTimeGetCurrent() - guard.savedAt);
            if (guard.ceiling >= 0 && remaining > 0) {
                _ceiling = guard.ceiling;
                _ceilingUntil = remaining;
                if (_ceiling > _tier) {
                    _tier = MIN(_ceiling, _tierCount - 1);
                    BBLog(@"%@ adaptive bitrate: reusing the previous stream's result, starting at %.0f kbps, trying a higher tier in %.0f s", _name, self.kbps, remaining);
                }
            }
        }
    }
    return self;
}

- (void)dealloc {
    BOOL blocking = _ceiling >= 0 && _clock < _ceilingUntil;
    Guard guard = { blocking ? _ceiling : -1, blocking ? _ceilingUntil - _clock : 0, _backoff, _failedTier, CFAbsoluteTimeGetCurrent() };
    os_unfair_lock_lock(&gGuardLock);
    if (!gGuards) gGuards = [NSMutableDictionary dictionary];
    gGuards[_key] = [NSValue valueWithBytes:&guard objCType:@encode(Guard)];
    os_unfair_lock_unlock(&gGuardLock);
}

- (double)kbps {
    return _tierKbps[_tier].doubleValue;
}

- (void)setTopTier:(int)topTier {
    _topTier = MAX(0, MIN(topTier, _tierCount - 1));
    if (_tier < _topTier) _tier = _topTier;
}

- (void)jumpToTier:(int)tier {
    _tier = MAX(_topTier, MIN(tier, _tierCount - 1));
    _calmSince = _clock;
    _probeTier = -1;
}

- (void)moveTo:(int)tier reason:(NSString *)reason {
    BBLog(@"%@ adaptive bitrate: %.0f → %.0f kbps (%@)", _name, self.kbps, _tierKbps[tier].doubleValue, reason);
    _tier = tier;
}

- (void)braceFor:(double)seconds {
    atomic_store(&_bracePending, seconds);
}

- (BOOL)updateWithDepth:(NSUInteger)depth seconds:(double)seconds {
    _clock += seconds;
    double brace = atomic_exchange(&_bracePending, 0.0);
    if (brace > 0) {
        _braceUntil = _clock + brace;
        _braceTier = MIN(_tier + 1, _tierCount - 1);
        _calmSince = _clock;
        if (_braceTier != _tier) {
            _probeTier = -1;
            [self moveTo:_braceTier reason:[NSString stringWithFormat:@"bracing for Bluetooth scanning for %.0f s", brace]];
            return YES;
        }
    }
    BOOL blocking = _ceiling >= 0 && _clock < _ceilingUntil;
    if (!blocking) _ceiling = -1;
    if (depth > 0) _calmSince = _clock;
    int drop = _clock - _lastDrop < kDropInterval ? 0 : depth >= kDropTwoDepth ? 2 : depth >= kDropDepth ? 1 : 0;
    if (drop && _tier < _tierCount - 1) {
        int tier = MIN(_tier + drop, _tierCount - 1);
        if (_probeTier >= 0 && tier > _probeTier && _clock - _probeStart < kProbeFailSeconds) {
            _failedTier = _probeTier;
            _ceiling = _probeTier + 1;
            _ceilingUntil = _clock + _backoff;
            BBLog(@"%@ adaptive bitrate: link cannot sustain %.0f kbps, not trying this tier again for %.0f s", _name, _tierKbps[_probeTier].doubleValue, _backoff);
            _backoff = MIN(_backoff * 2, BackoffMax());
        }
        _probeTier = -1;
        _lastDrop = _clock;
        [self moveTo:tier reason:[NSString stringWithFormat:@"backlog %lu packets", (unsigned long)depth]];
        return YES;
    }
    if (_probeTier >= 0 && _clock - _probeStart >= ProbeHoldSeconds()) {
        // Failing at tier A, dropping lower, then settling at a tier below A does not show that A can hold, so do not reset (same as ldac_a2dp.c guard_after_abr)
        if (_failedTier < 0 || _probeTier <= _failedTier) {
            _backoff = BackoffInitial();
            _failedTier = -1;
        }
        _probeTier = -1;
    }
    if (depth == 0 && _clock - _calmSince >= RaiseSeconds() && _tier > _topTier) {
        int tier = _tier - 1;
        if (_ceiling >= 0 && tier < _ceiling) return NO;
        if (_clock < _braceUntil && tier < _braceTier) return NO;
        _probeTier = tier;
        _probeStart = _clock;
        _calmSince = _clock;
        [self moveTo:tier reason:[NSString stringWithFormat:@"no backlog for %.0f s", RaiseSeconds()]];
        return YES;
    }
    return NO;
}

@end
