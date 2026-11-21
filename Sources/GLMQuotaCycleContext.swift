import Foundation
import CryptoKit

struct GLMQuotaHistoryContext: Equatable {
    enum Mode { case apiKey, oauth }
    let mode: Mode
    let partition: String?

    static func apiKey(_ value: String) -> Self {
        let material = Data(("glm-quota-cycle-v1|open.bigmodel.cn|api-key|" + value).utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return Self(mode: .apiKey, partition: digest)
    }
    static let oauth = Self(mode: .oauth, partition: nil)
    /// OAuth 回退的持久化分区：身份材料为 user_info 顶层服务端账号 id（跨登录稳定，
    /// token 轮换不改变分区）。与 apiKey material 域隔离；id 不可证时改用 `.oauth`
    /// 会话回退（partition nil），保持既有「仅本进程记录」语义。
    static func oauth(userInfoId: String) -> Self {
        let material = Data(("glm-quota-cycle-v1|open.bigmodel.cn|oauth|" + userInfoId).utf8)
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return Self(mode: .oauth, partition: digest)
    }
    func mayAttributeReset(planCredential: String, resetCredential: String) -> Bool {
        mode == .oauth && !planCredential.isEmpty && planCredential == resetCredential
    }
}

struct GLMQuotaCaptureToken: Equatable {
    let context: GLMQuotaHistoryContext
    let activation: UInt64
    let epoch: UInt64
    let requestStartedAt: Date
    func matches(context: GLMQuotaHistoryContext, activation: UInt64, epoch: UInt64) -> Bool {
        self.context == context && self.activation == activation && self.epoch == epoch
    }
}
