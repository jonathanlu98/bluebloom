import BlueBloomEngine
import SwiftUI

// Settings › Advanced › Experiments: the switches of BBExperiments, for investigating dropouts. Hidden until the version
// in Settings › About is Option-clicked (or `defaults write app.bluebloom BBShowExperiments -bool true`).
// The text is English only on purpose (Text(verbatim:), so it stays out of the string catalog): the switches come and go
// with the investigation, are not product features, and their names match the log lines and the command-line flags
struct ExperimentsSections: View {
    @AppStorage(BBExperimentsVisibleKey) private var visible = false
    @AppStorage(BBExperimentKeepWarmKey) private var keepWarm = false
    @AppStorage(BBExperimentAvrcpKeepaliveKey) private var avrcpKeepalive = false
    @AppStorage(BBExperimentAvrcpKeepaliveSecondsKey) private var avrcpKeepaliveSeconds = BBExperimentAvrcpKeepaliveDefaultSeconds
    @AppStorage(BBExperimentLightWakeKey) private var lightWake = false
    @AppStorage(BBExperimentForceNewLinkKey) private var forceNewLink = false
    @AppStorage(BBExperimentForceNewLinkAfterSecondsKey) private var forceNewLinkAfterSeconds = BBExperimentForceNewLinkDefaultSeconds
    @AppStorage(BBExperimentSlowABRKey) private var slowABR = false
    @AppStorage(BBExperimentHighPriorityKey) private var highPriority = false
    @AppStorage(BBExperimentLogLinkStateKey) private var logLinkState = false

    var body: some View {
        Section {
            ExperimentToggle(title: "Keep the stream open",
                             detail: "Keeps sending silence instead of suspending the stream after 10 s without sound.",
                             isOn: $keepWarm)
            ExperimentToggle(title: "AVRCP keepalive",
                             detail: "Sends an AVRCP request at intervals while the stream is suspended.",
                             isOn: $avrcpKeepalive)
            if avrcpKeepalive {
                ExperimentSeconds(title: "Interval", value: $avrcpKeepaliveSeconds)
            }
            ExperimentToggle(title: "Light wake",
                             detail: "Sends an AVRCP request 0.3 s before START when sound comes back.",
                             isOn: $lightWake)
            ExperimentToggle(title: "New session after a long pause",
                             detail: "Disconnects and connects again instead of resuming the suspended stream.",
                             isOn: $forceNewLink)
            if forceNewLink {
                ExperimentSeconds(title: "For pauses of at least", value: $forceNewLinkAfterSeconds)
            }
        } header: {
            Text(verbatim: "Experiments: While Paused")
        }
        Section {
            ExperimentToggle(title: "Slow adaptive recovery",
                             detail: "Adaptive bitrate waits longer before trying a higher tier again. Applies to AAC and SBC.",
                             isOn: $slowABR)
            ExperimentToggle(title: "High-priority link",
                             detail: "Asks the Bluetooth controller to put the headphones ahead of scanning while streaming.",
                             isOn: $highPriority)
        } header: {
            Text(verbatim: "Experiments: While Streaming")
        }
        Section {
            ExperimentToggle(title: "Log more around resume",
                             detail: "Adds the pause length and the active experiments to the log each time the stream resumes.",
                             isOn: $logLinkState)
            HStack {
                // Read on every update of the switches above; also lists the test harness values set with `defaults write`
                Text(verbatim: "On: \(BBExperiments.shared.summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    BBExperiments.resetAll()
                } label: {
                    Text(verbatim: "Turn All Off")
                }
                .disabled(BBExperiments.shared.activeCount == 0)
                Button {
                    visible = false
                } label: {
                    Text(verbatim: "Hide")
                }
            }
        } header: {
            Text(verbatim: "Experiments: Log")
        } footer: {
            Text(verbatim: "For investigating dropouts. Off by default, and none of them has been shown to prevent dropouts. A change applies to the current stream within a second or at its next pause. Hide keeps the switches as they are; Option-click the version in About to show this again.")
        }
    }
}

// A switch with its name and one line on what it does
private struct ExperimentToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: title)
            Text(verbatim: detail)
        }
    }
}

// The interval that belongs to the switch above it, in seconds
private struct ExperimentSeconds: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(value: $value, format: .number.precision(.fractionLength(0))) { EmptyView() }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .onChange(of: value) { _, seconds in
                        // The engine falls back to the default below the minimum; show what it will really use
                        if seconds < BBExperimentMinimumSeconds { value = BBExperimentMinimumSeconds }
                    }
                Text(verbatim: "s").foregroundStyle(.secondary)
            }
        } label: {
            Text(verbatim: title).padding(.leading, 16)
        }
    }
}
