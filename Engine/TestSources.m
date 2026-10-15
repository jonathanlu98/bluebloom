#import "TestSources.h"
#import "BBLog.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>

// Left 440Hz, right 660Hz: one pitch per ear, so swapped channels are audible right away
@implementation ToneSource {
    double _rate;
    size_t _remaining;
    double _phaseLeft;
    double _phaseRight;
}

- (instancetype)initWithRate:(double)rate seconds:(double)seconds {
    if ((self = [super init])) {
        _rate = rate;
        _remaining = (size_t)(rate * seconds);
    }
    return self;
}

- (size_t)read:(uint8_t *)output frames:(size_t)frames {
    size_t count = MIN(frames, _remaining);
    for (size_t i = 0; i < count; i++) {
        // Peak 0.1 (-20 dBFS), not harsh when listening on headphones
        PutS24(output + i * kPCMBytesPerSample, 0.1f * (float)sin(_phaseLeft));
        PutS24(output + i * kPCMBytesPerSample + 3, 0.1f * (float)sin(_phaseRight));
        _phaseLeft = fmod(_phaseLeft + 2 * M_PI * 440 / _rate, 2 * M_PI);
        _phaseRight = fmod(_phaseRight + 2 * M_PI * 660 / _rate, 2 * M_PI);
    }
    _remaining -= count;
    return count;
}

@end

@implementation FileSource {
    AVAudioFile *_file;
    AVAudioConverter *_converter;
    AVAudioFormat *_format;
    BOOL _inputEnded;
    BOOL _finished;
}

- (instancetype)initWithPath:(NSString *)path rate:(double)rate error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:error];
    if (!_file) return nil;
    AVAudioFormat *source = _file.processingFormat;
    _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:2 interleaved:NO];
    _converter = [[AVAudioConverter alloc] initFromFormat:source toFormat:_format];
    if (source.channelCount == 1) {
        _converter.channelMap = @[@0, @0];
    } else if (source.channelCount > 2) {
        _converter.downmix = YES;
    }
    _converter.sampleRateConverterQuality = AVAudioQualityMax;
    BBLog(@"Audio file %@: %.0f Hz × %u channels, %.1f s, converting to %.0f Hz stereo", path.lastPathComponent,
        source.sampleRate, source.channelCount, _file.length / source.sampleRate, rate);
    return self;
}

- (size_t)read:(uint8_t *)output frames:(size_t)frames {
    if (_finished) return 0;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:(AVAudioFrameCount)frames];
    AVAudioFile *file = _file;
    __block BOOL inputEnded = _inputEnded;
    NSError *error = nil;
    AVAudioConverterOutputStatus status = [_converter convertToBuffer:buffer error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *inputStatus) {
        if (inputEnded) {
            *inputStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:count];
        if (![file readIntoBuffer:input error:nil] || input.frameLength == 0) {
            inputEnded = YES;
            *inputStatus = AVAudioConverterInputStatus_EndOfStream;
            return nil;
        }
        *inputStatus = AVAudioConverterInputStatus_HaveData;
        return input;
    }];
    _inputEnded = inputEnded;
    if (status == AVAudioConverterOutputStatus_Error) {
        BBLog(@"Audio decoding failed: %@", error.localizedDescription);
        _finished = YES;
        return 0;
    }
    size_t count = buffer.frameLength;
    if (count < frames) _finished = YES;
    const float *left = buffer.floatChannelData[0];
    const float *right = buffer.floatChannelData[1];
    for (size_t i = 0; i < count; i++) {
        PutS24(output + i * kPCMBytesPerSample, left[i]);
        PutS24(output + i * kPCMBytesPerSample + 3, right[i]);
    }
    return count;
}

@end

