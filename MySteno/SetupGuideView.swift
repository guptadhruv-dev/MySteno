import AVFoundation
import SwiftUI

enum SetupGuide {
    static let windowID = "setup-guide"
    static let completedKey = "hasCompletedSetupGuide"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }
}

struct SetupGuideView: View {
    private static let microphoneSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    )!
    private static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    @Environment(MyStenoModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(SetupGuide.completedKey) private var hasCompletedSetup = false
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var practiceText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            VStack(spacing: 0) {
                modelStep
                Divider().padding(.leading, 46)
                microphoneStep
                Divider().padding(.leading, 46)
                accessibilityStep
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            practiceSection

            footer
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { NSApp.activate() }
        .task { await watchPermissions() }
        .onDisappear {
            if isSetUp { hasCompletedSetup = true }
        }
    }

    private var isSetUp: Bool {
        model.isModelReady && microphoneStatus == .authorized && model.hotkey.accessibilityGranted
    }

    private var shortcut: String {
        model.hotkey.config.displayString
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to MySteno")
                    .font(.title2.weight(.semibold))
                Text("Press a shortcut, speak, and your words appear where you're typing. Your voice never leaves this Mac. MySteno lives in the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modelStep: some View {
        let selected = model.transcription.selectedModel
        let state = model.transcription.states[selected] ?? .notInstalled
        return SetupStepRow(
            title: "Speech model",
            detail: modelDetail(for: selected, state: state),
            status: modelStatus(for: state)
        ) {
            switch state {
            case .notInstalled:
                Button("Download") {
                    Task { await model.installModel(selected) }
                }
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 110)
            case .failed:
                Button("Retry") {
                    Task { await model.selectModel(selected) }
                }
            case .installed, .loading, .warming, .ready:
                EmptyView()
            }
        }
    }

    private func modelDetail(for selected: TranscriptionModel, state: ModelLifecycleState) -> String {
        switch state {
        case .notInstalled:
            "Download \(selected.displayName) once. After that, everything runs offline."
        case .downloading(let progress):
            "Downloading \(selected.displayName)… \(Int(progress * 100))%"
        case .installed, .loading, .warming:
            "Getting \(selected.displayName) ready…"
        case .ready:
            model.isModelReady
                ? "\(selected.displayName) is ready."
                : "Getting \(selected.displayName) ready…"
        case .failed(let message):
            message
        }
    }

    private func modelStatus(for state: ModelLifecycleState) -> SetupStepStatus {
        switch state {
        case .notInstalled: .needsAction
        case .downloading, .installed, .loading, .warming: .inProgress
        case .ready: model.isModelReady ? .done : .inProgress
        case .failed: .failed
        }
    }

    private var microphoneStep: some View {
        SetupStepRow(
            title: "Microphone",
            detail: microphoneDetail,
            status: microphoneStepStatus
        ) {
            switch microphoneStatus {
            case .notDetermined:
                Button("Allow…") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
            case .denied, .restricted:
                Button("Open Settings") {
                    NSWorkspace.shared.open(Self.microphoneSettingsURL)
                }
            case .authorized:
                EmptyView()
            @unknown default:
                EmptyView()
            }
        }
    }

    private var microphoneDetail: String {
        switch microphoneStatus {
        case .authorized:
            "MySteno listens only while you're recording."
        case .denied, .restricted:
            "Microphone access is off. Turn on MySteno in System Settings."
        default:
            "Needed to hear you while you dictate. MySteno listens only while you're recording."
        }
    }

    private var microphoneStepStatus: SetupStepStatus {
        switch microphoneStatus {
        case .authorized: .done
        case .denied, .restricted: .failed
        default: .needsAction
        }
    }

    private var accessibilityStep: some View {
        let granted = model.hotkey.accessibilityGranted
        return SetupStepRow(
            title: "Accessibility",
            detail: granted
                ? "\(shortcut) works in every app, and MySteno can paste for you."
                : "Lets \(shortcut) work in every app and paste your words where you're typing.",
            status: granted ? .done : .needsAction
        ) {
            if !granted {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Allow…") {
                        model.hotkey.requestAccessibility()
                    }
                    Button("Open Settings") {
                        NSWorkspace.shared.open(Self.accessibilitySettingsURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try it")
                .font(.headline)
            Text(isSetUp
                ? "Click in the box, press \(shortcut), say a sentence, then press \(shortcut) again."
                : "Available once the steps above are done.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $practiceText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 96)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .disabled(!isSetUp)
                .opacity(isSetUp ? 1 : 0.5)
        }
    }

    private var footer: some View {
        HStack {
            if !isSetUp {
                Text("You can finish later with Setup Guide in the MySteno menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
                hasCompletedSetup = true
                dismissWindow(id: SetupGuide.windowID)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
    }

    private func watchPermissions() async {
        while !Task.isCancelled {
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if !model.hotkey.accessibilityGranted {
                model.hotkey.refresh()
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

private enum SetupStepStatus {
    case done
    case inProgress
    case needsAction
    case failed
}

private struct SetupStepRow<Action: View>: View {
    let title: String
    let detail: String
    let status: SetupStepStatus
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .inProgress:
            ProgressView()
                .controlSize(.small)
        case .needsAction:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
