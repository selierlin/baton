import AppKit
import CoreGraphics
import Vision

/// 工具条「更多」菜单里那些一次性动作：打开、隔空投送、QR 解码、保存并复制。
///
/// 这些动作都不改动标注文档，也不结束标注会话，所以独立成一个小工具，
/// 原地标注和弹窗标注两边共用同一份实现。
@MainActor
enum AnnotateExport {
    /// 复制到剪贴板。
    static func copy(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }

    /// 用系统默认看图程序打开。先落一份临时 PNG，避免往相册/下载目录塞文件。
    static func open(_ image: CGImage) {
        guard let url = tempPNG(image) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 隔空投送。
    static func airDrop(_ image: CGImage) {
        guard let url = tempPNG(image),
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: [url]) else { return }
        service.perform(withItems: [url])
    }

    /// QR 解码。图可能很大，放后台跑，回调回主线程。
    static func decodeQR(_ image: CGImage, completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
            DispatchQueue.main.async { completion(payloads) }
        }
    }

    /// 把解码结果摆到用户面前：有内容就给出「复制」和（是链接时的）「打开」。
    static func presentQRResult(_ payloads: [String], attachedTo window: NSWindow?) {
        guard let first = payloads.first else {
            let alert = NSAlert()
            alert.messageText = "没有识别到二维码"
            alert.informativeText = "选区里没有可解码的二维码或条码。"
            alert.addButton(withTitle: "好")
            _ = run(alert, on: window)
            return
        }

        let alert = NSAlert()
        alert.messageText = payloads.count > 1 ? "识别到 \(payloads.count) 个二维码" : "识别到二维码"
        alert.informativeText = first
        alert.addButton(withTitle: "复制内容")
        let link = URL(string: first).flatMap { $0.scheme == nil ? nil : $0 }
        if link != nil { alert.addButton(withTitle: "打开链接") }
        alert.addButton(withTitle: "好")

        let response = run(alert, on: window)
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(payloads.joined(separator: "\n"), forType: .string)
        case .alertSecondButtonReturn where link != nil:
            if let link { NSWorkspace.shared.open(link) }
        default:
            break
        }
    }

    // MARK: - 内部

    /// 覆盖层是 statusBar 级（25）的面板，比普通模态层还高，
    /// 交给 `ModalAlert` 按覆盖层的层级弹，不会被遮住。
    /// 这里用同步版：入口是覆盖层上的按钮，调用时 Baton 已经是前台 + key window，
    /// 不存在「菜单会话还没收尾」的问题。
    private static func run(_ alert: NSAlert, on window: NSWindow?) -> NSApplication.ModalResponse {
        ModalAlert.runInline(alert, name: "annotate.export", above: window)
    }

    private static func tempPNG(_ image: CGImage) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Baton", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("Baton-\(formatter.string(from: Date())).png")

        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
