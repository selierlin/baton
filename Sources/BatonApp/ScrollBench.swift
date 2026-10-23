import AppKit
import BatonCore
import CoreGraphics
import Foundation

/// 平滑滚动的实测台。
///
/// 开一个真的 `NSScrollView`，把光标锁在窗口中心，投几格滚轮进去，
/// 再按 2ms 采样内容区的 `bounds.origin.y`——这样能把「一格格跳」和
/// 「摊成几十帧」量成同一组数字，而不是靠肉眼看。
@MainActor
enum ScrollBench {
    /// 文档视图要从上往下排，和真实网页/文本一致
    private final class StripeDocument: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            dirtyRect.fill()
            NSColor.systemGray.withAlphaComponent(0.5).setFill()
            let first = Int(dirtyRect.minY / 40) * 40
            var row = CGFloat(first)
            while row < dirtyRect.maxY {
                NSRect(x: 0, y: row, width: bounds.width, height: 1).fill()
                row += 40
            }
        }
    }

    static func run(notches: Int, spacing: Double, trace: Bool, raw: Bool) {
        let shell = AppShell()
        shell.start()
        if raw { shell.smoothScroll?.setEnabled(false, persist: false) }

        let frame = NSRect(x: 360, y: 260, width: 420, height: 320)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "scroll bench"
        window.level = .floating

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        // 内容画在 draw() 里，不要塞几百个 subview——那会把渲染拖到 30fps，
        // 量出来的是「内容太重」而不是「平滑滚动」。
        let document = StripeDocument(frame: NSRect(x: 0, y: 0, width: frame.width, height: 20_000))
        scrollView.documentView = document
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // 光标必须落在窗口上，滚轮才会路由到这个 App
        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        let center = CGPoint(x: frame.midX, y: screenHeight - frame.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)

        // 用 bounds 变更通知采样，而不是 2ms 轮询：
        // 轮询本身会占满主线程，把要测的滚动帧挤丢
        var samples: [(t: Double, y: Double)] = []
        let start = CFAbsoluteTimeGetCurrent()
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                samples.append((CFAbsoluteTimeGetCurrent() - start, clip.bounds.origin.y))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                print("smoother enabled=\(shell.smoothScroll?.isEnabled ?? false) "
                      + "intercept=\(shell.hub.scrollTapIntercepts)")
                for index in 0..<notches {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * spacing) {
                        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                                  units: .line,
                                                  wheelCount: 1,
                                                  wheel1: -3,
                                                  wheel2: 0,
                                                  wheel3: 0) else { return }
                        event.post(tap: .cghidEventTap)
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            MainActor.assumeIsolated {
                NotificationCenter.default.removeObserver(token)
                report(samples: samples, trace: trace)
                print("swallowed=\(shell.smoothScroll?.swallowedTicks ?? -1) "
                      + "posted=\(shell.smoothScroll?.postedFrames ?? -1)")
                exit(0)
            }
        }
    }

    private static func report(samples: [(t: Double, y: Double)], trace: Bool) {
        guard let first = samples.first else { return }
        // 只留「位置变了」的采样点，重采样带来的重复值不算帧
        var moving: [(t: Double, dy: Double)] = []
        var previous = first.y
        for sample in samples {
            let dy = sample.y - previous
            previous = sample.y
            if abs(dy) > 0.01 {
                moving.append((sample.t, dy))
            }
        }
        guard let begin = moving.first?.t, let end = moving.last?.t else {
            print("没有发生滚动：光标下不是目标窗口，或拦截后没投递")
            return
        }
        let total = moving.reduce(0) { $0 + abs($1.dy) }
        let biggest = moving.map { abs($0.dy) }.max() ?? 0
        let mean = total / Double(moving.count)
        // 相邻两帧的间隔抖动：均匀才叫"丝"
        var gaps: [Double] = []
        for index in 1..<moving.count {
            gaps.append(moving[index].t - moving[index - 1].t)
        }
        let meanGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let jitter = gaps.isEmpty ? 0
            : (gaps.map { abs($0 - meanGap) }.reduce(0, +) / Double(gaps.count)) * 1000

        print(String(format: "steps=%d total=%.1fpt max=%.1fpt mean=%.1fpt span=%.0fms",
                     moving.count, total, biggest, mean, (end - begin) * 1000))
        print(String(format: "gap=%.1fms jitter=%.2fms", meanGap * 1000, jitter))

        if trace {
            for (index, item) in moving.enumerated() where index < 80 {
                print(String(format: "  %6.1fms  %+7.2f", item.t * 1000, item.dy))
            }
        }
    }
}
