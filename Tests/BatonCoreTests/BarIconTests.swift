import AppKit
import XCTest
@testable import BatonCore

/// 工具条位图资源。
///
/// 这里守的是最容易静默坏掉的一环：图标放在 SwiftPM 的 resource bundle 里，
/// 一旦 `Package.swift` 的声明、`make-app.sh` 的拷贝路径、`BarIcon` 的查找
/// 三者有一处对不上，图标不会报错，只是**悄悄退回手绘**——视觉上像是没生效。
final class BarIconTests: XCTestCase {

    /// 所有声明了资源的 glyph。新增映射时记得加进来。
    private let assets: [(LongshotGlyph, String)] = [
        (.square, "bar_square_drawBorder"),
        (.ellipse, "bar_ellipse_drawBorder"),
        (.line, "bar_line"),
        (.sinkArrow, "bar_sinkArrow"),
        (.mosaicSquare, "bar_mosaicSquare"),
        (.mosaicEllipse, "bar_mosaicEllipse"),
        (.mosaicPencil, "bar_mosaicPencil"),
        (.highlightSquare, "bar_highlightSquare"),
        (.highlightEllipse, "bar_highlightEllipse"),
        (.highlightPencil, "bar_highlightPencil"),
        (.ruler, "bar_labelRuler"),
        (.length, "bar_labelLength"),
        (.area, "bar_labelArea"),
        (.colorCircle, "bar_colorCircle"),
        (.markerPen, "bar_markerPen_square"),
        (.textMark, "bar_textMark"),
        (.labelText, "bar_labelText"),
        (.counter, "bar_counter"),
        (.undo, "bar_undo"),
        (.redo, "bar_redo"),
        (.ocr, "bar_ocr"),
        (.pin, "bar_pin"),
        (.open, "bar_open"),
        (.download, "bar_download"),
    ]

    func testEveryMappedGlyphHasItsAsset() {
        for (glyph, expected) in assets {
            XCTAssertEqual(glyph.assetName, expected, "\(glyph) 的资源名对不上")
        }
    }

    /// 资源能取到、且画出来不是一张全透明的空图。
    func testEveryAssetRendersVisiblePixels() {
        for (glyph, asset) in assets {
            guard let image = BarIcon.image(asset: asset, size: 18, color: .black) else {
                XCTFail("\(asset) 加载失败，会静默退回手绘")
                continue
            }
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), "\(asset) 画布尺寸不对")

            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            NSGraphicsContext.restoreGraphicsState()

            var opaque = 0
            for y in 0..<18 {
                for x in 0..<18 {
                    if let px = rep.colorAt(x: x, y: y), px.alphaComponent > 0.4 {
                        opaque += 1
                    }
                }
            }
            // 一条 45° 细线在 18×18 里只有十几个像素过阈值，下限按最瘦的图标定
            XCTAssertGreaterThan(opaque, 10, "\(asset) 画出来是空的")
        }
    }

    /// Baton 独有的工具没有原厂资源，必须继续走手绘而不是画成空白。
    func testBatonOnlyGlyphsStayHandDrawn() {
        for glyph in [LongshotGlyph.scrollcut, .video, .more, .cancel, .copy, .selector,
                      .flatArrow, .pencil] {
            XCTAssertNil(glyph.assetName, "\(glyph) 不该映射到 Longshot 资源")
            let image = glyph.image(size: 18, color: .black)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        }
    }

    func testUnknownAssetReturnsNil() {
        XCTAssertNil(BarIcon.image(asset: "bar_does_not_exist", size: 18, color: .black))
    }

    /// 染色要真的生效：同一个资源画成红和画成绿，像素得不一样。
    func testColorIsApplied() {
        func sample(_ color: NSColor) -> NSColor? {
            guard let image = BarIcon.image(asset: "bar_square_drawBorder", size: 18, color: color) else {
                return nil
            }
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            NSGraphicsContext.restoreGraphicsState()
            // 找最不透明的那个像素
            var best: NSColor?
            var bestAlpha: CGFloat = 0
            for y in 0..<18 {
                for x in 0..<18 {
                    guard let px = rep.colorAt(x: x, y: y) else { continue }
                    if px.alphaComponent > bestAlpha {
                        bestAlpha = px.alphaComponent
                        best = px.usingColorSpace(.deviceRGB)
                    }
                }
            }
            return best
        }

        guard let red = sample(.red), let green = sample(.green) else {
            return XCTFail("样张加载失败")
        }
        XCTAssertGreaterThan(red.redComponent, green.redComponent, "染色没生效")
        XCTAssertGreaterThan(green.greenComponent, red.greenComponent, "染色没生效")
    }
}
