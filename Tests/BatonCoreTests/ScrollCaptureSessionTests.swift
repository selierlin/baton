import XCTest
@testable import BatonCore

/// 端到端拼接：用一张「虚拟长页面」裁出连续两帧，验证接完的图与原始长页一致。
@MainActor
final class ScrollCaptureSessionTests: XCTestCase {
    private func makePage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        // 每一行一个可辨认的颜色，纵向无周期。
        // 别用 `y * k % 251` 这种写法：模数一固定就出现 251 行的重复周期，
        // 位移哪怕差一整个周期也能凑出低误差，正好把「滚太快接不上」的用例测成假阳性。
        for y in 0..<height {
            var x = UInt32(truncatingIfNeeded: y) &* 2_654_435_761
            x ^= x >> 15
            x = x &* 2_246_822_519
            x ^= x >> 13
            let value = UInt8(x & 0xFF)
            context.setFillColor(CGColor(srgbRed: CGFloat(value) / 255,
                                         green: CGFloat((Int(value) * 3) % 255) / 255,
                                         blue: CGFloat((Int(value) * 7) % 255) / 255,
                                         alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return context.makeImage()
    }

    /// 整行着色：`values` 里第 i 个元素就是图像第 i 行（从顶部数）。
    /// CGContext 原点在左下，所以这里翻一下，让「行号」和测试里的写法一致。
    private func makeRows(width: Int, values: [UInt8]) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: values.count,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        for (y, value) in values.enumerated() {
            context.setFillColor(CGColor(srgbRed: CGFloat(value) / 255,
                                         green: CGFloat((Int(value) * 3) % 255) / 255,
                                         blue: CGFloat((Int(value) * 7) % 255) / 255,
                                         alpha: 1))
            context.fill(CGRect(x: 0, y: values.count - 1 - y, width: width, height: 1))
        }
        return context.makeImage()
    }

    private func rowValue(_ y: Int) -> UInt8 {
        var x = UInt32(truncatingIfNeeded: y) &* 2_654_435_761
        x ^= x >> 15
        x = x &* 2_246_822_519
        x ^= x >> 13
        return UInt8(x & 0xFF)
    }

    private func crop(_ image: CGImage, y: Int, height: Int) -> CGImage? {
        image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height))
    }

    func testStitchesTwoFrames() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 1000))
        let first = try XCTUnwrap(crop(page, y: 0, height: 400))
        let second = try XCTUnwrap(crop(page, y: 100, height: 400))

        let session = try XCTUnwrap(ScrollCaptureSession(first: first))
        XCTAssertEqual(session.totalHeight, 400)

        let result = session.append(second)
        XCTAssertTrue(result.advanced)
        XCTAssertEqual(result.offset, 100)
        XCTAssertEqual(result.totalHeight, 500)

        let stitched = try XCTUnwrap(session.image())
        XCTAssertEqual(stitched.width, 120)
        XCTAssertEqual(stitched.height, 500)
    }

    func testUnchangedFrameIsRejected() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 1000))
        let first = try XCTUnwrap(crop(page, y: 0, height: 400))
        let session = try XCTUnwrap(ScrollCaptureSession(first: first))

        let result = session.append(first)
        XCTAssertFalse(result.advanced)
        XCTAssertEqual(session.totalHeight, 400)
    }

    func testIncludesEveryRowOfNewContent() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 1000))
        let first = try XCTUnwrap(crop(page, y: 0, height: 400))
        let second = try XCTUnwrap(crop(page, y: 100, height: 400))

        let session = try XCTUnwrap(ScrollCaptureSession(first: first))
        _ = session.append(second)

        // 追加区域的最后一行，应当就是当前帧的最后一行（新内容没有丢）
        let stitched = try XCTUnwrap(session.image())
        XCTAssertEqual(stitched.height, 500)
        XCTAssertEqual(second.height, 400)
    }

    /// 连续滚很多次：高度必须严格等于「首帧 + 累计位移」。
    /// 单次拼接对不代表连续拼对——误差会累积，重影也是几次之后才看得出来。
    func testTenAppendsAccumulateExactly() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 2000))
        let session = try XCTUnwrap(ScrollCaptureSession(first: try XCTUnwrap(crop(page, y: 0, height: 400))))

        var top = 0
        for _ in 0..<10 {
            top += 60
            let result = session.append(try XCTUnwrap(crop(page, y: top, height: 400)))
            XCTAssertTrue(result.advanced, "第 \(top)px 应判定为前进")
            XCTAssertEqual(result.offset, 60)
        }
        XCTAssertEqual(session.totalHeight, 400 + 10 * 60)
        XCTAssertEqual(try XCTUnwrap(session.image()).height, session.totalHeight)
    }

    /// 单帧滚过 70% 高度仍要能接上。
    ///
    /// 实测反馈「滚了但长图停在一屏」：旧搜索窗只有 0.6×高度，而 500ms 内
    /// 滚一屏（平滑滚动还会把手速堆积起来）轻松超过，匹配直接返回 nil。
    func testLargeScrollPerFrameStillMatches() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 1200))
        let first = try XCTUnwrap(crop(page, y: 0, height: 400))
        let second = try XCTUnwrap(crop(page, y: 280, height: 400))

        let session = try XCTUnwrap(ScrollCaptureSession(first: first))
        let result = session.append(second)
        XCTAssertTrue(result.advanced, "0.7 屏位移应该能匹配上")
        XCTAssertEqual(result.offset, 280)
        XCTAssertEqual(result.totalHeight, 680)
    }

    /// 单帧滚过 85% 高度：超出 0.75 屏的能力边界，必须判「没接上」，不能硬拼。
    ///
    /// 曾经试过宽窗兜底（模板压到 1/12、搜索放到 11/12 屏），代价是重叠区只剩 8%：
    /// 行距一致的文字、等高卡片足以让窄带在错误位置凑出近零误差，产出整段错位内容。
    /// 现在的策略是——超速就认，留断点标记，宁可缺也不给错图。
    func testOverSpeedFrameIsRejectedAndMarkedAsGap() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 2000))
        let first = try XCTUnwrap(crop(page, y: 0, height: 400))
        let second = try XCTUnwrap(crop(page, y: 340, height: 400))

        let session = try XCTUnwrap(ScrollCaptureSession(first: first))
        // 连续 3 帧都接不上才认账换基线
        for _ in 0..<3 {
            let miss = session.append(second)
            XCTAssertFalse(miss.advanced, "0.85 屏位移不该被硬拼成一段错位内容")
        }
        XCTAssertTrue(session.hasGap)
        XCTAssertEqual(session.gapMarks, [400], "断点应记在换基线时的累计高度上")

        // 换基线之后接着滚，追加的才是真内容
        let third = try XCTUnwrap(crop(page, y: 400, height: 400))
        let result = session.append(third)
        XCTAssertTrue(result.advanced)
        XCTAssertEqual(result.offset, 60)
        XCTAssertEqual(session.totalHeight, 460)

        // 有断点时出图仍要成功，尺寸不变（标记是叠加，不额外占高度）
        let image = try XCTUnwrap(session.image())
        XCTAssertEqual(image.height, 460)
    }

    /// 位移大到两帧完全没重叠时，不能瞎编一个偏移量，也不能悄悄换基线。
    ///
    /// 正确行为：先留着旧基线重试，连续几帧都接不上才认账换基线，
    /// 并把「中间有缺口」记下来，让 HUD 提醒用户。
    func testHugeJumpKeepsBaselineThenFlagsGap() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 2400))
        let first = try XCTUnwrap(crop(page, y: 0, height: 400))
        let session = try XCTUnwrap(ScrollCaptureSession(first: first))

        // 跳到 1400：与首帧毫无重叠
        let jumped = try XCTUnwrap(crop(page, y: 1400, height: 400))
        for _ in 0..<3 {
            let miss = session.append(jumped)
            XCTAssertFalse(miss.advanced)
            XCTAssertEqual(session.totalHeight, 400, "接不上时不能凭空加高度")
        }
        XCTAssertTrue(session.hasGap, "连续接不上应标记缺口")

        // 基线已换到 1400 那一帧，再滚 56（降采样步长 4 的整数倍）应正常接上
        let result = session.append(try XCTUnwrap(crop(page, y: 1456, height: 400)))
        XCTAssertTrue(result.advanced)
        XCTAssertEqual(result.offset, 56)
        XCTAssertEqual(session.totalHeight, 456)
    }

    /// 窄带凑巧对上、整区对不上：必须拒掉，不能把错位的一段接进去。
    ///
    /// 实测「44 行之后冒出 35 行乱码，然后从 40 行接下去」就是这个形状：
    /// 网页里行距一致的文字、等高卡片能让模板那一条窄带在错误位置上误差接近零，
    /// 但整个重叠区是错位的；接上去长图中段就是一坨乱码。
    func testNarrowBandCoincidenceIsRejected() throws {
        let previousRows = (0..<400).map { rowValue($0) }
        // 当前帧：上下都是无关内容，中间 100 行恰好等于上一帧底部模板带
        let currentRows = (0..<200).map { rowValue($0 + 10_000) }
            + Array(previousRows[300..<400])
            + (0..<100).map { rowValue($0 + 20_000) }

        let previous = try XCTUnwrap(makeRows(width: 120, values: previousRows))
        let current = try XCTUnwrap(makeRows(width: 120, values: currentRows))

        let grayPrevious = try XCTUnwrap(FrameStitcher.grayscale(previous))
        let grayCurrent = try XCTUnwrap(FrameStitcher.grayscale(current))
        XCTAssertNil(FrameStitcher.verticalOffset(previous: grayPrevious, current: grayCurrent),
                     "整区错位、只有窄带对上的匹配不能认")

        let session = try XCTUnwrap(ScrollCaptureSession(first: previous))
        XCTAssertFalse(session.append(current).advanced)
        XCTAssertEqual(session.totalHeight, 400)
    }

    /// 往回滚再往下滚：长图不能重复追加已截过的内容。
    ///
    /// 实测「上下快速滚动后出现数字行交叉」：旧实现把回滚的帧当「接不上」，
    /// 几帧后换基线，再往下滚时追加的整条都是重复内容。
    func testScrollBackDoesNotDuplicateRows() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 2400))
        let session = try XCTUnwrap(ScrollCaptureSession(first: try XCTUnwrap(crop(page, y: 0, height: 400))))
        XCTAssertEqual(session.totalHeight, 400)

        let forward = session.append(try XCTUnwrap(crop(page, y: 100, height: 400)))
        XCTAssertTrue(forward.advanced)
        XCTAssertEqual(session.totalHeight, 500)

        // 往回滚到 40：只该标记回滚，不该加高度
        let back = session.append(try XCTUnwrap(crop(page, y: 40, height: 400)))
        XCTAssertFalse(back.advanced)
        XCTAssertTrue(back.retreated, "往回滚要能识别出来")
        XCTAssertEqual(session.totalHeight, 500, "回滚不能加高度")
        XCTAssertFalse(session.hasGap, "回滚不是缺口")
        XCTAssertTrue(session.isWaitingForForward)

        // 再往下滚到 180：相对基线（100）前进 80，只追加 500~580 这段新内容
        let resumed = session.append(try XCTUnwrap(crop(page, y: 180, height: 400)))
        XCTAssertTrue(resumed.advanced)
        XCTAssertEqual(resumed.offset, 80)
        XCTAssertEqual(session.totalHeight, 580, "重复追加的话这里会多出几百行")
        XCTAssertFalse(session.isWaitingForForward)
    }

    func testStationaryFramesAreRecognised() throws {
        let page = try XCTUnwrap(makePage(width: 120, height: 800))
        let frame = try XCTUnwrap(crop(page, y: 100, height: 400))
        let gray = try XCTUnwrap(FrameStitcher.grayscale(frame))
        XCTAssertTrue(FrameStitcher.isStationary(previous: gray, current: gray))
        XCTAssertNil(FrameStitcher.verticalOffset(previous: gray, current: gray))
    }

    /// 到高度上限必须停下来：调用方靠 `reachedLimit` 收工，否则 12000px 的位图会一直往上吃。
    func testReachesHeightLimit() throws {
        let height = ScrollCaptureSession.maxHeight + 1000
        let page = try XCTUnwrap(makePage(width: 60, height: height))
        let session = try XCTUnwrap(ScrollCaptureSession(first: try XCTUnwrap(crop(page, y: 0, height: 400))))

        var top = 0
        var hit = false
        while top + 800 < height {
            top += 120
            if session.append(try XCTUnwrap(crop(page, y: top, height: 400))).reachedLimit {
                hit = true
                break
            }
        }
        XCTAssertTrue(hit, "超过上限应报 reachedLimit")
        XCTAssertLessThanOrEqual(session.totalHeight, ScrollCaptureSession.maxHeight)
    }
}

/// 方向回归：长图必须正立（第一行是页面最上面那行）。
@MainActor
final class ScrollCaptureOrientationTests: XCTestCase {
    private func makePage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        for y in 0..<height {
            let value = UInt8((y * 37 + 11) % 251)
            context.setFillColor(CGColor(srgbRed: CGFloat(value) / 255,
                                         green: CGFloat((Int(value) * 3) % 255) / 255,
                                         blue: CGFloat((Int(value) * 7) % 255) / 255,
                                         alpha: 1))
            // CGContext 是左下原点，y=0 是最下面一行；这里想按「页面行号」上色，
            // 就翻过来填，保证 makeImage 出来的第 0 行就是 y=0 的颜色。
            context.fill(CGRect(x: 0, y: height - 1 - y, width: width, height: 1))
        }
        return context.makeImage()
    }

    /// buffer 第一行对应图像最上面一行。
    private func rowColors(_ image: CGImage) -> [(r: Int, g: Int, b: Int)] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return []
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // BGRA
        return (0..<height).map { row in
            let base = row * width * 4
            return (Int(bytes[base + 2]), Int(bytes[base + 1]), Int(bytes[base]))
        }
    }

    func testStitchedImageIsNotFlipped() throws {
        let page = try XCTUnwrap(makePage(width: 40, height: 600))
        let first = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 0, width: 40, height: 300)))
        let second = try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: 80, width: 40, height: 300)))

        let session = try XCTUnwrap(ScrollCaptureSession(first: first))
        let appended = session.append(second)
        XCTAssertTrue(appended.advanced)
        let stitched = try XCTUnwrap(session.image())
        XCTAssertEqual(stitched.height, 380)

        let expected = rowColors(page)
        let actual = rowColors(stitched)
        XCTAssertEqual(actual.count, 380)
        for row in stride(from: 0, to: 380, by: 20) {
            XCTAssertEqual(actual[row].r, expected[row].r, "第 \(row) 行颜色不对，长图方向错了")
            XCTAssertEqual(actual[row].g, expected[row].g)
            XCTAssertEqual(actual[row].b, expected[row].b)
        }
    }
}
