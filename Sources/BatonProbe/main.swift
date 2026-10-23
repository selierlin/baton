import AppKit
import BatonCore
import Carbon.HIToolbox
import Foundation

// 被 kill 时也能看到输出
setvbuf(stdout, nil, _IONBF, 0)

// P1 冒烟探针：验证 Core 的四个接口在这台机器上能跑。
// 用法：
//   baton-probe          注册 ⌃⌥⌘K，打印输入事件
//   baton-probe capture  先截图框选，再打印选区几何

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let version = ProcessInfo.processInfo.operatingSystemVersion
print("macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")

for (kind, status) in PermissionCenter.all.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
    print("权限 \(kind.rawValue): \(status.rawValue)")
}

if let residue = OverlayRecovery.checkResidue() {
    print("警告：上次 overlay 残留 pid=\(residue.pid) alive=\(residue.alive)")
}

let hub = EventHub()
hub.start()
print("scroll tap: \(hub.scrollTapActive ? "已启用" : "未启用（缺输入监控）")")

Task {
    for await event in hub.events() {
        switch event {
        case .scroll(let s):
            print("scroll dy=\(s.deltaY) phase=\(s.phase) momentum=\(s.momentum)")
        case .frontAppChanged(let app):
            print("front app: \(app.name ?? "-") [\(app.ruleKey)]")
        case .clipboardChanged(let count):
            print("clipboard changeCount=\(count)")
        }
    }
}

let registry = HotkeyRegistry()
do {
    try registry.install()
    let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_K),
                         modifiers: UInt32(cmdKey | optionKey | controlKey))
    try registry.register(combo) {
        print("hotkey fired")
    }
    print("hotkey ⌃⌥⌘K registered")
} catch {
    print("hotkey 注册失败：\(error)")
}

if CommandLine.arguments.contains("capture") {
    Task {
        let session = CaptureSession()
        let outcome = await session.begin(intent: .area, action: .copy)
        switch outcome {
        case .cancelled:
            print("capture cancelled")
        case .failed(let reason):
            print("capture failed: \(reason)")
        case .captured(let result):
            print("captured \(result.pixelRect) in \(Int(result.display.pixelSize.width))×\(Int(result.display.pixelSize.height)) 位图")
        }
        NSApp.terminate(nil)
    }
}

app.run()
