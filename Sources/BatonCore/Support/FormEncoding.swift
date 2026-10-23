import Foundation

/// `application/x-www-form-urlencoded` 的严格编码。
///
/// 不能用 `URLComponents.percentEncodedQuery`：它遵循 RFC 3986，认为 `+` 是合法字符
/// 于是原样保留；而表单解析（`application/x-www-form-urlencoded`）会把 `+` 还原成**空格**。
/// base64 里 `+` 很常见，一被换成空格就等于换了图片字节 → 百度返回 `216201 图片格式错误`。
///
/// 另外不能图省事用 `CharacterSet.alphanumerics`：它包含全部 Unicode 字母（含中文），
/// 中文会原样留在 query 里。这里只放 ASCII 安全字符，其余一律百分号编码。
enum FormEncoding {
    private static let safe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
    }

    static func body(_ fields: [(key: String, value: String)]) -> Data? {
        fields
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}
