import Accelerate
import AVFoundation
import AudioToolbox
import CoreAudio
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
    case noAudio(deviceName: String?)
    case bufferOverflow
    case alreadyRecording
    case noInputDevice
    case inputNotReady
    case unsupportedLayout
    case converterUnavailable
    case audioUnitUnavailable
    case coreAudio(operation: String, status: OSStatus)

    fileprivate var errorDescription: String? {
        switch self {
        case .noAudio(let deviceName?):
            "No audio arrived from \(deviceName). A Bluetooth headset may still have been switching to microphone mode. Try again, or choose another microphone."
        case .noAudio(nil):
            "Recording produced no audio. Try again, or choose another microphone."
        case .bufferOverflow:
            "Recording could not keep up with the audio device and dropped samples."
        case .alreadyRecording:
            "Recorder is already running."
        case .noInputDevice:
            "No microphone is available. Connect one, or choose another microphone."
        case .inputNotReady:
            "The microphone isn't ready yet. It may still be waking up or switching modes."
        case .unsupportedLayout:
            "The selected microphone uses an audio layout MySteno can't mix down to mono."
        case .converterUnavailable:
            "Could not convert audio from the selected microphone."
        case .audioUnitUnavailable:
            "macOS's audio input unit isn't available."
        case .coreAudio(let operation, let status):
            "Could not \(operation) (Core Audio error \(status))."
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
            guard !collected.isEmpty else { throw AudioCaptureError.noAudio(deviceName: nil) }

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

nonisolated private final class AudioInputConduit: @unchecked Sendable {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "AudioPerformance")

    private let converter: AVAudioConverter
    private let downmixBuffer: AVAudioPCMBuffer?
    private let outputBuffer: AVAudioPCMBuffer
    private let captureStore: AudioCaptureStore
    private let sampleRateRatio: Double
    private let onReachedLimit: @Sendable () -> Void
    private let didLogFirstBuffer = OSAllocatedUnfairLock(initialState: false)
    private let receivedSignal = OSAllocatedUnfairLock(initialState: false)

    init(
        inputFormat: AVAudioFormat,
        canonicalFormat: AVAudioFormat,
        captureStore: AudioCaptureStore,
        onReachedLimit: @escaping @Sendable () -> Void
    ) throws {
        let downmix = AudioDownmix.buffer(for: inputFormat)
        guard inputFormat.channelCount == 1 || downmix != nil else {
            throw AudioCaptureError.unsupportedLayout
        }
        let converterFormat = downmix?.format ?? inputFormat
        guard let converter = AVAudioConverter(from: converterFormat, to: canonicalFormat),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: canonicalFormat,
                  frameCapacity: AVAudioFrameCount(AudioCaptureStore.slotFrameCapacity)
              )
        else {
            throw AudioCaptureError.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .none

        self.converter = converter
        self.sampleRateRatio = canonicalFormat.sampleRate / converterFormat.sampleRate
        self.downmixBuffer = downmix
        self.outputBuffer = outputBuffer
        self.captureStore = captureStore
        self.onReachedLimit = onReachedLimit
    }

    var hasReceivedSignal: Bool {
        receivedSignal.withLock { $0 }
    }

    func noteOverflow() {
        captureStore.noteOverflow()
    }

    private func noteSignal(in buffer: AVAudioPCMBuffer) {
        guard !hasReceivedSignal, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(buffer.frameLength))
        if peak > 0 {
            receivedSignal.withLock { $0 = true }
        }
    }

    private func monoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let downmixBuffer else { return buffer }
        guard buffer.frameLength <= downmixBuffer.frameCapacity else {
            captureStore.noteOverflow()
            return nil
        }
        return AudioDownmix.mix(buffer, into: downmixBuffer) ? downmixBuffer : nil
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        if !didLogFirstBuffer.withLock({ logged in defer { logged = true }; return logged }) {
            Self.logger.info(
                "Microphone first buffer frames=\(buffer.frameLength, privacy: .public) sampleRate=\(buffer.format.sampleRate, privacy: .public) channels=\(buffer.format.channelCount, privacy: .public)"
            )
        }
        guard let mono = monoBuffer(from: buffer) else { return }
        noteSignal(in: mono)
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

nonisolated private enum CoreAudioInputDevice {
    static func defaultDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: "find the default microphone", status: status)
        }
        guard deviceID != kAudioObjectUnknown else { throw AudioCaptureError.noInputDevice }
        return deviceID
    }

    static func name(of deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value) == noErr,
              let name = value?.takeRetainedValue() as String?,
              !name.isEmpty
        else { return nil }
        return name
    }

    static func builtInMicrophone() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size)
        guard !deviceIDs.isEmpty,
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr
        else { return nil }
        return deviceIDs.first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn && hasInput($0) }
    }

    static func isBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        let transport = transportType(of: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func hasInput(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func transportType(of deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transport) == noErr else {
            return nil
        }
        return transport
    }

    static func transport(of deviceID: AudioDeviceID) -> String {
        guard let transport = transportType(of: deviceID) else { return "unknown" }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        default: return "other"
        }
    }
}

nonisolated private final class InputCapture: @unchecked Sendable {
    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0
    private static let maximumFramesPerSlice: AVAudioFrameCount = 4_096

    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let renderBuffer: AVAudioPCMBuffer
    private let conduit: AudioInputConduit
    private var isStopped = false

    private init(
        deviceID: AudioDeviceID,
        format: AVAudioFormat,
        unit: AudioUnit,
        renderBuffer: AVAudioPCMBuffer,
        conduit: AudioInputConduit
    ) {
        self.deviceID = deviceID
        self.format = format
        self.unit = unit
        self.renderBuffer = renderBuffer
        self.conduit = conduit
    }

    deinit {
        stop()
    }

    var hasReceivedSignal: Bool {
        conduit.hasReceivedSignal
    }

    static func start(
        deviceID: AudioDeviceID,
        canonicalFormat: AVAudioFormat,
        captureStore: AudioCaptureStore,
        onReachedLimit: @escaping @Sendable () -> Void
    ) throws -> InputCapture {
        let unit = try makeUnit(deviceID: deviceID)
        let capture: InputCapture
        do {
            let format = try configureClientFormat(of: unit)
            let conduit = try AudioInputConduit(
                inputFormat: format,
                canonicalFormat: canonicalFormat,
                captureStore: captureStore,
                onReachedLimit: onReachedLimit
            )
            guard let renderBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesPerSlice) else {
                throw AudioCaptureError.converterUnavailable
            }
            capture = InputCapture(
                deviceID: deviceID,
                format: format,
                unit: unit,
                renderBuffer: renderBuffer,
                conduit: conduit
            )
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        try capture.run()
        return capture
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private static func makeUnit(deviceID: AudioDeviceID) throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioCaptureError.audioUnitUnavailable
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "open the audio input")
        guard let unit = instance else { throw AudioCaptureError.audioUnitUnavailable }
        do {
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            var device = deviceID
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputElement, &enable, UInt32(MemoryLayout<UInt32>.size)),
                "enable microphone input"
            )
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, outputElement, &disable, UInt32(MemoryLayout<UInt32>.size)),
                "disable audio output"
            )
            try check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, outputElement, &device, UInt32(MemoryLayout<AudioDeviceID>.size)),
                "use the selected microphone"
            )
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    private static func configureClientFormat(of unit: AudioUnit) throws -> AVAudioFormat {
        var deviceFormat = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputElement, &deviceFormat, &dataSize),
            "read the microphone format"
        )
        guard deviceFormat.mSampleRate > 0, deviceFormat.mChannelsPerFrame > 0 else {
            throw AudioCaptureError.inputNotReady
        }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: deviceFormat.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        try check(
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputElement, &clientFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "set the microphone format"
        )
        var framesPerSlice = UInt32(maximumFramesPerSlice)
        try check(
            AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, outputElement, &framesPerSlice, UInt32(MemoryLayout<UInt32>.size)),
            "size the microphone buffer"
        )
        guard let format = AVAudioFormat(streamDescription: &clientFormat) else {
            throw AudioCaptureError.unsupportedLayout
        }
        return format
    }

    private func run() throws {
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, _, frameCount, _ in
                Unmanaged<InputCapture>.fromOpaque(refCon)
                    .takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        do {
            try Self.check(
                AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, Self.outputElement, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "receive microphone audio"
            )
            try Self.check(AudioUnitInitialize(unit), "prepare the microphone")
            try Self.check(AudioOutputUnitStart(unit), "start the microphone")
        } catch {
            stop()
            throw error
        }
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= renderBuffer.frameCapacity else {
            conduit.noteOverflow()
            return noErr
        }
        renderBuffer.frameLength = frameCount
        let status = AudioUnitRender(unit, flags, timeStamp, Self.inputElement, frameCount, renderBuffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        conduit.process(renderBuffer)
        return noErr
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: operation, status: status)
        }
    }
}

private struct DeviceListener {
    let objectID: AudioObjectID
    var address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

@Observable
final class AudioRecorder {
    private static let logger = Logger(subsystem: "dev.guptadhruv.mysteno", category: "AudioCapture")
    private static let deviceChangeSettleMilliseconds = 300
    private static let silentBluetoothCheckMilliseconds = 500
    private static let maximumRestarts = 5

    private var isRecording = false
    private let onInterruption: (String) -> Void
    private let onInputFallback: (String) -> Void
    private let onMaximumDuration: () -> Void
    private var capture: InputCapture?
    private var captureDeviceName: String?
    private var deviceListeners: [DeviceListener] = []
    private var restartWork: DispatchWorkItem?
    private var silentInputCheck: DispatchWorkItem?
    private var fallbackDeviceID: AudioDeviceID?
    private var restartCount = 0
    private var wallClockTimer: Timer?
    private var recordingTimeline: RecordingTimeline?
    private var didNotifyMaximumDuration = false
    private let maximumDuration: TimeInterval
    private let onElapsedTimeChange: (TimeInterval) -> Void
    private let captureStore: AudioCaptureStore
    private let inputDeviceID: () -> AudioDeviceID?

    private let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioFormatConfiguration.sampleRate,
        channels: 1,
        interleaved: false
    )!

    init(
        maximumDuration: TimeInterval,
        inputDeviceID: @escaping () -> AudioDeviceID?,
        onInterruption: @escaping (String) -> Void,
        onInputFallback: @escaping (String) -> Void,
        onMaximumDuration: @escaping () -> Void,
        onElapsedTimeChange: @escaping (TimeInterval) -> Void
    ) {
        precondition(maximumDuration > 0)
        self.maximumDuration = maximumDuration
        self.inputDeviceID = inputDeviceID
        self.onInterruption = onInterruption
        self.onInputFallback = onInputFallback
        self.onMaximumDuration = onMaximumDuration
        self.onElapsedTimeChange = onElapsedTimeChange
        captureStore = AudioCaptureStore(
            maximumSampleCount: AudioFormatConfiguration.maximumCaptureSampleCount(
                for: maximumDuration
            )
        )
    }

    func start() throws {
        guard !isRecording else { throw AudioCaptureError.alreadyRecording }

        captureStore.begin()
        restartCount = 0
        do {
            try startCapture()
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
        let deviceName = captureDeviceName
        cleanup(discardCapture: false)
        let audio: CapturedAudio
        do {
            audio = try captureStore.finish()
        } catch AudioCaptureError.noAudio(_) {
            throw AudioCaptureError.noAudio(deviceName: deviceName)
        }
        return CapturedAudio(
            samples: audio.samples,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    func reset() {
        cleanup(discardCapture: true)
    }

    private func startCapture() throws {
        let selectedDeviceID = fallbackDeviceID ?? inputDeviceID()
        let deviceID = try selectedDeviceID ?? CoreAudioInputDevice.defaultDevice()
        let capture = try InputCapture.start(
            deviceID: deviceID,
            canonicalFormat: canonicalFormat,
            captureStore: captureStore,
            onReachedLimit: { [weak self] in
                DispatchQueue.main.async {
                    self?.notifyMaximumDuration()
                }
            }
        )
        self.capture = capture
        captureDeviceName = CoreAudioInputDevice.name(of: deviceID)

        addListener(deviceID, kAudioDevicePropertyDeviceIsAlive, reason: "device disconnected")
        addListener(deviceID, kAudioDevicePropertyNominalSampleRate, reason: "sample rate changed")
        addListener(
            deviceID,
            kAudioDevicePropertyStreamConfiguration,
            scope: kAudioObjectPropertyScopeInput,
            reason: "channel layout changed"
        )
        if selectedDeviceID == nil {
            addListener(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyDefaultInputDevice,
                reason: "default input changed"
            )
        }

        if fallbackDeviceID == nil, CoreAudioInputDevice.isBluetooth(deviceID) {
            scheduleSilentInputCheck()
        }

        Self.logger.notice(
            "Capture started transport=\(CoreAudioInputDevice.transport(of: deviceID), privacy: .public) sampleRate=\(capture.format.sampleRate, privacy: .public) channels=\(capture.format.channelCount, privacy: .public) restart=\(self.restartCount, privacy: .public)"
        )
    }

    private func stopCapture() {
        silentInputCheck?.cancel()
        silentInputCheck = nil
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, .main, listener.block)
        }
        deviceListeners.removeAll()
        capture?.stop()
        capture = nil
    }

    private func addListener(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        reason: String
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange(reason: reason)
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block)
        guard status == noErr else {
            Self.logger.error(
                "Could not watch the microphone for \(reason, privacy: .public): \(status, privacy: .public)"
            )
            return
        }
        deviceListeners.append(DeviceListener(objectID: objectID, address: address, block: block))
    }

    private func handleDeviceChange(reason: String) {
        guard isRecording else { return }
        Self.logger.notice("Microphone change while recording: \(reason, privacy: .public)")
        restartWork?.cancel()
        scheduleRestart(afterMilliseconds: Self.deviceChangeSettleMilliseconds)
    }

    private func scheduleRestart(afterMilliseconds delay: Int) {
        let work = DispatchWorkItem { [weak self] in
            self?.restartCapture()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func restartCapture() {
        guard isRecording else { return }
        guard restartCount < Self.maximumRestarts else {
            let deviceName = captureDeviceName ?? "the microphone"
            Self.logger.error("Microphone restart limit reached after \(Self.maximumRestarts, privacy: .public) restarts")
            cleanup(discardCapture: true)
            onInterruption("Lost audio from \(deviceName) and couldn't recover. Reconnect it or choose another microphone, then press the shortcut again.")
            return
        }
        restartCount += 1
        stopCapture()
        do {
            try startCapture()
        } catch {
            Self.logger.error(
                "Microphone restart \(self.restartCount, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            scheduleRestart(afterMilliseconds: min(1_000, restartCount * 200))
        }
    }

    private func scheduleSilentInputCheck() {
        let work = DispatchWorkItem { [weak self] in
            self?.fallBackIfInputIsSilent()
        }
        silentInputCheck = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.silentBluetoothCheckMilliseconds),
            execute: work
        )
    }

    private func fallBackIfInputIsSilent() {
        guard isRecording, let capture, !capture.hasReceivedSignal else { return }
        guard let builtInDeviceID = CoreAudioInputDevice.builtInMicrophone(),
              builtInDeviceID != capture.deviceID
        else {
            Self.logger.error("Bluetooth microphone sent only silence and no built-in microphone is available")
            return
        }
        let silentDeviceName = captureDeviceName ?? "The Bluetooth microphone"
        let builtInName = CoreAudioInputDevice.name(of: builtInDeviceID) ?? "the built-in microphone"
        Self.logger.notice("Bluetooth microphone sent only silence; switching to the built-in microphone")
        fallbackDeviceID = builtInDeviceID
        stopCapture()
        do {
            try startCapture()
        } catch {
            Self.logger.error(
                "Switching to the built-in microphone failed: \(error.localizedDescription, privacy: .public)"
            )
            scheduleRestart(afterMilliseconds: 200)
        }
        onInputFallback(
            "\(silentDeviceName) sent no sound, so MySteno recorded with \(builtInName) instead. AirPods can't send sound to your Mac while they're playing audio from another device."
        )
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

    private func cleanup(discardCapture: Bool) {
        restartWork?.cancel()
        restartWork = nil
        wallClockTimer?.invalidate()
        wallClockTimer = nil
        stopCapture()
        isRecording = false
        fallbackDeviceID = nil
        captureDeviceName = nil
        recordingTimeline = nil
        didNotifyMaximumDuration = false
        if discardCapture {
            captureStore.discard()
        }
    }
}
