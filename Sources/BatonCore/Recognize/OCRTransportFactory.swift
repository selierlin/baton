import Foundation

public enum OCRTransportFactory {
    public static func make(_ config: OCRProviderConfig) throws -> any OCRTransport {
        switch config.kind {
        case .vision:
            // 有 `BatonOCR` 就走子进程；找不到（`swift run` / 单测）自动退回进程内
            return SubprocessOCRTransport()
        case .baidu:
            guard let akRef = config.apiKeyRef, let skRef = config.secretRef else {
                throw OCRError.requestFailed("百度 OCR 配置缺少 Keychain 条目名")
            }
            let variant = BaiduOCRTransport.Variant(rawValue: config.variant ?? "") ?? .general
            return try BaiduOCRTransport(apiKeyRef: akRef,
                                         secretRef: skRef,
                                         variant: variant,
                                         languageType: config.languageType ?? "CHN_ENG")
        }
    }
}
