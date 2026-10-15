#import "BBLog.h"
#include <mach/mach_time.h>

static mach_timebase_info_data_t gTimebase;
static uint64_t gStartTicks;
static void (^gSink)(NSString *line);

__attribute__((constructor)) static void BBLogInit(void) {
    mach_timebase_info(&gTimebase);
    gStartTicks = mach_absolute_time();
}

double BBTicksToSeconds(uint64_t ticks) {
    return (double)ticks * gTimebase.numer / gTimebase.denom / 1e9;
}

uint64_t BBSecondsToTicks(double seconds) {
    return (uint64_t)(seconds * 1e9 * gTimebase.denom / gTimebase.numer);
}

void BBLogSetSink(void (^sink)(NSString *line)) {
    gSink = [sink copy];
}

void BBLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    BBLogLine(message);
}

void BBLogLine(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"[%8.3f] %@", BBTicksToSeconds(mach_absolute_time() - gStartTicks), message];
    void (^sink)(NSString *) = gSink;
    if (sink) {
        sink(line);
    } else {
        printf("%s\n", line.UTF8String);
        fflush(stdout);
    }
}

NSString *BBHex(const uint8_t *bytes, size_t length) {
    NSMutableString *text = [NSMutableString stringWithCapacity:length * 3];
    for (size_t i = 0; i < length; i++) {
        [text appendFormat:i ? @" %02X" : @"%02X", bytes[i]];
    }
    return text;
}
