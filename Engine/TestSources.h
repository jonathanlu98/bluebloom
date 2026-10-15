// PCM sources for testing: stereo test tone, audio file.

#import <Foundation/Foundation.h>
#import "PCMSource.h"

NS_ASSUME_NONNULL_BEGIN

@interface ToneSource : NSObject <PCMSource>
- (instancetype)initWithRate:(double)rate seconds:(double)seconds;
@end

@interface FileSource : NSObject <PCMSource>
- (nullable instancetype)initWithPath:(NSString *)path rate:(double)rate error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
