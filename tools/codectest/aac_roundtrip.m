// AAC round-trip test: AACEncoder encode, wrap in LATM → independently parse every AudioMuxElement per ISO/IEC 14496-3 (check StreamMuxConfig,
// PayloadLengthInfo, extract the AU) → decode with AudioConverter → align by the encoder delay, compute per-channel SNR, measured bitrate, max AU, encode time.
// Also wraps the elements in LOAS and hands them to the system LATM parser (AudioFileStream) for a cross-check.
// bazel run //tools/codectest:aac_roundtrip; exit code is 0 when everything passes.
// With the environment variable AAC_LOAS_DIR=<dir> set, each case also saves a .loas, which can be checked again with ffmpeg -f loas -i x.loas

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <mach/mach_time.h>

#import "AACEncoder.h"

static int gFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { gFailures++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

// ---- Test signal: 10 s stereo, left 1 kHz, right 3.5 kHz sine (peak 0.4) + independent white noise per channel (peak 0.05, about −31 dBFS RMS).
// The noise makes the delay search unique (a pure sine has one solution per period) and brings SNR closer to real music (perceptual coding does not reproduce noise sample by sample, SNR about 22–37 dB) ----
typedef NS_ENUM(int, Signal) { SignalTones, SignalPureTones, SignalTransients };

static float *MakeSignal(Signal kind, double rate, size_t frames) {
    float *x = malloc(frames * 2 * sizeof(float));
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; i++) {
        double t = i / rate;
        float n[2];
        for (int c = 0; c < 2; c++) {
            seed = seed * 1664525u + 1013904223u;
            n[c] = (float)((int32_t)seed / 2147483648.0);
        }
        if (kind != SignalTransients) {
            float noise = kind == SignalTones ? 0.05f : 0;
            x[2 * i] = 0.4f * sinf(2 * M_PI * 1000 * t) + noise * n[0];
            x[2 * i + 1] = 0.4f * sinf(2 * M_PI * 3500 * t) + noise * n[1];
        } else {   // a full-scale noise hit every 100 ms with exponential decay: the case that drains the bit reservoir most, to see the CBR AU peak
            size_t phase = i % (size_t)(rate / 10);
            float env = phase < 200 ? 1.0f : expf(-(float)(phase - 200) / 300.0f);
            x[2 * i] = 0.9f * env * n[0];
            x[2 * i + 1] = 0.9f * env * n[1];
        }
    }
    return x;
}

static void ToPCM24(const float *x, uint8_t *out, size_t samples) {
    for (size_t i = 0; i < samples; i++) {
        double v = fmax(-1.0, fmin(1.0, x[i]));
        int32_t s = (int32_t)lrint(v * 8388607.0);
        out[3 * i] = s & 0xFF;
        out[3 * i + 1] = (s >> 8) & 0xFF;
        out[3 * i + 2] = (s >> 16) & 0xFF;
    }
}

// ---- Bit reader ----
typedef struct { const uint8_t *p; size_t bits, total; BOOL overrun; } Reader;
static uint32_t Get(Reader *r, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        if (r->bits >= r->total) { r->overrun = YES; return 0; }
        v = v << 1 | ((r->p[r->bits >> 3] >> (7 - (r->bits & 7))) & 1);
        r->bits++;
    }
    return v;
}
static uint32_t LatmGetValue(Reader *r) {
    int bytes = (int)Get(r, 2) + 1;
    uint32_t v = 0;
    for (int i = 0; i < bytes; i++) v = v << 8 | Get(r, 8);
    return v;
}

static const double kFreqs[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};

// AudioMuxElement(1) (ISO/IEC 14496-3 1.7.3 tables 1.41-1.44). Returns the AU and checks that every field has the FDK/Android value
static NSData *ParseElement(NSData *element, double rate, NSData **ascOut, NSString **why) {
    Reader r = {element.bytes, 0, element.length * 8, NO};
#define REQUIRE(cond, msg) do { if (!(cond)) { *why = msg; return nil; } } while (0)
    REQUIRE(Get(&r, 1) == 0, @"useSameStreamMux should be 0 (every frame carries StreamMuxConfig)");
    uint32_t version = Get(&r, 1);
    REQUIRE(version == 1, @"audioMuxVersion should be 1");
    REQUIRE(Get(&r, 1) == 0, @"audioMuxVersionA should be 0");
    REQUIRE(LatmGetValue(&r) == 0xFF, @"taraBufferFullness should be 0xFF");
    REQUIRE(Get(&r, 1) == 1, @"allStreamsSameTimeFraming should be 1");
    REQUIRE(Get(&r, 6) == 0, @"numSubFrames should be 0");
    REQUIRE(Get(&r, 4) == 0, @"numProgram should be 0");
    REQUIRE(Get(&r, 3) == 0, @"numLayer should be 0");
    uint32_t ascLen = LatmGetValue(&r);
    size_t ascStart = r.bits;
    uint32_t aot = Get(&r, 5);
    uint32_t sfi = Get(&r, 4);
    uint32_t channels = Get(&r, 4);
    uint32_t frameLengthFlag = Get(&r, 1), dependsOnCore = Get(&r, 1), extensionFlag = Get(&r, 1);
    size_t ascBits = r.bits - ascStart;
    REQUIRE(aot == 2 && sfi < 13 && kFreqs[sfi] == rate && channels == 2, @"ASC should be AOT 2, the matching sample rate, channel configuration 2");
    REQUIRE(frameLengthFlag == 0 && dependsOnCore == 0 && extensionFlag == 0, @"GASpecificConfig should be all 0 (1024 frame length)");
    REQUIRE(ascLen >= ascBits && ascLen - ascBits < 8, @"ascLen does not match the ASC length");
    REQUIRE(Get(&r, (int)(ascLen - ascBits)) == 0, @"ASC padding bits should be 0");
    REQUIRE((r.bits - ascStart + 10) % 8 == 0, @"ascLen field + ASC + padding should be byte aligned (same as FDK)");
    if (ascOut) {
        uint8_t asc[2] = {0};
        Reader a = {element.bytes, ascStart, element.length * 8, NO};
        asc[0] = (uint8_t)Get(&a, 8);
        asc[1] = (uint8_t)Get(&a, 8);
        *ascOut = [NSData dataWithBytes:asc length:2];
    }
    REQUIRE(Get(&r, 3) == 0, @"frameLengthType should be 0");
    REQUIRE(Get(&r, 8) == 0xC0, @"latmBufferFullness should be 0xC0 (FDK AUDIOMUXVER=2)");
    REQUIRE(Get(&r, 1) == 0, @"otherDataPresent should be 0");
    REQUIRE(Get(&r, 1) == 0, @"crcCheckPresent should be 0");
    size_t length = 0;
    uint32_t tmp;
    do {
        tmp = Get(&r, 8);
        length += tmp;
    } while (tmp == 255 && !r.overrun);
    REQUIRE(r.bits % 8 == 0, @"AU should start on a byte boundary");
    REQUIRE(!r.overrun && r.bits / 8 + length == element.length, @"PayloadLengthInfo does not match the element length (there should be no extra bytes at the end)");
    return [element subdataWithRange:NSMakeRange(r.bits / 8, length)];
#undef REQUIRE
}

// ---- Decode: wrap the ASC in an ES_Descriptor as the magic cookie ----
static NSData *ESDSCookie(NSData *asc) {
    NSMutableData *d = [NSMutableData data];
    uint8_t dsi[2 + 2] = {0x05, (uint8_t)asc.length};
    NSMutableData *dcd = [NSMutableData dataWithBytes:(uint8_t[]){0x04, (uint8_t)(13 + 2 + asc.length), 0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0} length:15];
    [dcd appendBytes:dsi length:2];
    [dcd appendData:asc];
    uint8_t es[5] = {0x03, (uint8_t)(3 + dcd.length + 3), 0, 0, 0};
    [d appendBytes:es length:5];
    [d appendData:dcd];
    [d appendBytes:(uint8_t[]){0x06, 0x01, 0x02} length:3];
    return d;
}

typedef struct { __unsafe_unretained NSArray<NSData *> *aus; NSUInteger next; AudioStreamPacketDescription desc; } DecodeState;
static OSStatus DecodeInput(AudioConverterRef c, UInt32 *ioPackets, AudioBufferList *data, AudioStreamPacketDescription **desc, void *user) {
    DecodeState *s = user;
    if (s->next >= s->aus.count) { *ioPackets = 0; return noErr; }   // end of stream
    NSData *au = s->aus[s->next++];
    data->mBuffers[0].mData = (void *)au.bytes;
    data->mBuffers[0].mDataByteSize = (UInt32)au.length;
    data->mBuffers[0].mNumberChannels = 2;
    s->desc = (AudioStreamPacketDescription){0, 0, (UInt32)au.length};
    if (desc) *desc = &s->desc;
    *ioPackets = 1;
    return noErr;
}

static float *Decode(NSArray<NSData *> *aus, NSData *asc, double rate, size_t *framesOut, NSString **why) {
    AudioStreamBasicDescription in = {.mSampleRate = rate, .mFormatID = kAudioFormatMPEG4AAC, .mFormatFlags = kMPEG4Object_AAC_LC,
                                      .mFramesPerPacket = 1024, .mChannelsPerFrame = 2};
    AudioStreamBasicDescription out = {.mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
                                       .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                       .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32};
    AudioConverterRef dec = NULL;
    OSStatus st = AudioConverterNew(&in, &out, &dec);
    if (st) { *why = [NSString stringWithFormat:@"decoder creation failed %d", (int)st]; return NULL; }
    NSData *cookie = ESDSCookie(asc);
    st = AudioConverterSetProperty(dec, kAudioConverterDecompressionMagicCookie, (UInt32)cookie.length, cookie.bytes);
    if (st) { *why = [NSString stringWithFormat:@"setting the decoder cookie failed %d", (int)st]; AudioConverterDispose(dec); return NULL; }
    size_t capacity = (aus.count + 4) * 1024;
    float *pcm = calloc(capacity * 2, sizeof(float));
    DecodeState s = {aus, 0, {0}};
    size_t frames = 0;
    while (frames < capacity) {
        UInt32 n = (UInt32)MIN(capacity - frames, 4096);
        AudioBufferList abl = {1, {{2, n * 8, pcm + frames * 2}}};
        st = AudioConverterFillComplexBuffer(dec, DecodeInput, &s, &n, &abl, NULL);
        if (st) { *why = [NSString stringWithFormat:@"decode failed %d", (int)st]; free(pcm); AudioConverterDispose(dec); return NULL; }
        if (n == 0) break;
        frames += n;
    }
    AudioConverterDispose(dec);
    *framesOut = frames;
    return pcm;
}

// ---- Cross-check with the system LATM parser: prefix each element with a LOAS sync header (0x2B7 + 13-bit length, ISO/IEC 14496-3 1.7.2) and hand it to AudioFileStream ----
static NSData *LOASStream(NSArray<NSData *> *elements) {
    NSMutableData *loas = [NSMutableData data];
    for (NSData *e in elements) {
        uint8_t sync[3] = {0x56, (uint8_t)(0xE0 | (e.length >> 8)), (uint8_t)e.length};
        [loas appendBytes:sync length:3];
        [loas appendData:e];
    }
    return loas;
}

typedef struct { __unsafe_unretained NSMutableArray<NSData *> *aus; AudioStreamBasicDescription format; } LOASState;
static void LOASProperty(void *user, AudioFileStreamID stream, AudioFileStreamPropertyID property, AudioFileStreamPropertyFlags *flags) {
    LOASState *s = user;
    if (property == kAudioFileStreamProperty_DataFormat) {
        UInt32 size = sizeof s->format;
        AudioFileStreamGetProperty(stream, property, &size, &s->format);
    }
}
static void LOASPackets(void *user, UInt32 bytes, UInt32 packets, const void *data, AudioStreamPacketDescription *desc) {
    LOASState *s = user;
    for (UInt32 i = 0; desc && i < packets; i++) {
        [s->aus addObject:[NSData dataWithBytes:(const uint8_t *)data + desc[i].mStartOffset length:desc[i].mDataByteSize]];
    }
}

static void CheckWithSystemParser(NSArray<NSData *> *elements, NSArray<NSData *> *aus, double rate) {
    NSMutableArray<NSData *> *parsed = [NSMutableArray array];
    LOASState state = {parsed, {0}};
    AudioFileStreamID stream = NULL;
    OSStatus st = AudioFileStreamOpen(&state, LOASProperty, LOASPackets, kAudioFileLATMInLOASType, &stream);
    CHECK(st == noErr, "AudioFileStreamOpen %d", (int)st);
    if (st) return;
    NSData *loas = LOASStream(elements);
    st = AudioFileStreamParseBytes(stream, (UInt32)loas.length, loas.bytes, 0);
    AudioFileStreamClose(stream);
    CHECK(st == noErr, "system LATM parse failed %d", (int)st);
    CHECK(state.format.mFormatID == kAudioFormatMPEG4AAC && state.format.mSampleRate == rate && state.format.mChannelsPerFrame == 2,
          "wrong format from the system parser: %.0f Hz %u channels", state.format.mSampleRate, state.format.mChannelsPerFrame);
    NSUInteger same = 0;
    for (NSUInteger i = 0; i < MIN(parsed.count, aus.count); i++) same += [parsed[i] isEqualToData:aus[i]];
    CHECK(parsed.count == aus.count && same == aus.count, "system parser produced %lu AUs, %lu of them match this test's parse (should be %lu)",
          (unsigned long)parsed.count, (unsigned long)same, (unsigned long)aus.count);
    printf("  System LATM parser (AudioFileStream LOAS): %.0f Hz %u channels, %lu AUs byte-identical to this test's parse\n", state.format.mSampleRate,
           state.format.mChannelsPerFrame, (unsigned long)same);
    NSString *dir = NSProcessInfo.processInfo.environment[@"AAC_LOAS_DIR"];
    if (dir.length) {
        static int index = 0;
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"case%02d_%.0f.loas", index++, rate]];
        [loas writeToFile:path atomically:YES];
        printf("  Saved %s\n", path.UTF8String);
    }
}

// Find the integer delay in 0..maxDelay that minimizes the error energy (both channels summed, 1 s window)
static size_t FindDelay(const float *ref, const float *dec, size_t frames, size_t decFrames, size_t maxDelay, double rate) {
    size_t start = (size_t)rate, window = (size_t)rate;
    double best = INFINITY;
    size_t bestDelay = 0;
    for (size_t d = 0; d <= maxDelay; d++) {
        if (start + window + d > decFrames || start + window > frames) break;
        double e = 0;
        for (size_t i = 2 * start; i < 2 * (start + window); i++) {
            double diff = dec[i + 2 * d] - ref[i];
            e += diff * diff;
        }
        if (e < best) { best = e; bestDelay = d; }
    }
    return bestDelay;
}

static double Seconds(uint64_t ticks) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)ticks * tb.numer / tb.denom / 1e9;
}

typedef struct {
    const char *name;
    double rate;
    int bitrate;
    BOOL vbr;
    Signal signal;
    size_t mtu;             // >0: peak bitrate from AACMaxBitrateForMTU, and check every packet ≤ MTU
    double minSNR;          // per-channel SNR minimum (dB), 0 = not checked (transient signal)
} Case;

static void RunCase(Case c) {
    const double seconds = 10;
    size_t frames = (size_t)(c.rate * seconds) / 1024 * 1024;
    int bitrate = c.mtu ? AACMaxBitrateForMTU(c.mtu, c.rate) : c.bitrate;
    printf("\n== %s: %.1f kHz %s %d bit/s%s\n", c.name, c.rate / 1000, c.vbr ? "VBR peak" : "CBR", bitrate,
           c.mtu ? [NSString stringWithFormat:@" (L2CAP MTU %zu)", c.mtu].UTF8String : "");
    NSString *err = nil;
    AACEncoder *enc = [[AACEncoder alloc] initWithSampleRate:c.rate bitrate:bitrate vbr:c.vbr error:&err];
    CHECK(enc != nil, "init failed: %s", err.UTF8String);
    if (!enc) return;
    CHECK(enc.framesPerCall == 1024, "framesPerCall = %zu", enc.framesPerCall);
    printf("  Config: bitrate %d, maxElementBytes %zu, primingFrames %u\n", enc.bitrate, enc.maxElementBytes, enc.primingFrames);

    float *ref = MakeSignal(c.signal, c.rate, frames);
    size_t tailCalls = 4;   // pad the end with silence to flush the samples left in the encoder
    uint8_t *pcm24 = calloc((frames + tailCalls * 1024) * 6, 1);
    ToPCM24(ref, pcm24, frames * 2);

    NSMutableArray<NSData *> *elements = [NSMutableArray array];
    size_t calls = frames / 1024 + tailCalls, zeroCalls = 0, multiCalls = 0;
    uint64_t encodeTicks = 0;
    for (size_t k = 0; k < calls; k++) {
        uint64_t t0 = mach_absolute_time();
        NSArray<NSData *> *out = [enc encodePCM24:pcm24 + k * 1024 * 6 error:&err];
        encodeTicks += mach_absolute_time() - t0;
        if (!out) { CHECK(NO, "encode call %zu failed: %s", k, err.UTF8String); break; }
        if (out.count == 0) zeroCalls++;
        if (out.count > 1) multiCalls++;
        [elements addObjectsFromArray:out];
    }
    double encodeSec = Seconds(encodeTicks);

    // Parse
    NSMutableArray<NSData *> *aus = [NSMutableArray array];
    NSData *asc = nil;
    size_t auBytes = 0, elementBytes = 0, maxAU = 0, maxElement = 0, minAU = SIZE_MAX, parseErrors = 0;
    NSData *firstHeader = nil;
    for (NSData *e in elements) {
        NSString *why = nil;
        NSData *thisASC = nil;
        NSData *au = ParseElement(e, c.rate, &thisASC, &why);
        if (!au) {
            if (parseErrors++ < 3) CHECK(NO, "LATM parse failed: %s", why.UTF8String);
            continue;
        }
        if (!asc) asc = thisASC;
        if (!firstHeader) firstHeader = [e subdataWithRange:NSMakeRange(0, 9)];
        [aus addObject:au];
        auBytes += au.length;
        elementBytes += e.length;
        maxAU = MAX(maxAU, au.length);
        minAU = MIN(minAU, au.length);
        maxElement = MAX(maxElement, e.length);
    }
    CHECK(parseErrors == 0, "%zu elements failed to parse", parseErrors);
    if (!aus.count) return;
    double auSeconds = aus.count * 1024.0 / c.rate;
    double auKbps = auBytes * 8.0 / auSeconds / 1000, elementKbps = elementBytes * 8.0 / auSeconds / 1000;
    printf("  %zu elements (%zu calls, %zu with no output, %zu with more than 1); header %s\n", elements.count, calls, zeroCalls, multiCalls,
           firstHeader.description.UTF8String);
    printf("  Bitrate: AU %.1f kbps, with LATM header %.1f kbps; AU min/avg/max %zu/%.0f/%zu bytes; max element %zu bytes (peak/avg %.2f)\n",
           auKbps, elementKbps, minAU, (double)auBytes / aus.count, maxAU, maxElement, maxAU / ((double)auBytes / aus.count));
    printf("  Encode time: %.2f ms per second of audio (%.0fx real time)\n", encodeSec * 1000 / seconds, seconds / encodeSec);

    // Header byte-identical to FDK (AOSP/PipeWire): 47 FC 00 00 B0 xx 80 03 00
    uint8_t expected[9] = {0x47, 0xFC, 0x00, 0x00, 0xB0, c.rate == 44100 ? 0x90 : 0x8C, 0x80, 0x03, 0x00};
    if (c.rate == 44100 || c.rate == 48000) CHECK([firstHeader isEqualToData:[NSData dataWithBytes:expected length:9]], "element header differs from FDK");
    CHECK(elements.count >= calls - 3 && elements.count <= calls, "each call should produce about one AU");
    if (c.vbr) {
        size_t cap = (size_t)floor(bitrate * 1024.0 / c.rate / 8);
        CHECK(enc.maxElementBytes <= cap, "maxElementBytes %zu > peak %zu", enc.maxElementBytes, cap);
        CHECK(maxElement <= enc.maxElementBytes, "max element %zu > limit %zu", maxElement, enc.maxElementBytes);
        CHECK(elementKbps <= bitrate / 1000.0, "VBR average bitrate exceeds the peak");
        if (c.mtu) CHECK(maxElement + kAACMediaHeaderBytes <= c.mtu, "packet %zu exceeds MTU %zu", maxElement + kAACMediaHeaderBytes, c.mtu);
    } else {
        CHECK(fabs(auKbps * 1000 / enc.bitrate - 1) < 0.02, "CBR bitrate deviation: %.1f vs %d", auKbps, enc.bitrate);
    }

    CheckWithSystemParser(elements, aus, c.rate);

    // Decode, align, SNR
    size_t decFrames = 0;
    NSString *why = nil;
    float *dec = Decode(aus, asc, c.rate, &decFrames, &why);
    CHECK(dec != NULL, "%s", why.UTF8String);
    if (dec && c.signal != SignalTransients) {
        // a pure sine has one solution per period, so use the delay reported by the encoder directly (the noisy cases have verified the two agree)
        size_t delay = c.signal == SignalPureTones ? enc.primingFrames : FindDelay(ref, dec, frames, decFrames, 4096, c.rate);
        CHECK(delay == enc.primingFrames, "alignment delay %zu ≠ primingFrames %u", delay, enc.primingFrames);
        size_t start = (size_t)(c.rate / 2), end = frames - (size_t)(c.rate / 2);
        CHECK(end + delay <= decFrames, "not enough decoded samples: %zu", decFrames);
        double snr[2];
        for (int ch = 0; ch < 2; ch++) {
            double s = 0, e = 0;
            for (size_t i = start; i < end && i + delay < decFrames; i++) {
                double x = ref[2 * i + ch], y = dec[2 * (i + delay) + ch];
                s += x * x;
                e += (x - y) * (x - y);
            }
            snr[ch] = 10 * log10(s / fmax(e, 1e-20));
        }
        printf("  Decode: %zu frames, delay %zu, SNR left %.1f dB, right %.1f dB\n", decFrames, delay, snr[0], snr[1]);
        CHECK(snr[0] >= c.minSNR && snr[1] >= c.minSNR, "SNR below %.0f dB", c.minSNR);
    } else if (dec) {
        printf("  Decode: %zu frames (transient signal, only AU sizes are checked)\n", decFrames);
    }
    free(dec);
    free(ref);
    free(pcm24);
}

// Change bitrate while streaming (used by adaptive bitrate): switch tier every 2.5 seconds; each segment's element sizes follow the new bitrate (VBR stays under the new limit, CBR average bitrate stays close to the new value),
// decoding is continuous throughout, the alignment delay is unchanged, SNR passes
static void RunSwitchCase(const char *name, double rate, BOOL vbr, const int *bitrates, int count, double minSNR) {
    const double segmentSeconds = 2.5;
    size_t segmentCalls = (size_t)(rate * segmentSeconds) / 1024;
    size_t frames = segmentCalls * (size_t)count * 1024;
    printf("\n== %s: %.1f kHz %s, bitrate changes every %.1f seconds\n", name, rate / 1000, vbr ? "VBR peak" : "CBR", segmentSeconds);
    NSString *err = nil;
    AACEncoder *enc = [[AACEncoder alloc] initWithSampleRate:rate bitrate:bitrates[0] vbr:vbr error:&err];
    CHECK(enc != nil, "init failed: %s", err.UTF8String);
    if (!enc) return;
    float *ref = MakeSignal(SignalTones, rate, frames);
    size_t tailCalls = 4;
    uint8_t *pcm24 = calloc((frames + tailCalls * 1024) * 6, 1);
    ToPCM24(ref, pcm24, frames * 2);
    NSMutableArray<NSData *> *aus = [NSMutableArray array];
    NSData *asc = nil;
    for (int seg = 0; seg < count; seg++) {
        if (seg > 0) CHECK([enc setBitrate:bitrates[seg] error:&err], "setting bitrate %d failed: %s", bitrates[seg], err.UTF8String);
        size_t bytes = 0, maxElement = 0, elements = 0;
        size_t calls = segmentCalls + (seg == count - 1 ? tailCalls : 0);
        for (size_t k = 0; k < calls; k++) {
            NSArray<NSData *> *out = [enc encodePCM24:pcm24 + ((size_t)seg * segmentCalls + k) * 1024 * 6 error:&err];
            if (!out) { CHECK(NO, "encode failed: %s", err.UTF8String); break; }
            for (NSData *e in out) {
                NSString *why = nil;
                NSData *thisASC = nil;
                NSData *au = ParseElement(e, rate, &thisASC, &why);
                CHECK(au != nil, "LATM parse failed: %s", why.UTF8String);
                if (!au) continue;
                if (!asc) asc = thisASC;
                [aus addObject:au];
                // the encoder has about 2 frames of delay; the first two elements of a segment are still encoded at the old bitrate and are not counted for it
                if (k < 2) continue;
                bytes += e.length;
                maxElement = MAX(maxElement, e.length);
                elements++;
            }
        }
        double kbps = elements ? bytes * 8.0 * rate / 1024 / elements / 1000 : 0;
        printf("  Segment %d: requested %d, actual %d, average %.1f kbps, max element %zu bytes (limit %zu)\n", seg, bitrates[seg], enc.bitrate, kbps, maxElement,
               enc.maxElementBytes);
        if (vbr) CHECK(maxElement <= enc.maxElementBytes, "segment %d max element %zu > limit %zu", seg, maxElement, enc.maxElementBytes);
        else CHECK(fabs(kbps * 1000 / enc.bitrate - 1) < 0.05, "segment %d CBR bitrate deviation: %.1f vs %d", seg, kbps, enc.bitrate);
    }
    size_t decFrames = 0;
    NSString *why = nil;
    float *dec = Decode(aus, asc, rate, &decFrames, &why);
    CHECK(dec != NULL, "%s", why.UTF8String);
    if (dec) {
        size_t delay = FindDelay(ref, dec, frames, decFrames, 4096, rate);
        CHECK(delay == enc.primingFrames, "alignment delay %zu ≠ primingFrames %u", delay, enc.primingFrames);
        size_t start = (size_t)(rate / 2), end = frames - (size_t)(rate / 2);
        double s = 0, e = 0;
        for (size_t i = start; i < end && i + delay < decFrames; i++) {
            for (int ch = 0; ch < 2; ch++) {
                double x = ref[2 * i + ch], y = dec[2 * (i + delay) + ch];
                s += x * x;
                e += (x - y) * (x - y);
            }
        }
        double snr = 10 * log10(s / fmax(e, 1e-20));
        printf("  Decode: %zu frames, delay %zu, whole-run SNR %.1f dB\n", decFrames, delay, snr);
        CHECK(snr >= minSNR, "whole-run SNR %.1f below %.0f dB", snr, minSNR);
    }
    free(dec);
    free(ref);
    free(pcm24);
}

int main(void) {
    @autoreleasepool {
        Case cases[] = {
            {"CBR 256k", 44100, 256000, NO, SignalTones, 0, 18},
            {"CBR 320k", 44100, 320000, NO, SignalTones, 0, 20},
            {"VBR peak 320k", 44100, 320000, YES, SignalTones, 0, 20},
            {"CBR 256k", 48000, 256000, NO, SignalTones, 0, 18},
            {"CBR 320k", 48000, 320000, NO, SignalTones, 0, 20},
            {"VBR peak 320k", 48000, 320000, YES, SignalTones, 0, 20},
            {"VBR capped by MTU 895", 44100, 0, YES, SignalTones, 895, 18},
            {"VBR capped by MTU 679", 48000, 0, YES, SignalTones, 679, 18},
            {"Pure sine CBR 256k", 44100, 256000, NO, SignalPureTones, 0, 40},
            {"Pure sine VBR peak 320k", 48000, 320000, YES, SignalPureTones, 0, 40},
            {"Transient CBR 320k", 44100, 320000, NO, SignalTransients, 0, 0},
            {"Transient CBR 256k", 48000, 256000, NO, SignalTransients, 0, 0},
            {"Transient VBR capped by MTU 895", 44100, 0, YES, SignalTransients, 895, 0},
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) RunCase(cases[i]);
        static const int ladder[] = {320000, 256000, 192000, 128000, 256000};
        RunSwitchCase("VBR bitrate change while streaming", 48000, YES, ladder, 5, 15);
        RunSwitchCase("CBR bitrate change while streaming", 44100, NO, ladder, 5, 15);

        printf("\n== Parameter checks\n");
        NSString *err = nil;
        CHECK([[AACEncoder alloc] initWithSampleRate:12345 bitrate:256000 vbr:NO error:&err] == nil && err.length, "invalid sample rate should fail");
        printf("  Invalid sample rate: %s\n", err.UTF8String);
        AACEncoder *clamped = [[AACEncoder alloc] initWithSampleRate:48000 bitrate:500000 vbr:NO error:&err];
        CHECK(clamped && clamped.bitrate == 320000, "CBR 500k should be clamped to 320k, got %d", clamped.bitrate);
        uint8_t info[6] = {kAACObjectMPEG2LC, kAACFreq1_44100, kAACFreq2_48000 | kAACChannels2, kAACVBR | 0x04, 0xE2, 0x00};
        CHECK(AACInfoBitrate(info) == 320000, "AACInfoBitrate = %d", AACInfoBitrate(info));
        CHECK(AACMaxBitrateForMTU(895, 44100) == 304221, "AACMaxBitrateForMTU(895, 44.1k) = %d", AACMaxBitrateForMTU(895, 44100));   // 8×883×44100/1024

        printf("\n%s (%d failed)\n", gFailures ? "FAILED" : "ALL PASSED", gFailures);
        return gFailures ? 1 : 0;
    }
}
