#import "SourceRateMonitor.h"
#import "BBLog.h"

// Apple Music's PlaybackEvents log (observed 2026-10-12, macOS 27); each event carries a track ID (two numbers):
//   AUDIO CHANGE 14906 15728
//   activeFormat: tier: HighResolutionLossless; groupID: audio-alac-stereo-96000-24; bitDepth: 24-bit; sampleRate: 96khz; ...
//   FIRST AUDIO FRAME 14906 15728 / ITEM RESUME 14906 15728 / ITEM TICK 14906 15728   <- the track now playing
// Music preloads the next track ahead of time and logs AUDIO CHANGE + activeFormat for it too, so we cannot take "the latest format";
// record each track's format by track ID, then check which track is playing. The log is written in batches, about 5 s behind actual playback.
// Also read the lossless decoder's "Input format" line (com.apple.coreaudio, Music process): Music sometimes logs no AUDIO CHANGE for a long stretch (2026-10-14 04:04–04:20),
// while the decoder line appears for every track (also logged for the preloaded next track) and carries the bit depth
static NSString *const kPredicate = @"process == \"Music\" AND ((category == \"PlaybackEvents\" AND "
                                    @"(eventMessage CONTAINS \"AUDIO CHANGE\" OR eventMessage CONTAINS \"activeFormat:\" OR "
                                    @"eventMessage CONTAINS \"FIRST AUDIO FRAME\" OR eventMessage CONTAINS \"ITEM RESUME\" OR eventMessage CONTAINS \"ITEM TICK\")) OR "
                                    @"(eventMessage CONTAINS \"ACAppleLosslessDecoder\" AND eventMessage CONTAINS \"Input format\"))";

@implementation SourceRateMonitor {
    NSTask *_task;
    NSMutableData *_pending;
    BOOL _running;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_formats;  // track ID -> @[sample rate, bit depth]
    NSString *_formatItem;   // track of the latest AUDIO CHANGE; the next activeFormat line belongs to it
    NSString *_currentItem;  // track now playing
    double _reportedRate;
    int _reportedDepth;
}

- (instancetype)init {
    if ((self = [super init])) _formats = [NSMutableDictionary dictionary];
    return self;
}

- (void)start {
    if (_running) return;
    _running = YES;
    [self readRecent];
    [self launch];
}

// On start, read back the last half hour: the playing track was logged long ago, so waiting only for new log lines would never reveal the current format
- (void)readRecent {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
        task.arguments = @[@"show", @"--last", @"30m", @"--style", @"compact", @"--predicate", kPredicate];
        NSPipe *pipe = [NSPipe pipe];
        task.standardOutput = pipe;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        if (![task launchAndReturnError:nil]) return;
        NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf received:output]; });
    });
}

- (void)launch {
    if (!_running) return;
    _pending = [NSMutableData data];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    task.arguments = @[@"stream", @"--style", @"compact", @"--predicate", kPredicate];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf received:data]; });
    };
    task.terminationHandler = ^(NSTask *finished) {
        // If the log process exits unexpectedly, restart it after a few seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf launch]; });
    };
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        BBLog(@"Cannot read the Apple Music log: %@", error.localizedDescription);
        return;
    }
    _task = task;
}

- (void)received:(NSData *)data {
    if (!_pending) _pending = [NSMutableData data];
    [_pending appendData:data];
    NSData *newline = [NSData dataWithBytes:"\n" length:1];
    for (;;) {
        NSRange range = [_pending rangeOfData:newline options:0 range:NSMakeRange(0, _pending.length)];
        if (range.location == NSNotFound) break;
        NSString *line = [[NSString alloc] initWithData:[_pending subdataWithRange:NSMakeRange(0, range.location)] encoding:NSUTF8StringEncoding];
        [_pending replaceBytesInRange:NSMakeRange(0, range.location + 1) withBytes:NULL length:0];
        if (line) [self parseLine:line];
    }
    [self reportIfChanged];
}

- (void)parseLine:(NSString *)line {
    static NSRegularExpression *event, *group, *rate, *depth, *decoder;
    static NSDateFormatter *timeFormatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // In compact style each line starts with the local time "2026-10-14 04:20:58.485"
        decoder = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}\\.\\d{3}).*ACAppleLosslessDecoder.*Input format:\\s+\\d+ ch,\\s+(\\d+) Hz.*from (\\d+)-bit source"
                                                            options:0 error:nil];
        timeFormatter = [NSDateFormatter new];
        timeFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        timeFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        // The event name is padded with a run of spaces, followed by two numbers
        event = [NSRegularExpression regularExpressionWithPattern:@"(AUDIO CHANGE|FIRST AUDIO FRAME|ITEM RESUME|ITEM TICK)\\s+(\\d+)\\s+(\\d+)" options:0 error:nil];
        group = [NSRegularExpression regularExpressionWithPattern:@"groupID: [a-z0-9]+-[a-z0-9]+-[a-z0-9]+-(\\d{5,6})-(\\d{2})" options:0 error:nil];
        rate = [NSRegularExpression regularExpressionWithPattern:@"sampleRate: (\\d+)khz" options:0 error:nil];
        depth = [NSRegularExpression regularExpressionWithPattern:@"bitDepth: (\\d+)-bit" options:0 error:nil];
    });
    NSRange whole = NSMakeRange(0, line.length);
    NSTextCheckingResult *match = [decoder firstMatchInString:line options:0 range:whole];
    if (match) {
        NSDate *date = [timeFormatter dateFromString:[line substringWithRange:[match rangeAtIndex:1]]];
        double sampleRate = [line substringWithRange:[match rangeAtIndex:2]].doubleValue;
        int bitDepth = [line substringWithRange:[match rangeAtIndex:3]].intValue;
        if (date && sampleRate > 0 && _decoderHandler) _decoderHandler(sampleRate, bitDepth, date);
        return;
    }
    match = [event firstMatchInString:line options:0 range:whole];
    if (match) {
        NSString *kind = [line substringWithRange:[match rangeAtIndex:1]];
        NSString *item = [NSString stringWithFormat:@"%@ %@", [line substringWithRange:[match rangeAtIndex:2]], [line substringWithRange:[match rangeAtIndex:3]]];
        if ([kind isEqualToString:@"AUDIO CHANGE"]) _formatItem = item;
        else _currentItem = item;
        return;
    }
    if (![line containsString:@"activeFormat:"] || !_formatItem) return;
    double sampleRate = 0;
    int bitDepth = 0;
    // groupID holds the exact sample rate and bit depth (the sampleRate field writes 44.1k as "44khz")
    if ((match = [group firstMatchInString:line options:0 range:whole])) {
        sampleRate = [line substringWithRange:[match rangeAtIndex:1]].doubleValue;
        bitDepth = [line substringWithRange:[match rangeAtIndex:2]].intValue;
    } else if ((match = [rate firstMatchInString:line options:0 range:whole])) {
        // A lossy track's groupID has no sample rate, so fall back to the sampleRate field: 44 -> 44.1k, 88 -> 88.2k, 176 -> 176.4k
        int khz = [line substringWithRange:[match rangeAtIndex:1]].intValue;
        sampleRate = khz % 11 == 0 ? khz * 1000 + khz / 44 * 100 : khz * 1000;
        if ((match = [depth firstMatchInString:line options:0 range:whole])) bitDepth = [line substringWithRange:[match rangeAtIndex:1]].intValue;
    }
    if (sampleRate > 0) _formats[_formatItem] = @[@(sampleRate), @(bitDepth)];
}

- (void)reportIfChanged {
    NSArray<NSNumber *> *format = _currentItem ? _formats[_currentItem] : nil;
    if (!format) return;
    double sampleRate = format[0].doubleValue;
    int bitDepth = format[1].intValue;
    if (sampleRate == _reportedRate && bitDepth == _reportedDepth) return;
    _reportedRate = sampleRate;
    _reportedDepth = bitDepth;
    if (_formatHandler) _formatHandler(sampleRate, bitDepth);
}

- (void)stop {
    _running = NO;
    _task.terminationHandler = nil;
    [_task terminate];
    _task = nil;
}

@end
