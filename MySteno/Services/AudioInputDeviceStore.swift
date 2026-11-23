import CoreAudio
import Foundation
import Observation
import os

struct AudioInputDevice: Identifiable, Hashable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String

    var id: String {
        uid
    }
}

@Observable
final class AudioInputDeviceStore {
    private static let selectedDeviceUIDKey = "selectedAudioInputDeviceUID"
    private static let logger = Logger(
        subsystem: "dev.guptadhruv.mysteno",
        category: "AudioInputDeviceStore"
    )
    private static let devicesPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private(set) var devices: [AudioInputDevice] = []
    private(set) var errorMessage: String?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var selectedDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(selectedDeviceUID, forKey: Self.selectedDeviceUIDKey)
        }
    }

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: Self.selectedDeviceUIDKey)
        refresh()
        addDeviceListListener()
    }

    deinit {
        removeDeviceListListener()
    }

    var selectedDevice: AudioInputDevice? {
        devices.first { $0.uid == selectedDeviceUID }
    }

    var selectedDeviceID: AudioDeviceID? {
        selectedDevice?.deviceID
    }

    var selectedDeviceUnavailable: Bool {
        selectedDeviceUID != nil && selectedDevice == nil
    }

    func select(_ device: AudioInputDevice?) {
        selectedDeviceUID = device?.uid
    }

    func refresh() {
        do {
            devices = try availableDevices()
            errorMessage = nil
        } catch {
            devices = []
            errorMessage = error.localizedDescription
        }
    }

    private func availableDevices() throws -> [AudioInputDevice] {
        var address = Self.devicesPropertyAddress
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            operation: "read the available microphones"
        )

        var deviceIDs = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )
        guard !deviceIDs.isEmpty else { return [] }
        try deviceIDs.withUnsafeMutableBytes { buffer in
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    buffer.baseAddress!
                ),
                operation: "read the available microphones"
            )
        }

        var inputDevices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            do {
                guard try inputChannelCount(for: deviceID) > 0, !isPrivateAggregate(deviceID) else { continue }
                inputDevices.append(AudioInputDevice(
                    deviceID: deviceID,
                    uid: try stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
                    name: try stringProperty(kAudioObjectPropertyName, for: deviceID)
                ))
            } catch {
                Self.logger.error(
                    "Skipping unavailable microphone id=\(deviceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return inputDevices.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            operation: "inspect a microphone"
        )
        guard dataSize >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList),
            operation: "inspect a microphone"
        )

        return UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        ).reduce(0) { count, buffer in
            count + Int(buffer.mNumberChannels)
        }
    }

    private func isPrivateAggregate(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var composition: Unmanaged<CFDictionary>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &composition) == noErr,
              let composition = composition?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue == true
    }

    private func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UnsafeRawPointer?
        var dataSize = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value),
            operation: "read a microphone name"
        )
        guard let value else {
            throw AudioInputDeviceError.unavailableProperty
        }
        let string = Unmanaged<CFString>.fromOpaque(value).takeRetainedValue() as String
        guard !string.isEmpty else {
            throw AudioInputDeviceError.unavailableProperty
        }
        return string
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioInputDeviceError.coreAudio(operation: operation, status: status)
        }
    }

    private func addDeviceListListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refresh()
        }
        var address = Self.devicesPropertyAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )
        guard status == noErr else {
            Self.logger.error("Could not watch microphone changes: \(status, privacy: .public)")
            return
        }
        deviceListListener = listener
    }

    private func removeDeviceListListener() {
        guard let deviceListListener else { return }
        var address = Self.devicesPropertyAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            deviceListListener
        )
    }
}

private enum AudioInputDeviceError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case unavailableProperty

    var errorDescription: String? {
        switch self {
        case .coreAudio(let operation, let status):
            "Could not \(operation) (Core Audio error \(status))."
        case .unavailableProperty:
            "Could not read a microphone name."
        }
    }
}
