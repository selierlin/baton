import Carbon
import Foundation

public struct InputSourceInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// `.keylayout`（ABC、Dvorak）还是输入法模式（拼音、双拼）
    public let isASCIICapable: Bool
    public let isCurrent: Bool
}

/// TIS（Text Input Sources）薄封装。
///
/// 只暴露「列出可选的键盘输入源」「读当前」「按 ID 选」三件事，
/// 不做规则、不做记忆——那些在 `InputSourceService` 里。
@MainActor
public final class InputSourceCatalog {
    public init() {}

    public var currentID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.stringProperty(source, kTISPropertyInputSourceID)
    }

    public var currentName: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.stringProperty(source, kTISPropertyLocalizedName)
    }

    /// 只列「能选、已启用、属于键盘类」的源，避免把 Touch Bar / 手写之类混进来。
    public var all: [InputSourceInfo] {
        let conditions: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
            kTISPropertyInputSourceIsSelectCapable: true,
            kTISPropertyInputSourceIsEnabled: true,
        ]
        guard let raw = TISCreateInputSourceList(conditions as CFDictionary, false)?.takeRetainedValue(),
              let sources = raw as? [TISInputSource] else {
            return []
        }

        let current = currentID
        return sources.compactMap { source in
            guard let id = Self.stringProperty(source, kTISPropertyInputSourceID) else { return nil }
            return InputSourceInfo(
                id: id,
                name: Self.stringProperty(source, kTISPropertyLocalizedName) ?? id,
                isASCIICapable: Self.boolProperty(source, kTISPropertyInputSourceIsASCIICapable),
                isCurrent: id == current
            )
        }
    }

    /// 按 ID 切换。找不到或已经在该源上时不报错，返回是否真的发生了切换。
    @discardableResult
    public func select(id: String) -> Bool {
        guard id != currentID else { return false }
        guard let source = source(withID: id) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    public func contains(id: String) -> Bool {
        source(withID: id) != nil
    }

    private func source(withID target: String) -> TISInputSource? {
        let conditions: [CFString: Any] = [
            kTISPropertyInputSourceID: target,
        ]
        guard let raw = TISCreateInputSourceList(conditions as CFDictionary, false)?.takeRetainedValue(),
              let sources = raw as? [TISInputSource] else {
            return nil
        }
        return sources.first
    }

    // MARK: - 属性读取

    nonisolated static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    nonisolated static func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        let value = Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }
}
