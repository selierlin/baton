import CoreGraphics
import XCTest
@testable import BatonCore

final class CaptureGeometryTests: XCTestCase {
    private let retina = DisplayFrame(displayID: 1,
                                      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      pixelSize: CGSize(width: 2880, height: 1800),
                                      nativeScale: 2)

    func testCaptureScaleIsTwo() {
        XCTAssertEqual(retina.captureScale.width, 2, accuracy: 0.0001)
        XCTAssertEqual(retina.captureScale.height, 2, accuracy: 0.0001)
    }

    func testGlobalToPixel() {
        let rect = CaptureGeometry.pixelRect(forGlobal: CGRect(x: 100, y: 200, width: 50, height: 30),
                                             in: retina)
        XCTAssertEqual(rect, CGRect(x: 200, y: 400, width: 100, height: 60))
    }

    func testPixelToGlobalRoundTrip() {
        let global = CGRect(x: 120, y: 330, width: 44, height: 22)
        let pixel = CaptureGeometry.pixelRect(forGlobal: global, in: retina)
        let back = CaptureGeometry.globalRect(fromPixel: pixel, in: retina)
        XCTAssertEqual(back.origin.x, global.origin.x, accuracy: 0.0001)
        XCTAssertEqual(back.origin.y, global.origin.y, accuracy: 0.0001)
        XCTAssertEqual(back.width, global.width, accuracy: 0.0001)
        XCTAssertEqual(back.height, global.height, accuracy: 0.0001)
    }

    /// 副屏降采样到 0.5x 时，换算必须用 captureScale（=1），不能用 nativeScale（=2）。
    func testDownsampledDisplayUsesCaptureScale() {
        let downsampled = DisplayFrame(displayID: 2,
                                       screenFrame: CGRect(x: 1440, y: 0, width: 1440, height: 900),
                                       pixelSize: CGSize(width: 1440, height: 900),
                                       nativeScale: 2)
        let rect = CaptureGeometry.pixelRect(forGlobal: CGRect(x: 1540, y: 100, width: 100, height: 50),
                                             in: downsampled)
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 100, height: 50))
    }

    func testDisplayContainingPointOnSecondScreen() {
        let second = DisplayFrame(displayID: 2,
                                  screenFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
                                  pixelSize: CGSize(width: 3840, height: 2160),
                                  nativeScale: 2)
        let found = CaptureGeometry.display(containing: CGPoint(x: 2000, y: 500),
                                            in: [retina, second])
        XCTAssertEqual(found?.displayID, 2)
    }

    func testCocoaRectConversion() {
        // 主屏高 900；CG 上方 y=0..100 的条，在 Cocoa 里是 y=800..900
        let cocoa = CaptureGeometry.cocoaRect(fromGlobal: CGRect(x: 0, y: 0, width: 1440, height: 100),
                                              mainScreenHeight: 900)
        XCTAssertEqual(cocoa, CGRect(x: 0, y: 800, width: 1440, height: 100))
    }
}

final class TriggerDeduplicatorTests: XCTestCase {
    private let combo = KeyCombo(keyCode: 40, modifiers: 0)

    func testTapIsDroppedRightAfterCarbon() {
        var dedup = TriggerDeduplicator(window: 0.06)
        XCTAssertTrue(dedup.shouldFire(combo, source: .carbon, now: 0))
        XCTAssertFalse(dedup.shouldFire(combo, source: .eventTap, now: 0.02))
        XCTAssertTrue(dedup.shouldFire(combo, source: .eventTap, now: 0.1))
    }

    func testRapidDoublePressIsNotSuppressed() {
        var dedup = TriggerDeduplicator(window: 0.06)
        XCTAssertTrue(dedup.shouldFire(combo, source: .carbon, now: 0))
        XCTAssertTrue(dedup.shouldFire(combo, source: .carbon, now: 0.01))
    }

    func testTapAloneAlwaysFires() {
        var dedup = TriggerDeduplicator(window: 0.06)
        XCTAssertTrue(dedup.shouldFire(combo, source: .eventTap, now: 0))
        XCTAssertTrue(dedup.shouldFire(combo, source: .eventTap, now: 0.01))
    }

    func testDifferentComboIsNotSuppressed() {
        var dedup = TriggerDeduplicator(window: 0.06)
        let other = KeyCombo(keyCode: 41, modifiers: 0)
        XCTAssertTrue(dedup.shouldFire(combo, source: .carbon, now: 0))
        XCTAssertTrue(dedup.shouldFire(other, source: .eventTap, now: 0.01))
    }
}
