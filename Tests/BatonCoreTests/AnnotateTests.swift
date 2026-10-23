import CoreGraphics
import XCTest
@testable import BatonCore

final class AnnotateModelTests: XCTestCase {
    private let style = AnnotateStyle(color: .red, lineWidth: 4, opacity: 1, fontSize: 20, mosaicBlock: 8)

    func testUndoRedoRestoresSnapshots() {
        let doc = AnnotateDocument()
        let first = Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 50)), style: style)
        let second = Annotation(kind: .ellipse(CGRect(x: 20, y: 20, width: 30, height: 30)), style: style)

        doc.add(first)
        doc.add(second)
        XCTAssertEqual(doc.annotations.count, 2)
        XCTAssertTrue(doc.canUndo)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertEqual(doc.annotations.first?.id, first.id)

        XCTAssertTrue(doc.undo())
        XCTAssertTrue(doc.annotations.isEmpty)
        XCTAssertFalse(doc.canUndo)

        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.annotations.count, 1)
        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.annotations.count, 2)
        XCTAssertFalse(doc.canRedo)
    }

    func testNewEditClearsRedoStack() {
        let doc = AnnotateDocument()
        doc.add(Annotation(kind: .line(start: .zero, end: CGPoint(x: 10, y: 10)), style: style))
        doc.undo()
        XCTAssertTrue(doc.canRedo)
        doc.add(Annotation(kind: .line(start: .zero, end: CGPoint(x: 5, y: 5)), style: style))
        XCTAssertFalse(doc.canRedo)
    }

    func testUndoStackIsCapped() {
        let doc = AnnotateDocument()
        for index in 0..<130 {
            doc.add(Annotation(kind: .line(start: .zero, end: CGPoint(x: index, y: index)), style: style))
        }
        var undos = 0
        while doc.undo() { undos += 1 }
        XCTAssertEqual(undos, 100, "撤销栈应封顶在 100 步")
    }

    func testRemoveDropsSelection() {
        let doc = AnnotateDocument()
        let annotation = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), style: style)
        doc.add(annotation)
        XCTAssertEqual(doc.selection, annotation.id)
        doc.remove(id: annotation.id)
        XCTAssertNil(doc.selection)
        XCTAssertTrue(doc.annotations.isEmpty)
        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.annotations.count, 1, "删除也要能撤销")
    }

    func testNextCounterSkipsUsedNumbers() {
        let doc = AnnotateDocument()
        XCTAssertEqual(doc.nextCounterNumber, 1)
        doc.add(Annotation(kind: .counter(center: .zero, number: 1), style: style))
        doc.add(Annotation(kind: .counter(center: .zero, number: 2), style: style))
        XCTAssertEqual(doc.nextCounterNumber, 3)

        // 删中间那个，编号不回收，避免新旧序号撞号
        let middle = doc.annotations[1].id
        doc.remove(id: middle)
        XCTAssertEqual(doc.nextCounterNumber, 2, "最大号还在，只回退到最大号 + 1")
    }

    func testHitTestPrefersTopmostAnnotation() {
        let doc = AnnotateDocument()
        let bottom = Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)), style: style)
        let top = Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20)), style: style)
        doc.add(bottom)
        doc.add(top)

        XCTAssertEqual(doc.hitTest(CGPoint(x: 15, y: 15)), top.id)
        XCTAssertEqual(doc.hitTest(CGPoint(x: 80, y: 80)), bottom.id)
        XCTAssertNil(doc.hitTest(CGPoint(x: 300, y: 300)))
    }

    func testOffsetMovesEveryKind() {
        let doc = AnnotateDocument()
        doc.add(Annotation(kind: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 10, y: 10)), style: style))
        doc.add(Annotation(kind: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)), style: style))
        doc.add(Annotation(kind: .stroke(points: [CGPoint(x: 1, y: 2)]), style: style))
        doc.add(Annotation(kind: .counter(center: CGPoint(x: 5, y: 5), number: 1), style: style))

        for var annotation in doc.annotations {
            let before = annotation.bounds
            annotation.offsetBy(dx: 10, dy: 20)
            XCTAssertEqual(annotation.bounds.minX, before.minX + 10, accuracy: 0.001)
            XCTAssertEqual(annotation.bounds.minY, before.minY + 20, accuracy: 0.001)
        }
    }

    func testDocumentRoundTripsThroughJSON() throws {
        let doc = AnnotateDocument()
        doc.add(Annotation(kind: .text(origin: CGPoint(x: 12, y: 34), string: "标注"), style: style))
        doc.add(Annotation(kind: .arrow(start: .zero, end: CGPoint(x: 40, y: 50), sinkTail: true), style: style))

        let data = try JSONEncoder().encode(doc.annotations)
        let decoded = try JSONDecoder().decode([Annotation].self, from: data)
        XCTAssertEqual(decoded, doc.annotations)
    }
}

final class AnnotateRendererTests: XCTestCase {
    private let style = AnnotateStyle(color: .red, lineWidth: 6, opacity: 1, fontSize: 24, mosaicBlock: 16)

    // MARK: - 工具

    private func makeBase(width: Int = 120, height: Int = 120) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &buffer, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func pixel(_ buffer: [UInt8], width: Int, x: Int, y: Int) -> (Int, Int, Int) {
        let index = (y * width + x) * 4
        return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]))
    }

    // MARK: - 渲染

    func testRectangleStrokeLandsOnExpectedPixels() throws {
        let base = makeBase()
        let annotation = Annotation(kind: .rectangle(CGRect(x: 20, y: 20, width: 60, height: 40)), style: style)
        let output = try XCTUnwrap(AnnotateRenderer.flatten(base: base, annotations: [annotation]))

        let buffer = pixels(output)
        let onEdge = pixel(buffer, width: output.width, x: 50, y: 20)
        XCTAssertGreaterThan(onEdge.0, 180, "上边线应被画成红色")
        XCTAssertLessThan(onEdge.1, 120)

        let inside = pixel(buffer, width: output.width, x: 50, y: 40)
        XCTAssertEqual(inside.0, 255, "矩形只有描边，内部应还是白色")
        XCTAssertEqual(inside.2, 255)
    }

    func testFlattenKeepsBaseSize() throws {
        let base = makeBase(width: 200, height: 90)
        let output = try XCTUnwrap(AnnotateRenderer.flatten(
            base: base,
            annotations: [Annotation(kind: .line(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 90)), style: style)]))
        XCTAssertEqual(output.width, 200)
        XCTAssertEqual(output.height, 90)
    }

    func testNoAnnotationsReturnsBaseUntouched() {
        let base = makeBase()
        XCTAssertTrue(AnnotateRenderer.flatten(base: base, annotations: []) === base)
    }

    func testMosaicChangesRegionOnly() throws {
        // 底图切成黑白棋盘，马赛克后格子应被抹平
        let size = 120
        let context = CGContext(data: nil, width: size, height: size,
                                bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: size, by: 4) {
            for x in stride(from: 0, to: size, by: 4) {
                let dark = ((x / 4) + (y / 4)) % 2 == 0
                context.setFillColor(dark ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let base = context.makeImage()!

        var mosaicStyle = style
        mosaicStyle.mosaicBlock = 24
        let annotation = Annotation(kind: .mosaic(CGRect(x: 20, y: 20, width: 60, height: 60)),
                                    style: mosaicStyle)
        let output = try XCTUnwrap(AnnotateRenderer.flatten(base: base, annotations: [annotation]))
        let buffer = pixels(output)

        // 马赛克区域内相邻像素应接近（棋盘被平均成灰）；区域外仍是纯黑/纯白
        let inside = pixel(buffer, width: output.width, x: 40, y: 40)
        XCTAssertGreaterThan(inside.0, 20)
        XCTAssertLessThan(inside.0, 240)

        let outside = pixel(buffer, width: output.width, x: 4, y: 4)
        XCTAssertTrue(outside.0 < 10 || outside.0 > 245, "区域外不应被马赛克影响")
    }

    func testCounterDrawsFilledCircle() throws {
        let base = makeBase()
        let annotation = Annotation(kind: .counter(center: CGPoint(x: 60, y: 60), number: 1), style: style)
        let output = try XCTUnwrap(AnnotateRenderer.flatten(base: base, annotations: [annotation]))
        let buffer = pixels(output)

        // 圆内靠边缘处（避开白色数字）应是标注色
        let radius = AnnotateRenderer.counterRadius(style: style)
        let probe = Int(radius * 0.6)
        let edge = pixel(buffer, width: output.width, x: 60 - probe, y: 60)
        XCTAssertGreaterThan(edge.0, 150)
        XCTAssertLessThan(edge.1, 140)
    }

    /// 一位数和两位数都应该跟圆心对齐——字形左右边距不对称，靠字形包围盒才算得准。
    func testCounterNumberIsCenteredForEveryDigitCount() throws {
        for number in [1, 7, 12, 38] {
            try assertCounterCentered(number: number)
        }
    }

    private func assertCounterCentered(number: Int) throws {
        let base = makeBase()
        let center = CGPoint(x: 60, y: 60)
        let annotation = Annotation(kind: .counter(center: center, number: number), style: style)
        let output = try XCTUnwrap(AnnotateRenderer.flatten(base: base, annotations: [annotation]))
        let buffer = pixels(output)
        let radius = AnnotateRenderer.counterRadius(style: style)

        // 只看圆内 0.7r 的白色字形，避开白色描边
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var count = 0
        let limit = Int(radius * 0.7)
        for y in (60 - limit)...(60 + limit) {
            for x in (60 - limit)...(60 + limit) {
                let dx = Double(x - 60), dy = Double(y - 60)
                guard dx * dx + dy * dy <= Double(limit * limit) else { continue }
                let color = pixel(buffer, width: output.width, x: x, y: y)
                guard color.0 > 230, color.1 > 230, color.2 > 230 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(count, 15, "数字 \(number) 应画在圆内")

        let midX = Double(minX + maxX) / 2
        let midY = Double(minY + maxY) / 2
        XCTAssertEqual(midX, 60, accuracy: 1.2, "数字 \(number) 的墨迹应水平居中，实际 \(midX)")
        XCTAssertEqual(midY, 60, accuracy: 1.2, "数字 \(number) 的墨迹应垂直居中，实际 \(midY)")
    }

    func testTextSizeGrowsWithFontSize() {
        var small = style
        small.fontSize = 12
        var large = style
        large.fontSize = 48
        let smallSize = AnnotateRenderer.textSize("Hello 世界", style: small)
        let largeSize = AnnotateRenderer.textSize("Hello 世界", style: large)
        XCTAssertGreaterThan(smallSize.width, 0)
        XCTAssertGreaterThan(largeSize.width, smallSize.width)
        XCTAssertGreaterThan(largeSize.height, smallSize.height)
    }

    func testTextIsRendered() throws {
        let base = makeBase()
        let annotation = Annotation(kind: .text(origin: CGPoint(x: 10, y: 40), string: "AB"),
                                    style: AnnotateStyle(color: .black, lineWidth: 2, fontSize: 40))
        let output = try XCTUnwrap(AnnotateRenderer.flatten(base: base, annotations: [annotation]))
        let buffer = pixels(output)

        // 文字区内出现深色像素即视为画上了
        var darkCount = 0
        for y in 40..<80 {
            for x in 10..<70 where pixel(buffer, width: output.width, x: x, y: y).0 < 100 {
                darkCount += 1
            }
        }
        XCTAssertGreaterThan(darkCount, 20)
    }
}

@MainActor
final class AnnotateCanvasMappingTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// 视图点是「逻辑点」，标注是「图片像素」，两者差一个倍率。
    /// 这条以前漏了，导致 2x 截图上画的图形放大一倍。
    func testViewPointsConvertToImagePixels() {
        let canvas = AnnotateCanvasView(image: makeImage(width: 200, height: 100),
                                        style: AnnotateStyle())
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 200)

        let point = canvas.imagePoint(CGPoint(x: 100, y: 50))
        XCTAssertEqual(point.x, 50, accuracy: 0.001)
        XCTAssertEqual(point.y, 25, accuracy: 0.001)
    }

    func testRetinaScaleHalvesTheDrag() {
        let canvas = AnnotateCanvasView(image: makeImage(width: 800, height: 600),
                                        style: AnnotateStyle())
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        // 2x 图：屏幕上拖 10pt = 图里 20px
        let point = canvas.imagePoint(CGPoint(x: 10, y: 10))
        XCTAssertEqual(point.x, 20, accuracy: 0.001)
        XCTAssertEqual(point.y, 20, accuracy: 0.001)
    }
}

@MainActor
final class AnnotateBarLayoutTests: XCTestCase {
    func testBarMatchesLongshotGeometry() {
        let bar = AnnotateBarView()
        let size = bar.preferredSize

        // 8 个工具格 + 1 个分隔条 + 8 个动作格（撤销/长截图/OCR/更多/
        // 取消/贴图/存储/复制），无内边距。录屏按钮已删，比 Longshot 的 624 少一格
        let expected = AnnotateBarView.padding * 2
            + CGFloat(AnnotateBarView.groups.count) * AnnotateBarView.itemSize
            + AnnotateBarView.separatorWidth
            + 8 * AnnotateBarView.itemSize
        XCTAssertEqual(size.width, expected, accuracy: 0.5)
        XCTAssertEqual(size.height, 35, "Longshot 的工具条高 35pt")

        let property = AnnotatePropertyBarView()
        let propertySize = property.preferredSize
        // 7 个色板 + 分隔条 + 粗细滑杆
        XCTAssertGreaterThan(propertySize.width, 300, "属性条放不下色板和滑杆")
        XCTAssertEqual(propertySize.height, AnnotateBarView.height)
    }

    func testToolGroupsCoverEveryPairableTool() {
        // 每个工具都必须能在工具条上找到入口，否则切到子项后按钮会指错主项
        let groups = AnnotateBarView.groups
        let covered = Set(groups.flatMap { $0 })
        for tool in AnnotateTool.allCases where tool != .select {
            XCTAssertTrue(covered.contains(tool), "\(tool) 没有入口")
        }
        XCTAssertEqual(groups.count, 8)
    }

    func testGroupsMatchLongshotVariantOrder() {
        // 照 snipToolbarItemsRawValue 的「主项|子项…」拆开
        XCTAssertEqual(AnnotateBarView.groups[0], [.rectangle, .ellipse])
        XCTAssertEqual(AnnotateBarView.groups[2], [.mosaic, .mosaicEllipse, .mosaicPencil])
        XCTAssertEqual(AnnotateBarView.groups[3], [.marker, .markerEllipse, .markerPencil])
        XCTAssertEqual(AnnotateBarView.groups[4], [.ruler, .length, .area, .colorPick])
        XCTAssertEqual(AnnotateBarView.groups[5], [.pencil, .markerPen])
        XCTAssertEqual(AnnotateBarView.groups[6], [.text, .labelText])
        XCTAssertEqual(AnnotateBarView.groups[7], [.counter])
    }

    func testBarRemembersLastVariantAcrossInstances() {
        let defaults = UserDefaults.standard
        let key = "annotate.lastVariants"
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let first = AnnotateBarView()
        first.refresh(tool: .sinkArrow, canUndo: false, canRedo: false)

        // 新一次截图会新建工具条，第二个格子应当还是上次选的内凹箭头
        let second = AnnotateBarView()
        XCTAssertEqual(second.lastVariants[1], .sinkArrow)
    }

    func testArrowGroupMatchesLongshotOrder() {
        // Longshot: 第二个格子是「线条」组，默认落在第一项「直线」上（工具条上是一根斜线图标）
        XCTAssertEqual(AnnotateBarView.groups[1], [.line, .flatArrow, .sinkArrow])
        XCTAssertEqual(AnnotateBarView.defaultTool(for: 1), .line)
        XCTAssertEqual(AnnotateBarView.defaultTool(for: 0), .rectangle)
    }
}
