import XCTest
@testable import BatonCore

final class ColorTextTests: XCTestCase {
    func testShortHexExpands() {
        XCTAssertEqual(ColorText.hex(from: "#fff"), "#FFFFFF")
        XCTAssertEqual(ColorText.hex(from: "#0af"), "#00AAFF")
    }

    func testLongHexIsUppercased() {
        XCTAssertEqual(ColorText.hex(from: "#3399e6"), "#3399E6")
        XCTAssertEqual(ColorText.hex(from: "  #3399E6\n"), "#3399E6")
    }

    func testAlphaIsDropped() {
        XCTAssertEqual(ColorText.hex(from: "#3399E680"), "#3399E6")
        XCTAssertEqual(ColorText.hex(from: "#f008"), "#FF0000")
    }

    func testRGBValues() {
        XCTAssertEqual(ColorText.hex(from: "rgb(51, 153, 230)"), "#3399E6")
        XCTAssertEqual(ColorText.hex(from: "RGB(51 153 230 / 0.5)"), "#3399E6")
        XCTAssertEqual(ColorText.hex(from: "rgba(51,153,230,0.8)"), "#3399E6")
        XCTAssertEqual(ColorText.hex(from: "rgb(20%, 60%, 90%)"), "#3399E6")
    }

    func testHSLValues() {
        XCTAssertEqual(ColorText.hex(from: "hsl(210, 62%, 55%)"), "#458CD3")
        XCTAssertEqual(ColorText.hex(from: "hsla(210deg 62% 55% / 0.3)"), "#458CD3")
        XCTAssertEqual(ColorText.hex(from: "hsl(0, 0%, 100%)"), "#FFFFFF")
        XCTAssertEqual(ColorText.hex(from: "hsl(120, 100%, 50%)"), "#00FF00")
        XCTAssertEqual(ColorText.hex(from: "hsl(240, 100%, 50%)"), "#0000FF")
    }

    /// 只有「整段就是一个颜色值」才认：正文里顺带出现色值不算，
    /// 否则一段技术笔记会被整个塞进颜色分类。
    func testRejectsNonPureValues() {
        XCTAssertNil(ColorText.hex(from: ""))
        XCTAssertNil(ColorText.hex(from: "fff"))
        XCTAssertNil(ColorText.hex(from: "color: #fff;"))
        XCTAssertNil(ColorText.hex(from: "#fff 是这个色"))
        XCTAssertNil(ColorText.hex(from: "hex #3399E6"))
        XCTAssertNil(ColorText.hex(from: "51, 153, 230"))
        XCTAssertNil(ColorText.hex(from: "rgb(51, 153)"))
        XCTAssertNil(ColorText.hex(from: "rgb(300, 0, 0)"))
        XCTAssertNil(ColorText.hex(from: "hsl(210, 62, 55)"))
        XCTAssertNil(ColorText.hex(from: "#3399E"))
        XCTAssertNil(ColorText.hex(from: "#3399E6Z"))
    }
}
