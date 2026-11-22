import AVFoundation
import Foundation
import os

struct CapturedAudio: Sendable {
    let samples: [Float]
    let startedAt: Date?
    let endedAt: Date?

    var duration: TimeInterval {
        Double(samples.count) / AudioFormatConfiguration.sampleRate
    }

    var wallClockDuration: TimeInterval? {
        guard let startedAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(startedAt))
    }
}

private enum AudioCaptureError: LocalizedError {
    case noAudio
    case bufferOverflow

    fileprivate var errorDescription: String? {
        switch self {
        case .noAudio:
            "Recording produced no audio — the input device may have changed during recording."
        case .bufferOverflow:
            "Recording could not keep up with the audio device and dropped samples."
        }
    }
}

nonisolated private final class AudioCaptureStore: @unchecked Sendable {
    static let slotFrameCapacity = 8_192

    private static let slotCount = 256

    private let lock = OSAllocatedUnfairLock()
    private let drainQueue = DispatchQueue(
        label: "dev.guptadhruv.mysteno.audio-capture",
        qos: .userInitiated
    )
    private let drainSignal: DispatchSourceUserDataAdd

    private var slots = (0..<slotCount).map { _ in
        [Float](repeating: 0, count: slotFrameCapacity)
    }
    private var counts = [Int](repeating: 0, count: slotCount)
    private var readIndex = 0
    private var writeIndex = 0
    private var pendingCount = 0
    private var didOverflow = false
    private var acceptedSampleCount = 0
    private var collected: [Float] = []
    private var drainScratch = [Float](repeating: 0, count: slotFrameCapacity)
    private let maximumSampleCount: Int

    init(maximumSampleCount: Int) {
        precondition(maximumSampleCount > 0)
        self.maximumSampleCount = maximumSampleCount
        drainSignal = DispatchSource.makeUserDataAddSource(queue: drainQueue)
        drainSignal.setEventHandler { [weak self] in
            self?.drainAvailableSlots()
        }
        drainSignal.resume()
    }

    func begin() {
        drainQueue.sync {
            lock.lock()
            readIndex = 0
            writeIndex = 0
            pendingCount = 0
            didOverflow = false
            acceptedSampleCount = 0
            counts.withUnsafeMutableBufferPointer { counts in
                for index in counts.indices {
                    counts[index] = 0
                }
            }
            collected.removeAll(keepingCapacity: true)
            collected.reserveCapacity(
                AudioFormatConfiguration.initialSampleReservation(
                    maximumSampleCount: maximumSampleCount
                )
            )
            lock.unlock()
        }
    }

    func noteOverflow() {
        lock.lock()
        didOverflow = true
        lock.unlock()
    }

    func append(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return false }

        lock.lock()
        guard count <= Self.slotFrameCapacity else {
            didOverflow = true
            lock.unlock()
            return false
        }

        let remainingSampleCount = maximumSampleCount - acceptedSampleCount
        guard remainingSampleCount > 0 else {
            lock.unlock()
            return false
        }
        guard pendingCount < Self.slotCount else {
            didOverflow = true
            lock.unlock()
            return false
        }
        let acceptedCount = min(count, remainingSampleCount)

        slots[writeIndex].withUnsafeMutableBufferPointer { destination in
            destination.baseAddress?.update(from: samples, count: acceptedCount)
        }
        counts[writeIndex] = acceptedCount
        writeIndex = (writeIndex + 1) % Self.slotCount
        pendingCount += 1
        acceptedSampleCount += acceptedCount
        let reachedMaximumDuration = acceptedSampleCount == maximumSampleCount
        lock.unlock()

        drainSignal.add(data: 1)
        return reachedMaximumDuration
    }

    func finish() throws -> CapturedAudio {
        try drainQueue.sync {
            drainAvailableSlots()

            lock.lock()
            defer { lock.unlock() }
            guard !didOverflow else {
                collected.removeAll(keepingCapacity: true)
                throw AudioCaptureError.bufferOverflow
            }
            guard !collected.isEmpty else { throw AudioCaptureError.noAudio }

            let samples = collected
            collected = []
            return CapturedAudio(samples: samples, startedAt: nil, endedAt: nil)
        }
    }

    func discard() {
        drainQueue.sync {
            drainAvailableSlots()
            lock.lock()
            readIndex = 0
            writeIndex = 0
            pendingCount = 0
            didOverflow = false
            acceptedSampleCount = 0
            collected.removeAll(keepingCapacity: true)
            lock.unlock()
        }
    }

    private func drainAvailableSlots() {
        while true {
            lock.lock()
            guard pendingCount > 0 else {
                lock.unlock()
                return
            }

            let count = counts[readIndex]
            slots[readIndex].withUnsafeBufferPointer { slot in
                drainScratch.withUnsafeMutableBufferPointer { scratch in
                    if let source = slot.baseAddress, let destination = scratch.baseAddress, count > 0 {
                        destination.update(from: source, count: count)
                    }
                }
            }
            counts[readIndex] = 0
            readIndex = (readIndex + 1) % Self.slotCount
            pendingCount -= 1
            lock.unlock()

            if count > 0 {
                collected.append(contentsOf: drainScratch[..<count])
            }
        }
    }
}

nonisolated private enum AudioDownmix {
    static let frameCapacity: AVAudioFrameCount = 16_384

    static func buffer(for format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.channelCount > 1, !format.isInterleaved else { return nil }
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        return AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCapacity)
    }

    static func mix(
        _ source: AVAudioPCMBuffer,
        into destination: AVAudioPCMBuffer
    ) -> Bool {
        let frameCount = Int(source.frameLength)
        guard frameCount > 0, frameCount <= Int(destination.frameCapacity) else { return false }
        guard let input = source.floatChannelData,
              let output = destination.floatChannelData?[0]
        else { return false }

        let channelCount = Int(source.format.channelCount)
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += input[channel][frame]
            }
            output[frame] = sum * scale
        }
        destination.frameLength = AVAudioFrameCount(frameCount)
        return true
    }
}

nonisolated private final class AudioTapConduit: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "AudioPerformance")

    private let converter: AVAudioConverter
    private let downmixBuffer: AVAudioPCMBuffer?
    private let outputBuffer: AVAudioPCMBuffer
    private let captureStore: AudioCaptureStore
    private let sampleRateRatio: Double
    private let onReachedLimit: @Sendable () -> Void
    private let didLogFirstBuffer = OSAllocatedUnfairLock(initialState: false)

    fileprivate init(
        converter: AVAudioConverter,
        sampleRateRatio: Double,
        downmixBuffer: AVAudioPCMBuffer?,
        outputBuffer: AVAudioPCMBuffer,
        captureStore: AudioCaptureStore,
        onReachedLimit: @escaping @Sendable () -> Void
    ) {
        self.converter = converter
        self.sampleRateRatio = sampleRateRatio
        self.downmixBuffer = downmixBuffer
        self.outputBuffer = outputBuffer
        self.captureStore = captureStore
        self.onReachedLimit = onReachedLimit
    }

    private func monoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let downmixBuffer else { return buffer }
        guard buffer.frameLength <= downmixBuffer.frameCapacity else {
            captureStore.noteOverflow()
            return nil
        }
        return AudioDownmix.mix(buffer, into: downmixBuffer) ? downmixBuffer : nil
    }

    fileprivate func process(_ buffer: AVAudioPCMBuffer) {
        if !didLogFirstBuffer.withLock({ logged in defer { logged = true }; return logged }) {
            Self.logger.info(
                "Microphone tap frames=\(buffer.frameLength, privacy: .public) sampleRate=\(buffer.format.sampleRate, privacy: .public) channels=\(buffer.format.channelCount, privacy: .public)"
            )
        }
        guard let mono = monoBuffer(from: buffer) else { return }
        let expectedFrameCount = (Double(mono.frameLength) * sampleRateRatio).rounded(.up) + 64
        guard expectedFrameCount <= Double(outputBuffer.frameCapacity) else {
            captureStore.noteOverflow()
            return
        }
        nonisolated(unsafe) let inputBuffer = mono
        outputBuffer.frameLength = 0
        nonisolated(unsafe) var fed = false
        converter.convert(to: outputBuffer, error: nil) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inputBuffer
        }

        guard outputBuffer.frameLength > 0,
              let samples = outputBuffer.floatChannelData?[0]
        else { return }
        if captureStore.append(samples, count: Int(outputBuffer.frameLength)) {
            onReachedLimit()
        }
    }
}

@Observable
final class AudioRecorder {
    private var isRecording = false
    private let onInterruption: () -> Void
    private let onMaximumDuration: () -> Void
    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    private var reconfigureWork: DispatchWorkItem?
    private var wallClockTimer: Timer?
    private var recordingTimeline: RecordingTimeline?
    private var didNotifyMaximumDuration = false
    private let maximumDuration: TimeInterval
    private let onElapsedTimeChange: (TimeInterval) -> Void
    private let captureStore: AudioCaptureStore

    private let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioFormatConfiguration.sampleRate,
        channels: 1,
        interleaved: false
    )!

    init(
        maximumDuration: TimeInterval,
        onInterruption: @escaping () -> Void,
        onMaximumDuration: @escaping () -> Void,
        onElapsedTimeChange: @escaping (TimeInterval) -> Void
    ) {
        precondition(maximumDuration > 0)
        self.maximumDuration = maximumDuration
        self.onInterruption = onInterruption
        self.onMaximumDuration = onMaximumDuration
        self.onElapsedTimeChange = onElapsedTimeChange
        captureStore = AudioCaptureStore(
            maximumSampleCount: AudioFormatConfiguration.maximumCaptureSampleCount(
                for: maximumDuration
            )
        )
    }

    func start() throws {
        guard !isRecording else {
            throw NSError(domain: "AudioRecorder", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Recorder is already running."
            ])
        }

        captureStore.begin()
        do {
            addConfigObserver()
            try installTapAndStartEngine()
            isRecording = true
            startWallClockTimer(startedAt: Date())
        } catch {
            cleanup(discardCapture: true)
            throw error
        }
    }

    func stop() throws -> CapturedAudio {
        let endedAt = Date()
        let startedAt = recordingTimeline?.startedAt
        cleanup(discardCapture: false)
        let audio = try captureStore.finish()
        return CapturedAudio(
            samples: audio.samples,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    func reset() {
        cleanup(discardCapture: true)
    }

    private func addConfigObserver() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigChange()
        }
    }

    private func removeConfigObserver() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    private func installTapAndStartEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Audio input not ready (sample rate is 0). The selected input device is still waking up or unavailable."
            ])
        }

        let downmix = AudioDownmix.buffer(for: inputFormat)
        guard inputFormat.channelCount == 1 || downmix != nil else {
            throw NSError(domain: "AudioRecorder", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "The selected input device uses an audio layout this app cannot mix down to mono."
            ])
        }
        let converterFormat = downmix?.format ?? inputFormat

        guard let converter = AVAudioConverter(from: converterFormat, to: canonicalFormat) else {
            throw NSError(domain: "AudioRecorder", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "Could not create an audio converter for the selected input device."
            ])
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .none

        guard let output = AVAudioPCMBuffer(
            pcmFormat: canonicalFormat,
            frameCapacity: AVAudioFrameCount(AudioCaptureStore.slotFrameCapacity)
        ) else {
            throw NSError(domain: "AudioRecorder", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "The selected input device requires an unsupported conversion buffer size."
            ])
        }

        let conduit = AudioTapConduit(
            converter: converter,
            sampleRateRatio: canonicalFormat.sampleRate / converterFormat.sampleRate,
            downmixBuffer: downmix,
            outputBuffer: output,
            captureStore: captureStore,
            onReachedLimit: { [weak self] in
                DispatchQueue.main.async {
                    self?.notifyMaximumDuration()
                }
            }
        )

        var startError: Error?
        let exception = ObjCExceptionCatcher.catchException {
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
                conduit.process(buffer)
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                startError = error
            }
        }

        if let exception { throw exception }
        if let startError { throw startError }
    }

    private func startWallClockTimer(startedAt: Date) {
        didNotifyMaximumDuration = false
        recordingTimeline = RecordingTimeline(
            startedAt: startedAt,
            maximumDuration: maximumDuration
        )
        onElapsedTimeChange(0)

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateWallClock()
        }
        wallClockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateWallClock() {
        guard isRecording, let recordingTimeline else { return }
        let now = Date()
        onElapsedTimeChange(recordingTimeline.elapsed(at: now))
        if recordingTimeline.hasReachedLimit(at: now) {
            notifyMaximumDuration()
        }
    }

    private func notifyMaximumDuration() {
        guard isRecording, !didNotifyMaximumDuration else { return }
        didNotifyMaximumDuration = true
        wallClockTimer?.invalidate()
        wallClockTimer = nil
        onMaximumDuration()
    }

    private func handleConfigChange() {
        guard isRecording else { return }
        reconfigureWork?.cancel()
        engine.stop()
        scheduleReconfigure(attempt: 1, maxAttempts: 12, delayMs: 0)
    }

    private func scheduleReconfigure(attempt: Int, maxAttempts: Int, delayMs: Int) {
        let work = DispatchWorkItem { [weak self] in
            self?.reconfigure(attempt: attempt, maxAttempts: maxAttempts)
        }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: work)
    }

    private func reconfigure(attempt: Int, maxAttempts: Int) {
        guard isRecording else { return }

        removeConfigObserver()
        engine = AVAudioEngine()
        addConfigObserver()

        do {
            try installTapAndStartEngine()
        } catch {
            guard attempt < maxAttempts else {
                cleanup(discardCapture: true)
                onInterruption()
                return
            }
            scheduleReconfigure(
                attempt: attempt + 1,
                maxAttempts: maxAttempts,
                delayMs: min(1_000, attempt * 150)
            )
        }
    }

    private func cleanup(discardCapture: Bool) {
        reconfigureWork?.cancel()
        reconfigureWork = nil
        wallClockTimer?.invalidate()
        wallClockTimer = nil
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        recordingTimeline = nil
        didNotifyMaximumDuration = false
        if discardCapture {
            captureStore.discard()
        }
    }
}
