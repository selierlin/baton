import AppKit
import CoreGraphics
import XCTest
@testable import BatonCore

/// OCR 子进程的 wire 规格与降级判定。
///
/// 真起进程的路径由 `--ocr` 探针验（`swift test` 里没有 `BatonOCR` 可执行文件），
/// 这里只管两件容易写错的事：字段名/坐标顺序，以及「没有子进程时会不会自动退回进程内」。
final class OCRSubprocessTests: XCTestCase {
    func testRequestRoundTripKeepsPayloadAndLanguages() throws {
        let request = OCRWireRequest.ocr(id: "abc", pngBase64: "iVBORw0KGgo=",
                                         languages: ["zh-Hans", "en-US"])
        let data = try OCRWire.encode(request)
        XCTAssertTrue(data.last == 0x0A, "JSONL 必须以换行结尾，否则子进程会一直等")
        let decoded = try OCRWire.decode(OCRWireRequest.self, from: data.dropLast())
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.kind, "ocr")
        XCTAssertFalse(decoded.autoDetect)
    }

    func testHelloCarriesNoImage() throws {
        let request = OCRWireRequest.hello(id: "1")
        let decoded = try OCRWire.decode(OCRWireRequest.self,
                                         from: try OCRWire.encode(request).dropLast())
        XCTAssertEqual(decoded.kind, "hello")
        XCTAssertNil(decoded.bytes)
        XCTAssertTrue(decoded.languages.isEmpty)
    }

    func testResponsePreservesLeftTopPixelCoordinates() throws {
        // 顺序固定为 左上 → 右上 → 右下 → 左下；父进程直接拿它画框，不能重排。
        let wire = OCRWireResponse(id: "x", kind: "result", ms: 12, lines: [
            OCRWireLine(text: "Baton", points: [
                OCRWirePoint(x: 109, y: 13),
                OCRWirePoint(x: 189, y: 13),
                OCRWirePoint(x: 189, y: 38),
                OCRWirePoint(x: 109, y: 38),
            ]),
        ])
        let decoded = try OCRWire.decode(OCRWireResponse.self,
                                         from: try OCRWire.encode(wire).dropLast())
        let line = try XCTUnwrap(decoded.ocrLines.first)
        XCTAssertEqual(line.text, "Baton")
        XCTAssertEqual(line.points.first, CGPoint(x: 109, y: 13))
        XCTAssertEqual(line.boundingRect, CGRect(x: 109, y: 13, width: 80, height: 25))
        XCTAssertEqual(decoded.count, 1)
    }

    func testTransportWithoutHelperFallsBackToInProcess() {
        let transport = SubprocessOCRTransport()
        let worker = OCRWorker(helperURL: nil)
        XCTAssertFalse(worker.usesSubprocess)
        XCTAssertFalse(worker.isDegraded)
        // 打包后的 App 里应该有子进程；单测环境没有，走进程内
        XCTAssertEqual(transport.usesSubprocess, OCRWorker.locateHelper() != nil)
    }

    func testWorkerWithHelperPathStaysOnSubprocessUntilItFails() {
        let worker = OCRWorker(helperURL: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertTrue(worker.usesSubprocess)
        XCTAssertFalse(worker.isDegraded)
    }
}
