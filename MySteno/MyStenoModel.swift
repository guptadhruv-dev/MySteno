import Accelerate
import AppKit
import AVFoundation
import Darwin
import FluidAudio
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class MyStenoModel {
    private static let logger = Logger(
        subsystem: "dev.guptadhruv.mysteno",
        category: "MyStenoModel"
    )
    private static let performanceLogger = Logger(
        subsystem: "dev.guptadhruv.mysteno",
        category: "AudioPerformance"
    )
    private static let insertsParagraphBreaksKey = "insertsParagraphBreaks"

    private(set) var isRecording = false
    private(set) var isStartingRecording = false
    private(set) var isVoiceTranscribing = false
    private(set) var isFileTranscribing = false
    private(set) var isCancellingFile = false
    private(set) var statusMessage = "Starting…"
    private(set) var transcriptHistory: [String] = []
    private(set) var lastFileOutputURL: URL?
    private(set) var lastError: String?
    private(set) var inputNotice: String?
    private(set) var recordingElapsed: TimeInterval = 0
    private(set) var insertsParagraphBreaks = UserDefaults.standard.bool(forKey: insertsParagraphBreaksKey)

    let audioDuration = AudioDurationSettings()
    let launchAtLogin = LaunchAtLogin()
    let hotkey = HotkeyService()
    let transcription = TranscriptionCoordinator()
    let outputFolder = OutputFolderStore()
    let audioInputDevices = AudioInputDeviceStore()

    @ObservationIgnored private lazy var recorder = makeRecorder()
    private var vad: VadManager?
    private var currentVoiceJobID = UUID()
    private var startAttemptID = UUID()
    private var recordingRequestedAt = ContinuousClock.now
    private var isFinishingRecording = false
    private var voiceTask: Task<Void, Never>?
    private var fileTask: Task<Void, Never>?
    private let notifications = NotificationService()
    private let maximumTranscriptHistory = 10
    private let transcriptHistoryLabelWordLimit = 6
    private let transcriptHistoryLabelCharacterLimit = 40

    init() {
        activate()
        observeSleepWake()
    }

    var isModelReady: Bool {
        transcription.isSelectedReady && vad != nil
    }

    var jobsAreRunning: Bool {
        isRecording || isStartingRecording || isVoiceTranscribing || isFileTranscribing
    }

    var recordingTimerLabel: String {
        AudioFormatConfiguration.elapsedLabel(for: recordingElapsed)
    }

    private var selectedModelName: String {
        transcription.selectedModel.displayName
    }

    func clearError() {
        lastError = nil
    }

    func clearProcessingWarnings() {
        transcription.clearProcessingWarnings()
    }

    func clearInputNotice() {
        inputNotice = nil
    }

    var selectedAudioInputDevice: AudioInputDevice? {
        audioInputDevices.selectedDevice
    }

    func refreshAudioInputDevices() {
        audioInputDevices.refresh()
    }

    func selectAudioInputDevice(_ device: AudioInputDevice?) {
        guard !jobsAreRunning else { return }
        audioInputDevices.select(device)
        resetRecorder()
    }

    func clearTranscriptHistory() {
        transcriptHistory.removeAll()
    }

    func copyTranscript(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func transcriptHistoryLabel(for text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        var label = words.prefix(transcriptHistoryLabelWordLimit).joined(separator: " ")
        var isTruncated = words.count > transcriptHistoryLabelWordLimit
        if label.count > transcriptHistoryLabelCharacterLimit {
            label = String(label.prefix(transcriptHistoryLabelCharacterLimit))
            isTruncated = true
        }
        guard isTruncated else { return label }
        let trimmed = label.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return "\(trimmed)…"
    }

    private func activate() {
        hotkey.start(model: self, promptsForAccessibility: SetupGuide.isCompleted)
        statusMessage = "Loading models…"
        Task {
            do {
                async let loadedVad = VadManager()
                async let modelBootstrap: Void = transcription.bootstrap()
                let (newVad, _) = try await (loadedVad, modelBootstrap)
                vad = newVad
                setReadyStatus()
            } catch {
                statusMessage = "Model load failed"
                recordError("Model load failed: \(error.localizedDescription)")
            }
        }
    }

    func selectModel(_ model: TranscriptionModel) async {
        guard !jobsAreRunning else { return }
        statusMessage = "Preparing \(model.displayName)…"
        do {
            try await transcription.select(model)
            setReadyStatus()
        } catch {
            statusMessage = "Model error"
            recordError("Could not select \(model.displayName): \(error.localizedDescription)")
        }
    }

    func updateDefaultModel(_ model: TranscriptionModel) {
        guard !jobsAreRunning else { return }
        transcription.setDefaultModel(model)
    }

    func updateInsertsParagraphBreaks(_ enabled: Bool) {
        insertsParagraphBreaks = enabled
        UserDefaults.standard.set(enabled, forKey: Self.insertsParagraphBreaksKey)
    }

    func updateMaximumAudioDurationMinutes(_ minutes: Int) {
        guard !jobsAreRunning else { return }
        guard audioDuration.updateMaximumDurationMinutes(minutes) else { return }
        resetRecorder()
    }

    func installModel(_ model: TranscriptionModel) async {
        guard !jobsAreRunning else { return }
        statusMessage = "Installing \(model.displayName)…"
        do {
            try await transcription.install(model)
            setReadyStatus()
        } catch {
            statusMessage = "Install failed"
            recordError("Could not install \(model.displayName): \(error.localizedDescription)")
        }
    }

    func deleteModel(_ model: TranscriptionModel) async {
        guard transcription.canDelete(model, jobsAreRunning: jobsAreRunning) else { return }
        statusMessage = "Removing \(model.displayName)…"
        do {
            try await transcription.delete(model)
            setReadyStatus()
        } catch {
            statusMessage = "Remove failed"
            recordError("Could not remove \(model.displayName): \(error.localizedDescription)")
        }
    }

    func toggleRecording() {
        guard !isFileTranscribing else {
            recordError("Recording is unavailable while an audio file is being transcribed.")
            return
        }
        guard isModelReady, !isStartingRecording, !isFinishingRecording else { return }
        if isRecording {
            finishRecordingAfterTail()
            return
        }
        guard !isVoiceTranscribing else {
            recordError("The previous dictation is still being transcribed. Start recording again once it finishes.")
            return
        }
        startRecording()
    }

    func chooseAudioFile() {
        guard !jobsAreRunning else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Audio File"
        panel.message = "Choose an audio file up to \(audioDuration.limitDescription) long."
        panel.prompt = "Transcribe"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["wav", "aiff", "caf", "m4a", "mp3"].compactMap {
            UTType(filenameExtension: $0)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if outputFolder.folderURL == nil, !outputFolder.chooseFolder() {
            if let error = outputFolder.errorMessage { recordError(error) }
            return
        }
        beginFileTranscription(url)
    }

    func cancelFileTranscription() {
        guard isFileTranscribing else { return }
        isCancellingFile = true
        statusMessage = "Cancelling file transcription…"
        fileTask?.cancel()
    }

    func revealLastOutput() {
        guard let lastFileOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFileOutputURL])
    }

    func changeShortcut() {
        hotkey.setMuted(true)
        ShortcutRecorder.shared.beginRecording { [weak self] config in
            guard let self else { return }
            hotkey.setMuted(false)
            if let config { hotkey.updateConfig(config) }
        }
    }

    func resetShortcut() {
        hotkey.updateConfig(.default)
    }

    private func makeRecorder() -> AudioRecorder {
        let inputDevices = audioInputDevices
        return AudioRecorder(
            maximumDuration: audioDuration.maximumDuration,
            inputDeviceID: { [weak inputDevices] in
                inputDevices?.selectedDeviceID
            },
            onInterruption: { [weak self] message in
                guard let self else { return }
                let wasActive = isRecording || isStartingRecording
                startAttemptID = UUID()
                isStartingRecording = false
                isRecording = false
                clearRecordingTimeline()
                setReadyStatus()
                resetRecorder()
                hotkey.refresh()
                if wasActive {
                    recordError(message)
                }
            },
            onInputFallback: { [weak self] message in
                self?.inputNotice = message
            },
            onMaximumDuration: { [weak self] in
                guard let self, isRecording else { return }
                stopRecording(reachedLimit: true)
            },
            onElapsedTimeChange: { [weak self] elapsed in
                guard let self, isRecording || isStartingRecording else { return }
                let wholeSeconds = elapsed.rounded(.down)
                if wholeSeconds != recordingElapsed {
                    recordingElapsed = wholeSeconds
                }
            }
        )
    }

    private func resetRecorder() {
        recorder.reset()
        recorder = makeRecorder()
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if isRecording {
                stopRecording(pasteToActiveField: false)
            } else if isStartingRecording {
                startAttemptID = UUID()
                isStartingRecording = false
                clearRecordingTimeline()
                setReadyStatus()
                resetRecorder()
                recordError("Recording could not start because the Mac went to sleep.")
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            startAttemptID = UUID()
            isStartingRecording = false
            isRecording = false
            clearRecordingTimeline()
            if isModelReady, !jobsAreRunning { setReadyStatus() }
            resetRecorder()
            hotkey.recoverAfterWake()
        }
    }

    private func startRecording() {
        guard !isStartingRecording, !isRecording, !isVoiceTranscribing, !isFileTranscribing else { return }
        inputNotice = nil
        guard !audioInputDevices.selectedDeviceUnavailable else {
            statusMessage = "Selected microphone unavailable"
            recordError("The selected microphone is unavailable. Reconnect it or choose another microphone.")
            return
        }
        currentVoiceJobID = UUID()

        let attemptID = UUID()
        startAttemptID = attemptID
        recordingRequestedAt = .now
        isStartingRecording = true
        statusMessage = "Starting mic…"

        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                guard startAttemptID == attemptID else { return }
                isStartingRecording = false
                statusMessage = "Mic access denied"
                recordError("Microphone access denied — grant permission in System Settings > Privacy & Security > Microphone.")
                return
            }
            await startEngine(attemptID: attemptID, attempt: 1, maxAttempts: 6)
        }
    }

    private func startEngine(attemptID: UUID, attempt: Int, maxAttempts: Int) async {
        guard startAttemptID == attemptID, isStartingRecording, !isRecording, !isFileTranscribing else { return }
        do {
            try recorder.start()
            guard startAttemptID == attemptID, isStartingRecording else {
                _ = try? recorder.stop()
                clearRecordingTimeline()
                return
            }
            recordingElapsed = 0
            isStartingRecording = false
            isRecording = true
            statusMessage = "Listening · \(selectedModelName)"
            Self.performanceLogger.info(
                "Microphone start latency=\(self.recordingRequestedAt.duration(to: .now), privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        } catch {
            guard startAttemptID == attemptID, isStartingRecording else { return }
            resetRecorder()
            guard attempt < maxAttempts else {
                isStartingRecording = false
                isRecording = false
                clearRecordingTimeline()
                statusMessage = "Mic error"
                recordError("Audio engine failed to start after \(maxAttempts) attempts: \(error.localizedDescription)")
                return
            }
            try? await Task.sleep(for: .milliseconds(min(1_500, attempt * 300)))
            await startEngine(attemptID: attemptID, attempt: attempt + 1, maxAttempts: maxAttempts)
        }
    }

    private func finishRecordingAfterTail() {
        isFinishingRecording = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            isFinishingRecording = false
            guard isRecording else { return }
            stopRecording()
        }
    }

    private func stopRecording(
        reachedLimit: Bool = false,
        pasteToActiveField: Bool = true
    ) {
        startAttemptID = UUID()
        let audio: CapturedAudio
        do {
            audio = try recorder.stop()
            let wallClockDuration = audio.wallClockDuration ?? recordingElapsed
            var peak: Float = 0
            var rootMeanSquare: Float = 0
            vDSP_maxmgv(audio.samples, 1, &peak, vDSP_Length(audio.samples.count))
            vDSP_rmsqv(audio.samples, 1, &rootMeanSquare, vDSP_Length(audio.samples.count))
            Self.performanceLogger.info(
                "Microphone capture wallClockDuration=\(wallClockDuration, format: .fixed(precision: 3), privacy: .public)s sampleDuration=\(audio.duration, format: .fixed(precision: 3), privacy: .public)s samples=\(audio.samples.count, privacy: .public) peak=\(peak, format: .fixed(precision: 4), privacy: .public) rms=\(rootMeanSquare, format: .fixed(precision: 5), privacy: .public)"
            )
        } catch {
            isStartingRecording = false
            isRecording = false
            clearRecordingTimeline()
            setReadyStatus()
            recordError(error.localizedDescription)
            return
        }

        isStartingRecording = false
        isRecording = false
        clearRecordingTimeline()
        isVoiceTranscribing = true
        statusMessage = reachedLimit
            ? "Preparing audio · \(audioDuration.limitDescription) limit reached"
            : "Preparing audio…"
        let jobID = UUID()
        currentVoiceJobID = jobID
        voiceTask = Task { [weak self] in
            await self?.transcribeVoice(
                samples: audio.samples,
                jobID: jobID,
                shouldPasteToActiveField: pasteToActiveField
            )
        }
    }

    private func transcribeVoice(
        samples rawSamples: [Float],
        jobID: UUID,
        shouldPasteToActiveField: Bool
    ) async {
        let requestStart = ContinuousClock.now
        defer {
            if currentVoiceJobID == jobID {
                isVoiceTranscribing = false
                voiceTask = nil
            }
        }

        do {
            let preparedSpeech = try await prepareSpeech(from: rawSamples)
            try Task.checkCancellation()
            guard !preparedSpeech.isEmpty else {
                if currentVoiceJobID == jobID, !isRecording { statusMessage = "No speech detected" }
                return
            }

            statusMessage = "Transcribing · \(selectedModelName)"
            let inferenceStart = ContinuousClock.now
            let text = try await transcription.transcribe(preparedSpeech)
            Self.performanceLogger.info(
                "Voice inference=\(inferenceStart.duration(to: .now), privacy: .public) endToEnd=\(requestStart.duration(to: .now), privacy: .public) preparedSamples=\(preparedSpeech.retainedSampleCount, privacy: .public)"
            )
            try Task.checkCancellation()
            guard currentVoiceJobID == jobID, !isRecording, !isFileTranscribing else { return }
            addTranscriptToHistory(text)
            setReadyStatus()
            if shouldPasteToActiveField {
                pasteToActiveField(text)
            } else {
                await notifications.send(
                    title: "Dictation transcribed",
                    body: "Recording stopped before sleep. Open the MySteno menu to copy the transcript."
                )
            }
        } catch is CancellationError {
            if currentVoiceJobID == jobID, !isRecording { setReadyStatus() }
        } catch {
            guard currentVoiceJobID == jobID, !isRecording else { return }
            statusMessage = "Error"
            recordError("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func beginFileTranscription(_ url: URL) {
        isFileTranscribing = true
        isCancellingFile = false
        statusMessage = "Checking audio file…"
        fileTask = Task { [weak self] in
            await self?.transcribeFile(url)
        }
    }

    private func transcribeFile(_ sourceURL: URL) async {
        let sourceScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if sourceScope { sourceURL.stopAccessingSecurityScopedResource() }
            isFileTranscribing = false
            isCancellingFile = false
            fileTask = nil
        }

        do {
            let duration = try await AVURLAsset(url: sourceURL).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw FileTranscriptionError.invalidDuration }
            guard duration <= audioDuration.maximumDuration else {
                throw FileTranscriptionError.tooLong(
                    maximumDurationDescription: audioDuration.limitDescription
                )
            }
            try Task.checkCancellation()

            statusMessage = "Preparing audio…"
            let preparedSpeech = try await prepareSpeech(from: sourceURL)
            guard !preparedSpeech.isEmpty else { throw FileTranscriptionError.noSpeech }
            try Task.checkCancellation()

            statusMessage = "Transcribing file · \(selectedModelName)"
            let text = try await transcription.transcribe(preparedSpeech)
            try Task.checkCancellation()

            let outputURL = try writeTranscript(text, sourceURL: sourceURL)
            lastFileOutputURL = outputURL
            setReadyStatus()
            await notifications.send(
                title: "Transcription complete",
                body: "Saved \(outputURL.lastPathComponent). Reveal it from the MySteno menu."
            )
        } catch is CancellationError {
            statusMessage = "File transcription cancelled"
            await notifications.send(
                title: "Transcription cancelled",
                body: "No output file was created."
            )
        } catch {
            statusMessage = "File transcription failed"
            recordError("File transcription failed: \(error.localizedDescription)")
            await notifications.send(
                title: "Transcription failed",
                body: error.localizedDescription
            )
        }
    }

    private func prepareSpeech(from url: URL) async throws -> PreparedSpeech {
        let start = ContinuousClock.now
        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioConverter().resampleAudioFile(url)
        }.value
        Self.performanceLogger.info(
            "Imported audio decode/resample=\(start.duration(to: .now), privacy: .public) samples=\(samples.count, privacy: .public)"
        )
        return try await prepareSpeech(from: samples)
    }

    private func prepareSpeech(from samples: [Float]) async throws -> PreparedSpeech {
        try Task.checkCancellation()
        guard let vad else { throw FileTranscriptionError.vadUnavailable }

        let vadStart = ContinuousClock.now
        let segments = try await vad.segmentSpeech(
            samples,
            config: SpeechPreparation.segmentationConfig
        )
        let vadElapsed = vadStart.duration(to: .now)

        let assemblyStart = ContinuousClock.now
        let insertsParagraphBreaks = insertsParagraphBreaks
        let prepared = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let speechRanges = segments.map {
                SpeechTimeRange(startTime: $0.startTime, endTime: $0.endTime)
            }
            return SpeechPreparation.prepared(
                samples: samples,
                segments: speechRanges,
                insertsParagraphBreaks: insertsParagraphBreaks
            )
        }.value
        Self.performanceLogger.info(
            "Audio preparation vad=\(vadElapsed, privacy: .public) assembly=\(assemblyStart.duration(to: .now), privacy: .public) inputSamples=\(samples.count, privacy: .public) retainedSamples=\(prepared.retainedSampleCount, privacy: .public) segments=\(segments.count, privacy: .public) paragraphs=\(prepared.paragraphRanges.count, privacy: .public)"
        )
        return prepared
    }

    private func writeTranscript(_ text: String, sourceURL: URL) throws -> URL {
        let access = try outputFolder.beginAccess()
        defer {
            if access.securityScopeStarted { access.url.stopAccessingSecurityScopedResource() }
        }

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        var outputURL = access.url.appendingPathComponent(baseName).appendingPathExtension("txt")
        var suffix = 2
        guard let data = "\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n".data(using: .utf8) else {
            throw FileTranscriptionError.encodingFailed
        }
        let temporaryURL = access.url.appendingPathComponent(".\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL)
        defer {
            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                do {
                    try FileManager.default.removeItem(at: temporaryURL)
                } catch {
                    Self.logger.error("Could not remove temporary transcript output: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        while true {
            let status = renamex_np(temporaryURL.path, outputURL.path, UInt32(RENAME_EXCL))
            if status == 0 { return outputURL }
            let errorNumber = errno
            if errorNumber == ENOTSUP {
                do {
                    try data.write(to: outputURL, options: .withoutOverwriting)
                    return outputURL
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    outputURL = access.url
                        .appendingPathComponent("\(baseName)-\(suffix)")
                        .appendingPathExtension("txt")
                    suffix += 1
                    continue
                }
            }
            guard errorNumber == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
            }
            outputURL = access.url
                .appendingPathComponent("\(baseName)-\(suffix)")
                .appendingPathExtension("txt")
            suffix += 1
        }
    }

    private func addTranscriptToHistory(_ text: String) {
        transcriptHistory.insert(text, at: 0)
        if transcriptHistory.count > maximumTranscriptHistory {
            transcriptHistory.removeLast(transcriptHistory.count - maximumTranscriptHistory)
        }
    }

    private func pasteToActiveField(_ text: String) {
        let pasteboard = NSPasteboard.general
        let existingItems = pasteboardItems(from: pasteboard.pasteboardItems ?? [])
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            let restored = restorePasteboard(existingItems, to: pasteboard)
            recordError(
                restored
                    ? "Could not place the transcript on the clipboard for pasting."
                    : "Could not place the transcript on the clipboard or restore the previous clipboard contents."
            )
            return
        }
        let transcriptChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            let restored = restorePasteboard(existingItems, to: pasteboard)
            recordError(
                restored
                    ? "Could not create the keyboard event needed to paste the transcript."
                    : "Could not create the keyboard event or restore the previous clipboard contents."
            )
            return
        }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard pasteboard.changeCount == transcriptChangeCount else { return }
            guard let self else { return }
            if !self.restorePasteboard(existingItems, to: pasteboard) {
                self.recordError("Could not restore the clipboard after pasting the transcript.")
            }
        }
    }

    private func pasteboardItems(from items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.compactMap { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy.types.isEmpty ? nil : copy
        }
    }

    private func restorePasteboard(
        _ items: [NSPasteboardItem],
        to pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()
        return items.isEmpty || pasteboard.writeObjects(items)
    }

    private func setReadyStatus() {
        if transcription.selectedModel == .accuracy {
            statusMessage = "Ready · Accuracy"
        } else {
            statusMessage = "Ready · \(selectedModelName)"
        }
    }

    private func clearRecordingTimeline() {
        recordingElapsed = 0
    }

    private func recordError(_ detail: String) {
        lastError = detail
        Self.logger.error("\(detail, privacy: .public)")
    }
}

private enum FileTranscriptionError: LocalizedError {
    case tooLong(maximumDurationDescription: String)
    case invalidDuration
    case noSpeech
    case vadUnavailable
    case encodingFailed

    fileprivate var errorDescription: String? {
        switch self {
        case .tooLong(let maximumDurationDescription):
            "Audio files must be \(maximumDurationDescription) or shorter."
        case .invalidDuration: "The audio file duration could not be read."
        case .noSpeech: "No speech was detected in the audio file."
        case .vadUnavailable: "Voice activity detection is not ready."
        case .encodingFailed: "The transcript could not be encoded as UTF-8."
        }
    }
}
