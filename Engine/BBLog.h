// Logging and timing utilities: prints to standard output by default, with seconds since launch; the app can set another receiver (write to a file, show in the UI).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void BBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
// Same as BBLog, without formatting (for Swift)
void BBLogLine(NSString *message);
// Once set, log lines go to sink (called on any thread) instead of standard output; pass nil to restore the default
void BBLogSetSink(void (^_Nullable sink)(NSString *line));
double BBTicksToSeconds(uint64_t ticks);
uint64_t BBSecondsToTicks(double seconds);
NSString *BBHex(const uint8_t *bytes, size_t length);

NS_ASSUME_NONNULL_END
