// VirtualDeviceKeepAlive: tells the Blue Bloom driver that this process (the app or the command-line tool) is running, so the
// driver publishes the virtual device only while Blue Bloom runs (GitHub issue #3: after quitting, the device stayed and could stay
// the default output with nobody reading it). Protocol: kBBPropertyClientAlive in VirtualDeviceProtocol.h. With a driver older than
// CFBundleVersion 6 the beats are skipped and the device stays published as before.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VirtualDeviceKeepAlive : NSObject

// Beats now and then every kBBClientAliveInterval seconds; calling it again does nothing
+ (void)start;
// Stops beating and tells the driver this process is gone, so it withdraws the device at once unless another client is alive
+ (void)stop;
// Waits (running the current run loop on the main thread) until the device is published; YES when it is there
+ (BOOL)waitForDevice:(double)timeout;
// When sound is playing into the device, asks the Now Playing app to pause and waits until the device goes silent (at most
// 0.5 s); YES when a pause was sent. Called before the sound has to go elsewhere (the output moves away from the device, or the
// device is withdrawn), so what was playing does not suddenly come out of the speakers. Blocks
+ (BOOL)pausePlaybackAndWait;
// The same without blocking; done runs on the main queue
+ (void)pausePlaybackThen:(void (^)(void))done NS_SWIFT_NAME(pausePlayback(then:));

@end

NS_ASSUME_NONNULL_END
