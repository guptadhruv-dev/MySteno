import CoreML
import FluidAudio
import Foundation
import OSLog

enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case speed
    case accuracy

    var id: Self { self }

    var displayName: String {
        switch self {
        case .speed: "Speed"
        case .accuracy: "Accuracy (Beta)"
        }
    }

    var detail: String {
        switch self {
        case .speed: "Parakeet Unified · fast local transcription"
        case .accuracy: "Cohere Transcribe · about 2.19 GB"
        }
    }
}

enum ModelLifecycleState: Equatable {
    case notInstalled
    case downloading(Double)
    case installed
    case loading
    case warming
    case ready
    case failed(String)

    var isInstalled: Bool {
        switch self {
        case .notInstalled, .downloading:
            false
        case .installed, .loading, .warming, .ready, .failed:
            true
        }
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .loading, .warming:
            true
        default:
            false
        }
    }

    var label: String {
        switch self {
        case .notInstalled: "Not installed"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .installed: "Installed"
        case .loading: "Loading…"
        case .warming: "Preparing first use…"
        case .ready: "Ready"
        case .failed: "Needs attention"
        }
    }
}

private actor SpeedTranscriptionEngine {
    private static let trailingSilence = [Float](
        repeating: 0,
        count: Int(0.5 * AudioFormatConfiguration.sampleRate)
    )

    private var manager: UnifiedAsrManager?

    fileprivate func prepare(modelDirectory: URL) async throws {
        guard manager == nil else { return }
        let loadedManager = UnifiedAsrManager()
        try await loadedManager.loadModels(from: modelDirectory)
        manager = loadedManager
    }

    fileprivate func transcribe(_ samples: ArraySlice<Float>) async throws -> String {
        guard let manager else { throw TranscriptionCoordinatorError.modelNotReady(.speed) }
        var padded: [Float] = []
        padded.reserveCapacity(samples.count + Self.trailingSilence.count)
        padded.append(contentsOf: samples)
        padded.append(contentsOf: Self.trailingSilence)
        return try await manager.transcribe(padded)
    }
}

private actor AccuracyTranscriptionEngine {
    private static let logger = Logger(
        subsystem: "dev.guptadhruv.mysteno",
        category: "CoherePerformance"
    )

    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?
    private var preparationTask: Task<CoherePipeline.LoadedModels, Error>?
    private var warmupTask: Task<Void, Error>?
    private var isWarm = false

    fileprivate func prepare(modelDirectory: URL) async throws {
        guard models == nil else { return }
        if let preparationTask {
            models = try await preparationTask.value
            return
        }

        let task = Task {
            try await CoherePipeline.loadModels(
                encoderDir: modelDirectory,
                decoderDir: modelDirectory,
                vocabDir: modelDirectory,
                decoderVariant: .v3,
                computeUnits: .cpuAndNeuralEngine
            )
        }
        preparationTask = task
        do {
            models = try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    fileprivate func warmUp() async throws {
        guard !isWarm else { return }
        if let warmupTask {
            try await warmupTask.value
            return
        }
        guard let models else {
            throw TranscriptionCoordinatorError.modelNotReady(.accuracy)
        }

        let task = Task {
            let start = ContinuousClock.now
            _ = try await pipeline.transcribe(
                audio: [Float](repeating: 0, count: Int(AudioFormatConfiguration.sampleRate)),
                models: models,
                language: .english
            )
            let elapsed = start.duration(to: .now)
            Self.logger.info("Cohere warm-up completed in \(elapsed, privacy: .public)")
        }
        warmupTask = task
        do {
            try await task.value
            isWarm = true
            warmupTask = nil
        } catch {
            warmupTask = nil
            throw error
        }
    }

    fileprivate func transcribe(_ samples: [Float]) async throws -> CoherePipeline.TranscriptionResult {
        guard let models else { throw TranscriptionCoordinatorError.modelNotReady(.accuracy) }
        let result = try await pipeline.transcribe(
            audio: samples,
            models: models,
            language: .english
        )
        let duration = Double(samples.count) / AudioFormatConfiguration.sampleRate
        let rtfx = result.totalSeconds > 0 ? duration / result.totalSeconds : 0
        Self.logger.info(
            "Cohere duration=\(duration, format: .fixed(precision: 3), privacy: .public)s encoder=\(result.encoderSeconds, format: .fixed(precision: 3), privacy: .public)s decoder=\(result.decoderSeconds, format: .fixed(precision: 3), privacy: .public)s total=\(result.totalSeconds, format: .fixed(precision: 3), privacy: .public)s tokens=\(result.tokenIds.count, privacy: .public) rtfx=\(rtfx, format: .fixed(precision: 2), privacy: .public)"
        )
        return result
    }
}

@Observable
final class TranscriptionCoordinator {
    private static let logger = Logger(
        subsystem: "dev.guptadhruv.mysteno",
        category: "TranscriptionCoordinator"
    )
    private static let speedModelVariant = "offline"
    private static let accuracyWindowSampleCount = 20 * CohereAsrConfig.sampleRate
    private static let accuracyOverlapSampleCount = 4 * CohereAsrConfig.sampleRate
    private static let accuracyMinimumWindowSampleCount = 4 * CohereAsrConfig.sampleRate

    private(set) var selectedModel: TranscriptionModel
    private(set) var defaultModel: TranscriptionModel
    private(set) var states: [TranscriptionModel: ModelLifecycleState] = [:]
    private(set) var transcriptionWarning: String?

    private var speedEngine: SpeedTranscriptionEngine?
    private var accuracyEngine: AccuracyTranscriptionEngine?

    private let defaultModelKey = "selectedTranscriptionModel"
    private let userDefaults = UserDefaults.standard
    private let modelsBase: URL

    init() {
        let storedDefaultModel = TranscriptionModel(
            rawValue: UserDefaults.standard.string(forKey: defaultModelKey) ?? ""
        ) ?? .speed
        selectedModel = storedDefaultModel
        defaultModel = storedDefaultModel
        modelsBase = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("FluidAudio", isDirectory: true)
        .appendingPathComponent("Models", isDirectory: true)
        refreshInstalledStates()
    }

    private var selectedState: ModelLifecycleState {
        states[selectedModel] ?? .notInstalled
    }

    var isSelectedReady: Bool {
        selectedState == .ready
    }

    var installedModels: [TranscriptionModel] {
        TranscriptionModel.allCases.filter { states[$0]?.isInstalled == true }
    }

    func bootstrap() async throws {
        refreshInstalledStates()
        if installedModels.isEmpty {
            try await install(.speed)
            return
        }
        if states[selectedModel]?.isInstalled != true {
            selectedModel = installedModels[0]
            defaultModel = selectedModel
            persistDefaultModel()
        }
        try await prepare(selectedModel)
    }

    func select(_ model: TranscriptionModel) async throws {
        guard states[model]?.isInstalled == true else {
            throw TranscriptionCoordinatorError.modelNotInstalled(model)
        }
        selectedModel = model
        releaseInactiveEngine()
        if case .failed = states[model] {
            states[model] = .installed
        }
        try await prepare(model)
    }

    func setDefaultModel(_ model: TranscriptionModel) {
        guard defaultModel != model else { return }
        defaultModel = model
        persistDefaultModel()
    }

    func install(_ model: TranscriptionModel) async throws {
        guard states[model]?.isBusy != true else { return }
        do {
            switch model {
            case .speed:
                states[model] = .downloading(0)
                try await ModelHub.download(
                    .parakeetUnified,
                    to: modelsBase,
                    variant: Self.speedModelVariant
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateDownloadProgress(.speed, progress.fractionCompleted)
                    }
                }
                states[model] = .installed
                if installedModels.count == 1 {
                    selectedModel = .speed
                    defaultModel = .speed
                    persistDefaultModel()
                }
                if selectedModel == .speed {
                    try await prepare(.speed)
                }
            case .accuracy:
                try ensureAccuracyDiskSpace()
                states[model] = .downloading(0)
                try await downloadAccuracyModels()
                states[model] = .installed
                if installedModels.count == 1 {
                    selectedModel = .accuracy
                    defaultModel = .accuracy
                    persistDefaultModel()
                }
                if selectedModel == .accuracy {
                    try await prepare(.accuracy)
                }
            }
        } catch {
            refreshInstalledStates()
            if states[model]?.isInstalled == true {
                states[model] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func delete(_ model: TranscriptionModel) async throws {
        let remaining = installedModels.filter { $0 != model }
        guard !remaining.isEmpty else { throw TranscriptionCoordinatorError.lastInstalledModel }

        releaseEngine(model)
        switch model {
        case .speed:
            ModelHub.clearCache(for: .parakeetUnified, directory: modelsBase)
        case .accuracy:
            ModelHub.clearCache(for: .cohereTranscribeCoreml, directory: modelsBase)
        }
        states[model] = .notInstalled

        if defaultModel == model {
            setDefaultModel(remaining[0])
        }
        if selectedModel == model {
            try await select(remaining[0])
        }
    }

    func transcribe(_ preparedSpeech: PreparedSpeech) async throws -> String {
        transcriptionWarning = nil
        var paragraphs: [String] = []
        paragraphs.reserveCapacity(preparedSpeech.paragraphRanges.count)

        for index in preparedSpeech.paragraphRanges.indices {
            try Task.checkCancellation()
            let paragraph: String
            switch selectedModel {
            case .speed:
                paragraph = try await transcribeSpeedParagraph(
                    preparedSpeech.samples[preparedSpeech.paragraphRanges[index]]
                )
            case .accuracy:
                paragraph = try await transcribeAccuracyParagraph(
                    preparedSpeech,
                    paragraphIndex: index
                )
            }
            if !paragraph.isEmpty {
                paragraphs.append(paragraph)
            }
        }

        return try requireText(
            paragraphs.joined(separator: "\n\n"),
            model: selectedModel
        )
    }

    func clearProcessingWarnings() {
        transcriptionWarning = nil
    }

    func canDelete(_ model: TranscriptionModel, jobsAreRunning: Bool) -> Bool {
        !jobsAreRunning && states[model]?.isInstalled == true && installedModels.count > 1
    }

    func errorMessage(for model: TranscriptionModel) -> String? {
        if case .failed(let message) = states[model] { return message }
        return nil
    }

    private func prepare(_ model: TranscriptionModel) async throws {
        guard states[model]?.isInstalled == true else {
            throw TranscriptionCoordinatorError.modelNotInstalled(model)
        }
        guard model == selectedModel else {
            throw TranscriptionCoordinatorError.modelNotReady(model)
        }
        if states[model] == .ready { return }

        do {
            states[model] = .loading
            switch model {
            case .speed:
                let engine = speedEngine ?? SpeedTranscriptionEngine()
                speedEngine = engine
                try await engine.prepare(modelDirectory: speedDirectory)
                guard speedEngine === engine else { return }
            case .accuracy:
                let engine = accuracyEngine ?? AccuracyTranscriptionEngine()
                accuracyEngine = engine
                try await engine.prepare(modelDirectory: accuracyDirectory)
                guard accuracyEngine === engine else { return }
                states[model] = .warming
                try await engine.warmUp()
                guard accuracyEngine === engine else { return }
            }
            states[model] = .ready
        } catch is CancellationError {
            releaseEngine(model)
            throw CancellationError()
        } catch {
            releaseEngine(model)
            states[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func transcribeSpeedParagraph(_ samples: ArraySlice<Float>) async throws -> String {
        do {
            try await prepare(.speed)
            guard let text = try await speedEngine?.transcribe(samples) else {
                throw TranscriptionCoordinatorError.emptyTranscript(.speed)
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            releaseEngine(.speed)
            states[.speed] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func transcribeAccuracyParagraph(
        _ preparedSpeech: PreparedSpeech,
        paragraphIndex: Int
    ) async throws -> String {
        do {
            try await prepare(.accuracy)
            guard let engine = accuracyEngine else {
                throw TranscriptionCoordinatorError.modelNotReady(.accuracy)
            }
            let text = try await transcribeAccuracyUnits(
                preparedSpeech,
                paragraphIndex: paragraphIndex,
                engine: engine
            )
            states[.accuracy] = .ready
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            releaseEngine(.accuracy)
            states[.accuracy] = .failed(error.localizedDescription)
            throw error
        }
    }

    private func transcribeAccuracyUnits(
        _ preparedSpeech: PreparedSpeech,
        paragraphIndex: Int,
        engine: AccuracyTranscriptionEngine
    ) async throws -> String {
        let samples = preparedSpeech.samples[preparedSpeech.paragraphRanges[paragraphIndex]]
        if samples.count <= CohereAsrConfig.maxSamples {
            let result = try await engine.transcribe(Array(samples))
            if result.cappedWindows == 0 {
                return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let window = samples.count <= CohereAsrConfig.maxSamples
            ? min(Self.accuracyWindowSampleCount, max(8 * CohereAsrConfig.sampleRate, samples.count * 3 / 5))
            : Self.accuracyWindowSampleCount
        return try await stitchedAccuracyWords(
            samples,
            window: window,
            overlap: Self.accuracyOverlapSampleCount,
            engine: engine
        )
        .joined(separator: " ")
    }

    private func stitchedAccuracyWords(
        _ samples: ArraySlice<Float>,
        window: Int,
        overlap: Int,
        engine: AccuracyTranscriptionEngine
    ) async throws -> [String] {
        let sampleRate = CohereAsrConfig.sampleRate
        let hop = max(sampleRate, window - overlap)
        var merged: [String] = []
        var start = samples.startIndex

        while start < samples.endIndex {
            try Task.checkCancellation()
            let end = min(start + window, samples.endIndex)
            let chunk = samples[start..<end]
            let result = try await engine.transcribe(Array(chunk))
            let words: [String]
            if result.cappedWindows > 0, window > Self.accuracyMinimumWindowSampleCount {
                let nextWindow = max(Self.accuracyMinimumWindowSampleCount, window * 3 / 5)
                words = try await stitchedAccuracyWords(
                    chunk,
                    window: nextWindow,
                    overlap: min(overlap, max(sampleRate, nextWindow / 5)),
                    engine: engine
                )
            } else {
                if result.cappedWindows > 0 {
                    transcriptionWarning = "Accuracy reached its per-window decoding limit during very dense speech, so words may be missing in one section."
                }
                words = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
            }
            merged = TranscriptStitcher.merged(merged, words)
            if end >= samples.endIndex { break }
            start += hop
        }
        return merged
    }

    private func releaseInactiveEngine() {
        for model in TranscriptionModel.allCases where model != selectedModel {
            releaseEngine(model)
        }
    }

    private func releaseEngine(_ model: TranscriptionModel) {
        switch model {
        case .speed:
            speedEngine = nil
        case .accuracy:
            accuracyEngine = nil
        }
        if states[model]?.isInstalled == true {
            states[model] = .installed
        }
    }

    private func refreshInstalledStates() {
        states[.speed] = speedModelsExist ? .installed : .notInstalled
        states[.accuracy] = accuracyModelsExist ? .installed : .notInstalled
    }

    private var speedDirectory: URL {
        modelsBase.appendingPathComponent(Repo.parakeetUnified.folderName, isDirectory: true)
    }

    private var speedModelsExist: Bool {
        ModelNames.ParakeetUnified.requiredModels(variant: Self.speedModelVariant).allSatisfy {
            FileManager.default.fileExists(atPath: speedDirectory.appendingPathComponent($0).path)
        }
    }

    private var accuracyDirectory: URL {
        modelsBase.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    private var accuracyModelsExist: Bool {
        ModelNames.CohereTranscribe.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: accuracyDirectory.appendingPathComponent($0).path)
        }
    }

    private func downloadAccuracyModels() async throws {
        let repositoryRoot = modelsBase.appendingPathComponent(
            "cohere-transcribe",
            isDirectory: true
        )
        let downloads: [(name: String, start: Double, weight: Double)] = [
            (ModelNames.CohereTranscribe.encoderCompiledFile, 0, 0.84),
            (ModelNames.CohereTranscribe.decoderCacheExternalV3CompiledFile, 0.84, 0.15),
        ]

        for download in downloads
        where !FileManager.default.fileExists(
            atPath: accuracyDirectory.appendingPathComponent(download.name).path
        ) {
            try await ModelHub.download(
                .cohereTranscribeCoreml,
                subdirectory: "q8/\(download.name)",
                to: repositoryRoot
            ) { [weak self] progress in
                let fraction = download.start + progress.fractionCompleted * download.weight
                Task { @MainActor [weak self] in
                    self?.updateDownloadProgress(.accuracy, fraction)
                }
            }
        }

        try FileManager.default.createDirectory(
            at: accuracyDirectory,
            withIntermediateDirectories: true
        )
        let vocabularyURL = accuracyDirectory.appendingPathComponent(
            ModelNames.CohereTranscribe.vocab
        )
        if !FileManager.default.fileExists(atPath: vocabularyURL.path) {
            let remoteURL = try ModelRegistry.resolveModel(
                Repo.cohereTranscribeCoreml.remotePath,
                ModelNames.CohereTranscribe.vocab
            )
            let vocabulary = try await ModelHub.fetchFile(
                from: remoteURL,
                description: ModelNames.CohereTranscribe.vocab
            )
            try vocabulary.write(to: vocabularyURL, options: .atomic)
        }
    }

    private func updateDownloadProgress(_ model: TranscriptionModel, _ fraction: Double) {
        guard case .downloading = states[model] else { return }
        states[model] = .downloading(fraction)
    }

    private func ensureAccuracyDiskSpace() throws {
        try FileManager.default.createDirectory(
            at: modelsBase,
            withIntermediateDirectories: true
        )
        let values = try modelsBase.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let required = Int64(12 * 1_024 * 1_024 * 1_024)
        if let available = values.volumeAvailableCapacityForImportantUsage, available < required {
            throw TranscriptionCoordinatorError.insufficientDiskSpace
        }
    }

    private func requireText(_ text: String, model: TranscriptionModel) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionCoordinatorError.emptyTranscript(model) }
        return trimmed
    }

    private func persistDefaultModel() {
        userDefaults.set(defaultModel.rawValue, forKey: defaultModelKey)
    }
}

private enum TranscriptionCoordinatorError: LocalizedError {
    case modelNotInstalled(TranscriptionModel)
    case modelNotReady(TranscriptionModel)
    case lastInstalledModel
    case insufficientDiskSpace
    case emptyTranscript(TranscriptionModel)

    fileprivate var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let model): "\(model.displayName) is not installed."
        case .modelNotReady(let model): "\(model.displayName) is not ready."
        case .lastInstalledModel: "At least one transcription model must remain installed."
        case .insufficientDiskSpace: "Accuracy needs at least 12 GiB of available disk space for its model and Core ML specialization cache."
        case .emptyTranscript(let model): "\(model.displayName) returned an empty transcript."
        }
    }
}
