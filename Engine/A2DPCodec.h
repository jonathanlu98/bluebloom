// A2DPCodec: common interface for A2DP codecs. One subclass per codec (built-in SBC, AAC, aptX, aptX HD, LDAC; codec plugins can
// also be linked in), responsible for: recognizing the codec information element declared by a headphone endpoint, listing the
// sample rates it supports, building the configuration for SET_CONFIGURATION from the sample rate and user options, and creating
// the encoder once the media channel is open (MTU known). The encoder turns PCM into complete media packets that can be written
// straight to the media channel (including the RTP header when needed).
// Plugin model: each codec registers in its own +load and declares its own vendor, default priority, bitrate tiers, etc.; the
// rest of the engine, the app and the CLI know codecs only through these declarations and hard-code none of them.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSString *CodecID NS_TYPED_EXTENSIBLE_ENUM;
extern CodecID const CodecIDSBC NS_SWIFT_NAME(sbc);           // @"sbc"
extern CodecID const CodecIDAAC NS_SWIFT_NAME(aac);           // @"aac"
extern CodecID const CodecIDAptX NS_SWIFT_NAME(aptX);          // @"aptx"
extern CodecID const CodecIDAptXHD NS_SWIFT_NAME(aptXHD);        // @"aptx-hd"
extern CodecID const CodecIDLDAC NS_SWIFT_NAME(ldac);          // @"ldac"

// Bitrate tier: declared by the codec itself; the Settings page, menu and CLI list tiers from it. Adaptive tiers move between minimumKbps and the cap according to the link
@interface CodecPreset : NSObject
@property (nonatomic, readonly) NSInteger identifier;  // Stored in settings; unique within a codec and stable across versions
@property (nonatomic, readonly, getter=isAdaptive) BOOL adaptive;
@property (nonatomic, readonly) double kbps;           // Nominal bitrate for the 48k family (the cap for adaptive tiers)
@property (nonatomic, readonly) double kbps44;         // Nominal bitrate for the 44.1k family
@property (nonatomic, readonly) double minimumKbps;    // Floor for adaptive tiers; same as kbps for fixed tiers
+ (instancetype)presetWithID:(NSInteger)identifier kbps:(double)kbps kbps44:(double)kbps44;
+ (instancetype)adaptivePresetWithID:(NSInteger)identifier kbps:(double)kbps kbps44:(double)kbps44 minimumKbps:(double)minimumKbps;
// Nominal bitrate at a sample rate; rate 0 means the 48k family
- (double)kbpsAtSampleRate:(double)rate NS_SWIFT_NAME(kbps(atSampleRate:));
@end

// User options (app settings), passed in at the start of each session
@interface CodecOptions : NSObject <NSCopying>
// Codec priority, highest first; codecs not in the list are not used. Defaults to each codec's declared rank
@property (nonatomic, copy) NSArray<CodecID> *priority;
// Codec chosen by the user for this device; used first when the headphones support it, nil means auto
@property (nonatomic, copy, nullable) CodecID preferredCodec;
// Bitrate tier chosen per codec (CodecPreset identifier); codecs without a choice use their defaultPresetID
@property (nonatomic, copy) NSDictionary<CodecID, NSNumber *> *presets;
// Highest bitrate (kbps) per codec these headphones can take, found at runtime (see A2DPEncoder mediaStalled), stored per device and passed back; codecs without an entry follow the spec
@property (nonatomic, copy) NSDictionary<CodecID, NSNumber *> *maxKbps;
// AAC target bitrate (bit/s); 0 means auto: at most 320k and one frame fits in one media packet
@property (nonatomic) NSInteger aacBitrate;
// AAC uses per-frame capped variable bitrate (default YES; the headphones must support it); NO means constant bitrate
@property (nonatomic) BOOL aacVBR;
// SBC uses dual channel with a high bitpool (known as SBC XQ, about 450–550 kbps); falls back to high-quality joint stereo when the headphones do not support dual channel
@property (nonatomic) BOOL sbcXQ;
// SBC and AAC automatically lower the bitrate when the link is congested and raise it again later (BitrateAdapter, default YES); the maximum still follows the settings above
@property (nonatomic) BOOL sbcAdaptive;
@property (nonatomic) BOOL aacAdaptive;
// Maximum sample rate (Hz); 0 means no limit
@property (nonatomic) double maxSampleRate;
+ (NSArray<CodecID> *)defaultPriority;
@end

// Chosen configuration: the codec information element for SET_CONFIGURATION and the matching stream parameters
@interface CodecConfiguration : NSObject
@property (nonatomic, readonly) CodecID codec;
@property (nonatomic, readonly) NSData *element;      // Starts at the media type byte
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) int bitsPerSample;    // Effective bit depth of the codec (for display); 0 means not applicable (AAC)
@property (nonatomic, readonly) double nominalKbps;   // Nominal bitrate (for display; varies with adaptive bitrate and AAC VBR)
@property (nonatomic, readonly) NSString *summary;    // Short description for logs
// Codec-private parameters (e.g. SBC bitpool), interpreted by each subclass
@property (nonatomic, readonly, nullable) NSDictionary *parameters;
- (instancetype)initWithCodec:(CodecID)codec element:(NSData *)element sampleRate:(double)rate bitsPerSample:(int)bits
                   nominalKbps:(double)kbps summary:(NSString *)summary parameters:(nullable NSDictionary *)parameters;
@end

// One codec declared by the headphones (one Sink endpoint), for UI display and caching. When read from the cache it is re-recognized against the current registry (a codec plugin takes effect as soon as it is built in)
@interface RemoteCodec : NSObject <NSSecureCoding>
@property (nonatomic, readonly, nullable) CodecID codec;  // Implemented codec; nil if not implemented
@property (nonatomic, readonly) NSString *name;         // Display name; the codec ID for unimplemented codecs (e.g. D7/AD)
@property (nonatomic, readonly) NSArray<NSNumber *> *sampleRates;  // Sample rates we can stream
@property (nonatomic, readonly) NSData *element;
- (instancetype)initWithCodec:(nullable CodecID)codec name:(NSString *)name sampleRates:(NSArray<NSNumber *> *)rates element:(NSData *)element;
@end

// Encoder: takes framesPerCall frames of PCM per call and returns zero or more complete media packets. Called only on the streaming thread
@protocol A2DPEncoder <NSObject>
@property (nonatomic, readonly) size_t framesPerCall;
// Current target bitrate (kbps); changes with adaptive bitrate
@property (nonatomic, readonly) double bitrateKbps;
// pcm: framesPerCall frames of 24-bit little-endian interleaved stereo (6 bytes per frame). Returns nil with a reason on error
- (nullable NSArray<NSData *> *)encode:(const uint8_t *)pcm error:(NSString *_Nullable *_Nullable)error;
@optional
// Before each encode the streamer reports how many packets are still queued and not yet written to the media channel (for adaptive bitrate)
- (void)reportQueueDepth:(NSUInteger)depth;
// RTP sequence number and timestamp of the next packet. When the encoder is replaced while streaming (MediaStreamer replaceEncoderWith:) the new encoder continues counting from the old one, so the headphones do not see packet loss or reordering
@property (nonatomic) uint16_t rtpSequence;
@property (nonatomic) uint32_t rtpTimestamp;
// Called on the streaming queue when the media channel cannot take data for several seconds (headphones stopped receiving). If the encoder decides the headphones cannot take the current bitrate, return the highest bitrate (kbps) to use from now on,
// otherwise return 0 (e.g. for some codecs the frame length varies with bitrate and the headphones cannot take overly long frames)
- (double)mediaStalled;
// When only codec parameters change while streaming (configuration bytes unchanged), first ask the encoder whether it can switch in place: YES means no new encoder is needed (for some codecs a new encoder resets the encoding state)
- (BOOL)applyConfiguration:(CodecConfiguration *)configuration;
@end

@interface A2DPCodec : NSObject
@property (nonatomic, readonly) CodecID identifier;
@property (nonatomic, readonly) NSString *displayName;
// Codec registration: each codec (including plugins) calls this in its own +load (+load is not inherited; subclasses must write their own)
+ (void)registerCodecClass:(Class)codecClass;
// All registered codecs, sorted by rank ascending
+ (NSArray<A2DPCodec *> *)allCodecs;
+ (nullable A2DPCodec *)codecWithID:(CodecID)identifier NS_SWIFT_NAME(codec(id:));
// Recognize which implemented codec a codec information element belongs to (the media codec service category content, starting at the media type byte)
+ (nullable A2DPCodec *)codecForElement:(NSData *)element NS_SWIFT_NAME(codec(element:));
// For logs: describe any codec information element (including unimplemented vendor codecs)
+ (NSString *)describeElement:(NSData *)element;
// Display name of a codec information element: implemented codecs use their own name, others the codec ID (hex; vendor codecs e.g. D7/AD)
+ (NSString *)nameForElement:(NSData *)element;
+ (RemoteCodec *)remoteCodecForElement:(NSData *)element;

// Declared by subclasses (the UI, settings and CLI look only at these)
@property (nonatomic, readonly) NSString *vendorName;  // Company or organization the codec belongs to
@property (nonatomic, readonly) NSInteger rank;        // Default priority, lower first
// Clearly better than the AAC built into macOS: auto mode takes over when the headphones support it
@property (nonatomic, readonly, getter=isPremium) BOOL premium;
// Selectable bitrate tiers (adaptive tiers first, the rest from high to low); empty means no tiers (constant bitrate, or separate settings as with AAC and SBC)
@property (nonatomic, readonly) NSArray<CodecPreset *> *presets;
@property (nonatomic, readonly) NSInteger defaultPresetID;
// About page credits: encoder origin, authors and license (English, shown as is, no trademarks); codecs with the same origin are merged into one line
@property (nonatomic, readonly, nullable) NSString *credit;
// Trademark notice for the codec name (English), placed in the notice at the bottom of the About page; each sentence is listed once
@property (nonatomic, readonly, nullable) NSString *trademark;
// Upstream project link attached to the credit line (project homepage, not a pinned commit; see third-party notices for exact versions); none for system-provided or private codecs
@property (nonatomic, readonly, nullable) NSURL *creditURL;
// Start and end colors of the badge gradient (0xRRGGBB)
@property (nonatomic, readonly) NSArray<NSNumber *> *badgeColors;
// Codec information element declaring all of our capabilities (starting at the media type byte): the UI lists sample rates and bit depths from it, and the CLI codectest runs through it offline
@property (nonatomic, readonly) NSData *fullCapabilityElement;
- (nullable CodecPreset *)presetWithID:(NSInteger)identifier;
// Bitrate tier chosen for this codec in options (the default tier if none chosen or it no longer exists); nil for codecs without tiers
- (nullable CodecPreset *)presetForOptions:(CodecOptions *)options;

// Implemented by subclasses
- (BOOL)matchesElement:(NSData *)element;
// Sample rates declared in the capability element that we can stream (ascending)
- (NSArray<NSNumber *> *)sampleRatesInCapability:(NSData *)element;
// Build a configuration for a sample rate; nil when the headphone capabilities do not allow it
- (nullable CodecConfiguration *)configurationForCapability:(NSData *)element sampleRate:(double)rate options:(CodecOptions *)options;
// Called before configuring the headphones: whether the encoder itself can be opened (e.g. a codec library that needs initialization); default YES
- (BOOL)prepareWithError:(NSString *_Nullable *_Nullable)error;
// Create the encoder after the media channel is open; outMTU is the media channel's outgoing MTU
- (nullable id<A2DPEncoder>)encoderForConfiguration:(CodecConfiguration *)configuration outMTU:(uint16_t)outMTU
                                             options:(CodecOptions *)options error:(NSString *_Nullable *_Nullable)error;
@end

// RTP header (RFC 3550, 12 bytes, network byte order): V=2, no padding/extension/CSRC
static const size_t kRTPHeaderBytes = 12;
static const uint8_t kRTPPayloadType = 96;
void A2DPWriteRTPHeader(uint8_t *p, uint16_t sequence, uint32_t timestamp, uint32_t ssrc, BOOL marker);

// Pick a sample rate: use desired if it is in rates; otherwise, within the same family (44.1/88.2 or 48/96), the highest rate not above desired,
// or failing that the lowest rate above it; when strict, do not cross families (return 0), otherwise when crossing families prefer 48k, then the highest
double A2DPBestSampleRate(NSArray<NSNumber *> *rates, double desired, BOOL strict);

// Helpers for codec information elements
uint32_t A2DPReadLE32(const uint8_t *p);
uint16_t A2DPReadLE16(const uint8_t *p);
// Vendor codec element: [media type, 0xFF, vendor ID(4, little-endian), codec ID(2, little-endian), ...]
BOOL A2DPIsVendorElement(NSData *element, uint32_t vendor, uint16_t codec, size_t minimumLength);

NS_ASSUME_NONNULL_END
