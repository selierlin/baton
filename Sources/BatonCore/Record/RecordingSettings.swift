import Foundation

/// 录制的少量偏好：录不录系统声音、录不录麦克风旁白。
///
/// 放 `recording.json`，和 `capture.json` 一个套路——小配置用文件，不占数据库。
@MainActor
public final class RecordingSettingsStore {
    public private(set) var capturesAudio: Bool
    public private(set) var capturesMicrophone: Bool

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
                .appendingPathComponent("recording.json")
        }
        self.url = target

        if let data = try? Data(contentsOf: target),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            capturesAudio = decoded.capturesAudio
            capturesMicrophone = decoded.capturesMicrophone
        } else {
            // 默认录系统声音：静音视频事后补声音是不可能的，而不要声音随时能关。
            // 麦克风默认关：一开就会弹系统授权框，不该在用户没要求时打扰。
            capturesAudio = true
            capturesMicrophone = false
        }
    }

    public func setCapturesAudio(_ value: Bool) {
        guard capturesAudio != value else { return }
        capturesAudio = value
        save()
    }

    public func setCapturesMicrophone(_ value: Bool) {
        guard capturesMicrophone != value else { return }
        capturesMicrophone = value
        save()
    }

    private struct Payload: Codable {
        var capturesAudio: Bool
        var capturesMicrophone: Bool

        init(capturesAudio: Bool, capturesMicrophone: Bool) {
            self.capturesAudio = capturesAudio
            self.capturesMicrophone = capturesMicrophone
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // 老版本只存了 capturesAudio：缺 key 按默认关闭处理，别让整份配置解码失败
            capturesAudio = (try? container.decode(Bool.self, forKey: .capturesAudio)) ?? true
            capturesMicrophone = (try? container.decode(Bool.self, forKey: .capturesMicrophone)) ?? false
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(capturesAudio: capturesAudio, capturesMicrophone: capturesMicrophone)
        guard let data = try? encoder.encode(payload) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
