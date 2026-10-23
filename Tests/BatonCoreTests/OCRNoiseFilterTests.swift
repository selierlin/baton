import CoreGraphics
import Foundation
import XCTest
@testable import BatonCore

final class OCRNoiseFilterTests: XCTestCase {
    func testPureSymbolsAreNoise() {
        for text in [")", "(", "+", "-", "...", "———", "·", "★", " ", ""] {
            XCTAssertTrue(OCRLine.isNoise(text), "「\(text)」应判为噪音")
        }
    }

    func testIconLookingSnippetsAreNoise() {
        // 符号 + 单个字母，是被识别成文字的图标，不是正文。
        XCTAssertTrue(OCRLine.isNoise("#K"))
        XCTAssertTrue(OCRLine.isNoise("·A"))
        XCTAssertTrue(OCRLine.isNoise("|1"))
    }

    func testShortButMeaningfulTextIsKept() {
        // 长度不是判据：单个汉字、两位数都是正文。
        for text in ["用", "是", "13", "OK", "你好", "A1"] {
            XCTAssertFalse(OCRLine.isNoise(text), "「\(text)」应保留")
        }
    }

    func testDashSeparatedNumbersAreKept() {
        XCTAssertFalse(OCRLine.isNoise("10:03"))
        XCTAssertFalse(OCRLine.isNoise("2026-10-18"))
    }

    func testResultFiltersNoiseByDefault() {
        let lines = [
            OCRLine(text: "+", points: []),
            OCRLine(text: "Baton", points: []),
            OCRLine(text: "...", points: []),
            OCRLine(text: "工具", points: []),
        ]
        let result = OCRResult(lines: lines, milliseconds: 10)
        XCTAssertEqual(result.lines.map(\.text), ["Baton", "工具"])
        XCTAssertEqual(result.text, "Baton\n工具")
    }

    func testRawResultCanOptOut() {
        let lines = [OCRLine(text: "+", points: []), OCRLine(text: "Baton", points: [])]
        let result = OCRResult(lines: lines, milliseconds: 10, filterNoise: false)
        XCTAssertEqual(result.lines.count, 2)
    }

    func testAllNoiseYieldsEmptyResult() {
        let result = OCRResult(lines: [OCRLine(text: ")", points: []),
                               OCRLine(text: "—", points: [])],
                               milliseconds: 5)
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.text, "")
    }
}
