import AppKit
import BatonCore

/// 启动入口。真的只剩四行：
///
/// 1. 建 AppShell（所有功能的装配都在它里面）
/// 2. `--xxx` 调试命令（在 `DebugCommands.swift`，命中就 exit）
/// 3. 起 App
///
/// `app` / `shell` / `args` 是模块级全局：调试命令要复用同一个 shell 实例——
/// 换个实例跑 `--clip-panel` 之类，测的就不是刚启动的那套状态了。
setvbuf(stdout, nil, _IONBF, 0)

let app = NSApplication.shared
let shell = AppShell()
let args = Array(CommandLine.arguments.dropFirst())

runDebugCommand()

shell.start()
app.run()
