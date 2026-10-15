// bluebloom: command-line tool for debugging. Shares Engine with the menu bar app.
// Subcommands: selftest / list / disconnect / probe / play / serve, see PrintUsage.

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <math.h>
#include <signal.h>
#include "freeaptx.h"
#import "A2DPSource.h"
#import "StreamController.h"
#import "BBLog.h"
#import "A2DPProtocol.h"
#import "PCMSource.h"
#import "TestSources.h"
#include <mach/mach_time.h>

#pragma mark - Self-test: encode -> decode round trip, verifying the PCM packing format and the encoder

static inline int32_t GetS24(const uint8_t *p) {
    int32_t sample = p[0] | p[1] << 8 | p[2] << 16;
    return sample & 0x800000 ? sample - 0x1000000 : sample;
}

static double GoertzelPower(const float *samples, size_t count, double frequency, double rate) {
    double coefficient = 2 * cos(2 * M_PI * frequency / rate);
    double previous = 0, previous2 = 0;
    for (size_t i = 0; i < count; i++) {
        double current = samples[i] + coefficient * previous - previous2;
        previous2 = previous;
        previous = current;
    }
    return previous2 * previous2 + previous * previous - coefficient * previous * previous2;
}

static int RunSelfTest(NSString *outputPath) {
    const double rate = 48000;
    const size_t samples = 96000;  // 2 seconds, a multiple of 4
    NSMutableData *pcm = [NSMutableData dataWithLength:samples * kPCMBytesPerSample];
    [[[ToneSource alloc] initWithRate:rate seconds:2] read:pcm.mutableBytes frames:samples];

    struct aptx_context *encoder = aptx_init(0);
    NSMutableData *encoded = [NSMutableData dataWithLength:samples + 1024];
    size_t written = 0, tail = 0;
    size_t consumed = aptx_encode(encoder, pcm.bytes, pcm.length, encoded.mutableBytes, encoded.length, &written);
    aptx_encode_finish(encoder, (uint8_t *)encoded.mutableBytes + written, encoded.length - written, &tail);
    aptx_finish(encoder);
    encoded.length = written + tail;
    BBLog(@"Encode: input %zu/%lu bytes PCM -> %lu bytes aptX (compression ratio %.2f:1, expected 6:1)", consumed, (unsigned long)pcm.length,
        (unsigned long)encoded.length, (double)pcm.length / written);
    if (consumed != pcm.length || written != samples) {
        BBLog(@"Failed: encoder input/output lengths do not match the aptX spec");
        return 1;
    }
    if (outputPath) {
        [encoded writeToFile:outputPath atomically:YES];
        BBLog(@"Wrote raw aptX stream: %@", outputPath);
    }

    struct aptx_context *decoder = aptx_init(0);
    NSMutableData *decoded = [NSMutableData dataWithLength:(encoded.length / kAptxFrameBytes + 1) * 24];
    size_t decodedBytes = 0;
    size_t decodedInput = aptx_decode(decoder, encoded.bytes, encoded.length, decoded.mutableBytes, decoded.length, &decodedBytes);
    aptx_finish(decoder);
    BBLog(@"Decode: %zu/%lu bytes passed the parity sync check, got %zu samples", decodedInput, (unsigned long)encoded.length, decodedBytes / kPCMBytesPerSample);
    if (decodedInput != encoded.length) {
        BBLog(@"Failed: sync check failed partway through decoding");
        return 1;
    }

    size_t count = MIN(decodedBytes / kPCMBytesPerSample, samples);
    const uint8_t *original = pcm.bytes;
    const uint8_t *output = decoded.bytes;
    // Find the alignment offset with the smallest error, then compute the SNR of both channels
    int bestLag = 0;
    double bestError = INFINITY;
    for (int lag = -200; lag <= 200; lag++) {
        double error = 0;
        for (size_t i = 4096; i < count - 4096; i += 7) {
            double difference = GetS24(output + i * 6) - GetS24(original + (i + lag) * 6);
            error += difference * difference;
        }
        if (error < bestError) {
            bestError = error;
            bestLag = lag;
        }
    }
    int result = 0;
    for (int channel = 0; channel < 2; channel++) {
        double signalPower = 0, noisePower = 0;
        NSMutableData *floats = [NSMutableData dataWithLength:(count - 8192) * sizeof(float)];
        float *values = floats.mutableBytes;
        for (size_t i = 4096; i < count - 4096; i++) {
            double reference = GetS24(original + (i + bestLag) * 6 + channel * 3);
            double actual = GetS24(output + i * 6 + channel * 3);
            signalPower += reference * reference;
            noisePower += (actual - reference) * (actual - reference);
            values[i - 4096] = (float)actual;
        }
        double snr = 10 * log10(signalPower / fmax(noisePower, 1));
        double expected = channel == 0 ? 440 : 660;
        double other = channel == 0 ? 660 : 440;
        double separation = 10 * log10(GoertzelPower(values, count - 8192, expected, rate) / fmax(GoertzelPower(values, count - 8192, other, rate), 1e-9));
        BBLog(@"%@ channel: alignment offset %d samples, SNR %.1f dB, %.0fHz exceeds %.0fHz by %.1f dB", channel == 0 ? @"Left" : @"Right", bestLag, snr, expected, other, separation);
        if (snr < 40 || separation < 40) result = 1;
    }
    BBLog(result == 0 ? @"Self-test passed" : @"Self-test failed");
    return result;
}

#pragma mark - Entry point

static void PrintUsage(void) {
    printf("Usage:\n"
           "  bluebloom selftest [--out file.aptx]          Encode->decode round-trip self-test; can write out the raw aptX stream\n"
           "  bluebloom list                                List paired devices\n"
           "  bluebloom disconnect <address|name>           Disconnect macOS from the device\n"
           "  bluebloom probe <address|name>                Connect to the headphones and list their declared codec capabilities\n"
           "  bluebloom play <address|name> [--rate sample-rate] [--file audio-file] [--seconds seconds] [codec options]\n"
           "                                                Stream a test tone or an audio file\n"
           "  bluebloom play <address|name> --system        Stream system-wide audio (Mac speakers muted meanwhile); Ctrl-C to stop\n"
           "  bluebloom play <address|name> --device        Stream the audio the virtual device receives (virtual device driver must be installed first); Ctrl-C to stop\n"
           "  bluebloom serve <address|name> [--system]     Resident: auto-connect, reconnect on drop, idle suspend; takes audio from the virtual device by default\n"
           "  bluebloom codectest [--mtu bytes]             Without headphones: encode a 5 s test tone with each codec at each sample rate; report packet size, bitrate, encode time\n"
           "Codec options:\n"
           "  --codec codec-ID                                Prefer this codec (falls back by default priority if the headphones do not support it or it is unavailable)\n"
           "  --preset codec=abr|kbps                         Bitrate tier for a codec: abr for adaptive, or pick by 48k bitrate (kbps),\n"
           "                                                  e.g. ldac=660; repeatable (default: each codec's default tier)\n"
           "  --aac-bitrate bits-per-second  --aac-cbr        AAC bitrate (default capped at 320k); use constant bitrate\n"
           "  --sbc-xq                                        SBC with dual-channel high bitpool\n"
           "  --fixed-rate                                    SBC and AAC do not lower the bitrate automatically with the link\n"
           "  --max-rate sample-rate                          Maximum sample rate\n");
    printf("Compiled-in codecs (ID: bitrate tiers):\n");
    for (A2DPCodec *codec in [A2DPCodec allCodecs]) {
        NSMutableArray<NSString *> *presets = [NSMutableArray array];
        for (CodecPreset *preset in codec.presets) [presets addObject:preset.adaptive ? @"abr" : [NSString stringWithFormat:@"%.0f", preset.kbps]];
        printf("  %-14s %s\n", codec.identifier.UTF8String, presets.count ? [presets componentsJoinedByString:@"|"].UTF8String : "—");
    }
}

static IOBluetoothDevice *FindDevice(NSString *query) {
    NSString *address = [[query stringByReplacingOccurrencesOfString:@":" withString:@"-"] lowercaseString];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^([0-9a-f]{2}-){5}[0-9a-f]{2}$" options:0 error:nil];
    if ([pattern numberOfMatchesInString:address options:0 range:NSMakeRange(0, address.length)]) {
        return [IOBluetoothDevice deviceWithAddressString:address];
    }
    for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
        if ([device.name rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) return device;
    }
    return nil;
}

static NSString *OptionValue(NSArray<NSString *> *arguments, NSString *name) {
    NSUInteger index = [arguments indexOfObject:name];
    return index != NSNotFound && index + 1 < arguments.count ? arguments[index + 1] : nil;
}

static CodecOptions *OptionsFromArguments(NSArray<NSString *> *arguments) {
    CodecOptions *options = [CodecOptions new];
    options.preferredCodec = OptionValue(arguments, @"--codec");
    // --preset codec=abr|kbps: bitrate tiers are declared by each codec (A2DPCodec presets)
    NSMutableDictionary<CodecID, NSNumber *> *presets = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i + 1 < arguments.count; i++) {
        if (![arguments[i] isEqualToString:@"--preset"]) continue;
        NSArray<NSString *> *parts = [arguments[i + 1] componentsSeparatedByString:@"="];
        A2DPCodec *codec = parts.count == 2 ? [A2DPCodec codecWithID:parts[0].lowercaseString] : nil;
        BOOL adaptive = [parts.lastObject.lowercaseString isEqualToString:@"abr"];
        CodecPreset *match = nil;
        for (CodecPreset *preset in codec.presets) {
            if (adaptive ? preset.adaptive : (!preset.adaptive && preset.kbps == parts.lastObject.doubleValue)) match = preset;
        }
        if (match) presets[codec.identifier] = @(match.identifier);
        else fprintf(stderr, "Ignoring --preset %s: no such codec or tier\n", arguments[i + 1].UTF8String);
    }
    options.presets = presets;
    options.aacBitrate = [OptionValue(arguments, @"--aac-bitrate") integerValue];
    options.aacVBR = ![arguments containsObject:@"--aac-cbr"];
    options.sbcXQ = [arguments containsObject:@"--sbc-xq"];
    options.sbcAdaptive = options.aacAdaptive = ![arguments containsObject:@"--fixed-rate"];
    options.maxSampleRate = [OptionValue(arguments, @"--max-rate") doubleValue];
    return options;
}

#pragma mark - Codec-layer smoke test: without headphones, run configure -> create encoder -> encode with a capability element where "the headphones support everything"

// Unit tests for the sample rate selection rules (A2DPBestSampleRate)
static int CheckRateRules(void) {
    struct { NSArray<NSNumber *> *rates; double desired; BOOL strict; double expected; } cases[] = {
        { @[@44100, @48000, @88200, @96000], 96000, YES, 96000 },   // LDAC: 96k source used as is
        { @[@44100, @48000, @88200, @96000], 192000, YES, 96000 },  // 192k track: highest in the same family, 96k
        { @[@44100, @48000, @88200, @96000], 176400, YES, 88200 },  // 176.4k: highest in the 44.1 family, 88.2k
        { @[@44100, @48000], 96000, YES, 48000 },                   // aptX + 96k track: 48k
        { @[@44100, @48000], 88200, YES, 44100 },                   // aptX + 88.2k track: 44.1k
        { @[@48000], 44100, YES, 0 },                               // strict: no crossing families
        { @[@48000], 44100, NO, 48000 },                            // 48k-only codec + 44.1k track: used when choosing a codec, crosses families to 48k
        { @[@44100], 48000, NO, 44100 },
        { @[@88200, @96000], 44100, YES, 88200 },                   // Same family has only higher rates: take the lowest of them
        { @[], 48000, NO, 0 },
    };
    int failures = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        double got = A2DPBestSampleRate(cases[i].rates, cases[i].desired, cases[i].strict);
        if (got != cases[i].expected) {
            printf("Sample rate rule #%zu failed: expected %.0f, got %.0f\n", i, cases[i].expected, got);
            failures++;
        }
    }
    if (failures) printf("Sample rate rules: %d failed\n", failures);
    else printf("Sample rate rules: all %zu passed\n", sizeof(cases) / sizeof(cases[0]));
    return failures;
}

// Cached headphone codecs are re-identified against the current registry when read back (RemoteCodec initWithCoder): simulate records saved by an old build (codec is nil);
// compiled-in codecs must be recognized again, and unimplemented vendor codecs show as "vendor ID/codec ID"
static int CheckRemoteCodecCache(void) {
    int failures = 0;
    NSMutableArray<NSData *> *elements = [NSMutableArray array];
    for (A2DPCodec *codec in [A2DPCodec allCodecs]) [elements addObject:codec.fullCapabilityElement];
    static const uint8_t unknown[] = { 0x00, 0xFF, 0x3A, 0x05, 0x00, 0x00, 0x35, 0x4C, 0x00, 0x00 };  // vendor 0x053A, codec 0x4C35
    [elements addObject:[NSData dataWithBytes:unknown length:sizeof(unknown)]];
    for (NSData *element in elements) {
        RemoteCodec *stale = [[RemoteCodec alloc] initWithCodec:nil name:@"Stale record" sampleRates:@[] element:element];
        NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:@[stale] requiringSecureCoding:YES error:nil];
        RemoteCodec *loaded = [NSKeyedUnarchiver unarchivedArrayOfObjectsOfClass:RemoteCodec.class fromData:archive error:nil].firstObject;
        A2DPCodec *expected = [A2DPCodec codecForElement:element];
        NSString *expectedName = expected ? expected.displayName : @"53A/4C35";
        BOOL ok = loaded && (loaded.codec == expected.identifier || [loaded.codec isEqualToString:expected.identifier]) &&
                  [loaded.name isEqualToString:expectedName] && (expected == nil) == (loaded.sampleRates.count == 0);
        if (!ok) {
            printf("Cache re-identification failed: expected %s, got %s (%s)\n", expectedName.UTF8String, loaded.name.UTF8String, (loaded.codec ?: @"nil").UTF8String);
            failures++;
        }
    }
    if (!failures) printf("Cache re-identification: all %lu passed\n", (unsigned long)elements.count);
    return failures;
}

static int RunCodecTest(NSArray<NSString *> *arguments) {
    uint16_t mtu = (uint16_t)([OptionValue(arguments, @"--mtu") intValue] ?: 895);
    CodecOptions *options = OptionsFromArguments(arguments);
    int failures = CheckRateRules() + CheckRemoteCodecCache();
    printf("Media channel MTU %u; compiled-in codecs: ", mtu);
    for (A2DPCodec *codec in [A2DPCodec allCodecs]) printf("%s ", codec.displayName.UTF8String);
    printf("\n");
    // Run each codec through its own declared full-capability element (A2DPCodec fullCapabilityElement)
    for (A2DPCodec *codec in [A2DPCodec allCodecs]) {
        NSData *element = codec.fullCapabilityElement;
        if ([A2DPCodec codecForElement:element] != codec) {
            printf("%-14s failed: full-capability element is not recognized as this codec\n", codec.displayName.UTF8String);
            failures++;
            continue;
        }
        for (NSNumber *rateValue in [codec sampleRatesInCapability:element]) @autoreleasepool {
            double rate = rateValue.doubleValue;
            CodecConfiguration *configuration = [codec configurationForCapability:element sampleRate:rate options:options];
            NSString *error = nil;
            id<A2DPEncoder> encoder = configuration ? [codec encoderForConfiguration:configuration outMTU:mtu options:options error:&error] : nil;
            if (!encoder) {
                printf("%-14s %5.1f kHz  failed: %s\n", codec.displayName.UTF8String, rate / 1000, (error ?: @"no configuration").UTF8String);
                failures++;
                continue;
            }
            ToneSource *tone = [[ToneSource alloc] initWithRate:rate seconds:5];
            NSMutableData *pcm = [NSMutableData dataWithLength:encoder.framesPerCall * kPCMBytesPerSample];
            size_t frames = 0, packets = 0, bytes = 0, maxPacket = 0;
            uint64_t begin = mach_absolute_time();
            while (frames < rate * 5) {
                [tone read:pcm.mutableBytes frames:encoder.framesPerCall];
                frames += encoder.framesPerCall;
                NSArray<NSData *> *output = [encoder encode:pcm.bytes error:&error];
                if (!output) break;
                for (NSData *packet in output) {
                    packets++;
                    bytes += packet.length;
                    maxPacket = MAX(maxPacket, packet.length);
                }
            }
            double seconds = BBTicksToSeconds(mach_absolute_time() - begin);
            double audio = frames / rate;
            BOOL ok = error == nil && packets > 0 && maxPacket <= mtu;
            if (!ok) failures++;
            printf("%-14s %5.1f kHz  %s  %4zu packets, max %3zu bytes, on air %6.1f kbps (nominal %6.1f), encode time %.2f%%  %s\n",
                codec.displayName.UTF8String, rate / 1000, ok ? "passed" : "failed", packets, maxPacket, bytes * 8 / audio / 1000,
                configuration.nominalKbps, seconds / audio * 100, (error ?: configuration.summary).UTF8String);
        }
    }
    printf(failures ? "%d failed\n" : "All passed\n", failures);
    return failures ? 1 : 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        if (arguments.count < 2) {
            PrintUsage();
            return 64;
        }
        NSString *command = arguments[1];
        if ([command isEqualToString:@"selftest"]) {
            return RunSelfTest(OptionValue(arguments, @"--out"));
        }
        if ([command isEqualToString:@"codectest"]) {
            return RunCodecTest(arguments);
        }
        if ([command isEqualToString:@"list"]) {
            for (IOBluetoothDevice *device in [IOBluetoothDevice pairedDevices]) {
                printf("%s  %-28s connected=%d\n", device.addressString.UTF8String, device.name.UTF8String, device.isConnected);
            }
            return 0;
        }
        if ([command isEqualToString:@"disconnect"] && arguments.count >= 3) {
            IOBluetoothDevice *device = FindDevice(arguments[2]);
            if (!device) {
                BBLog(@"Device not found: %@", arguments[2]);
                return 2;
            }
            IOReturn result = [device closeConnection];
            BBLog(@"Disconnect %@: IOReturn 0x%08X", device.name, result);
            return result == kIOReturnSuccess ? 0 : 2;
        }
        BOOL probe = [command isEqualToString:@"probe"];
        BOOL serve = [command isEqualToString:@"serve"];
        if ((!probe && !serve && ![command isEqualToString:@"play"]) || arguments.count < 3) {
            PrintUsage();
            return 64;
        }
        if ([IOBluetoothHostController defaultController].powerState != kBluetoothHCIPowerStateON) {
            BBLog(@"Bluetooth is off");
            return 2;
        }
        IOBluetoothDevice *device = FindDevice(arguments[2]);
        if (!device) {
            BBLog(@"Device not found: %@", arguments[2]);
            return 2;
        }
        CodecOptions *options = OptionsFromArguments(arguments);
        if (serve) {
            // Resident: reconnect automatically after the headphones disconnect or the session fails; takes audio from the virtual device by default, --system captures system-wide audio instead
            StreamController *controller = [[StreamController alloc] initWithDevice:device virtualDevice:![arguments containsObject:@"--system"]];
            controller.optionsProvider = ^CodecOptions *{ return options; };
            signal(SIGINT, SIG_IGN);
            dispatch_source_t interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(interrupt, ^{ [controller stopWithCompletion:^{ exit(0); }]; });
            dispatch_resume(interrupt);
            [controller start];
            CFRunLoopRun();
            return 0;
        }
        double rate = [OptionValue(arguments, @"--rate") doubleValue];
        NSString *seconds = OptionValue(arguments, @"--seconds");
        A2DPSource *source = [[A2DPSource alloc] initWithDevice:device
                                                          mode:probe ? SourceModeProbe : SourceModePlay
                                                          rate:rate
                                                          file:OptionValue(arguments, @"--file")
                                                       seconds:seconds ? seconds.doubleValue : 15
                                                   systemAudio:[arguments containsObject:@"--system"]];
        source.useVirtualDevice = [arguments containsObject:@"--device"];
        source.options = options;
        signal(SIGINT, SIG_IGN);
        dispatch_source_t interrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(interrupt, ^{ [source stopWithReason:@"Interrupted by user" exitCode:130]; });
        dispatch_resume(interrupt);
        [source start];
        CFRunLoopRun();
    }
    return 0;
}
