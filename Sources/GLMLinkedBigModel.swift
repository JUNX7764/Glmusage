import Foundation

/// ZCode 4.0 `zai_cn` 登录关联 BigModel 账号后写入 `~/.zcode/v2/credentials.json` 的
/// `oauth:linked_bigmodel` 明文负载（解密后的 JSON 对象）：
/// `{"userId": "...", "customerId": "...", "accessToken": "<bigmodel-access-token>"}`。
/// 仅在内存中解析使用；`accessToken` 与 `customerId` 绝不写日志、status.json 或明文落盘。
struct GLMLinkedBigModelPayload: Equatable {
    let accessToken: String
    let customerId: String?
}

enum GLMLinkedBigModel {
    static let credentialKey = "oauth:linked_bigmodel"

    /// 严格解析解密后的 `oauth:linked_bigmodel` JSON：
    /// - 仅当文本为合法 JSON 对象且 `accessToken` 为 trim 后非空且不含内部空白/控制字符的字符串时返回有效负载；
    /// - `customerId` 为可选字段，仅当为 trim 后非空字符串时保留，否则为 `nil`；
    /// - 不读取 `userId` 或其他平台字段作为邮箱/跨平台身份。
    static func parse(_ jsonString: String) -> GLMLinkedBigModelPayload? {
        guard let data = jsonString.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawToken = object["accessToken"] as? String else { return nil }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !token.isEmpty,
              !token.unicodeScalars.contains(where: { forbidden.contains($0) }) else { return nil }
        let customerId: String?
        if let rawCustomerId = object["customerId"] as? String {
            let trimmed = rawCustomerId.trimmingCharacters(in: .whitespacesAndNewlines)
            customerId = trimmed.isEmpty ? nil : trimmed
        } else {
            customerId = nil
        }
        return GLMLinkedBigModelPayload(accessToken: token, customerId: customerId)
    }
}
