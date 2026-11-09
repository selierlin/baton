import Foundation

public enum OCRTransportFactory {
    /// `id` / `key` 只在设置页「测试」时传：用户刚敲完凭据还没保存，不该为了试一次就写进 Keychain。
    /// 传 `nil` 表示用已保存的（配置文件里的账号 + Keychain 里的密钥）。
    public static func make(_ config: OCRProviderConfig,
                            id: String? = nil,
                            key: String? = nil) throws -> any OCRTransport {
        let credentials = config.kind.credentials
        switch config.kind {
        case .vision:
            // 有 `BatonOCR` 就走子进程；找不到（`swift run` / 单测）自动退回进程内
            return SubprocessOCRTransport()
        case .baidu:
            let variant = BaiduOCRTransport.Variant(rawValue: config.variant ?? "") ?? .general
            return BaiduOCRTransport(accessKey: try resolve(id,
                                                            stored: config.accountID,
                                                            ref: config.apiKeyRef,
                                                            label: credentials?.idLabel ?? "AK"),
                                     secretKey: try resolve(key,
                                                            stored: nil,
                                                            ref: config.secretRef,
                                                            label: credentials?.secretLabel ?? "SK"),
                                     variant: variant,
                                     languageType: config.languageType ?? "CHN_ENG")
        case .tencent:
            return TencentOCRTransport(secretID: try resolve(id,
                                                             stored: config.accountID,
                                                             ref: config.apiKeyRef,
                                                             label: credentials?.idLabel ?? "SecretId"),
                                       secretKey: try resolve(key,
                                                              stored: nil,
                                                              ref: config.secretRef,
                                                              label: credentials?.secretLabel ?? "SecretKey"),
                                       languageType: config.languageType ?? "auto")
        }
    }

    /// 优先级：刚敲的 > 配置文件里的账号 > Keychain（旧版本把账号也存那儿）。
    private static func resolve(_ override: String?,
                                stored: String?,
                                ref: String?,
                                label: String) throws -> String {
        for candidate in [override, stored] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        if let ref, let value = KeychainStore.read(account: ref), !value.isEmpty {
            return value
        }
        throw OCRError.missingCredential(account: ref ?? label)
    }
}
