import AppKit

/// 录制时钉在选区外侧的边框。
///
/// 和标注用的覆盖层是两回事：这里没有冻结帧、不压暗、不吃鼠标——
/// 录制期间用户要能正常操作框里框外的东西，屏幕也必须是实时画面。
///
/// 关键约束：**这个窗不能被录进去**。做法不是隐藏它，而是在
/// `SCContentFilter` 里把 Baton 自己整个排除（见 `ScreenRecorder.makeFilter`），
/// 用户可以看见边框，成片里没有。
@MainActor
public final class RecordingFrame: NSPanel {
    private let borderLayer = CAShapeLayer()
    private let badgeLayer = CATextLayer()

    /// `globalRect` 是 CG 全局显示坐标（左上原点）。
    public init(globalRect: CGRect, mainScreenHeight: CGFloat) {
        // 留 1pt 余量给 2pt 线的外扩，不然边框右侧会被窗口裁掉一半
        let padded = globalRect.insetBy(dx: -2, dy: -2)
        let cocoa = CGRect(x: padded.minX,
                           y: mainScreenHeight - padded.maxY,
                           width: padded.width,
                           height: padded.height)

        super.init(contentRect: cocoa,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true          // 录的时候别挡着用户点选区里的东西
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: CGRect(origin: .zero, size: cocoa.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        borderLayer.frame = container.bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.systemRed.cgColor
        borderLayer.lineWidth = 2
        // 贴着选区画：路径内缩 1pt，2pt 线刚好压在边界上
        let rect = container.bounds.insetBy(dx: 1, dy: 1)
        borderLayer.path = CGPath(rect: rect, transform: nil)
        container.layer?.addSublayer(borderLayer)

        // 左上角钉一个 REC 角标，一眼能看出「这块正在录」
        let badgeWidth: CGFloat = 44
        badgeLayer.frame = CGRect(x: 6, y: container.bounds.height - 22, width: badgeWidth, height: 16)
        badgeLayer.string = "REC"
        badgeLayer.font = NSFont.boldSystemFont(ofSize: 10)
        badgeLayer.fontSize = 10
        badgeLayer.alignmentMode = .center
        badgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        badgeLayer.foregroundColor = NSColor.white.cgColor
        badgeLayer.backgroundColor = NSColor.systemRed.cgColor
        badgeLayer.cornerRadius = 3
        badgeLayer.isHidden = container.bounds.height < 60 || container.bounds.width < 80
        container.layer?.addSublayer(badgeLayer)

        contentView = container
    }
}
