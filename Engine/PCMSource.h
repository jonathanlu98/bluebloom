#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// libfreeaptx input: 24-bit little-endian interleaved stereo (freeaptx.h aptx_encode comment)
static const size_t kPCMBytesPerSample = 6;

static inline void PutS24(uint8_t *p, float value) {
    value = fmaxf(-1.f, fminf(1.f, value));
    int32_t sample = (int32_t)lrintf(value * 8388607.f);
    p[0] = sample & 0xFF;
    p[1] = (sample >> 8) & 0xFF;
    p[2] = (sample >> 16) & 0xFF;
}

@protocol PCMSource <NSObject>
// Read frames stereo samples, written as 24-bit little-endian interleaved (LLLRRR); returns the actual count, fewer than requested means the end was reached
- (size_t)read:(uint8_t *)output frames:(size_t)frames;
@optional
// Live capture sources implement this: streaming paces sends by the source's data arrival rather than the local clock
- (size_t)availableFrames;
@end

NS_ASSUME_NONNULL_END
