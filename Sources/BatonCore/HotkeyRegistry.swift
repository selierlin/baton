import Carbon.HIToolbox
import Foundation

public struct KeyCombo: Hashable, Sendable, Codable {
    /// 硬件 keycode（与键盘布局无关；Dvorak/AZERTY 下字符会变，keycode 不变）
    public let keyCode: UInt32
    /// Carbon 修饰键掩码（cmdKey / optionKey / controlKey / shiftKey）
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public enum HotkeySource: Sendable {
    case carbon
    case eventTap
}

/// Carbon 与 tap 会同时收到同一次按键。只抑制「tap 紧跟 carbon」这一种重复，
/// 不能用时间窗一刀切——用户快速连按两次是合法操作。
public struct TriggerDeduplicator: Sendable {
    public let window: TimeInterval
    private var lastCarbon: [KeyCombo: TimeInterval] = [:]

    public init(window: TimeInterval = 0.06) {
        self.window = window
    }

    public mutating func shouldFire(_ combo: KeyCombo, source: HotkeySource, now: TimeInterval) -> Bool {
        switch source {
        case .carbon:
            lastCarbon[combo] = now
            return true
        case .eventTap:
            if let last = lastCarbon[combo], now - last < window {
                return false
            }
            return true
        }
    }

    public mutating func reset() {
        lastCarbon.removeAll()
    }
}

public struct HotkeyID: Hashable, Sendable {
    public let raw: UInt32
}

public enum HotkeyError: Error, Sendable {
    case conflict(KeyCombo)
    case osStatus(OSStatus)
    case notInstalled
}

/// Carbon 全局热键。冲突可检测（-9878 eventHotKeyExistsErr），
/// 失败后的 tap 兜底由调用方决定要不要启用（见 `TriggerDeduplicator`）。
@MainActor
public final class HotkeyRegistry {
    private static let signature: OSType = 0x42544E31  // "BTN1"

    private var eventHandler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: (combo: KeyCombo, run: @MainActor () -> Void)] = [:]
    private var nextID: UInt32 = 1
    private var dedup = TriggerDeduplicator()

    public private(set) var installed = false

    public init() {}

    public func install() throws {
        guard !installed else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         batonHotKeyHandler,
                                         1,
                                         &spec,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &eventHandler)
        guard status == noErr else { throw HotkeyError.osStatus(status) }
        installed = true
    }

    @discardableResult
    public func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) throws -> HotkeyID {
        guard installed else { throw HotkeyError.notInstalled }

        var ref: EventHotKeyRef?
        let id = nextID
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode,
                                         combo.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        if status == -9878 {  // eventHotKeyExistsErr
            throw HotkeyError.conflict(combo)
        }
        guard status == noErr, let ref else {
            throw HotkeyError.osStatus(status)
        }

        nextID += 1
        refs[id] = ref
        actions[id] = (combo, { action() })
        if ProcessInfo.processInfo.environment["BATON_HOTKEY_DEBUG"] != nil {
            print("[hotkey] registered id=\(id) key=\(combo.keyCode) mods=\(combo.modifiers) \(combo.display)")
        }
        return HotkeyID(raw: id)
    }

    public func unregister(_ id: HotkeyID) {
        guard let ref = refs.removeValue(forKey: id.raw) else { return }
        UnregisterEventHotKey(ref)
        actions.removeValue(forKey: id.raw)
    }

    public func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        dedup.reset()
    }

    /// tap 兜底入口。Carbon 已经触发过就丢弃。
    @MainActor
    func dispatchFromTap(_ combo: KeyCombo, now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        if ProcessInfo.processInfo.environment["BATON_HOTKEY_DEBUG"] != nil {
            print("[hotkey] combo=\(combo.keyCode) source=tap(fallback)")
        }
        guard dedup.shouldFire(combo, source: .eventTap, now: now) else { return }
        actions.first { $0.value.combo == combo }?.value.run()
    }

    fileprivate func dispatch(id: UInt32, source: HotkeySource) {
        guard let entry = actions[id] else { return }
        if ProcessInfo.processInfo.environment["BATON_HOTKEY_DEBUG"] != nil {
            let label: String
            switch source {
            case .carbon: label = "carbon"
            case .eventTap: label = "tap"
            }
            print("[hotkey] id=\(id) source=\(label)")
        }
        guard dedup.shouldFire(entry.combo, source: source,
                               now: Date.timeIntervalSinceReferenceDate) else { return }
        entry.run()
    }
}

/// Carbon 的 C 回调。不能捕获上下文，靠 userData 找回 registry。
private func batonHotKeyHandler(_ call: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr else { return status }

    let registry = Unmanaged<HotkeyRegistry>.fromOpaque(userData).takeUnretainedValue()
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            registry.dispatch(id: hotKeyID.id, source: .carbon)
        }
    } else {
        Task { @MainActor in
            registry.dispatch(id: hotKeyID.id, source: .carbon)
        }
    }
    return noErr
}
