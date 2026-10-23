import BatonCore
import CoreGraphics
import Foundation
import ImageIO

/// OCR 子进程。JSONL over stdin/stdout，一行一个请求/响应。
///
/// 存在的理由：Vision 的常驻内存留在自己身上（父进程实测一次 +30 MB 且不回落），
/// 它崩了也只崩这一份，父进程重启一次就行。
///
/// 不申请任何 TCC 权限——没有 UI，弹不出授权框，也不需要。
setvbuf(stdout, nil, _IONBF, 0)

/// 等待第一条请求的时长：父进程可能在框选前就预热（见 `CaptureSession`），给足余量。
let firstWaitTimeout: TimeInterval = 60
/// 之后空闲多久退出。队列空即退，不留常驻进程。
let idleTimeout: TimeInterval = 20

var buffer = Data()

/// 读一行 JSON。返回 nil 表示该退出了（EOF / 空闲超时 / 父进程没了）。
@MainActor
func readMessage(timeout: TimeInterval) -> OCRWireRequest? {
    while true {
        if let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.isEmpty { continue }
            // 解析失败直接退出：协议都对不上，继续跑只会让父进程每帧都等超时
            guard let request = try? OCRWire.decode(OCRWireRequest.self, from: Data(line)) else {
                _exit(3)
            }
            return request
        }

        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(timeout * 1000))
        if ready == 0 { return nil }
        if ready < 0 {
            if errno == EINTR { continue }
            return nil
        }

        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        let count = read(STDIN_FILENO, &chunk, chunk.count)
        if count <= 0 { return nil }
        buffer.append(contentsOf: chunk[0..<count])
    }
}

@MainActor
func send(_ response: OCRWireResponse) {
    guard let data = try? OCRWire.encode(response) else { return }
    FileHandle.standardOutput.write(data)
}

let transport = VisionOCRTransport()
var first = true

while true {
    // 父进程被强杀时 getppid 会变成 1，别在这儿当孤儿
    if getppid() == 1 { break }
    guard let request = readMessage(timeout: first ? firstWaitTimeout : idleTimeout) else { break }
    first = false

    switch request.kind {
    case "hello":
        send(OCRWireResponse(id: request.id, kind: "ready"))

    case "ocr":
        guard let base64 = request.bytes,
              let data = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            send(OCRWireResponse(id: request.id, kind: "error", error: "图片解码失败"))
            continue
        }
        do {
            let result = try await transport.recognize(
                OCRRequest(image: image, languages: request.languages)
            )
            send(OCRWireResponse(id: request.id,
                                 kind: "result",
                                 ms: result.milliseconds,
                                 lines: result.lines.map(OCRWireLine.init)))
        } catch {
            send(OCRWireResponse(id: request.id,
                                 kind: "error",
                                 error: error.localizedDescription))
        }

    default:
        send(OCRWireResponse(id: request.id, kind: "error", error: "未知请求 \(request.kind)"))
    }
}
