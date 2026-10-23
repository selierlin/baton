import CoreGraphics
import XCTest
@testable import BatonCore

final class RulerMetricsTests: XCTestCase {
    func testSizeTextKeepsPixelsAndPointsSeparate() {
        // 2x 屏：800×600 像素 = 400×300 点
        XCTAssertEqual(RulerMetrics.sizeText(width: 800, height: 600,
                                             scale: CGSize(width: 2, height: 2)),
                       "800 × 600 px   400 × 300 pt")
    }

    func testSizeTextOmitsPointsOnOneToOneScreen() {
        XCTAssertEqual(RulerMetrics.sizeText(width: 1440, height: 900,
                                             scale: CGSize(width: 1, height: 1)),
                       "1440 × 900 px")
    }

    func testHexIsUppercaseAndPadded() {
        XCTAssertEqual(RulerMetrics.hex(red: 0, green: 10, blue: 255), "#000AFF")
        XCTAssertEqual(RulerMetrics.hex(red: 0x3A, green: 0x7B, blue: 0xD5), "#3A7BD5")
    }

    func testShiftLocksSquareToTheLargerDelta() {
        // |dy| > |dx|：横向撑到 |dy|，纵向不动
        let wide = RulerMetrics.squareLocked(anchor: CGPoint(x: 10, y: 10),
                                             point: CGPoint(x: 30, y: 50))
        XCTAssertEqual(wide, CGPoint(x: 50, y: 50))

        // |dx| > |dy|：纵向撑到 |dx|
        let tall = RulerMetrics.squareLocked(anchor: CGPoint(x: 10, y: 10),
                                             point: CGPoint(x: 80, y: 30))
        XCTAssertEqual(tall, CGPoint(x: 80, y: 80))

        // 向左上拖时方向不能翻
        let flipped = RulerMetrics.squareLocked(anchor: CGPoint(x: 100, y: 100),
                                                point: CGPoint(x: 70, y: 40))
        XCTAssertEqual(flipped, CGPoint(x: 40, y: 40))
    }

    func testRectNormalizesDraggedCorners() {
        let rect = RulerMetrics.rect(from: CGPoint(x: 90, y: 80), to: CGPoint(x: 30, y: 20))
        XCTAssertEqual(rect, CGRect(x: 30, y: 20, width: 60, height: 60))
    }

    func testPixelRectIsIntegralAndScaled() {
        let rect = CGRect(x: 10.4, y: 20.6, width: 30.2, height: 40.1)
        let pixel = RulerMetrics.pixelRect(rect, scale: CGSize(width: 2, height: 2))
        // 20.8→20、41.2→41 向下取整，81.2→82、121.4→122 向上取整
        XCTAssertEqual(pixel, CGRect(x: 20, y: 41, width: 62, height: 81))
    }
}

final class RulerUnitTests: XCTestCase {
    private let scale = CGSize(width: 2, height: 2)

    /// 800×600 像素 @2x = 400×300 pt = 14.1×10.6 cm ≈ 5.6×4.2 inch
    func testSizeTextPerUnit() {
        XCTAssertEqual(RulerMetrics.sizeText(width: 800, height: 600, scale: scale, unit: .pixel),
                       "800 × 600 px   400 × 300 pt")
        XCTAssertEqual(RulerMetrics.sizeText(width: 800, height: 600, scale: scale, unit: .point),
                       "400 × 300 pt")
        XCTAssertEqual(RulerMetrics.sizeText(width: 800, height: 600, scale: scale, unit: .centimeter),
                       "14.1 × 10.6 cm")
        XCTAssertEqual(RulerMetrics.sizeText(width: 800, height: 600, scale: scale, unit: .inch),
                       "5.6 × 4.2 in")
    }

    /// 换算必须可逆，否则「按 72pt 输入尺寸」这类后续功能会越算越偏
    func testValueAndPixelsRoundTrip() {
        for unit in RulerUnit.allCases {
            let pixels = unit.pixels(from: 10, pixelsPerPoint: 2)
            XCTAssertEqual(unit.value(pixels: pixels, pixelsPerPoint: 2), 10, accuracy: 0.0001,
                           "\(unit) 往返丢了精度")
        }
    }

    func testPointUnitEqualsPixelsOverScale() {
        XCTAssertEqual(RulerMetricPoint(1000, 2), 500)
    }

    private func RulerMetricPoint(_ pixels: Double, _ scale: Double) -> Double {
        RulerUnit.point.value(pixels: pixels, pixelsPerPoint: scale)
    }

    func testColorTextFormats() {
        XCTAssertEqual(RulerMetrics.colorText(red: 0x3A, green: 0x7B, blue: 0xD5, format: .hex),
                       "#3A7BD5")
        XCTAssertEqual(RulerMetrics.colorText(red: 58, green: 123, blue: 213, format: .rgb),
                       "rgb(58, 123, 213)")
        // 3A7BD5 → h=214.8°、s=64.8%、l=53.1%，四舍五入到 215/65/53
        XCTAssertEqual(RulerMetrics.colorText(red: 0x3A, green: 0x7B, blue: 0xD5, format: .hsl),
                       "hsl(215, 65%, 53%)")
    }

    func testHSLOfGrayscaleHasNoHue() {
        let (h, s, l) = RulerMetrics.hsl(red: 128, green: 128, blue: 128)
        XCTAssertEqual(h, 0)
        XCTAssertEqual(s, 0, accuracy: 0.0001)
        XCTAssertEqual(l, 128.0 / 255.0, accuracy: 0.0001)
    }

    func testAngleIsDegreesBetweenRays() {
        let vertex = CGPoint(x: 100, y: 100)
        XCTAssertEqual(RulerMetrics.degrees(from: CGPoint(x: 200, y: 100),
                                            vertex: vertex,
                                            to: CGPoint(x: 100, y: 0)), 90, accuracy: 0.001)
        XCTAssertEqual(RulerMetrics.degrees(from: CGPoint(x: 200, y: 100),
                                            vertex: vertex,
                                            to: CGPoint(x: 0, y: 100)), 180, accuracy: 0.001)
        // 顶点与射线重合时不能除零
        XCTAssertEqual(RulerMetrics.degrees(from: vertex, vertex: vertex, to: vertex), 0)
        XCTAssertEqual(RulerMetrics.angleText(45), "45.0°")
    }

    func testAxisLockKeepsOneDirection() {
        let anchor = CGPoint(x: 10, y: 20)
        XCTAssertEqual(RulerMetrics.axisLocked(anchor: anchor, point: CGPoint(x: 90, y: 77),
                                               horizontal: true),
                       CGPoint(x: 90, y: 20))
        XCTAssertEqual(RulerMetrics.axisLocked(anchor: anchor, point: CGPoint(x: 90, y: 77),
                                               horizontal: false),
                       CGPoint(x: 10, y: 77))
    }
}

@MainActor
final class RulerSettingsStoreTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-ruler-\(UUID().uuidString).json")
    }

    func testDefaultsAndPersistence() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = RulerSettingsStore(url: url)
        XCTAssertEqual(store.settings.unit, .pixel)
        XCTAssertTrue(store.settings.snapEnabled)

        store.update { settings in
            settings.unit = .centimeter
            settings.colorFormat = .hsl
            settings.snapEnabled = false
            settings.accent = .blue
            settings.lineWidth = 3
        }

        let reopened = RulerSettingsStore(url: url)
        XCTAssertEqual(reopened.settings.unit, .centimeter)
        XCTAssertEqual(reopened.settings.colorFormat, .hsl)
        XCTAssertFalse(reopened.settings.snapEnabled)
        XCTAssertEqual(reopened.settings.accent, .blue)
        XCTAssertEqual(reopened.settings.lineWidth, 3)
    }

    func testLineWidthIsClamped() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RulerSettingsStore(url: url)
        store.update { $0.lineWidth = 99 }
        XCTAssertEqual(store.settings.lineWidth, RulerSettings.maxLineWidth)
        store.update { $0.lineWidth = 0 }
        XCTAssertEqual(store.settings.lineWidth, RulerSettings.minLineWidth)
    }

    func testObserversFireOnRealChangesOnly() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RulerSettingsStore(url: url)
        var received = 0
        store.addObserver { _ in received += 1 }

        store.update { $0.unit = .point }
        XCTAssertEqual(received, 1)
        // 值没变就不该通知（设置页滑杆连续回调会刷屏）
        store.update { $0.unit = .point }
        XCTAssertEqual(received, 1)
    }

    /// 老配置缺字段时不能整份失效
    func testDecodeToleratesMissingFields() throws {
        let json = #"{"unit":"inch"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RulerSettings.self, from: json)
        XCTAssertEqual(decoded.unit, .inch)
        XCTAssertEqual(decoded.colorFormat, .hex)
        XCTAssertTrue(decoded.snapEnabled)
        XCTAssertEqual(decoded.lineWidth, 1)
    }
}
