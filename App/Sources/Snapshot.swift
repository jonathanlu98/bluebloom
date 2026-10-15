// Snapshot mode (for development): `BlueBloom --snapshot <directory>` renders the menu panel and each Settings pane to PNG from mock data, then quits, without touching Bluetooth or audio devices.
// Switch languages with arguments like -AppleLanguages "(zh-Hans)"; one image per appearance (light, dark).
// With `--stress`: headphone and output device names are replaced with very long ones and file names get -stress, for checking truncation (tools/ui/check-truncation.sh).
// Demo mode (for development): `BlueBloom --demo` also uses mock data and doesn't touch Bluetooth, but stays in the menu bar and switches state every 4 seconds,
// to see the layout of the real menu bar popover as its content changes (snapshot mode can't render the popover's own behavior).
// With `--demo-window`: stays in the streaming state and also puts the panel in a regular window (titled Blue Bloom Demo), so the accessibility API can click menus and read checkmarks to verify interaction.
// `--demo-appearance light|dark` fixes the demo window's appearance regardless of the system setting (used for the README screenshot).
// Both modes write settings to a separate domain and never persist device records, so the release app is unaffected.
import AppKit
import BlueBloomEngine
import SwiftUI

enum Snapshot {
    static let directory: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()

    static let demo = CommandLine.arguments.contains("--demo")

    static var isActive: Bool { directory != nil || demo }
    @MainActor private static var demoWindow: NSWindow?

    @MainActor
    static func run(model: AppModel) {
        if demo {
            runDemo(model: model)
            return
        }
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The snapshot settings domain is cleared every run: treat the first-run notice as accepted except in the "first use" scene, so every menu image doesn't carry that item
        model.settings.acceptedNotice = WelcomeView.noticeVersion
        let stress = CommandLine.arguments.contains("--stress")
        let language = (Bundle.main.preferredLocalizations.first ?? "en") + (stress ? "-stress" : "")
        // Stress data: long names seen in practice (with a "- Find My" suffix, numbered only at the end) and longer ones
        let names = stress ? ["Alexander的Focal Bathys 无线降噪耳机 - 客厅", "Sony WH-1000XM5 Wireless Noise Canceling Headphones",
                              "Alexander的AirPods Pro #2 - Find My"]
                           : ["Focal Bathys", "WH-1000XM5", "AirPods Pro"]
        let output = stress ? "MacBook Pro 扬声器（外接显示器 LG UltraFine 5K）" : "MacBook Pro Speakers"
        let devices = [
            BluetoothDevice(address: "aa-bb-cc-dd-ee-01", name: names[0], isConnected: true, minorClass: 6,
                            battery: BatteryLevels(main: 100)),
            BluetoothDevice(address: "a0-12-34-56-78-9a", name: names[1], isConnected: false, minorClass: 6),
            BluetoothDevice(address: "b0-12-34-56-78-9b", name: names[2], isConnected: true, minorClass: 1,
                            battery: BatteryLevels(left: 80, right: 75, caseLevel: 40)),
        ]
        func remote(_ ids: [CodecID]) -> [RemoteCodec] {
            ids.map { RemoteCodec(codec: $0, name: CodecInfo.of($0).name, sampleRates: [44100, 48000], element: Data()) }
        }
        var records: [String: DeviceRecord] = [:]
        // Include a codec not implemented here (shown as its codec ID)
        let unsupported = RemoteCodec(codec: nil, name: "D7/AD", sampleRates: [], element: Data())
        records[devices[0].address] = DeviceRecord(mode: .automatic, preferredCodec: nil, codecs: remote([.aptXHD, .aptX, .aac, .sbc]) + [unsupported])
        records[devices[1].address] = DeviceRecord(mode: .automatic, preferredCodec: .ldac, codecs: remote([.ldac, .aac, .sbc]))
        records[devices[2].address] = DeviceRecord(mode: .system, preferredCodec: nil, codecs: remote([.aac, .sbc]))
        model.devices.loadPreview(devices: devices, records: records)
        let history: [Double] = (0..<60).map { (i: Int) -> Double in
            let wave: Double = 60 * sin(Double(i) / 4)
            let jitter: Double = Double(i % 7) * 6
            return 900 + wave + jitter
        }

        // Scene 1: streaming LDAC at 96k
        model.settings.activeDevice = devices[1].address
        let ldac = CodecConfiguration(codec: .ldac, element: Data(), sampleRate: 96_000, bitsPerSample: 24, nominalKbps: 990,
                                      summary: "", parameters: nil)
        model.loadPreview(status: .streaming, configuration: ldac, battery: 80, history: history, driver: .current)
        render(MenuContentView(), model: model, name: "\(language)-menu-ldac", directory: directory)

        // Scene 2: aptX, the higher codec unused because of the sample rate
        model.settings.activeDevice = devices[0].address
        let aptx = CodecConfiguration(codec: .aptX, element: Data(), sampleRate: 44_100, bitsPerSample: 16, nominalKbps: 352.8,
                                      summary: "", parameters: nil)
        model.loadPreview(status: .streaming, configuration: aptx, battery: 35, history: history.map { $0 * 0.39 }, driver: .current,
                          fallback: (.aptXHD, .unsupportedRate), remoteControlBlocked: true)
        render(MenuContentView(), model: model, name: "\(language)-menu-aptx", directory: directory)

        // Scene 3: first use; first-run notice not accepted, driver not installed, no headphones chosen
        model.settings.activeDevice = nil
        model.settings.acceptedNotice = 0
        model.loadPreview(status: .stopped, configuration: nil, battery: -1, history: [], driver: .missing, output: output)
        render(MenuContentView(), model: model, name: "\(language)-menu-setup", directory: directory)
        render(WelcomeView(), model: model, name: "\(language)-welcome", directory: directory, width: 500, height: 520)
        model.settings.acceptedNotice = WelcomeView.noticeVersion

        // Scene 4: AirPods left to macOS, battery from the system (left earbud, right earbud, charging case)
        model.settings.activeDevice = devices[2].address
        model.loadPreview(status: .system, configuration: nil, battery: -1, history: [], driver: .current)
        render(MenuContentView(), model: model, name: "\(language)-menu-system", directory: directory)

        // Scene 5: headphones not answering (powered off or connected to another device)
        model.settings.activeDevice = devices[1].address
        model.loadPreview(status: .waitingHeadset, configuration: nil, battery: -1, history: [], driver: .current)
        render(MenuContentView(), model: model, name: "\(language)-menu-waiting", directory: directory)

        // Scene 6: headphones busy with a phone, retry in 20 seconds
        model.loadPreview(status: .busy, configuration: nil, battery: -1, history: [], driver: .current, retryIn: 20)
        render(MenuContentView(), model: model, name: "\(language)-menu-busy", directory: directory)

        // Settings panes
        model.settings.activeDevice = devices[0].address
        model.loadPreview(status: .streaming, configuration: aptx, battery: 35, history: history, driver: .current)
        // Settings panes are scrolling Forms: only rows in the visible area are built, and window height is limited to the screen, so no height captures it all (the AAC and SBC sections were once missed),
        // so capture screen by screen while scrolling; from the second screen on, file names get -p2, -p3…
        render(GeneralPane(), model: model, name: "\(language)-settings-general", directory: directory, width: 560, height: 700, pages: true)
        render(CodecsPane(), model: model, name: "\(language)-settings-codecs", directory: directory, width: 560, height: 700, pages: true)
        render(AudioPane(), model: model, name: "\(language)-settings-audio", directory: directory, width: 560, height: 700, pages: true)
        render(DevicesPane(), model: model, name: "\(language)-settings-devices", directory: directory, width: 560, height: 700, pages: true)
        render(AdvancedPane(), model: model, name: "\(language)-settings-advanced", directory: directory, width: 560, height: 700, pages: true)
        // No height for the About pane: the Settings window sizes itself to its ideal height, so capture at the ideal height here too to get the same wrapping and truncation as the real window
        render(AboutPane(), model: model, name: "\(language)-settings-about", directory: directory, width: 560)
        render(NoticesSheet(), model: model, name: "\(language)-notices", directory: directory, width: 680, height: 520)
        // Sample contents of "Copy Diagnostics" on the About pane
        try? model.diagnostics.write(to: directory.appendingPathComponent("\(language)-diagnostics.txt"), atomically: true, encoding: .utf8)
        // Pairing window: found devices and the pairing status line
        let pairing = PairingModel()
        pairing.loadPreview(found: [
            .init(address: "00-1b-66-aa-bb-cc", name: names[1], isAudio: true, isPaired: false),
            .init(address: "f4-0e-01-12-34-56", name: names[2], isAudio: true, isPaired: true),
            .init(address: "7c-2a-31-98-76-54", name: stress ? "Living Room Smart Speaker with Alexa (Ultra Long Name Edition)" : "Living Room Speaker",
                  isAudio: false, isPaired: false),
        ], state: .pairing("00-1b-66-aa-bb-cc"))
        render(PairingView(pairing: pairing), model: model, name: "\(language)-pairing", directory: directory)
        exit(0)
    }

    @MainActor
    private static func runDemo(model: AppModel) {
        // As in snapshot mode, treat the first-run notice as accepted (demo mode doesn't hook up the first-run notice window)
        model.settings.acceptedNotice = WelcomeView.noticeVersion
        let devices = [
            BluetoothDevice(address: "aa-bb-cc-dd-ee-01", name: "Focal Bathys", isConnected: true, minorClass: 6,
                            battery: BatteryLevels(main: 100)),
            BluetoothDevice(address: "aa-bb-cc-dd-ee-02", name: "WH-1000XM4", isConnected: false, minorClass: 6),
            BluetoothDevice(address: "b0-12-34-56-78-9b", name: "Alexander’s AirPods Pro", isConnected: false, minorClass: 1),
        ]
        func remote(_ ids: [CodecID]) -> [RemoteCodec] {
            ids.map { RemoteCodec(codec: $0, name: CodecInfo.of($0).name, sampleRates: [44100, 48000], element: Data()) }
        }
        model.devices.loadPreview(devices: devices, records: [
            devices[0].address: DeviceRecord(mode: .automatic, preferredCodec: nil, codecs: remote([.aptXHD, .aptX, .aac, .sbc])),
            devices[1].address: DeviceRecord(mode: .automatic, preferredCodec: .ldac, codecs: remote([.ldac, .aac, .sbc])),
        ])
        model.settings.activeDevice = devices[1].address
        let ldac = CodecConfiguration(codec: .ldac, element: Data(), sampleRate: 96_000, bitsPerSample: 24, nominalKbps: 990,
                                      summary: "", parameters: nil)
        let history = (0..<60).map { 900 + 60 * sin(Double($0) / 4) }
        let steps: [(String, () -> Void)] = [
            ("connecting", { model.loadPreview(status: .connecting, configuration: nil, battery: -1, history: [], driver: .current) }),
            ("waiting", { model.loadPreview(status: .waitingHeadset, configuration: nil, battery: -1, history: [], driver: .current) }),
            ("streaming", { model.loadPreview(status: .streaming, configuration: ldac, battery: 60, history: history, driver: .current) }),
            ("busy", { model.loadPreview(status: .busy, configuration: nil, battery: -1, history: [], driver: .current, retryIn: 20) }),
        ]
        var index = 0
        func apply() {
            steps[index].1()
            print("demo \(Date().timeIntervalSince1970) \(steps[index].0)")
            fflush(stdout)
        }
        if CommandLine.arguments.contains("--demo-window") {
            // --demo-codec <codec ID> (e.g. aac, sbc): stream with this codec instead (to verify each codec's bitrate menu); LDAC by default
            let arguments = CommandLine.arguments
            if let i = arguments.firstIndex(of: "--demo-codec"), i + 1 < arguments.count {
                let codec = CodecID(rawValue: arguments[i + 1])
                let configuration = CodecConfiguration(codec: codec, element: Data(), sampleRate: 48_000, bitsPerSample: codec == .aac ? 0 : 16,
                                                       nominalKbps: 320, summary: "", parameters: nil)
                model.devices.loadPreview(devices: devices, records: [
                    devices[1].address: DeviceRecord(mode: .automatic, preferredCodec: nil, codecs: remote([codec, .aac, .sbc])),
                ])
                model.loadPreview(status: .streaming, configuration: configuration, battery: 60, history: history, driver: .current)
            } else {
                index = 2
                apply()
            }
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 348, height: 600), styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Blue Bloom Demo"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MenuContentView().environment(model))
            if let i = CommandLine.arguments.firstIndex(of: "--demo-appearance"), i + 1 < CommandLine.arguments.count {
                window.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "dark" ? .darkAqua : .aqua)
            }
            window.makeKeyAndOrderFront(nil)
            // Like the real menu bar panel, start with nothing focused (otherwise the first device row shows a focus ring)
            window.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            demoWindow = window
            return
        }
        apply()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            MainActor.assumeIsolated {
                index = (index + 1) % steps.count
                apply()
            }
        }
    }

    @MainActor
    private static func render<V: View>(_ view: V, model: AppModel, name: String, directory: URL, width: CGFloat? = nil,
                                        height: CGFloat? = nil, pages: Bool = false) {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let root = view
                .environment(model)
                .frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            hosting.appearance = NSAppearance(named: appearance)
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            func capture(_ fileName: String) {
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(fileName))
            }
            capture("\(name)-\(suffix).png")
            guard pages, let scroll = firstScrollView(in: hosting), let document = scroll.documentView else { continue }
            let visible = scroll.contentView.bounds.height
            var page = 2
            var offset = visible * 0.8
            while offset < document.frame.height - visible * 0.2, page <= 6 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset, document.frame.height - visible)))
                scroll.reflectScrolledClipView(scroll.contentView)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                capture("\(name)-p\(page)-\(suffix).png")
                offset += visible * 0.8
                page += 1
            }
        }
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
