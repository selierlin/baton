import AppKit
import AVFoundation
import BatonCore
import Foundation
import ImageIO

setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
let shell = AppShell()
let args = Array(CommandLine.arguments.dropFirst())

/// 探针需要强引用，否则控制器出了作用域就被回收
var probeAnnotator: AnnotateWindowController?
var probeRuler: RulerController?
var probePins: PinController?
var probePreview: RecordingPreviewWindow?
var probeCapture: CaptureSession?



/// 用真鼠标事件拖一次（探针用）：从 `frame` 中心出发，按 `delta` 挪。
///
/// 合成 `NSEvent` 只能验「我们的计算对不对」，验不了「AppKit 到底把
/// mouseDragged 送到谁手上」——后者才是贴图拖拽这类 bug 的高发区。
func simulateDrag(over frame: CGRect, by delta: CGSize) {
    guard let screen = NSScreen.main else { return }
    // CGEvent 用屏幕全局坐标（左上原点），Cocoa 是左下原点
    let start = CGPoint(x: frame.midX, y: screen.frame.height - frame.midY)
    let end = CGPoint(x: start.x + delta.width, y: start.y - delta.height)
    CGWarpMouseCursorPosition(start)
    usleep(80_000)
    // 只负责投递，处理交给事件循环：这里转 run loop 也捞不到这些事件，
    // 调用方要留足时间再读 frame
    postMouse(.leftMouseDown, at: start)
    for step in 1...8 {
        let t = CGFloat(step) / 8
        postMouse(.leftMouseDragged, at: CGPoint(x: start.x + delta.width * t,
                                                 y: start.y - delta.height * t))
        usleep(20_000)
    }
    postMouse(.leftMouseUp, at: end)
}

func postMouse(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

/// 贴图探针用的假图：几条色带 + 对角线，够看清「标注画在哪、工具条盖没盖住内容」。
func probePinImage(width: Int = 1200, height: Int = 760) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let colors = [CGColor(srgbRed: 0.95, green: 0.35, blue: 0.3, alpha: 1),
                  CGColor(srgbRed: 0.98, green: 0.7, blue: 0.2, alpha: 1),
                  CGColor(srgbRed: 0.25, green: 0.7, blue: 0.45, alpha: 1),
                  CGColor(srgbRed: 0.2, green: 0.5, blue: 0.95, alpha: 1)]
    for (index, color) in colors.enumerated() {
        context.setFillColor(color)
        context.fill(CGRect(x: 60, y: 60 + index * 150, width: 700, height: 110))
    }
    context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
    context.setLineWidth(6)
    context.move(to: CGPoint(x: 800, y: 60))
    context.addLine(to: CGPoint(x: 1140, y: 700))
    context.strokePath()
    return context.makeImage()!
}

func loadCGImage(_ path: String) -> CGImage? {
    guard let nsImage = NSImage(contentsOfFile: path) else { return nil }
    var rect = CGRect(origin: .zero, size: nsImage.size)
    return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

/// 录屏探针共用的目标解析：`--record` 只验管线，`--record-ui` 走完整控制条。
/// 第三个返回值是录制时要画边框的区域（整屏为 nil）。
@MainActor
func probeRecordingConfig(mode: String, out: String,
                          extra: String?,
                          microphone: Bool = false) -> (RecordingConfig, RecordingTarget, CGRect?)? {
    let url = URL(fileURLWithPath: out)
    switch mode {
    case "full":
        return (RecordingConfig(target: .fullScreen, displayID: CGMainDisplayID(), url: url,
                                capturesMicrophone: microphone),
                .fullScreen, nil)
    case "window":
        let windowID = extra.flatMap(Int.init)
            ?? WindowPicker.enumerate(excludingPID: getpid()).first?.windowID
        guard let windowID else { print("没有候选窗口，先跑 --window-list"); return nil }
        print("window id=\(windowID)")
        let bounds = WindowPicker.enumerate(excludingPID: getpid())
            .first(where: { $0.windowID == windowID })?.bounds
        return (RecordingConfig(target: .window, displayID: CGMainDisplayID(),
                                windowID: windowID, url: url,
                                capturesMicrophone: microphone), .window, bounds)
    case "app":
        let pid = extra.flatMap { Int32($0) }
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid else { print("没有前台应用"); return nil }
        print("app pid=\(pid)")
        let windows = WindowPicker.enumerate(excludingPID: getpid()).filter { $0.ownerPID == pid }
        var union = windows.first?.bounds
        for window in windows.dropFirst() { union = union?.union(window.bounds) ?? window.bounds }
        return (RecordingConfig(target: .application, displayID: CGMainDisplayID(),
                                ownerPID: pid, url: url,
                                capturesMicrophone: microphone), .application, union)
    case "area":
        let full = CGDisplayBounds(CGMainDisplayID())
        let rect = CGRect(x: full.midX - 320, y: full.midY - 200, width: 640, height: 400)
        return (RecordingConfig(target: .area, rect: rect, displayID: CGMainDisplayID(), url: url,
                                capturesMicrophone: microphone),
                .area, rect)
    default:
        print("未知模式 \(mode)")
        return nil
    }
}

switch args.first {
case "--login-status":
    print("bundle=\(Bundle.main.bundlePath)")
    print("id=\(Bundle.main.bundleIdentifier ?? "nil")")
    let status = shell.loginItem.status
    print("status=\(status.rawValue) enabled=\(status.enabled) approval=\(status.requiresApproval) — \(status.detail)")
    exit(0)

case "--login-enable", "--login-disable":
    let enable = args[0] == "--login-enable"
    do {
        let status = try shell.loginItem.setEnabled(enable)
        print("ok status=\(status.rawValue) — \(status.detail)")
        exit(0)
    } catch {
        let ns = error as NSError
        print("failed domain=\(ns.domain) code=\(ns.code) — \(ns.localizedDescription)")
        exit(1)
    }

case "--input-sources":
    MainActor.assumeIsolated {
        let catalog = InputSourceCatalog()
        print("current: \(catalog.currentName ?? "nil") [\(catalog.currentID ?? "-")]")
        for source in catalog.all {
            let mark = source.isCurrent ? "*" : " "
            let kind = source.isASCIICapable ? "layout" : "ime"
            print("\(mark) \(source.id)  \(kind)  \(source.name)")
        }
    }
    exit(0)

case "--input-switch":
    guard args.count > 1 else {
        print("usage: Baton --input-switch <input-source-id>")
        exit(2)
    }
    MainActor.assumeIsolated {
        let catalog = InputSourceCatalog()
        let before = catalog.currentID ?? "-"
        let ok = catalog.select(id: args[1])
        print("from=\(before) to=\(catalog.currentID ?? "-") changed=\(ok)")
    }
    exit(0)

case "--browser-focus":
    // 冒烟：焦点在地址栏 / 网页输入框时各跑一次，确认分类对了
    MainActor.assumeIsolated {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            print("没有前台 App")
            exit(1)
        }
        let focus = BrowserFocusReader.focus(pid: front.processIdentifier)
        print("front=\(front.localizedName ?? "-") [\(front.bundleIdentifier ?? "-")] "
              + "supported=\(BrowserFocusReader.isSupported(front.bundleIdentifier)) "
              + "focus=\(focus) trusted=\(AXIsProcessTrusted())")
    }
    exit(0)

case "--clip-panel":
    shell.start()
    shell.openClipboardPanel()
    // 冒烟：给布局与首响应者 1.5s 暴露崩溃，然后自己退出
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exit(0) }
    app.run()

case "--prefs":
    shell.start()
    // 冒烟用：直接落到指定页，省得用 UI scripting 点菜单栏
    shell.openPreferences(tab: args.count > 1 ? (Int(args[1]) ?? 0) : 0)
    app.run()

case "--scroll-status":
    MainActor.assumeIsolated {
        let smoother = ScrollSmoother(store: try? SmoothScrollStore())
        let s = smoother.settings
        print("enabled=\(s.enabled) pointsPerLine=\(s.pointsPerLine) duration=\(s.duration) maxPending=\(s.maxPending)")
        for kind in PermissionKind.allCases {
            print("perm \(kind.rawValue)=\(PermissionCenter.status(kind).rawValue)")
        }
    }
    exit(0)

case "--perm-status":
    for kind in PermissionKind.allCases {
        print("\(kind.rawValue)=\(PermissionCenter.status(kind).rawValue)")
    }
    exit(0)

case "--perm-request":
    guard args.count > 1, let kind = PermissionKind(rawValue: args[1]) else {
        print("usage: Baton --perm-request accessibility|screenRecording|listenEvent")
        exit(2)
    }
    print("before=\(PermissionCenter.status(kind).rawValue)")
    MainActor.assumeIsolated { PermissionCenter.request(kind) }
    print("after=\(PermissionCenter.status(kind).rawValue)")
    exit(0)

case "--capture-suite":
    // 截图态场景自动跑测：框选 + 原地标注，真窗口 + 真鼠标事件。
    // 不真抓屏（终端里 SCK 拿不到共享内容），用自绘冻结帧铺满主屏。
    freopen("/tmp/baton-capture-suite.log", "w", stdout)
    Task { @MainActor in
        let code = await runCaptureSuite()
        exit(code)
    }
    app.run()

case "--pin-suite":
    // 贴图场景自动跑测：真窗口 + 真鼠标事件，逐条断言并打 PASS/FAIL。
    // 退出码非 0 表示有用例挂了，方便脚本里卡住。
    freopen("/tmp/baton-pin-suite.log", "w", stdout)
    Task { @MainActor in
        let code = await runPinSuite()
        exit(code)
    }
    app.run()

case "--pin-probe":
    // 贴图标注联调：钉一张测试图 → 缩放 + 空格 → 全屏截一张，确认图还在、工具条落在哪。
    // 走真 store：落库后内存原图会被丢掉，显示改走 blob，这条路径才是线上那条。
    freopen("/tmp/baton-pin.log", "w", stdout)
    Task { @MainActor in
        let storeDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-pin-probe-store", isDirectory: true)
        var store: PinStore?
        if let database = try? BatonDatabase(directory: storeDirectory) {
            store = PinStore(clipboard: ClipboardStore(database: database))
        }
        let pins = PinController(store: store)
        let probeWidth = args.count > 1 ? Int(args[1]) ?? 1200 : 1200
        let probeHeight = args.count > 2 ? Int(args[2]) ?? 760 : 760
        pins.pin(probePinImage(width: probeWidth, height: probeHeight), scale: 2)
        print("pinned=\(pins.count) store=\(store != nil) \(pins.debugLastState)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            for _ in 0..<3 { pins.debugSendKeyLast(24) }   // = 放大三次，会跨显示桶
            print("zoomed \(pins.debugLastState)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            pins.debugSendKeyLast(49)                     // 空格调工具条
            print("space-on \(pins.debugLastState) crosshair=\(NSCursor.current === NSCursor.crosshair)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            // 标注态拖一次：这时候拖拽该落在画布上，窗口一寸都不能动
            print("trusted=\(AXIsProcessTrusted()) frame=\(pins.debugLastFrame)")
            fflush(stdout)
            simulateDrag(over: pins.debugLastFrame, by: CGSize(width: 30, height: 30))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            print("drag-while-editing frame=\(pins.debugLastFrame)")
            pins.debugSendKeyLast(49)                     // 收工具条
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            print("space-off \(pins.debugLastState) arrow=\(NSCursor.current === NSCursor.arrow)")
            fflush(stdout)
            simulateDrag(over: pins.debugLastFrame, by: CGSize(width: 40, height: -30))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            print("drag-while-reading frame=\(pins.debugLastFrame)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "/tmp/baton-pin.png"]
            try? shot.run()
            shot.waitUntilExit()
            print("shot=/tmp/baton-pin.png")
            fflush(stdout)
            exit(0)
        }
    }
    app.run()

case "--inplace-probe":
    // 原地标注联调：锁定一块固定区域，挂上编辑器，截一张全屏图确认位置
    freopen("/tmp/baton-inplace.log", "w", stdout)
    print("stage=boot")
    let rect = CGRect(x: 220, y: 180,
                      width: args.count > 2 ? CGFloat(Double(args[1]) ?? 700) : 700,
                      height: args.count > 2 ? CGFloat(Double(args[2]) ?? 460) : 460)
    Task { @MainActor in
        print("stage=task")
        let session = CaptureSession()
        let outcome = await session.begin(intent: .fixed(rect), action: .edit)
        print("stage=captured \(outcome)")
        guard case .captured(let result) = outcome else { exit(1) }
        let pins = PinController()
        let editor = InPlaceAnnotator(pinController: pins)
        let ok = editor.present(result: result, overlay: session.overlayController)
        print("present=\(ok) screenRect=\(result.screenRect) pixel=\(result.cropped?.width ?? 0)x\(result.cropped?.height ?? 0)")
        fflush(stdout)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "/tmp/baton-inplace.png"]
            try? shot.run()
            shot.waitUntilExit()
            print("shot=/tmp/baton-inplace.png")
            fflush(stdout)
            exit(0)
        }
    }
    app.run()

case "--ruler":
    shell.start()
    MainActor.assumeIsolated {
        let controller = RulerController()
        controller.onCaptureArea = { image, scale in
            print("capture=\(image.width)x\(image.height) scale=\(scale.width)")
        }
        probeRuler = controller
        Task {
            let outcome = await controller.run()
            print("ruler=\(outcome)")
            exit(0)
        }
    }
    app.run()

case "--annotate":
    guard let path = args.dropFirst().first, let image = loadCGImage(path) else {
        print("usage: Baton --annotate <image-path> [scale]")
        exit(2)
    }
    let scale = args.count > 2 ? CGFloat(Double(args[2]) ?? 2) : 2
    MainActor.assumeIsolated {
        let pins = PinController()
        let controller = AnnotateWindowController(pinController: pins)
        controller.onFinish = { outcome in
            print("outcome=\(outcome)")
            // 贴图后窗口要留下来看效果，其余结局直接退出
            if case .pinned = outcome { return }
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { exit(0) }
        probeAnnotator = controller
        probePins = pins
        controller.show(image: image, scale: scale)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        print("screen.visible=\(screen) window=\(controller.debugFrame)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            print(controller.debugDump())
            exit(0)
        }
    }
    app.run()

case "--pin":
    guard let path = args.dropFirst().first, let image = loadCGImage(path) else {
        print("usage: Baton --pin <image-path> [scale]")
        exit(2)
    }
    let scale = args.count > 2 ? CGFloat(Double(args[2]) ?? 2) : 2
    MainActor.assumeIsolated {
        // 探针用独立库，别污染真实贴图历史
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("baton-pin-probe")
        var store: PinStore?
        if let database = try? BatonDatabase(directory: dir) {
            store = PinStore(clipboard: ClipboardStore(database: database))
        }
        let pins = PinController(store: store)
        probePins = pins
        pins.restore()
        print("restored=\(pins.count)")
        pins.pin(image, scale: scale)
        print("pinned count=\(pins.count)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    app.run()

case "--translate-panel":
    let preview = args.dropFirst().first ?? "Hello, world. 这是一段用来检查排版的中文。"
    MainActor.assumeIsolated {
        let panel = TranslatePanelController()
        panel.show(result: TranslateResult(text: "这是译文预览，用来检查行高、换行和复制按钮位置。长句应当正常折行，不应把面板撑宽。",
                                           providerID: "preview",
                                           milliseconds: 123),
                   source: preview,
                   providerName: "Preview")
        Task {
            try? await Task.sleep(for: .seconds(1))
            print("[frames] \(panel.debugFrames())")
            try? await Task.sleep(for: .seconds(9))
            exit(0)
        }
    }
    app.run()

case "--ocr-config":
    let settings = (try? OCRSettingsStore())?.load() ?? .default
    print("active=\(settings.active?.id ?? "none")")
    for provider in settings.providers {
        let mark = provider.id == settings.activeID ? "*" : " "
        var state = ""
        if provider.kind == .baidu {
            let ak = provider.apiKeyRef.flatMap { KeychainStore.read(account: $0) } != nil
            let sk = provider.secretRef.flatMap { KeychainStore.read(account: $0) } != nil
            state = ak && sk ? "ak/sk=已配置" : "ak/sk=未配置"
        }
        print("\(mark) \(provider.id)  kind=\(provider.kind.rawValue)  \(state)")
    }
    exit(0)

case "--ocr-preset":
    guard let id = args.dropFirst().first else {
        print("usage: Baton --ocr-preset vision|baidu")
        exit(2)
    }
    guard let config: OCRProviderConfig = id == "baidu" ? .baidu : id == "vision" ? .vision : nil else {
        print("usage: Baton --ocr-preset vision|baidu")
        exit(2)
    }
    do {
        let store = try OCRSettingsStore()
        var settings = store.load()
        if let index = settings.providers.firstIndex(where: { $0.id == config.id }) {
            settings.providers[index] = config
        } else {
            settings.providers.append(config)
        }
        settings.activeID = config.id
        try store.save(settings)
        print("ok active=\(config.id)")
        if config.kind == .baidu {
            let ak = KeychainStore.read(account: BaiduOCRCredentials.accessKeyAccount) != nil
            let sk = KeychainStore.read(account: BaiduOCRCredentials.secretKeyAccount) != nil
            print(ak && sk ? "凭据已配置" : "下一步：Baton --ocr-key <API Key> <Secret Key>")
        }
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--ocr-variant":
    guard let raw = args.dropFirst().first else {
        print("usage: Baton --ocr-variant general|general_basic|accurate|accurate_basic")
        print("  带 location 的只有 general / accurate；_basic 只返回文字")
        exit(2)
    }
    guard BaiduOCRTransport.Variant(rawValue: raw) != nil else {
        print("unknown variant: \(raw)")
        exit(2)
    }
    do {
        let store = try OCRSettingsStore()
        var settings = store.load()
        guard let index = settings.providers.firstIndex(where: { $0.kind == .baidu }) else {
            print("还没有添加百度 OCR，先跑 --ocr-preset baidu")
            exit(1)
        }
        settings.providers[index].variant = raw
        try store.save(settings)
        print("ok baidu.variant=\(raw)")
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--ocr-key":
    guard args.count > 2 else {
        print("usage: Baton --ocr-key <API Key> <Secret Key>")
        exit(2)
    }
    do {
        try KeychainStore.save(args[1], account: BaiduOCRCredentials.accessKeyAccount)
        try KeychainStore.save(args[2], account: BaiduOCRCredentials.secretKeyAccount)
        print("ok 百度 OCR AK/SK 已存入 Keychain")
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--ocr":
    guard let path = args.dropFirst().first else {
        print("usage: Baton --ocr <image-path>")
        exit(2)
    }
    guard let nsImage = NSImage(contentsOfFile: path) else {
        print("无法读取图片：\(path)")
        exit(1)
    }
    var rect = CGRect(origin: .zero, size: nsImage.size)
    guard let image = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        print("无法解码图片：\(path)")
        exit(1)
    }
    let ocrSettings = (try? OCRSettingsStore())?.load() ?? .default
    guard let ocrConfig = ocrSettings.active else {
        print("failed 没有配置 OCR 服务")
        exit(1)
    }
    print("image=\(image.width)×\(image.height) provider=\(ocrConfig.id)")
    // `--hold`：识别完不退出，停 15 s 便于外部量常驻内存（子进程/进程内的差就在这里）
    let hold = args.dropFirst().contains("--hold")
    Task {
        do {
            let transport = try OCRTransportFactory.make(ocrConfig)
            if let subprocess = transport as? SubprocessOCRTransport {
                print("transport=\(subprocess.usesSubprocess ? "subprocess" : "in-process")"
                      + (subprocess.isDegraded ? "（子进程已降级）" : ""))
            }
            let result = try await transport.recognize(OCRRequest(image: image))
            print("ok \(result.milliseconds)ms lines=\(result.lines.count)")
            for line in result.lines {
                let box = line.boundingRect
                print(String(format: "  [%.0f,%.0f %.0fx%.0f] %@",
                             box.minX, box.minY, box.width, box.height, line.text))
            }
        } catch {
            print("failed \(error.localizedDescription)")
        }
        if hold {
            print("hold pid=\(ProcessInfo.processInfo.processIdentifier)")
            try? await Task.sleep(for: .seconds(15))
        }
        exit(0)
    }
    RunLoop.main.run()

case "--translate-config":
    let settings = (try? TranslateSettingsStore())?.load() ?? .default
    print("active=\(settings.active?.id ?? "none")")
    for provider in settings.providers {
        let mark = provider.id == settings.activeID ? "*" : " "
        let key = KeychainStore.read(account: provider.apiKeyRef) == nil ? "未配置" : "已配置"
        let endpoint = provider.baseURL?.absoluteString ?? "-"
        print("\(mark) \(provider.id)  kind=\(provider.kind.rawValue)  model=\(provider.model.isEmpty ? "-" : provider.model)")
        print("    url=\(endpoint) appid=\(provider.appID ?? "-") key=\(key)")
    }
    print("target=\(settings.targetLanguage) source=\(settings.sourceLanguage ?? "auto") silent=\(settings.silentMode)")
    print("presets=" + ProviderPreset.all.map(\.id).joined(separator: ",") + ",baidu")
    exit(0)

case "--translate-preset":
    guard let id = args.dropFirst().first,
          let preset = ProviderPreset.all.first(where: { $0.id == id }),
          let config = preset.config() else {
        print("usage: Baton --translate-preset <" + ProviderPreset.all.map(\.id).joined(separator: "|") + ">")
        exit(2)
    }
    do {
        let store = try TranslateSettingsStore()
        var settings = store.load()
        // 同一 id 重复设置时保留已存的 key；覆盖配置但不动 Keychain。
        if let index = settings.providers.firstIndex(where: { $0.id == config.id }) {
            settings.providers[index] = config
        } else {
            settings.providers.append(config)
        }
        settings.activeID = config.id
        try store.save(settings)
        let configured = KeychainStore.read(account: config.apiKeyRef) != nil
        print("ok active=\(config.id) model=\(config.model) key=\(configured ? "已配置" : "未配置")")
        if !configured {
            print("下一步：Baton --translate-key \(config.id) <key>")
        }
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--translate-add":
    // 自定义服务：Baton --translate-add <id> <baseURL> <model> [proxy]
    guard args.count > 3, let url = URL(string: args[2]) else {
        print("usage: Baton --translate-add <id> <baseURL> <model> [proxy]")
        exit(2)
    }
    do {
        let kind: ProviderConfig.Kind = args.count > 4 && args[4] == "proxy" ? .proxy : .openAICompatible
        let config = ProviderConfig(id: args[1],
                                    displayName: args[1],
                                    kind: kind,
                                    baseURL: url,
                                    model: args[3],
                                    apiKeyRef: "provider.\(args[1])")
        let store = try TranslateSettingsStore()
        var settings = store.load()
        if let index = settings.providers.firstIndex(where: { $0.id == config.id }) {
            settings.providers[index] = config
        } else {
            settings.providers.append(config)
        }
        settings.activeID = config.id
        try store.save(settings)
        print("ok active=\(config.id) kind=\(kind.rawValue) url=\(url.absoluteString) model=\(config.model)")
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--translate-baidu":
    // 百度翻译用 appid + 密钥两个值：Baton --translate-baidu <appid>
    guard let appID = args.dropFirst().first, !appID.isEmpty else {
        print("usage: Baton --translate-baidu <appid>")
        exit(2)
    }
    do {
        let config = ProviderConfig(id: "baidu",
                                    displayName: "百度翻译",
                                    kind: .baiduTranslate,
                                    apiKeyRef: "provider.baidu",
                                    appID: appID)
        let store = try TranslateSettingsStore()
        var settings = store.load()
        if let index = settings.providers.firstIndex(where: { $0.id == config.id }) {
            settings.providers[index] = config
        } else {
            settings.providers.append(config)
        }
        settings.activeID = config.id
        try store.save(settings)
        let configured = KeychainStore.read(account: config.apiKeyRef) != nil
        print("ok active=baidu appid=\(appID) key=\(configured ? "已配置" : "未配置")")
        if !configured {
            print("下一步：Baton --translate-key baidu <密钥>")
        }
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--translate-use":
    guard let id = args.dropFirst().first else {
        print("usage: Baton --translate-use <provider-id>")
        exit(2)
    }
    do {
        let store = try TranslateSettingsStore()
        var settings = store.load()
        guard settings.providers.contains(where: { $0.id == id }) else {
            print("没有这个 provider：\(id)，先看 --translate-config")
            exit(1)
        }
        settings.activeID = id
        try store.save(settings)
        print("ok active=\(id)")
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--translate-key":
    guard args.count > 2 else {
        print("usage: Baton --translate-key <provider-id> <key>")
        exit(2)
    }
    do {
        try KeychainStore.save(args[2], account: "provider.\(args[1])")
        print("ok saved provider.\(args[1]) 到 Keychain")
    } catch {
        print("failed \(error.localizedDescription)")
        exit(1)
    }
    exit(0)

case "--translate":
    guard let text = args.dropFirst().first, !text.isEmpty else {
        print("usage: Baton --translate <text>")
        exit(2)
    }
    let settings = (try? TranslateSettingsStore())?.load() ?? .default
    guard let config = settings.active else {
        print("failed 没有配置翻译服务，先跑 --translate-config")
        exit(1)
    }
    print("→ \(config.id) kind=\(config.kind.rawValue) model=\(config.model.isEmpty ? "-" : config.model) \(settings.targetLanguage)")
    Task {
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let provider = try TranslateProviderFactory.make(config)
            let result = try await provider.translate(TranslateRequest(text: text,
                                                                      source: settings.sourceLanguage,
                                                                      target: settings.targetLanguage))
            let total = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            print("ok \(result.milliseconds)ms(api) / \(total)ms(total)")
            print(result.text)
        } catch {
            print("failed \(error.localizedDescription)")
        }
        exit(0)
    }
    RunLoop.main.run()

case "--scroll-smooth":
    guard args.count > 1 else {
        print("usage: Baton --scroll-smooth on|off")
        exit(2)
    }
    MainActor.assumeIsolated {
        let smoother = ScrollSmoother(store: try? SmoothScrollStore())
        smoother.setEnabled(args[1] == "on")
        print("enabled=\(smoother.isEnabled)")
    }
    exit(0)

case "--scroll-watch":
    // 用真实鼠标滚一下，看原始样本：discrete 鼠标应报 continuous=0，触控板报 1
    let seconds = Double(args.dropFirst().first ?? "") ?? 60
    shell.start()
    print("watching \(Int(seconds))s — 现在滚动鼠标滚轮 / 触控板，Ctrl-C 结束")
    Task { @MainActor in
        for await event in shell.hub.events(buffering: 64) {
            guard case .scroll(let sample) = event else { continue }
            let source = sample.sourcePID > 0
                ? (NSRunningApplication(processIdentifier: sample.sourcePID)?.bundleIdentifier
                   ?? NSRunningApplication(processIdentifier: sample.sourcePID)?.localizedName
                   ?? "pid \(sample.sourcePID)")
                : "-"
            print(String(format: "delta=(%6.2f,%6.2f) unit=%@ continuous=%d phase=%ld momentum=%ld count=%ld src=%@",
                         sample.deltaX, sample.deltaY,
                         sample.unit == .lines ? "行" : "像素",
                         sample.isContinuous ? 1 : 0, sample.phase, sample.momentum,
                         sample.scrollCount, source))
            if let decision = shell.smoothScroll?.lastDecision {
                print("  → \(decision)")
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()

case "--scroll-selftest":
    // 自己投 3 次离散滚轮，确认「吞掉 → 插值重放」这条路是通的。
    // 注意：会让光标下的窗口实际滚动几行。
    shell.start()
    print("tap active=\(shell.hub.scrollTapActive) intercept=\(shell.hub.scrollTapIntercepts) "
          + "reason=\(shell.hub.scrollInterceptionUnavailableReason ?? "-")")
    guard shell.hub.scrollTapIntercepts else {
        if shell.smoothScroll?.isEnabled == false {
            print("平滑滚动已关闭，先执行 --scroll-smooth on")
        } else {
            print("无法拦截滚动事件，自测中止（需要「辅助功能」权限）")
        }
        exit(1)
    }
    for i in 0..<3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.15) {
            if let event = CGEvent(scrollWheelEvent2Source: nil,
                                   units: .line,
                                   wheelCount: 1,
                                   wheel1: -3,
                                   wheel2: 0,
                                   wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        let smoother = shell.smoothScroll
        print("swallowed=\(smoother?.swallowedTicks ?? -1) posted=\(smoother?.postedFrames ?? -1)")
        exit(0)
    }
    app.run()

case "--scroll-post":
    // 对照实验：哪种字段组合能让 NSScrollView 真的动起来
    MainActor.assumeIsolated {
        ScrollPostTest.run(variant: args.count > 1 ? args[1] : "plain")
    }
    app.run()

case "--scroll-bench":
    // 量「一格滚轮 → 摊成多少帧」。`raw` 先关掉平滑做基线，`trace` 打印逐帧位移
    MainActor.assumeIsolated {
        ScrollBench.run(notches: 3, spacing: 0.05, trace: args.contains("trace"),
                        raw: args.contains("raw"))
    }
    app.run()

case "--stitch":
    // 固定选区直接跑长截图采集，跳过框选与热键：方便脚本化复现「滚动后没拼上」这类问题。
    // 用法：Baton --stitch <x> <y> <w> <h> [out.png]，另开一个进程投递滚轮。
    guard args.count >= 5,
          let sx = Double(args[1]), let sy = Double(args[2]),
          let sw = Double(args[3]), let sh = Double(args[4]) else {
        print("usage: Baton --stitch <x> <y> <w> <h> [out.png]")
        exit(2)
    }
    Task { @MainActor in
        let rect = CGRect(x: sx, y: sy, width: sw, height: sh)
        let out = args.count >= 6 ? args[5] : "/tmp/baton-stitch.png"
        do {
            let frames = try await ScreenCapturer.captureAll()
            guard let display = CaptureGeometry.display(
                containing: CGPoint(x: rect.midX, y: rect.midY),
                in: frames.map(\.display)
            ) else {
                print("选区不在任何屏幕上")
                exit(1)
            }
            let overlay = OverlayController()
            let controller = ScrollCaptureController(
                selection: CaptureSelection(globalRect: rect, display: display),
                overlay: overlay
            )
            switch await controller.run() {
            case .finished(let image):
                let url = URL(fileURLWithPath: out)
                guard let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil
                ) else {
                    print("写不了 \(out)")
                    exit(1)
                }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                print("ok \(image.width)×\(image.height) → \(out)")
            case .cancelled:
                print("cancelled")
            case .failed(let reason):
                print("failed \(reason)")
            }
        } catch {
            print("failed \(error.localizedDescription)")
        }
        exit(0)
    }
    app.run()

case "--window-list":
    // 列出可截图窗口（layer 0），窗口截图验收时用来挑 ID
    MainActor.assumeIsolated {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let windows = WindowPicker.enumerate(excludingPID: getpid())
        print("frontmost=\(front) 共 \(windows.count) 个候选窗口")
        for window in windows {
            let mark = window.ownerPID == front ? "*" : " "
            let title = window.title ?? ""
            print("\(mark) id=\(window.windowID) pid=\(window.ownerPID) \(window.ownerName) | \(title) | \(Int(window.bounds.width))×\(Int(window.bounds.height)) @\(Int(window.bounds.minX)),\(Int(window.bounds.minY))")
        }
    }
    exit(0)

case "--window-capture":
    // 按 windowID 直接抓窗口，验证「被遮挡也能截全」。
    // 用法：Baton --window-capture <id|frontmost> [out.png]
    guard args.count >= 2 else {
        print("usage: Baton --window-capture <windowID|frontmost> [out.png]")
        exit(2)
    }
    Task { @MainActor in
        var windowID: Int?
        if args[1] == "frontmost" {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            windowID = WindowPicker.activeWindow(frontmostPID: front, excludingPID: getpid())?.windowID
        } else {
            windowID = Int(args[1])
        }
        guard let windowID else {
            print("找不到目标窗口（先跑 --window-list 看候选）")
            exit(1)
        }
        do {
            let shot = try await ScreenCapturer.captureWindow(windowID: windowID)
            let scale = CGFloat(shot.image.width) / max(shot.frame.width, 1)
            print("ok id=\(windowID) image=\(shot.image.width)×\(shot.image.height) frame=\(Int(shot.frame.width))×\(Int(shot.frame.height))@\(Int(shot.frame.minX)),\(Int(shot.frame.minY)) scale=\(scale)")
            if args.count >= 3 {
                let out = args[2]
                guard let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil
                ) else {
                    print("写不了 \(out)")
                    exit(1)
                }
                CGImageDestinationAddImage(dest, shot.image, nil)
                CGImageDestinationFinalize(dest)
                print("→ \(out)")
            }
        } catch {
            print("failed \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
    app.run()

case "--audio-probe":
    // 验音轨：轨数、每轨时长、峰值。用来一眼看出「混没混上」和「是不是一片噪声」
    guard args.count >= 2 else {
        print("usage: Baton --audio-probe <file.mp4>")
        exit(2)
    }
    Task {
        let url = URL(fileURLWithPath: args[1])
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            print("duration=\(String(format: "%.3f", CMTimeGetSeconds(duration)))s video=\(video.count) audio=\(audio.count)")
            for (index, track) in audio.enumerated() {
                let range = try await track.load(.timeRange)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                reader.add(output)
                reader.startReading()
                var peak: Float = 0
                var frames = 0
                var nonzero = 0
                while let buffer = output.copyNextSampleBuffer() {
                    guard let segment = CanonicalAudio.read(buffer) else { continue }
                    frames += segment.frames
                    for sample in segment.samples {
                        let magnitude = abs(sample)
                        if magnitude > peak { peak = magnitude }
                        if magnitude > 0.001 { nonzero += 1 }
                    }
                }
                let seconds = CanonicalAudio.seconds(ofFrames: frames)
                print(String(format: "audio[%d] start=%.3fs dur=%.3fs frames=%d peak=%.3f nonzero=%d",
                             index, CMTimeGetSeconds(range.start), seconds, frames, peak, nonzero))
            }
            exit(0)
        } catch {
            print("probe failed: \(error)")
            exit(1)
        }
    }
    app.run()

case "--record":
    // 录屏管线探针：跑 N 秒，验证四种 filter 能不能出帧。
    // 用法：Baton --record <full|window|app|area> <seconds> [out.mp4] [windowID|pid] [--mic]
    guard args.count >= 3 else {
        print("usage: Baton --record <full|window|app|area> <seconds> [out.mp4] [windowID|pid] [--mic]")
        exit(2)
    }
    let wantsMic = args.contains("--mic")
    Task { @MainActor in
        let mode = args[1]
        let seconds = Double(args[2]) ?? 3
        let positional = args.dropFirst(3).filter { !$0.hasPrefix("--") }
        let out = positional.first ?? "/tmp/baton-record-\(mode).mp4"
        try? FileManager.default.removeItem(atPath: out)

        guard let (config, _, _) = probeRecordingConfig(mode: mode, out: out,
                                                        extra: positional.count >= 2 ? positional[1] : nil,
                                                        microphone: wantsMic) else {
            exit(2)
        }

        let recorder = ScreenRecorder(config: config)
        let began = Date()
        do {
            try await recorder.start()
        } catch {
            let text = (error as? RecordingError)?.message ?? error.localizedDescription
            print("start failed: \(text)")
            exit(1)
        }
        print("recording \(mode) for \(seconds)s → \(out)")
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let result = await recorder.stop()
        switch result {
        case .success(let url):
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            print("ok \(url.path) \(size) bytes in \(String(format: "%.1f", Date().timeIntervalSince(began)))s")
            exit(0)
        case .failure(let error):
            print("stop failed: \(error.message)")
            exit(1)
        }
    }
    app.run()

case "--record-ui":
    // 走 RecorderController：控制条、计时、状态回调都真的跑一遍，用来肉眼验收浮条。
    // 用法：Baton --record-ui <full|window|app|area> <seconds> [windowID|pid]
    guard args.count >= 3 else {
        print("usage: Baton --record-ui <full|window|app|area> <seconds> [windowID|pid]")
        exit(2)
    }
    Task { @MainActor in
        let mode = args[1]
        let seconds = Double(args[2]) ?? 3
        let out = "/tmp/baton-ui-\(mode).mp4"
        try? FileManager.default.removeItem(atPath: out)

        guard let (config, target, highlight) = probeRecordingConfig(mode: mode, out: out,
                                                                     extra: args.count >= 4 ? args[3] : nil) else {
            exit(2)
        }

        let controller = RecorderController()
        var finished = false
        controller.onFinish = { url in
            print("finished → \(url.path)")
            finished = true
        }
        controller.onFailure = { text in
            print("failed: \(text)")
            finished = true
        }
        controller.onStateChange = { recording in
            print("indicator recording=\(recording)")
        }

        do {
            try await controller.start(target: target, config: config, highlight: highlight)
        } catch {
            print("start failed: \((error as? RecordingError)?.message ?? error.localizedDescription)")
            exit(1)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await controller.stop()
        // 留 2 秒给「已保存」提示条，探针里能截到它
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        exit(finished ? 0 : 1)
    }
    app.run()

case "--record-pause":
    // 暂停语义验收：录 2 秒 → 暂停 2 秒 → 再录 2 秒，成片应该是 4 秒而不是 6 秒。
    Task { @MainActor in
        let out = "/tmp/baton-pause.mp4"
        try? FileManager.default.removeItem(atPath: out)
        let config = RecordingConfig(target: .fullScreen, displayID: CGMainDisplayID(),
                                     url: URL(fileURLWithPath: out))
        let recorder = ScreenRecorder(config: config)
        do { try await recorder.start() } catch {
            print("start failed: \((error as? RecordingError)?.message ?? "?")")
            exit(1)
        }
        print("rec 2s"); try? await Task.sleep(nanoseconds: 2_000_000_000)
        recorder.pause(); print("paused 2s"); try? await Task.sleep(nanoseconds: 2_000_000_000)
        recorder.resume(); print("rec 2s"); try? await Task.sleep(nanoseconds: 2_000_000_000)
        let result = await recorder.stop()
        switch result {
        case .success(let url): print("ok \(url.path) paused=\(String(format: "%.2f", recorder.pausedSeconds))s")
        case .failure(let error): print("failed: \(error.message)"); exit(1)
        }
        exit(0)
    }
    app.run()

case "--overlay":
    // 只开选区覆盖层，不产成品：用来肉眼验收放大镜/遮罩
    shell.start()
    MainActor.assumeIsolated {
        let session = CaptureSession()
        probeCapture = session
        Task {
            let selection = await session.selectRegion()
            print("selection=\(String(describing: selection?.globalRect))")
            exit(0)
        }
    }
    app.run()
    exit(0)

case "--preview":
    guard args.count >= 2 else { print("usage: Baton --preview <file.mp4>"); exit(2) }
    let file = URL(fileURLWithPath: args[1])
    shell.start()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let preview = RecordingPreviewWindow(url: file, duration: 3)
            preview.show()
            probePreview = preview
            print("preview shown frame=\(preview.frame)")
        }
    }
    app.run()
    exit(0)

case "--prefs":
    shell.start()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let tab = args.count > 1 ? (Int(args[1]) ?? 0) : 0
            shell.openPreferences(tab: tab)
        }
    }
    app.run()
    exit(0)

case "--selection-probe":
    // 在目标 App 里选中文字后跑：看取词走的是哪条路、拿到多少字符
    print(SelectionReader.diagnose())
    print("text=\(SelectionReader.selectedText() ?? "<nil>")")
    exit(0)

case "--pick-probe":
    guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
        print("usage: Baton --pick-probe <x> <y> [window|element]")
        exit(2)
    }
    MainActor.assumeIsolated {
        let point = CGPoint(x: x, y: y)
        var displayID = CGDirectDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &displayID, &count)
        guard count > 0 else {
            print("point \(point) 不在任何屏幕上")
            exit(1)
        }

        let bounds = CGDisplayBounds(displayID)
        // CGDisplayPixelsWide 在缩放模式下返回的是「点宽」，不能用它算倍率；
        // 真正的 backing scale 只有 NSScreen 知道。
        let backing = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 1
        let frame = DisplayFrame(displayID: displayID,
                                 screenFrame: bounds,
                                 pixelSize: CGSize(width: bounds.width * backing, height: bounds.height * backing),
                                 nativeScale: backing)

        let candidates = WindowPicker.enumerate(excludingPID: getpid())
        let kind = PickTarget.Kind(rawValue: args.count > 3 ? args[3] : "window") ?? .window
        print("screen=\(Int(bounds.width))×\(Int(bounds.height)) scale=\(frame.captureScale.width) candidates=\(candidates.count)")

        // 逐层命中，帮你看清每个窗口的边界在哪
        for window in candidates where window.bounds.contains(point) {
            print("  window[\(window.windowID)] \(window.ownerName) layer=\(window.layer) \(window.bounds)")
        }

        if let target = PickService().probe(kind: kind, at: point, in: frame) {
            print("hit kind=\(target.kind.rawValue) app=\(target.ownerName) label=\(target.label)")
            print("    rect=\(target.rect)")
        } else {
            print("hit 无目标（光标下没有普通窗口）")
        }

        if kind == .element {
            print("ax: \(PickService().diagnoseElements(at: point))")
            if PermissionCenter.status(.accessibility) == .denied {
                PermissionCenter.request(.accessibility)
                print("→ 缺「辅助功能」权限，已拉起系统授权入口")
            }
        }
    }
    exit(0)

default:
    break
}

shell.start()
app.run()
