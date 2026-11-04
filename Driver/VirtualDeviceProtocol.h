// Contract between the virtual device driver and Blue Bloom, shared by the driver (Driver/BlueBloomDevice.c) and Engine.
// The app does not read the device's input (macOS would treat that as using the microphone and keep the orange dot lit in the menu bar); it fetches sound through the custom property below instead.

#ifndef APTX_DEVICE_PROTOCOL_H
#define APTX_DEVICE_PROTOCOL_H

#include <CoreAudio/AudioServerPlugIn.h>

#define kBBDeviceUID "app.bluebloom.device"

// Fetch sound from the ring buffer.
// Qualifier: CFNumber (SInt64), the sample time the caller wants next; passing -1 or an out-of-range value starts from the current write position.
// Returns: CFData = BBAudioChunkHeader + frames × channels float32 values (interleaved).
// The caller passes startSample + frames next time; a change in generation means the device IO restarted and sample times count from 0 again.
enum { kBBPropertyAudioData = 'aptd' };

// Hardware volume mode (CFNumber 0/1, read-write). When 1, the volume control is only for display and sync (Blue Bloom sends it to the headphones' amplifier via AVRCP absolute volume),
// and the driver no longer attenuates the sound by volume; when 0, software attenuation is applied by volume (the fallback when the headphones' AVRCP channel could not be grabbed). Mute works in both modes.
enum { kBBPropertyHardwareVolume = 'aptm' };

// Client presence, on the driver's plug-in object (not the device; find it with kAudioHardwarePropertyTranslateBundleIDToPlugIn
// and kBBPlugInBundleID). CFNumber: Blue Bloom (the app or the command-line tool) writes a nonzero value every
// kBBClientAliveInterval seconds while it runs and 0 when it quits. The driver publishes the device only while a client is alive:
// it withdraws it at once on 0, or kBBClientAliveTimeout seconds after the last beat (a crash or forced quit) once nothing has
// played into it for a few seconds, and macOS then moves its default output elsewhere instead of playing into a device nobody
// reads (GitHub issue #3). Before writing 0 the client pauses what plays into the device, so it does not jump to the speakers.
// Drivers before CFBundleVersion 6 publish the device all the time and do not have this property
enum { kBBPropertyClientAlive = 'aptc' };
#define kBBPlugInBundleID "app.bluebloom.driver"
#define kBBClientAliveInterval 2.0
#define kBBClientAliveTimeout 20.0

// Maximum frames returned at once (about 170ms@96k); when further behind, the oldest part is dropped
#define kBBMaxChunkFrames 16384

typedef struct {
    UInt64 generation;
    UInt64 startSample;
    UInt32 frames;
    UInt32 channels;
    Float64 sampleRate;
} BBAudioChunkHeader;

#endif
