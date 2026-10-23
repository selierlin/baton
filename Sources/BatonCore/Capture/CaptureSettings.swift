import CoreGraphics
import Foundation

/// 截图相关的偏好与「上一次区域」。
///
/// 只存偏好和几何，不存图像——上次截图的内容不进这里。
public struct CaptureSettings: Codable, Sendable, Equatable {
    /// 上一次框/选的区域（全局显示坐标，点）。
    public struct LastArea: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var displayID: UInt32

        public init(rect: CGRect, displayID: CGDirectDisplayID) {
            self.x = rect.origin.x
            self.y = rect.origin.y
            self.width = rect.size.width
            self.height = rect.size.height
            self.displayID = displayID
        }

        public var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }

        public var display: CGDirectDisplayID { displayID }

        /// 屏幕分辨率或显示器更换后，旧区域可能整块落在屏幕外。
        public func isUsable(on screenFrame: CGRect) -> Bool {
            guard width >= 1, height >= 1 else { return false }
            return rect.intersects(screenFrame)
        }
    }

    public var lastArea: LastArea?
    /// 延迟截图的默认秒数。
    public var timedSeconds: Int

    public init(lastArea: LastArea? = nil, timedSeconds: Int = 5) {
        self.lastArea = lastArea
        self.timedSeconds = timedSeconds
    }

    /// 手写解码：以后加字段时老配置不会整份失效。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastArea = try? container.decodeIfPresent(LastArea.self, forKey: .lastArea)
        timedSeconds = (try? container.decodeIfPresent(Int.self, forKey: .timedSeconds)) ?? 5
        if !(1...60).contains(timedSeconds) { timedSeconds = 5 }
    }
}

/// `~/Library/Application Support/Baton/capture.json`。
///
/// 与 `translate.json` 同一套路：小配置直接用文件，不占数据库。
@MainActor
public final class CaptureSettingsStore {
    public private(set) var settings: CaptureSettings

    private let url: URL

    public init(url: URL? = nil) {
        let target: URL
        if let url {
            target = url
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil,
                                                     create: true))
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            target = base.appendingPathComponent("Baton", isDirectory: true)
                .appendingPathComponent("capture.json")
        }
        self.url = target

        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode(CaptureSettings.self, from: data) {
            settings = decoded
        } else {
            settings = CaptureSettings()
        }
    }

    /// 记住本次选区，供「截取上一次区域」复用。
    public func remember(rect: CGRect, displayID: CGDirectDisplayID) {
        let area = CaptureSettings.LastArea(rect: rect, displayID: displayID)
        guard settings.lastArea != area else { return }
        settings.lastArea = area
        save()
    }

    public func setTimedSeconds(_ seconds: Int) {
        let clamped = min(max(seconds, 1), 60)
        guard settings.timedSeconds != clamped else { return }
        settings.timedSeconds = clamped
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
