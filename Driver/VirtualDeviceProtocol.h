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
