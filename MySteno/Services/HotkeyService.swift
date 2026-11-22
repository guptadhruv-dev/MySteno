import CoreGraphics
import AppKit

struct HotkeyConfig: Equatable {
    let keyCode: Int64
    let modifiers: CGEventFlags

    static let `default` = HotkeyConfig(
        keyCode: 0x11,
        modifiers: CGEventFlags([.maskControl, .maskAlternate])
    )

    private static let keyCodeDefaultsKey = "hotkeyKeyCode"
    private static let modifiersDefaultsKey = "hotkeyModifiers"

    fileprivate static func load() -> HotkeyConfig {
        guard UserDefaults.standard.object(forKey: keyCodeDefaultsKey) != nil else { return .default }
        let keyCode = Int64(UserDefaults.standard.integer(forKey: keyCodeDefaultsKey))
        let modifierRawValue = UInt64(
            bitPattern: Int64(UserDefaults.standard.integer(forKey: modifiersDefaultsKey))
        )
        return HotkeyConfig(
            keyCode: keyCode,
            modifiers: CGEventFlags(rawValue: modifierRawValue)
        )
    }

    fileprivate func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        UserDefaults.standard.set(
            Int(bitPattern: UInt(modifiers.rawValue)),
            forKey: Self.modifiersDefaultsKey
        )
    }

    var displayString: String {
        var displayString = ""
        if modifiers.contains(.maskControl) { displayString += "⌃" }
        if modifiers.contains(.maskAlternate) { displayString += "⌥" }
        if modifiers.contains(.maskShift) { displayString += "⇧" }
        if modifiers.contains(.maskCommand) { displayString += "⌘" }
        displayString += keyCodeLabel(keyCode)
        return displayString
    }

    private func keyCodeLabel(_ code: Int64) -> String {
        let labelsByKeyCode: [Int64: String] = [
            0x00:"A", 0x01:"S", 0x02:"D", 0x03:"F", 0x04:"H", 0x05:"G",
            0x06:"Z", 0x07:"X", 0x08:"C", 0x09:"V", 0x0B:"B", 0x0C:"Q",
            0x0D:"W", 0x0E:"E", 0x0F:"R", 0x10:"Y", 0x11:"T", 0x12:"1",
            0x13:"2", 0x14:"3", 0x15:"4", 0x16:"6", 0x17:"5", 0x18:"=",
            0x19:"9", 0x1A:"7", 0x1B:"-", 0x1C:"8", 0x1D:"0", 0x1E:"]",
            0x1F:"O", 0x20:"U", 0x21:"[", 0x22:"I", 0x23:"P", 0x25:"L",
            0x26:"J", 0x27:"'", 0x28:"K", 0x29:";", 0x2A:"\\", 0x2B:",",
            0x2C:"/", 0x2D:"N", 0x2E:"M", 0x2F:".", 0x32:"`",
            0x24:"↩", 0x30:"⇥", 0x31:"Space", 0x33:"⌫", 0x35:"⎋",
            0x4C:"⌤", 0x72:"Help", 0x73:"↖", 0x74:"⇞", 0x75:"⌦",
            0x77:"↘", 0x79:"⇟",
            0x7B:"←", 0x7C:"→", 0x7D:"↓", 0x7E:"↑",
            0x7A:"F1", 0x78:"F2", 0x63:"F3", 0x76:"F4", 0x60:"F5",
            0x61:"F6", 0x62:"F7", 0x64:"F8", 0x65:"F9", 0x6D:"F10",
            0x67:"F11", 0x6F:"F12", 0x69:"F13", 0x6B:"F14", 0x71:"F15",
            0x6A:"F16", 0x40:"F17", 0x4F:"F18", 0x50:"F19",
            0x52:"Num 0", 0x53:"Num 1", 0x54:"Num 2", 0x55:"Num 3",
            0x56:"Num 4", 0x57:"Num 5", 0x58:"Num 6", 0x59:"Num 7",
            0x5B:"Num 8", 0x5C:"Num 9", 0x41:"Num .", 0x43:"Num *",
            0x45:"Num +", 0x4B:"Num /", 0x4E:"Num -", 0x51:"Num ="
        ]
        return labelsByKeyCode[code] ?? "Key \(code)"
    }
}

@Observable
final class HotkeyService {
    private(set) var accessibilityGranted = false
    private(set) var config: HotkeyConfig = .load()

    private var isMuted = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private weak var model: MyStenoModel?

    func start(model: MyStenoModel) {
        self.model = model
        requestAccessibilityIfNeeded()
        installTap()
    }

    private func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        runLoopSource = nil
        runLoop = nil
        eventTap = nil
    }

    func retryInstall() {
        installTap()
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else {
            stop()
            return
        }

        guard let tap = eventTap, CFMachPortIsValid(tap) else {
            installTap()
            return
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func recoverAfterWake() {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refresh()
        }
    }

    func updateConfig(_ newConfig: HotkeyConfig) {
        config = newConfig
        newConfig.save()
        installTap()
    }

    func setMuted(_ isMuted: Bool) {
        self.isMuted = isMuted
    }

    private func requestAccessibilityIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func installTap() {
        stop()
        accessibilityGranted = AXIsProcessTrusted()
        guard accessibilityGranted else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }

                let service = Unmanaged<HotkeyService>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = service.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    DispatchQueue.main.async { service.refresh() }
                    return nil
                }

                guard !service.isMuted else { return Unmanaged.passUnretained(event) }

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let relevantMask = CGEventFlags([.maskControl, .maskAlternate, .maskCommand, .maskShift])
                let actualMods = flags.intersection(relevantMask)
                let requiredMods = service.config.modifiers.intersection(relevantMask)

                if keyCode == service.config.keyCode && actualMods == requiredMods {
                    DispatchQueue.main.async { service.model?.toggleRecording() }
                    return nil
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )

        guard let tap else {
            accessibilityGranted = false
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let targetRunLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(targetRunLoop, source, .commonModes)
        runLoopSource = source
        runLoop = targetRunLoop
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
