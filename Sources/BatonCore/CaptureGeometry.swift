import CoreGraphics
import Foundation

/// 一块屏幕的抓取结果所对应的几何信息。
///
/// 坐标系约定：`screenFrame` 与所有「全局」坐标都使用 **CoreGraphics 显示坐标**
/// （主屏左上角为原点，y 向下）。AppKit 的 Cocoa 坐标（左下原点）只在窗口层做一次转换。
public struct DisplayFrame: Sendable, Hashable {
    public let displayID: CGDirectDisplayID
    /// 该屏在全局显示坐标中的矩形（点）
    public let screenFrame: CGRect
    /// 实际抓到的位图尺寸（像素）。降采样后小于 `screenFrame * nativeScale`
    public let pixelSize: CGSize
    /// 屏幕自身的 backing scale（通常 2.0）
    public let nativeScale: CGFloat

    public init(displayID: CGDirectDisplayID,
                screenFrame: CGRect,
                pixelSize: CGSize,
                nativeScale: CGFloat) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.pixelSize = pixelSize
        self.nativeScale = nativeScale
    }

    /// 抓取倍率 = 像素 / 点。**降采样时必须用这个值做换算，不能用 `nativeScale`。**
    public var captureScale: CGSize {
        guard screenFrame.width > 0, screenFrame.height > 0 else {
            return CGSize(width: nativeScale, height: nativeScale)
        }
        return CGSize(width: pixelSize.width / screenFrame.width,
                      height: pixelSize.height / screenFrame.height)
    }
}

public enum CaptureGeometry {
    /// 全局点坐标 → 该屏位图的像素坐标（左上原点）。
    public static func pixelRect(forGlobal rect: CGRect, in frame: DisplayFrame) -> CGRect {
        let s = frame.captureScale
        let local = CGRect(x: rect.minX - frame.screenFrame.minX,
                           y: rect.minY - frame.screenFrame.minY,
                           width: rect.width,
                           height: rect.height)
        return CGRect(x: (local.minX * s.width).rounded(.down),
                      y: (local.minY * s.height).rounded(.down),
                      width: (local.width * s.width).rounded(.up),
                      height: (local.height * s.height).rounded(.up))
    }

    /// 该屏位图的像素坐标 → 全局点坐标。
    public static func globalRect(fromPixel rect: CGRect, in frame: DisplayFrame) -> CGRect {
        let s = frame.captureScale
        guard s.width > 0, s.height > 0 else { return .zero }
        return CGRect(x: frame.screenFrame.minX + rect.minX / s.width,
                      y: frame.screenFrame.minY + rect.minY / s.height,
                      width: rect.width / s.width,
                      height: rect.height / s.height)
    }

    public static func contains(_ point: CGPoint, in frame: DisplayFrame) -> Bool {
        frame.screenFrame.contains(point)
    }

    /// 点落在哪块屏。多屏重叠时取面积最小的那块（更具体的屏优先）。
    public static func display(containing point: CGPoint, in frames: [DisplayFrame]) -> DisplayFrame? {
        frames
            .filter { $0.screenFrame.contains(point) }
            .min { $0.screenFrame.width * $0.screenFrame.height < $1.screenFrame.width * $1.screenFrame.height }
    }

    /// CoreGraphics 全局坐标 → Cocoa 全局坐标。
    /// `mainScreenHeight` 传主屏高度（点），即 `NSScreen.screens[0].frame.height`。
    public static func cocoaRect(fromGlobal rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: mainScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    public static func globalRect(fromCocoa rect: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: mainScreenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// 全局坐标点 → Cocoa 全局坐标点。
    public static func cocoaPoint(fromGlobal point: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: mainScreenHeight - point.y)
    }
}
