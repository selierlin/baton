import AVFoundation
import Foundation

/// 朗读原文 / 译文。Bob 每个气泡右下角都有一对喇叭 + 复制，喇叭就是这个。
///
/// 不引第三方 TTS：`AVSpeechSynthesizer` 用的是系统音色，中英日都能读。
/// 语言按文本里的字符粗判——判错的代价只是口音奇怪，比不读好。
@MainActor
final class SpeechPlayer {
    static let shared = SpeechPlayer()

    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.language(of: trimmed))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    static func language(of text: String) -> String {
        var hasHan = false
        var hasKana = false
        var hasHangul = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF: hasKana = true
            case 0xAC00...0xD7AF: hasHangul = true
            case 0x4E00...0x9FFF: hasHan = true
            default: break
            }
        }
        if hasKana { return "ja-JP" }
        if hasHangul { return "ko-KR" }
        if hasHan { return "zh-CN" }
        return "en-US"
    }
}
