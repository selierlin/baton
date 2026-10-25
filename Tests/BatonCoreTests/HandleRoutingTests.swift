import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// 选区手柄的事件路由。
///
/// 手柄骑在选区边界上，朝外那半边落在画布外面——画布只覆盖选区，那一圈原本没人
/// 接事件：光标不变、按下被覆盖层宿主吞掉，表现成「角落的手柄有时候拖不动」。
/// 这里钉住「外半边要转给画布」，同时保证工具条这类压在附近的子视图不被抢。
@MainActor
final class HandleRoutingTests: XCTestCase {
    private let mainScreenHeight: CGFloat = 300
    /// 画布在宿主里的位置（左下原点）：选区 = 这块，四角就是它的四个角。
    private let canvasFrame = CGRect(x: 100, y: 80, width: 200, height: 120)

    private var host: OverlayView!
    private var canvas: AnnotateCanvasView!

    /// XCTest 的 `setUp()` 是 nonisolated，而 AppKit 视图的构造在 main actor 上，
    /// 所以每个用例自己建场景。
    private func build() {
        let display = DisplayFrame(displayID: 1,
                                   screenFrame: CGRect(x: 0, y: 0, width: 400, height: 300),
                                   pixelSize: CGSize(width: 800, height: 600),
                                   nativeScale: 2)
        let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let frame = CapturedFrame(image: context.makeImage()!, display: display)

        host = OverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                           captured: frame,
                           mainScreenHeight: mainScreenHeight,
                           mode: .area,
                           probe: nil)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host

        canvas = AnnotateCanvasView(image: frame.image, style: AnnotateStyle())
        canvas.adjustableSelection = true
        canvas.frame = canvasFrame
        host.addSubview(canvas)
        host.annotationCanvas = canvas

        // 全局矩形与 canvasFrame 必须互相对应，换算公式见 localRect(fromGlobal:)
        host.lockSelection(CGRect(x: canvasFrame.minX,
                                  y: mainScreenHeight - canvasFrame.maxY,
                                  width: canvasFrame.width,
                                  height: canvasFrame.height))
    }

    private func hit(at local: CGPoint) -> NSView? {
        guard let parent = host.superview else {
            XCTFail("宿主没有父视图，坐标系无从换算")
            return nil
        }
        return host.hitTest(host.convert(local, to: parent))
    }

    func testInsideCanvasGoesToCanvas() {
        build()
        XCTAssertTrue(hit(at: CGPoint(x: 200, y: 140)) === canvas)
    }

    /// 角手柄朝外那半边：落在画布外，仍然要能按下拖动。
    func testOuterHalfOfCornerHandleGoesToCanvas() {
        build()
        // 左上角在 (100, 200)，往左上 3pt 已经出了画布
        XCTAssertTrue(hit(at: CGPoint(x: 97, y: 203)) === canvas)

        // 右下角 (300, 80)，往右下 4pt
        XCTAssertTrue(hit(at: CGPoint(x: 304, y: 76)) === canvas)

        // 上边中点 (200, 200)，往上 5pt
        XCTAssertTrue(hit(at: CGPoint(x: 200, y: 205)) === canvas)
    }

    func testFarOutsideStaysWithHost() {
        build()
        // 离所有手柄都超过捕捉半径，不该被画布抢走
        XCTAssertTrue(hit(at: CGPoint(x: 60, y: 260)) === host)
        XCTAssertTrue(hit(at: CGPoint(x: 340, y: 40)) === host)
    }

    /// 工具条就贴在选区外侧，不能因为落在环形热区里被画布吃掉。
    func testSubviewsNearHandlesStillWin() {
        build()
        let toolbar = NSView(frame: CGRect(x: 92, y: 192, width: 60, height: 24))
        host.addSubview(toolbar)
        XCTAssertTrue(hit(at: CGPoint(x: 105, y: 200)) === toolbar)
    }

    /// 热区是给「手抖」留的余量，8pt 外仍然要算按住了手柄。
    /// 这条会把旧半径（6pt）钉死：改小就红。
    func testHandleHotspotReachesEightPointsOut() {
        build()
        // 左上角 (100, 200) 往左上 7,5 → 距离 8.6
        XCTAssertTrue(hit(at: CGPoint(x: 93, y: 205)) === canvas)
        // 下边中点 (200, 80) 往下 8
        XCTAssertTrue(hit(at: CGPoint(x: 200, y: 72)) === canvas)
    }

    /// 但热区必须有边界，再远就该归宿主（那里是继续拉选区用的）。
    func testFarOutsideHandleKeepsHost() {
        build()
        let justOutside = SelectionChrome.reach + 2
        XCTAssertTrue(hit(at: CGPoint(x: 200, y: 80 - justOutside)) === host)
        XCTAssertTrue(hit(at: CGPoint(x: 200, y: 200 + justOutside)) === host)
    }

    /// 工具条与选区的间距必须比手柄热区大，否则贴边的手柄会压到工具条上。
    /// `toolbarGap` 是从 `reach` 推出来的，这条钉住推导关系本身。
    func testToolbarGapClearsHandleHotspot() {
        XCTAssertGreaterThan(SelectionChrome.toolbarGap, SelectionChrome.reach)
    }
}
