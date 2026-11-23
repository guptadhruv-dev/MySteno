import SwiftUI

struct MenuView: View {
    @Environment(MyStenoModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !model.hotkey.accessibilityGranted {
            accessibilityWarning
            Divider()
        }
        if let error = model.lastError {
            errorBanner(error)
            Divider()
        }
        if let warning = model.transcription.transcriptionWarning {
            warningBanner(warning)
            Divider()
        }

        Text(model.statusMessage)
            .padding(.vertical, 4)

        Picker("Model", selection: Binding(
            get: { model.transcription.selectedModel },
            set: { selected in
                Task { await model.selectModel(selected) }
            }
        )) {
            ForEach(model.transcription.installedModels) { option in
                Text(option.displayName).tag(option)
            }
        }
        .disabled(model.jobsAreRunning || model.transcription.installedModels.count < 2)

        Picker("Microphone", selection: Binding(
            get: { model.selectedAudioInputDevice },
            set: { selected in
                model.selectAudioInputDevice(selected)
            }
        )) {
            Text("System Default").tag(nil as AudioInputDevice?)
            ForEach(model.audioInputDevices.devices) { device in
                Text(device.name).tag(Optional(device))
            }
        }
        .disabled(model.jobsAreRunning)

        if let error = model.audioInputDevices.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if model.audioInputDevices.selectedDeviceUnavailable {
            Label("Selected microphone unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Divider()

        Button(model.isRecording ? "Stop Recording" : "Start Recording") {
            model.toggleRecording()
        }
        .disabled(
            !model.hotkey.accessibilityGranted ||
            !model.isModelReady ||
            model.isStartingRecording ||
            model.isFileTranscribing ||
            (model.isVoiceTranscribing && !model.isRecording)
        )

        Button("Choose Audio File…") {
            model.chooseAudioFile()
        }
        .disabled(!model.isModelReady || model.jobsAreRunning)

        if model.isFileTranscribing {
            Button(model.isCancellingFile ? "Cancelling…" : "Cancel File Transcription") {
                model.cancelFileTranscription()
            }
            .disabled(model.isCancellingFile)
        }

        if !model.transcriptHistory.isEmpty || model.lastFileOutputURL != nil {
            Divider()
        }

        if !model.transcriptHistory.isEmpty {
            Menu("Transcript History") {
                ForEach(Array(model.transcriptHistory.enumerated()), id: \.offset) { _, transcript in
                    Button(model.transcriptHistoryLabel(for: transcript)) {
                        model.copyTranscript(transcript)
                    }
                }
            }
        }

        if model.lastFileOutputURL != nil {
            Button("Reveal Last Output") {
                model.revealLastOutput()
            }
        }

        Divider()

        Button("Setup Guide…") {
            openWindow(id: SetupGuide.windowID)
            NSApp.activate()
        }

        SettingsLink {
            Text("Preferences")
        }

        Divider()

        Button("Quit MySteno") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Last Error", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear") { model.clearError() }
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func warningBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Processing Warning", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Clear") { model.clearProcessingWarnings() }
                .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Accessibility needed for the shortcut and paste", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.weight(.medium))

            Text("Grant access in System Settings\nthen click Retry.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open System Settings…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .font(.caption)

            Button("Retry") {
                model.hotkey.retryInstall()
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
