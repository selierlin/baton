import CoreGraphics
import Foundation

/// 悬停拾取的调度层：查窗口 → （可选）查 AX 元素 → 裁剪到目标屏 → 产出 `PickTarget`。
///
/// 窗口列表按 120 ms 缓存。鼠标在窗口内移动时反复 `CGWindowListCopyWindowInfo`
/// 会很浪费（一屏常驻几十个窗），而窗口本身在这段时间里几乎不会变。
@MainActor
public final class PickService {
    private var windows: [WindowInfo] = []
    private var windowsAt: CFAbsoluteTime = 0
    private let windowTTL: CFAbsoluteTime = 0.12

    public init() {}

    public func invalidate() {
        windows = []
        windowsAt = 0
    }

    public func probe(kind: PickTarget.Kind,
                      at point: CGPoint,
                      in display: DisplayFrame) -> PickTarget? {
        guard let window = window(at: point) else { return nil }

        switch kind {
        case .window:
            return makeTarget(kind: .window,
                              rect: window.bounds,
                              label: window.displayLabel,
                              window: window,
                              display: display)

        case .element:
            if let element = ElementPicker.element(at: point, pid: window.ownerPID),
               let rect = ElementPicker.frame(of: element),
               isUsableElementRect(rect, in: window.bounds) {
                return makeTarget(kind: .element,
                                  rect: rect,
                                  label: ElementPicker.label(of: element),
                                  window: window,
                                  display: display)
            }
            // 不支持 AX 的 App（部分 Electron / 游戏）退化成整窗
            return makeTarget(kind: .window,
                              rect: window.bounds,
                              label: window.displayLabel,
                              window: window,
                              display: display)
        }
    }

    /// 诊断用：窗口存在但元素没选中时，区分「AX 没命中」和「命中但矩形不合格」。
    public func diagnoseElements(at point: CGPoint) -> String {
        guard let window = window(at: point) else {
            return "光标下没有普通窗口（layer 0）"
        }
        return ElementPicker.diagnose(at: point, pid: window.ownerPID)
            + " window=\(window.ownerName) \(window.bounds)"
    }

    private func window(at point: CGPoint) -> WindowInfo? {
        let now = CFAbsoluteTimeGetCurrent()
        if windows.isEmpty || now - windowsAt > windowTTL {
            windows = WindowPicker.enumerate(excludingPID: getpid())
            windowsAt = now
        }
        return WindowPicker.pick(point, from: windows, excludingPID: getpid())
    }

    /// 元素框太碎（&lt; 6pt）或几乎等于整窗时没有拾取价值，退回窗口。
    private func isUsableElementRect(_ rect: CGRect, in windowBounds: CGRect) -> Bool {
        guard rect.width >= 6, rect.height >= 6 else { return false }
        guard rect.intersects(windowBounds) else { return false }
        let windowArea = windowBounds.width * windowBounds.height
        guard windowArea > 0 else { return false }
        return rect.width * rect.height < windowArea * 0.98
    }

    /// 跨屏窗口只取光标所在屏的那一段：本工程的抓帧与裁剪都是逐屏的，
    /// 不裁剪会算出越界像素矩形。
    nonisolated static func clip(_ rect: CGRect, to display: CGRect) -> CGRect? {
        let clipped = rect.intersection(display)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        return clipped
    }

    private func makeTarget(kind: PickTarget.Kind,
                            rect: CGRect,
                            label: String,
                            window: WindowInfo,
                            display: DisplayFrame) -> PickTarget? {
        guard let clipped = Self.clip(rect, to: display.screenFrame) else { return nil }
        return PickTarget(kind: kind,
                          rect: clipped,
                          label: label,
                          ownerPID: window.ownerPID,
                          ownerName: window.ownerName,
                          windowID: window.windowID)
    }
}
