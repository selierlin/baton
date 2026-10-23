import AppKit
import BatonCore
import CoreGraphics
import Foundation

/// 投递方式的对照实验：同一段位移，换不同的字段组合，看 `NSScrollView` 认哪几种。
///
/// 场景很具体——平滑滚动要自己造几百个小事件，只要目标 App 不认，用户看到的就是「没反应」。
@MainActor
enum ScrollPostTest {
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    static func run(variant: String) {
        let frame = NSRect(x: 360, y: 260, width: 420, height: 320)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "post \(variant)"
        window.level = .floating

        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
        scrollView.hasVerticalScroller = true
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: frame.width, height: 20_000))
        document.wantsLayer = true
        document.layer?.backgroundColor = NSColor.white.cgColor
        scrollView.documentView = document
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let screenHeight = NSScreen.screens.first?.frame.height ?? 900
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: screenHeight - frame.midY))
        CGAssociateMouseAndMouseCursorPosition(1)

        let before = scrollView.contentView.bounds.origin.y
        var posted = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            for index in 0..<10 {
                let dy: Int32 = -6
                let event = CGEvent(scrollWheelEvent2Source: nil, units: variant == "line" ? .line : .pixel,
                                    wheelCount: 1,
                                    wheel1: variant == "line" ? -1 : dy,
                                    wheel2: 0, wheel3: 0)
                guard let event else { continue }
                switch variant {
                case "plain":
                    // 只有 pixel 单位 + isContinuous，不带相位、不动 location
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                case "phase":
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
                    event.setDoubleValueField(.scrollWheelEventScrollPhase,
                                              value: index == 0 ? 1 : (index == 9 ? 4 : 2))
                case "location":
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
                    event.location = CGEvent(source: nil)?.location ?? .zero
                case "pid":
                    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
                    event.location = CGEvent(source: nil)?.location ?? .zero
                case "line":
                    // 离散行事件（不声明连续），让系统自己按行滚
                    break
                default:
                    break
                }
                if variant == "pid" {
                    event.postToPid(getpid())
                } else {
                    event.post(tap: .cghidEventTap)
                }
                posted += 1
                usleep(16_000)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let after = scrollView.contentView.bounds.origin.y
            print("variant=\(variant) posted=\(posted) moved=\(String(format: "%.1f", after - before))pt")
            exit(0)
        }
    }
}
