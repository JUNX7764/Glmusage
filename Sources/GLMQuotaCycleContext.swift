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
