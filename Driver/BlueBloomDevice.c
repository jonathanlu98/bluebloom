// BlueBloomDevice: a Core Audio server plug-in (AudioServerPlugIn) that provides a virtual output device for the user to pick in Sound settings.
// Sound that apps play to this device is written into a ring buffer; Blue Bloom fetches it through the custom property kBBPropertyAudioData (see VirtualDeviceProtocol.h),
// encodes it with the negotiated codec and sends it to the headphones. No input is provided: reading an input would make macOS treat it as using the microphone.
// The plug-in runs in coreaudiod's sandboxed process and cannot set up its own communication channel; property reads are relayed by the HAL.
// Interface definitions are in CoreAudio/AudioServerPlugIn.h; the structure follows Apple's NullAudio sample.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>
#include "VirtualDeviceProtocol.h"

#ifndef DEVICE_NAME
#define DEVICE_NAME "Blue Bloom"
#endif

#define kPlugInBundleID     "app.bluebloom.driver"
#define kDeviceUID          kBBDeviceUID
#define kDeviceModelUID     "app.bluebloom.model"
#define kManufacturerName   "Blue Bloom"

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Output = 4,
    kObjectID_Volume_Output = 5,
    kObjectID_Mute_Output = 6,
};

// Ring buffer size in frames, also used as the timestamp period (kAudioDevicePropertyZeroTimeStampPeriod must not be less than 10923)
#define kRingFrames         32768
#define kChannels           2
#define kBytesPerFrame      (sizeof(Float32) * kChannels)
// aptX only goes up to 48k; LDAC and others support 88.2k / 96k. The app sets the nominal sample rate from the current codec and source
static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0 };
#define kSampleRateCount    (sizeof(kSampleRates) / sizeof(kSampleRates[0]))
// Output latency reported to macOS: the headphones report 220ms of playback delay, plus Blue Bloom's send queue, so 250ms is used, letting video players align audio and picture with it
#define kOutputLatencySeconds 0.25
#define kVolumeMinDB        (-64.0f)

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static Float64 gSampleRate = 44100.0;
static Float64 gHostTicksPerFrame = 0;
static UInt32 gIOCount = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static Boolean gOutputActive = true;
static _Atomic Float32 gVolumeScalar = 1.0f;
static _Atomic Boolean gMuted = false;
static _Atomic Boolean gHardwareVolume = false;
static Float32 gRing[kRingFrames * kChannels];
// End position of the most recent write (a sample time on the output timeline); the custom property fetches data based on it
static _Atomic UInt64 gWrittenUntil = 0;
// Incremented each time IO goes from stopped to started: sample times then count from 0 again, and the fetching side resets its read position accordingly
static _Atomic UInt64 gGeneration = 0;

#pragma mark Utilities

static Float32 ScalarToDecibels(Float32 scalar) {
    // Volume curve: gain = scalar², i.e. dB = 40·log10(scalar), floor -64dB
    if (scalar <= 0) return kVolumeMinDB;
    Float32 db = 40.0f * log10f(scalar);
    return db < kVolumeMinDB ? kVolumeMinDB : (db > 0 ? 0 : db);
}

static Float32 DecibelsToScalar(Float32 db) {
    if (db <= kVolumeMinDB) return 0;
    if (db > 0) db = 0;
    return powf(10.0f, db / 40.0f);
}

static void FillFormat(AudioStreamBasicDescription *format, Float64 rate) {
    memset(format, 0, sizeof(*format));
    format->mSampleRate = rate;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = kBytesPerFrame;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = kBytesPerFrame;
    format->mChannelsPerFrame = kChannels;
    format->mBitsPerChannel = 32;
}

static void UpdateTicksPerFrame(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / gSampleRate;
}

static void NotifyChanged(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    if (!gHost) return;
    AudioObjectPropertyAddress address = { selector, scope, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, object, 1, &address);
}

#define CHECK_SIZE(type) do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; } while (0)

#pragma mark Forward declarations

static HRESULT AptX_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AptX_AddRef(void *inDriver);
static ULONG AptX_Release(void *inDriver);
static OSStatus AptX_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus AptX_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus AptX_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AptX_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus AptX_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus AptX_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus AptX_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean AptX_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus AptX_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus AptX_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus AptX_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus AptX_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus AptX_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AptX_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus AptX_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus AptX_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus AptX_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus AptX_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus AptX_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    AptX_QueryInterface,
    AptX_AddRef,
    AptX_Release,
    AptX_Initialize,
    AptX_CreateDevice,
    AptX_DestroyDevice,
    AptX_AddDeviceClient,
    AptX_RemoveDeviceClient,
    AptX_PerformDeviceConfigurationChange,
    AptX_AbortDeviceConfigurationChange,
    AptX_HasProperty,
    AptX_IsPropertySettable,
    AptX_GetPropertyDataSize,
    AptX_GetPropertyData,
    AptX_SetPropertyData,
    AptX_StartIO,
    AptX_StopIO,
    AptX_GetZeroTimeStamp,
    AptX_WillDoIOOperation,
    AptX_BeginIOOperation,
    AptX_DoIOOperation,
    AptX_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

#pragma mark Factory and COM interface

// CFPlugInFactories in Info.plist points to this function
void *BlueBloom_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void *BlueBloom_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

static HRESULT AptX_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AptX_AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG count = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG AptX_Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus AptX_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    UpdateTicksPerFrame();
    return noErr;
}

static OSStatus AptX_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AptX_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AptX_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    return inDeviceObjectID == kObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus AptX_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    return inDeviceObjectID == kObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

// Sample rate changes go through the host's configuration change flow: requested in SetPropertyData, actually applied here; inChangeAction is an index into kSampleRates
static OSStatus AptX_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (inChangeAction >= kSampleRateCount) return kAudioHardwareBadDeviceError;
    pthread_mutex_lock(&gStateMutex);
    gSampleRate = kSampleRates[inChangeAction];
    UpdateTicksPerFrame();
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AptX_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    return noErr;
}

#pragma mark Properties: existence

static Boolean PlugInHasProperty(const AudioObjectPropertyAddress *address) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBundleID:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        default:
            return false;
    }
}

static Boolean DeviceHasProperty(const AudioObjectPropertyAddress *address) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kBBPropertyAudioData:
        case kBBPropertyHardwareVolume:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return address->mScope == kAudioObjectPropertyScopeInput || address->mScope == kAudioObjectPropertyScopeOutput;
        default:
            return false;
    }
}

static Boolean StreamHasProperty(const AudioObjectPropertyAddress *address) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default:
            return false;
    }
}

static Boolean VolumeHasProperty(const AudioObjectPropertyAddress *address) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange:
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return true;
        default:
            return false;
    }
}

static Boolean MuteHasProperty(const AudioObjectPropertyAddress *address) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioControlPropertyScope:
        case kAudioControlPropertyElement:
        case kAudioBooleanControlPropertyValue:
            return true;
        default:
            return false;
    }
}

static Boolean AptX_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    if (inDriver != gDriverRef || !inAddress) return false;
    switch (inObjectID) {
        case kObjectID_PlugIn: return PlugInHasProperty(inAddress);
        case kObjectID_Device: return DeviceHasProperty(inAddress);
        case kObjectID_Stream_Output: return StreamHasProperty(inAddress);
        case kObjectID_Volume_Output: return VolumeHasProperty(inAddress);
        case kObjectID_Mute_Output: return MuteHasProperty(inAddress);
        default: return false;
    }
}

static OSStatus AptX_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outIsSettable) return kAudioHardwareIllegalOperationError;
    if (!AptX_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    switch (inObjectID) {
        case kObjectID_Device:
            *outIsSettable = inAddress->mSelector == kAudioDevicePropertyNominalSampleRate || inAddress->mSelector == kBBPropertyHardwareVolume;
            break;
        case kObjectID_Stream_Output:
            *outIsSettable = inAddress->mSelector == kAudioStreamPropertyIsActive ||
                             inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
                             inAddress->mSelector == kAudioStreamPropertyPhysicalFormat;
            break;
        case kObjectID_Volume_Output:
            *outIsSettable = inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
                             inAddress->mSelector == kAudioLevelControlPropertyDecibelValue;
            break;
        case kObjectID_Mute_Output:
            *outIsSettable = inAddress->mSelector == kAudioBooleanControlPropertyValue;
            break;
        default:
            *outIsSettable = false;
            break;
    }
    return noErr;
}

#pragma mark Properties: reading

// Objects the device owns in a given scope: global and output = output stream + two controls; input = none
static UInt32 DeviceObjects(AudioObjectPropertyScope scope, Boolean streamsOnly, AudioObjectID *objects) {
    UInt32 count = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) {
        objects[count++] = kObjectID_Stream_Output;
        if (!streamsOnly) {
            objects[count++] = kObjectID_Volume_Output;
            objects[count++] = kObjectID_Mute_Output;
        }
    }
    return count;
}

static OSStatus AptX_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize) return kAudioHardwareIllegalOperationError;
    // Device name, sound data and hardware volume mode create a new CF object on every read (released by the caller), so they must not be created when only the size is asked
    if (inObjectID == kObjectID_Device && (inAddress->mSelector == kAudioObjectPropertyName || inAddress->mSelector == kBBPropertyAudioData ||
                                           inAddress->mSelector == kBBPropertyHardwareVolume)) {
        *outDataSize = sizeof(CFStringRef);
        return noErr;
    }
    // For the other properties, fetch the data once with the largest possible size and report the actual size, to avoid writing the size logic twice
    UInt8 scratch[4096];
    return AptX_GetPropertyData(inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, sizeof(scratch), outDataSize, scratch);
}

static OSStatus GetPlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            CHECK_SIZE(AudioObjectID);
            *(AudioObjectID *)outData = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyManufacturer:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kManufacturerName);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioPlugInPropertyBundleID:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kPlugInBundleID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (inDataSize < sizeof(AudioObjectID)) {
                *outDataSize = 0;
                return noErr;
            }
            *(AudioObjectID *)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CHECK_SIZE(AudioObjectID);
            if (qualifierSize < sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qualifier;
            *(AudioObjectID *)outData = uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo ? kObjectID_Device : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioPlugInPropertyResourceBundle:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetDeviceProperty(const AudioObjectPropertyAddress *address, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            CHECK_SIZE(AudioObjectID);
            *(AudioObjectID *)outData = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyName:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFStringCreateWithCString(NULL, DEVICE_NAME, kCFStringEncodingUTF8);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyManufacturer:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kManufacturerName);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioDevicePropertyDeviceUID:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kDeviceUID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioDevicePropertyModelUID:
            CHECK_SIZE(CFStringRef);
            *(CFStringRef *)outData = CFSTR(kDeviceModelUID);
            *outDataSize = sizeof(CFStringRef);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList: {
            AudioObjectID objects[4];
            UInt32 count;
            if (address->mSelector == kAudioObjectPropertyControlList) {
                objects[0] = kObjectID_Volume_Output;
                objects[1] = kObjectID_Mute_Output;
                count = 2;
            } else {
                count = DeviceObjects(address->mScope, address->mSelector == kAudioDevicePropertyStreams, objects);
            }
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (count > fit) count = fit;
            memcpy(outData, objects, count * sizeof(AudioObjectID));
            *outDataSize = count * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioDevicePropertyTransportType:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            if (inDataSize < sizeof(AudioObjectID)) {
                *outDataSize = 0;
                return noErr;
            }
            *(AudioObjectID *)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioDevicePropertyClockDomain:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceIsAlive:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceIsRunning:
            CHECK_SIZE(UInt32);
            pthread_mutex_lock(&gStateMutex);
            *(UInt32 *)outData = gIOCount > 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            // Only the output scope can become a default device: the device has no input (see the file header), so it must never be offered as a microphone
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = address->mScope == kAudioObjectPropertyScopeOutput;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyLatency:
            CHECK_SIZE(UInt32);
            pthread_mutex_lock(&gStateMutex);
            *(UInt32 *)outData = address->mScope == kAudioObjectPropertyScopeOutput ? (UInt32)(gSampleRate * kOutputLatencySeconds) : 0;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertySafetyOffset:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            CHECK_SIZE(Float64);
            pthread_mutex_lock(&gStateMutex);
            *(Float64 *)outData = gSampleRate;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(Float64);
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 count = inDataSize / sizeof(AudioValueRange);
            if (count > kSampleRateCount) count = kSampleRateCount;
            AudioValueRange *ranges = outData;
            for (UInt32 i = 0; i < count; i++) ranges[i] = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            *outDataSize = count * sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioDevicePropertyIsHidden:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            *outDataSize = size;
            return noErr;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = kRingFrames;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo list[] = {
                { kBBPropertyAudioData, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList },
                { kBBPropertyHardwareVolume, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, kAudioServerPlugInCustomPropertyDataTypeNone },
            };
            UInt32 count = inDataSize / sizeof(AudioServerPlugInCustomPropertyInfo);
            if (count > 2) count = 2;
            memcpy(outData, list, count * sizeof(AudioServerPlugInCustomPropertyInfo));
            *outDataSize = count * sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        }
        case kBBPropertyHardwareVolume: {
            CHECK_SIZE(CFPropertyListRef);
            int value = atomic_load(&gHardwareVolume) ? 1 : 0;
            *(CFPropertyListRef *)outData = CFNumberCreate(NULL, kCFNumberIntType, &value);
            *outDataSize = sizeof(CFPropertyListRef);
            return noErr;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// Fetch sound from the sample time given by the caller; format in VirtualDeviceProtocol.h
static OSStatus GetAudioData(UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    CHECK_SIZE(CFDataRef);
    SInt64 cursor = -1;
    if (qualifierSize >= sizeof(CFPropertyListRef) && qualifier) {
        CFPropertyListRef value = *(const CFPropertyListRef *)qualifier;
        if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberSInt64Type, &cursor);
    }
    UInt64 generation = atomic_load(&gGeneration);
    UInt64 written = atomic_load(&gWrittenUntil);
    UInt64 start = cursor < 0 || (UInt64)cursor > written ? written : (UInt64)cursor;
    if (written - start > kBBMaxChunkFrames) start = written - kBBMaxChunkFrames;
    UInt32 frames = (UInt32)(written - start);
    BBAudioChunkHeader header = { generation, start, frames, kChannels, 0 };
    pthread_mutex_lock(&gStateMutex);
    header.sampleRate = gSampleRate;
    pthread_mutex_unlock(&gStateMutex);
    CFIndex length = (CFIndex)(sizeof(header) + (size_t)frames * kBytesPerFrame);
    CFMutableDataRef data = CFDataCreateMutable(NULL, length);
    CFDataSetLength(data, length);
    UInt8 *bytes = CFDataGetMutableBytePtr(data);
    memcpy(bytes, &header, sizeof(header));
    // The writer is at most one IO buffer ahead, and what is fetched is the most recent ≤ half a ring of fully written data, so it never overlaps a write
    Float32 *samples = (Float32 *)(bytes + sizeof(header));
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 slot = (start + i) % kRingFrames;
        for (UInt32 c = 0; c < kChannels; c++) samples[i * kChannels + c] = gRing[slot * kChannels + c];
    }
    *(CFDataRef *)outData = data;
    *outDataSize = sizeof(CFDataRef);
    return noErr;
}

static OSStatus GetStreamProperty(AudioObjectID stream, const AudioObjectPropertyAddress *address, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            CHECK_SIZE(AudioObjectID);
            *(AudioObjectID *)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return noErr;
        case kAudioStreamPropertyIsActive:
            CHECK_SIZE(UInt32);
            pthread_mutex_lock(&gStateMutex);
            *(UInt32 *)outData = gOutputActive;
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyDirection:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyTerminalType:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = kAudioStreamTerminalTypeHeadphones;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyStartingChannel:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 1;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyLatency:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = 0;
            *outDataSize = sizeof(UInt32);
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            CHECK_SIZE(AudioStreamBasicDescription);
            pthread_mutex_lock(&gStateMutex);
            FillFormat(outData, gSampleRate);
            pthread_mutex_unlock(&gStateMutex);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 count = inDataSize / sizeof(AudioStreamRangedDescription);
            if (count > kSampleRateCount) count = kSampleRateCount;
            AudioStreamRangedDescription *formats = outData;
            for (UInt32 i = 0; i < count; i++) {
                FillFormat(&formats[i].mFormat, kSampleRates[i]);
                formats[i].mSampleRateRange = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            }
            *outDataSize = count * sizeof(AudioStreamRangedDescription);
            return noErr;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus GetControlProperty(AudioObjectID control, const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    Boolean volume = control == kObjectID_Volume_Output;
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = volume ? kAudioLevelControlClassID : kAudioBooleanControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyClass:
            CHECK_SIZE(AudioClassID);
            *(AudioClassID *)outData = volume ? kAudioVolumeControlClassID : kAudioMuteControlClassID;
            *outDataSize = sizeof(AudioClassID);
            return noErr;
        case kAudioObjectPropertyOwner:
            CHECK_SIZE(AudioObjectID);
            *(AudioObjectID *)outData = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return noErr;
        case kAudioControlPropertyScope:
            CHECK_SIZE(AudioObjectPropertyScope);
            *(AudioObjectPropertyScope *)outData = kAudioObjectPropertyScopeOutput;
            *outDataSize = sizeof(AudioObjectPropertyScope);
            return noErr;
        case kAudioControlPropertyElement:
            CHECK_SIZE(AudioObjectPropertyElement);
            *(AudioObjectPropertyElement *)outData = kAudioObjectPropertyElementMain;
            *outDataSize = sizeof(AudioObjectPropertyElement);
            return noErr;
        case kAudioLevelControlPropertyScalarValue:
            CHECK_SIZE(Float32);
            *(Float32 *)outData = atomic_load(&gVolumeScalar);
            *outDataSize = sizeof(Float32);
            return noErr;
        case kAudioLevelControlPropertyDecibelValue:
            CHECK_SIZE(Float32);
            *(Float32 *)outData = ScalarToDecibels(atomic_load(&gVolumeScalar));
            *outDataSize = sizeof(Float32);
            return noErr;
        case kAudioLevelControlPropertyDecibelRange:
            CHECK_SIZE(AudioValueRange);
            *(AudioValueRange *)outData = (AudioValueRange){ kVolumeMinDB, 0 };
            *outDataSize = sizeof(AudioValueRange);
            return noErr;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            // outData is both input and output: the caller puts in a scalar and gets back dB
            CHECK_SIZE(Float32);
            *(Float32 *)outData = ScalarToDecibels(*(Float32 *)outData);
            *outDataSize = sizeof(Float32);
            return noErr;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            CHECK_SIZE(Float32);
            *(Float32 *)outData = DecibelsToScalar(*(Float32 *)outData);
            *outDataSize = sizeof(Float32);
            return noErr;
        case kAudioBooleanControlPropertyValue:
            CHECK_SIZE(UInt32);
            *(UInt32 *)outData = atomic_load(&gMuted);
            *outDataSize = sizeof(UInt32);
            return noErr;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus AptX_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;
    if (!AptX_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    switch (inObjectID) {
        case kObjectID_PlugIn: return GetPlugInProperty(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        case kObjectID_Device:
            if (inAddress->mSelector == kBBPropertyAudioData) return GetAudioData(inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            return GetDeviceProperty(inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Stream_Output: return GetStreamProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
        case kObjectID_Volume_Output:
        case kObjectID_Mute_Output: return GetControlProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
        default: return kAudioHardwareBadObjectError;
    }
}

#pragma mark Properties: writing

static OSStatus RequestSampleRate(Float64 rate) {
    for (UInt64 i = 0; i < kSampleRateCount; i++) {
        if (kSampleRates[i] != rate) continue;
        pthread_mutex_lock(&gStateMutex);
        Float64 current = gSampleRate;
        pthread_mutex_unlock(&gStateMutex);
        if (current == rate) return noErr;
        // The host calls PerformDeviceConfigurationChange back at a safe moment
        return gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, i, NULL);
    }
    return kAudioDeviceUnsupportedFormatError;
}

static OSStatus AptX_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!inAddress || !inData) return kAudioHardwareIllegalOperationError;
    switch (inObjectID) {
        case kObjectID_Device:
            if (inAddress->mSelector == kBBPropertyHardwareVolume) {
                CHECK_SIZE(CFPropertyListRef);
                CFPropertyListRef value = *(const CFPropertyListRef *)inData;
                int enabled = 0;
                if (!value || CFGetTypeID(value) != CFNumberGetTypeID() || !CFNumberGetValue(value, kCFNumberIntType, &enabled)) {
                    return kAudioHardwareIllegalOperationError;
                }
                atomic_store(&gHardwareVolume, enabled != 0);
                NotifyChanged(kObjectID_Device, kBBPropertyHardwareVolume, kAudioObjectPropertyScopeGlobal);
                return noErr;
            }
            if (inAddress->mSelector != kAudioDevicePropertyNominalSampleRate) return kAudioHardwareUnknownPropertyError;
            CHECK_SIZE(Float64);
            return RequestSampleRate(*(const Float64 *)inData);
        case kObjectID_Stream_Output:
            if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
                CHECK_SIZE(UInt32);
                pthread_mutex_lock(&gStateMutex);
                gOutputActive = *(const UInt32 *)inData != 0;
                pthread_mutex_unlock(&gStateMutex);
                NotifyChanged(inObjectID, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal);
                return noErr;
            }
            if (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat) {
                CHECK_SIZE(AudioStreamBasicDescription);
                const AudioStreamBasicDescription *format = inData;
                AudioStreamBasicDescription expected;
                FillFormat(&expected, format->mSampleRate);
                if (format->mFormatID != expected.mFormatID || format->mChannelsPerFrame != kChannels || format->mBitsPerChannel != 32 ||
                    (format->mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
                    return kAudioDeviceUnsupportedFormatError;
                }
                return RequestSampleRate(format->mSampleRate);
            }
            return kAudioHardwareUnknownPropertyError;
        case kObjectID_Volume_Output: {
            CHECK_SIZE(Float32);
            Float32 value = *(const Float32 *)inData;
            if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) {
                value = value < 0 ? 0 : (value > 1 ? 1 : value);
            } else if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
                value = DecibelsToScalar(value);
            } else {
                return kAudioHardwareUnknownPropertyError;
            }
            atomic_store(&gVolumeScalar, value);
            AudioObjectPropertyAddress changed[] = {
                { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
            };
            if (gHost) gHost->PropertiesChanged(gHost, kObjectID_Volume_Output, 2, changed);
            return noErr;
        }
        case kObjectID_Mute_Output:
            if (inAddress->mSelector != kAudioBooleanControlPropertyValue) return kAudioHardwareUnknownPropertyError;
            CHECK_SIZE(UInt32);
            atomic_store(&gMuted, *(const UInt32 *)inData != 0);
            NotifyChanged(kObjectID_Mute_Output, kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal);
            return noErr;
        default:
            return kAudioHardwareBadObjectError;
    }
}

#pragma mark IO

static OSStatus AptX_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRing, 0, sizeof(gRing));
        atomic_store(&gWrittenUntil, 0);
        atomic_fetch_add(&gGeneration, 1);
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AptX_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

// Virtual clock advanced on the host clock at the nominal sample rate: one timestamp every kRingFrames frames (as NullAudio does)
static OSStatus AptX_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = gHostTicksPerFrame * kRingFrames;
    UInt64 next = gAnchorHostTime + (UInt64)((gNumberTimeStamps + 1) * ticksPerRing);
    if (next <= now) gNumberTimeStamps++;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)(gNumberTimeStamps * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AptX_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Boolean willDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus AptX_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return inDriver == gDriverRef && inDeviceObjectID == kObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus AptX_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    Float32 *buffer = ioMainBuffer;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && inStreamObjectID == kObjectID_Stream_Output) {
        // The mix of all apps is written into the ring buffer along the output timeline, and volume is applied here (gain = scalar²);
        // in hardware volume mode the headphones' amplifier handles volume, so only mute is handled here
        Float32 scalar = atomic_load(&gVolumeScalar);
        Float32 gain = atomic_load(&gMuted) ? 0 : atomic_load(&gHardwareVolume) ? 1 : scalar * scalar;
        UInt64 start = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        // The timeline skipped ahead (the host skips frames after an IO overload): zero the skipped slots first, so stale data from a ring ago is not fetched
        UInt64 written = atomic_load(&gWrittenUntil);
        for (UInt64 t = written; t < start && start - t <= kRingFrames; t++) {
            for (UInt32 c = 0; c < kChannels; c++) gRing[(t % kRingFrames) * kChannels + c] = 0;
        }
        for (UInt32 i = 0; i < inIOBufferFrameSize; i++) {
            UInt64 slot = (start + i) % kRingFrames;
            for (UInt32 c = 0; c < kChannels; c++) gRing[slot * kChannels + c] = buffer[i * kChannels + c] * gain;
        }
        UInt64 end = start + inIOBufferFrameSize;
        if (end > atomic_load(&gWrittenUntil)) atomic_store(&gWrittenUntil, end);
    }
    return noErr;
}

static OSStatus AptX_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return inDriver == gDriverRef && inDeviceObjectID == kObjectID_Device ? noErr : kAudioHardwareBadObjectError;
}
