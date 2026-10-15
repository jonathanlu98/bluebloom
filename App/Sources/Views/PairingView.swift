// Add headphones: scan for nearby Bluetooth devices in pairing mode and pair them; once paired they can be made the current headphones directly.
import SwiftUI

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pairing: PairingModel

    // pairing is only passed to supply preview data in snapshot mode
    @MainActor
    init(pairing: PairingModel? = nil) {
        _pairing = State(initialValue: pairing ?? PairingModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BloomMark(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Headphones").font(.title3.weight(.semibold))
                    Text("Put your headphones in pairing mode, then choose them below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            GroupBox {
                VStack(spacing: 0) {
                    if pairing.found.isEmpty {
                        VStack(spacing: 8) {
                            if pairing.scanning {
                                ProgressView().controlSize(.small)
                                Text("Looking for nearby devices…").foregroundStyle(.secondary)
                            } else {
                                Image(systemName: "headphones").font(.title2).foregroundStyle(.tertiary)
                                Text("No devices found yet").foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(pairing.found) { device in
                                    row(device)
                                }
                            }
                            .padding(4)
                        }
                        .frame(minHeight: 160, maxHeight: 260)
                    }
                }
            }
            // Status on its own line, buttons on another: squeezed into one line, the French, German, Spanish and Japanese button titles were compressed to "Réglages Bluetoo…"
            if pairing.state != .idle {
                statusLine.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Bluetooth Settings…") { model.openBluetoothSettings() }
                    .fixedSize()
                Button(pairing.scanning ? "Stop" : "Scan Again") {
                    pairing.scanning ? pairing.stopScan() : pairing.startScan()
                }
                .fixedSize()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { pairing.startScan() }
        .onDisappear { pairing.stopScan() }
    }

    @ViewBuilder
    private func row(_ device: PairingModel.Found) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.isAudio ? "headphones" : "dot.radiowaves.left.and.right")
                .frame(width: 22)
                .foregroundStyle(device.isAudio ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1).truncationMode(.middle).help(Text(verbatim: device.name))
                Text(device.address).font(.caption).foregroundStyle(.tertiary).monospaced()
            }
            Spacer()
            if device.isPaired {
                Button("Use") {
                    model.devices.refresh()
                    if let paired = model.devices.device(device.address) { model.activate(paired) }
                    dismissWindow(id: "pairing")
                }
                .controlSize(.small)
            } else if pairing.state == .pairing(device.address) {
                ProgressView().controlSize(.small)
            } else {
                Button("Pair") { pairing.pair(device.address) }
                    .controlSize(.small)
                    .disabled({ if case .pairing = pairing.state { return true } else { return false } }())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private var statusLine: some View {
        switch pairing.state {
        case .pairing:
            Label("Pairing… confirm on your headphones if asked", systemImage: "link").labelStyle(.compact).font(.callout).foregroundStyle(.secondary)
        case .paired:
            Label("Paired", systemImage: "checkmark.circle.fill").labelStyle(.compact).font(.callout).foregroundStyle(.green)
        case .failed:
            Label("Pairing failed — is the device in pairing mode?", systemImage: "exclamationmark.triangle.fill").labelStyle(.compact)
                .font(.callout).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }
}
