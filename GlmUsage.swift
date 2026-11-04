import Cocoa
import CryptoKit
import Foundation
import CoreFoundation

// MARK: - 凭证读取（复用 ZCode 本地加密凭证库）
//
// ZCode 把订阅 API key 加密存在 ~/.zcode/v2/credentials.json（"enc:v1:" 前缀）：
// AES-256-GCM，密钥 = SHA256(secret)，secret 取环境变量 ZCODE_CREDENTIAL_SECRET，
// 未设置时用确定性 fallback "zcode-credential-fallback:<platform>:<homedir>:<username>"
// （与 ZCode 客户端 zcode.cjs 内置逻辑一致）。密文格式 iv.tag.ciphertext，均为 base64url。
// 本应用只读取、绝不写入该文件；key 仅存在于内存。

enum CredStore {
    static let credPath = NSHomeDirectory() + "/.zcode/v2/credentials.json"
    // 允许用环境变量直接提供 key（调试 / 无 ZCode 凭证库的场景）
    static let envKey = "GLM_API_KEY"

    static func loadApiKey() -> String? {
        if let k = ProcessInfo.processInfo.environment[envKey],
           !k.trimmingCharacters(in: .whitespaces).isEmpty { return k }
        guard let data = FileManager.default.contents(atPath: credPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        // coding-plan 的 api-key 可能有多个账户：优先 bigmodel（国内订阅）
        var candidates: [(key: String, enc: String)] = []
        for (k, v) in obj {
            guard v.hasPrefix("enc:v1:"), k.contains("api-key"), k.contains("coding-plan") else {
                continue
            }
            candidates.append((k, v))
        }
        candidates.sort { a, b in
            let am = a.key.contains("bigmodel"), bm = b.key.contains("bigmodel")
            if am != bm { return am }            // bigmodel 优先
            return a.key < b.key
        }
        if let enc = candidates.first?.enc { return decrypt(enc) }
        // 纯 OAuth 登录的凭证库没有独立 api-key 条目；监控接口实测接受 access_token 作为 Bearer 凭证
        return decrypt(obj["oauth:bigmodel:access_token"] ?? "")
    }

    // 重置卡（额度重置卡）接口所需的两个 ZCode 登录态 token（同一密文格式、同一把密钥）。
    // 任一缺失/解密失败返回 nil，由调用方优雅降级；同样只存内存、绝不落盘。
    static func loadResetTokens() -> (jwt: String, maas: String)? {
        guard let data = FileManager.default.contents(atPath: credPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        guard let jwt = decrypt(obj["zcodejwttoken"] ?? "")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !jwt.isEmpty,
              let maas = decrypt(obj["oauth:bigmodel:access_token"] ?? "")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !maas.isEmpty else {
            return nil
        }
        return (jwt, maas)
    }

    static func decrypt(_ s: String) -> String? {
        let parts = s.dropFirst("enc:v1:".count)
            .split(separator: ".")
            .map { base64urlDecode(String($0)) }
        guard parts.count == 3, let iv = parts[0], let tag = parts[1], let ct = parts[2] else {
            return nil
        }
        let secret = resolveSecret()
        let key = SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
        guard let box = try? AES.GCM.open(
            AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag),
            using: key) else { return nil }
        return String(data: box, encoding: .utf8)
    }

    private static func resolveSecret() -> String {
        if let env = ProcessInfo.processInfo.environment["ZCODE_CREDENTIAL_SECRET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        // 与 zcode.cjs 的 fallback 完全一致：os.platform() + os.homedir() + userInfo().username
        let platform = "darwin"
        let username = String(cString: getpwuid(getuid()).pointee.pw_name)
        return "zcode-credential-fallback:\(platform):\(NSHomeDirectory()):\(username)"
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }
}

// MARK: - 用量数据模型

/// quota/limit 返回的一条窗口限制（credit 额度）
struct LimitEntry {
    var label: String          // "5 小时窗口" / "7 天额度"
    var isFiveHour: Bool
    var limit: Double          // usage 字段 = 窗口总额度（credits）
    var used: Double           // currentValue
    var remaining: Double
    var usedRatio: Double      // 0..1（percentage/100）
    var reset: Date?
    var usedRemainingRatio: Double { max(0, min(1, 1 - usedRatio)) }  // 剩余比例
}

/// model-usage 返回的时间窗统计
struct ModelUsage {
    var totalTokens: Double
    var totalCalls: Double
    var byModel: [(name: String, tokens: Double)]
    var isEmpty: Bool { totalTokens == 0 && totalCalls == 0 }
}

/// Token 板块按模型明细：按用量降序、过滤 0，平局按名称排序保证稳定
enum TokenModelList {
    static func visible(_ models: [(name: String, tokens: Double)]) -> [(name: String, tokens: Double)] {
        models.filter { $0.tokens > 0 }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.name < $1.name }
    }

    /// 旧式 NSMenu fallback 保留树形文本；主面板使用独立对齐的列。
    static func render(_ models: [(name: String, tokens: Double)]) -> [String] {
        let visible = visible(models)
        return visible.enumerated().map { i, m in
            (i == visible.count - 1 ? "└ " : "├ ") + "\(m.name) \(Fmt.tokens(m.tokens))"
        }
    }
}

struct ToolUsage {
    var networkSearch: Double
    var webRead: Double
}

/// 重置卡（官方名：额度重置卡）：按窗口类型分组的未过期卡到期时间（已过滤 expire_at <= now）
struct ResetCards {
    var fiveHour: [Date]?
    var week: [Date]?
}

/// 套餐订阅信息（subscription/list）
struct SubscriptionInfo {
    var name: String
    var expireDate: Date?
}

struct UsageData {
    var fiveHour: LimitEntry?
    var week: LimitEntry?
    var level: String?                 // 套餐等级 lite/pro/max...
    var tokensToday: ModelUsage?
    var tokens7d: ModelUsage?
    var tokens30d: ModelUsage?
    var tools30d: ToolUsage?
    var resetCards: ResetCards?        // 重置卡（额度重置卡）可用列表
    var resetCardsError: String?
    var subscription: SubscriptionInfo?
    var subscriptionSucceeded = false
    var quotaError: String?
    var tokensError: String?
    var fiveHourError: String?
    var weekError: String?
    var tokensTodayError: String?
    var tokens7dError: String?
    var tokens30dError: String?
    var toolsError: String?
    var fiveHourCardsError: String?
    var weekCardsError: String?
    var subscriptionError: String?
}

enum GLMNumber {
    static func finite(_ value: Any?) -> Double? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else { return nil }
            return number
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = finite(value), number.rounded(.towardZero) == number,
              number >= Double(Int.min), number < Double(Int.max) else { return nil }
        return Int(number)
    }

    static func nonnegativeRoundedInteger(_ value: Any?) -> Int? {
        guard let number = finite(value), number >= 0 else { return nil }
        return Int(exactly: number.rounded())
    }
}

enum GLMFreshness {
    static func isStale(lastSuccess: Date?, hasData: Bool, now: Date, after: TimeInterval) -> Bool {
        guard hasData else { return false }
        guard let lastSuccess = lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > after
    }

    static func availableCards(_ cards: [Date], now: Date) -> [Date] {
        cards.filter { $0 > now }.sorted()
    }

    /// 纯函数：fresh 成功 → 新值+新成功时间+清错误；仅失败 → 保留旧值/旧成功时间+记录错误；
    /// 两者皆无 → 原样返回。调用处对结果做顺序赋值——不要把 self 的多个子字段同时作为
    /// inout 实参传入一个调用（同一存储属性的并发独占访问会触发 Swift 运行时崩溃）。
    static func apply<T>(fresh: T?, failure: String?, old: T?, oldLastOK: Date?, oldError: String?,
                         now: Date) -> (value: T?, lastOK: Date?, error: String?) {
        if let fresh = fresh {
            return (fresh, now, nil)
        }
        if let failure = failure {
            return (old, oldLastOK, failure)
        }
        return (old, oldLastOK, oldError)
    }
}

enum GLMSubscriptionFreshness {
    static func apply(fresh: SubscriptionInfo?, succeeded: Bool, failure: String?, old: SubscriptionInfo?,
                      oldLastOK: Date?, oldError: String?, now: Date) -> (SubscriptionInfo?, Date?, String?) {
        if succeeded { return (fresh, now, nil) }
        if let failure = failure { return (old, oldLastOK, failure) }
        return (old, oldLastOK, oldError)
    }
}

enum GLMRefreshDispatch {
    static func start(slowDue: Bool, quota: () -> Void, slow: () -> Void) {
        quota()
        if slowDue { slow() }
    }
}

enum GLMRefreshSchedule {
    static func slowItemsDue(cycle: Int, every: Int = 5, manual: Bool) -> Bool {
        manual || (every > 0 && cycle % every == 0)
    }
}

struct ResetCardsResult {
    var fiveHour: [Date]?
    var week: [Date]?
    var fiveHourError: String?
    var weekError: String?
}

/// Each network callback serializes its merge through this accumulator before leaving the group.
final class RefreshAccumulator {
    private let lock = NSLock()
    private var value = UsageData()

    func update(_ body: (inout UsageData) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&value)
    }

    func snapshot() -> UsageData {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class RefreshGate {
    private let lock = NSLock()
    private var active = false
    private var queuedManual = false

    func begin(manual: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { if manual { queuedManual = true }; return false }
        active = true
        return true
    }

    /// Returns true when one queued manual full refresh should start; in that case the gate stays held.
    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if queuedManual { queuedManual = false; return true }
        active = false
        return false
    }
}

// MARK: - 网络请求（智谱开放平台监控接口）
//
// 三个接口均来自官方 glm-plan-usage 插件（zai-org/zai-coding-plugins）：
//   GET {base}/api/monitor/usage/quota/limit                    额度窗口（无参数）
//   GET {base}/api/monitor/usage/model-usage?startTime=&endTime= 按小时 token/调用数
//   GET {base}/api/monitor/usage/tool-usage?startTime=&endTime=  MCP 工具次数
// 时间参数为本地时区 "yyyy-MM-dd HH:mm:ss"；Authorization: Bearer <订阅 api-key>。
// token 统计由服务端完成，无需扫描本地会话日志（与 KimiUsage 的差异点）。
// 另有两个扩展接口：
//   GET https://zcode.z.ai/api/v1/coding-plan/reset/status  重置卡（额度重置卡），
//       需 Authorization/X-Bigmodel-Authorization/Bigmodel-Target-Type 三个自定义头，成功码 code==0
//   GET {base}/api/biz/subscription/list                    套餐订阅（code==200，data 为数组）

enum Fetcher {
    static let base = "https://open.bigmodel.cn"

    private static func authRequest(_ urlStr: String, apiKey: String) -> URLRequest? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("GlmUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private static func winParams(from: Date, to: Date) -> [URLQueryItem] {
        let f = Fmt.queryTime
        return [URLQueryItem(name: "startTime", value: f.string(from: from)),
                URLQueryItem(name: "endTime", value: f.string(from: to))]
    }

    /// 通用 GET（code==200 判成功），回调 data 字段原始 JSON（dict / array 均可）
    private static func fetchRaw(apiKey: String, path: String, from: Date? = nil, to: Date? = nil,
                                 completion: @escaping (Any?, String?) -> Void) {
        let req: URLRequest?
        if let from = from, let to = to {
            var comp = URLComponents(string: base + path)
            comp?.queryItems = winParams(from: from, to: to)
            req = comp?.url.map { authRequest($0.absoluteString, apiKey: apiKey)! }
        } else {
            req = authRequest(base + path, apiKey: apiKey)
        }
        guard let req = req else { completion(nil, "bad url"); return }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, err?.localizedDescription ?? "bad response"); return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                completion(nil, "HTTP \(http.statusCode)"); return
            }
            guard let code = GLMNumber.integer(obj["code"]), code == 200 else {
                let code = GLMNumber.integer(obj["code"]).map(String.init) ?? "missing or invalid"
                completion(nil, "code \(code) \(obj["msg"] as? String ?? "")"); return
            }
            completion(obj["data"], nil)
        }.resume()
    }

    /// data 为 dict 的接口走这里（额度窗口 / token 统计 / MCP 工具）
    static func fetch(apiKey: String, path: String, from: Date? = nil, to: Date? = nil,
                      completion: @escaping ([String: Any]?, String?) -> Void) {
        fetchRaw(apiKey: apiKey, path: path, from: from, to: to) { data, err in
            completion(data as? [String: Any], err)
        }
    }

    /// 额度窗口：5 小时 + 7 天（周）
    static func fetchQuota(apiKey: String, completion: @escaping (UsageData) -> Void) {
        fetch(apiKey: apiKey, path: "/api/monitor/usage/quota/limit") { data, err in
            completion(parseQuota(data, error: err, now: Date()))
        }
    }

    /// Each quota window is validated independently; an invalid window never becomes a zero value.
    static func parseQuota(_ data: [String: Any]?, error: String?, now: Date) -> UsageData {
        var result = UsageData()
        if let error = error {
            result.fiveHourError = error
            result.weekError = error
            result.quotaError = error
            return result
        }
        guard let data = data else {
            result.fiveHourError = "no quota data"
            result.weekError = "no quota data"
            result.quotaError = "no quota data"
            return result
        }
        result.level = data["level"] as? String
        guard let limits = data["limits"] as? [[String: Any]] else {
            result.fiveHourError = "missing or invalid limits"
            result.weekError = "missing or invalid limits"
            result.quotaError = "missing or invalid limits"
            return result
        }

        var sawFive = false
        var sawWeek = false
        for row in limits {
            let type = row["type"] as? String ?? ""
            let unit = GLMNumber.integer(row["unit"])
            let number = GLMNumber.integer(row["number"])
            var isFive = false
            var isWeek = false
            if type == "TOKENS_LIMIT" { isFive = true }
            else if type == "TIME_LIMIT" { isWeek = true }
            else if type == "CREDIT_LIMIT" {
                if unit == 3 { isFive = true }
                else if unit == 6 { isWeek = true }
            }
            guard isFive || isWeek else { continue }
            if isFive { sawFive = true }
            if isWeek { sawWeek = true }

            let label = isFive ? "5 小时窗口" : "7 天额度"
            let window = isFive ? "5H" : "7D"
            let invalid = "invalid \(window) quota fields"
            if type == "CREDIT_LIMIT" && (unit == nil || (isFive && number != 5)) {
                if isFive { result.fiveHourError = invalid } else { result.weekError = invalid }
                continue
            }
            let fields = ["usage", "currentValue", "remaining", "percentage"]
            let bad = fields.filter { GLMNumber.finite(row[$0]) == nil }
            guard bad.isEmpty, let limit = GLMNumber.finite(row["usage"]), limit > 0,
                  let used = GLMNumber.finite(row["currentValue"]), used >= 0, used <= limit,
                  let remaining = GLMNumber.finite(row["remaining"]), remaining >= 0, remaining <= limit,
                  GLMNumber.nonnegativeRoundedInteger(limit) != nil,
                  GLMNumber.nonnegativeRoundedInteger(used) != nil,
                  GLMNumber.nonnegativeRoundedInteger(remaining) != nil,
                  let percentage = GLMNumber.finite(row["percentage"]), (0...100).contains(percentage) else {
                var invalidFields = bad
                if let n = GLMNumber.finite(row["usage"]), n <= 0 || GLMNumber.nonnegativeRoundedInteger(n) == nil { invalidFields.append("usage") }
                if let n = GLMNumber.finite(row["currentValue"]), n < 0 || n > (GLMNumber.finite(row["usage"]) ?? 0) || GLMNumber.nonnegativeRoundedInteger(n) == nil { invalidFields.append("currentValue") }
                if let n = GLMNumber.finite(row["remaining"]), n < 0 || n > (GLMNumber.finite(row["usage"]) ?? 0) || GLMNumber.nonnegativeRoundedInteger(n) == nil { invalidFields.append("remaining") }
                if let n = GLMNumber.finite(row["percentage"]), !(0...100).contains(n) { invalidFields.append("percentage") }
                let detail = invalidFields.joined(separator: ", ")
                if isFive { result.fiveHourError = "invalid \(window): \(detail)" } else { result.weekError = "invalid \(window): \(detail)" }
                continue
            }
            // 容许额度四舍五入误差及百分比四舍五入（各 0.5 个单位）。
            guard abs((used + remaining) - limit) <= max(1.5, limit * 0.000001),
                  abs(percentage - used / limit * 100) <= 0.51 + 50 / limit else {
                if isFive { result.fiveHourError = "invalid \(window): inconsistent usage/currentValue/remaining/percentage" }
                else { result.weekError = "invalid \(window): inconsistent usage/currentValue/remaining/percentage" }
                continue
            }
            let reset: Date?
            var resetError: String?
            if let rawReset = row["nextResetTime"] {
                if let milliseconds = GLMNumber.finite(rawReset), milliseconds > 0 {
                    reset = Date(timeIntervalSince1970: milliseconds / 1000)
                } else { reset = nil; resetError = "invalid \(window): nextResetTime" }
            } else { reset = nil }
            let entry = LimitEntry(label: label, isFiveHour: isFive, limit: limit, used: used,
                                   remaining: remaining, usedRatio: percentage / 100, reset: reset)
            if isFive, result.fiveHour == nil {
                result.fiveHour = entry
                result.fiveHourError = resetError
            }
            if isWeek, result.week == nil {
                result.week = entry
                result.weekError = resetError
            }
        }
        if result.fiveHour == nil && !sawFive { result.fiveHourError = "missing 5H quota" }
        if result.week == nil && !sawWeek { result.weekError = "missing 7D quota" }
        if result.fiveHour == nil && result.week == nil {
            result.quotaError = [result.fiveHourError, result.weekError].compactMap { $0 }.joined(separator: "; ")
        }
        return result
    }

    /// model-usage：一个时间窗的 token/调用统计
    static func fetchModelUsage(apiKey: String, from: Date, to: Date,
                                completion: @escaping (ModelUsage?, String?) -> Void) {
        fetch(apiKey: apiKey, path: "/api/monitor/usage/model-usage", from: from, to: to) { data, err in
            guard let data = data, err == nil else { completion(nil, err ?? "no data"); return }
            guard let usage = parseModelUsage(data) else {
                completion(nil, "missing or invalid model usage fields"); return
            }
            completion(usage, nil)
        }
    }

    static func parseModelUsage(_ data: [String: Any]) -> ModelUsage? {
        guard let total = data["totalUsage"] as? [String: Any],
              let tokens = GLMNumber.integer(total["totalTokensUsage"]), tokens >= 0,
              let calls = GLMNumber.integer(total["totalModelCallCount"]), calls >= 0 else { return nil }
        var byModel: [(String, Double)] = []
        if let rawList = data["modelSummaryList"] {
            guard let list = rawList as? [[String: Any]] else { return nil }
            for model in list {
                guard let count = GLMNumber.integer(model["totalTokens"]), count >= 0 else { return nil }
                byModel.append((model["modelName"] as? String ?? "?", Double(count)))
            }
        }
        return ModelUsage(totalTokens: Double(tokens), totalCalls: Double(calls), byModel: byModel)
    }

    /// tool-usage：MCP 工具次数（网络搜索 / 网页读取）
    static func fetchToolUsage(apiKey: String, from: Date, to: Date,
                               completion: @escaping (ToolUsage?, String?) -> Void) {
        fetch(apiKey: apiKey, path: "/api/monitor/usage/tool-usage", from: from, to: to) { data, err in
            guard let data = data, err == nil else { completion(nil, err ?? "no data"); return }
            guard let usage = parseToolUsage(data) else {
                completion(nil, "missing or invalid tool usage fields"); return
            }
            completion(usage, nil)
        }
    }

    static func parseToolUsage(_ data: [String: Any]) -> ToolUsage? {
        guard let total = data["totalUsage"] as? [String: Any],
              let search = GLMNumber.integer(total["totalNetworkSearchCount"]), search >= 0,
              let webRead = GLMNumber.integer(total["totalWebReadMcpCount"]), webRead >= 0 else { return nil }
        return ToolUsage(networkSearch: Double(search), webRead: Double(webRead))
    }

    // 重置卡（额度重置卡）：ZCode 侧接口，成功码为 code==0（与 open.bigmodel.cn 系的 200 不同）
    static let resetBase = "https://zcode.z.ai"

    /// 查询可用重置卡列表；jwt/maas 为 ZCode 登录态 token，过期/缺失由上层优雅降级
    static func fetchResetCards(jwt: String, maas: String,
                                completion: @escaping (ResetCardsResult) -> Void) {
        guard let url = URL(string: resetBase + "/api/v1/coding-plan/reset/status") else {
            completion(ResetCardsResult(fiveHourError: "bad url", weekError: "bad url")); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        // zcodejwttoken 明文可能已自带 "Bearer " 前缀，避免重复拼接
        let auth = jwt.lowercased().hasPrefix("bearer ") ? jwt : "Bearer \(jwt)"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(maas, forHTTPHeaderField: "X-Bigmodel-Authorization")
        req.setValue("PERSONAL", forHTTPHeaderField: "Bigmodel-Target-Type")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("GlmUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard err == nil, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let error = err?.localizedDescription ?? "bad response"
                completion(ResetCardsResult(fiveHourError: error, weekError: error)); return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let error = "HTTP \(http.statusCode)"
                completion(ResetCardsResult(fiveHourError: error, weekError: error)); return
            }
            let code = GLMNumber.integer(obj["code"]) ?? -1
            guard code == 0 else {
                let error = "code \(code) \(obj["msg"] as? String ?? "")"
                completion(ResetCardsResult(fiveHourError: error, weekError: error)); return
            }
            guard let d = obj["data"] as? [String: Any] else {
                completion(ResetCardsResult(fiveHourError: "no data", weekError: "no data")); return
            }
            completion(parseResetCards(d, now: Date()))
        }.resume()
    }

    static func parseResetCards(_ data: [String: Any], now: Date) -> ResetCardsResult {
        func cards(_ key: String) -> ([Date]?, String?) {
            guard let raw = data[key] else { return (nil, "missing \(key)") }
            guard let list = raw as? [[String: Any]] else { return (nil, "invalid \(key)") }
            var dates: [Date] = []
            for card in list {
                guard let millis = GLMNumber.finite(card["expire_at"]), millis > 0 else {
                    return (nil, "invalid \(key) expiration")
                }
                let date = Date(timeIntervalSince1970: millis / 1000)
                if date > now { dates.append(date) }
            }
            return (dates.sorted(), nil)
        }
        let five = cards("available_five_hour_resets")
        let week = cards("available_week_resets")
        return ResetCardsResult(fiveHour: five.0, week: week.0,
                                fiveHourError: five.1, weekError: week.1)
    }

    /// 套餐订阅：取 status=="VALID" 的第一条；到期时间解析失败时仅降级显示名称
    static func fetchSubscription(apiKey: String,
                                  completion: @escaping (SubscriptionInfo?, String?) -> Void) {
        fetchRaw(apiKey: apiKey, path: "/api/biz/subscription/list") { data, err in
            if let err = err { completion(nil, err); return }
            let result = parseSubscription(data)
            completion(result.0, result.1)
        }
    }

    static func parseSubscription(_ data: Any?) -> (SubscriptionInfo?, String?) {
        guard let list = data as? [[String: Any]] else { return (nil, "unexpected payload") }
        guard list.allSatisfy({ $0["status"] is String }) else { return (nil, "invalid subscription status") }
        guard let sub = list.first(where: { ($0["status"] as? String) == "VALID" }) else {
            return (nil, nil)
        }
        guard let name = sub["productName"] as? String, !name.isEmpty else {
            return (nil, "invalid subscription name")
        }
        return (SubscriptionInfo(name: name, expireDate: parseSubscriptionExpiry(sub)), nil)
    }

    /// valid 形如 "2026-09-26 18:18:52-2027-09-26 10:00:00"，但部分套餐返回的是
    /// 后续周期区间，不能直接总取末端。nextRenewTime 才是当前周期边界：若它与
    /// valid 中某一天一致，取该天对应的完整时间（保留接口给出的时分秒）；否则
    /// 直接取 nextRenewTime。旧响应没有 nextRenewTime 时才回退到 valid 末端。
    private static func parseSubscriptionExpiry(_ sub: [String: Any]) -> Date? {
        let valid = sub["valid"] as? String ?? ""
        let dates = parseValidDates(valid)
        if let next = sub["nextRenewTime"] as? String, next.count >= 10 {
            let day = String(next.prefix(10))
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let nextDay = f.date(from: day) {
                if let match = dates.first(where: { Calendar.current.isDate($0, inSameDayAs: nextDay) }) {
                    return match
                }
                return nextDay
            }
        }
        return dates.last
    }

    private static func parseValidDates(_ valid: String) -> [Date] {
        guard let re = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#) else {
            return []
        }
        let ns = valid as NSString
        return re.matches(in: valid, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let s = ns.substring(with: m.range).replacingOccurrences(of: " ", with: "T")
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"   // 无时区字段，按本地时区解释
            return f.date(from: s)
        }
    }
}

// MARK: - 菜单栏堆叠两行文字渲染

enum StackImage {
    struct Line {
        let badge: String
        let label: String
        let value: String
        let remaining: Double?
    }

    // 纯几何：badge（峰谷/过期 emoji）挂在文本列左侧向左突出，两行正文从同一 x 起左对齐（5H/7D 对齐）
    static func geometry(badge1Width: CGFloat, badge2Width: CGFloat,
                         text1Width: CGFloat, text2Width: CGFloat)
            -> (textX: CGFloat, badge1X: CGFloat?, badge2X: CGFloat?, width: CGFloat) {
        let margin: CGFloat = 1
        let gap: CGFloat = 2
        let hasBadge = badge1Width > 0 || badge2Width > 0
        let textX = margin + (hasBadge ? ceil(max(badge1Width, badge2Width)) + gap : 0)
        let badge1X = badge1Width > 0 ? textX - gap - ceil(badge1Width) : nil
        let badge2X = badge2Width > 0 ? textX - gap - ceil(badge2Width) : nil
        let width = textX + ceil(max(text1Width, text2Width)) + margin
        return (textX, badge1X, badge2X, width)
    }

    private static func attributed(_ line: Line, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line.label + " ", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        result.append(NSAttributedString(string: line.value, attributes: [
            .font: font,
            .foregroundColor: GLMRemainingColor.color(line.remaining)
        ]))
        return result
    }

    static func make(line1: Line, line2: Line) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
        let s1 = attributed(line1, font: font)
        let s2 = attributed(line2, font: font)
        let badgeAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let b1 = line1.badge.isEmpty ? nil : NSAttributedString(string: line1.badge, attributes: badgeAttrs)
        let b2 = line2.badge.isEmpty ? nil : NSAttributedString(string: line2.badge, attributes: badgeAttrs)
        let g = geometry(badge1Width: b1?.size().width ?? 0, badge2Width: b2?.size().width ?? 0,
                         text1Width: s1.size().width, text2Width: s2.size().width)
        // 不钉死绘制外观：全部使用动态颜色（labelColor / GLMRemainingColor 动态包装），
        // 由系统在每条菜单栏上绘制时按该栏外观解析——双屏两条栏底色不同也能各自正确
        let img = NSImage(size: NSSize(width: ceil(g.width), height: 21), flipped: false) { _ in
            if let x = g.badge1X { b1?.draw(at: NSPoint(x: x, y: 10.5)) }
            if let x = g.badge2X { b2?.draw(at: NSPoint(x: x, y: 0.5)) }
            s1.draw(at: NSPoint(x: g.textX, y: 10.5))
            s2.draw(at: NSPoint(x: g.textX, y: 0.5))
            return true
        }
        img.isTemplate = false   // 保留百分比余量颜色；动态色由系统按各屏菜单栏外观解析
        return img
    }
}

// MARK: - 格式化

enum Fmt {
    static func pct(_ v: Double?) -> String {
        guard let v = v else { return "--" }
        let p = v * 100
        if p > 0 && p < 1 { return "<1%" }
        return String(format: "%.0f%%", p)
    }
    static func pctLong(_ v: Double?) -> String {
        guard let v = v else { return "暂无数据" }
        return String(format: "%.2f%%", v * 100)
    }
    // 展示用 formatter 静态缓存：菜单每轮重建要调十几次，新建 DateFormatter 开销大
    private static func zhFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
    private static let timeFmt = zhFormatter("HH:mm")
    private static let dayTimeFmt = zhFormatter("MM-dd HH:mm")
    private static let expiresTodayFmt = zhFormatter("'今天' HH:mm")
    private static let expiresTomorrowFmt = zhFormatter("'明天' HH:mm")
    private static let expiresFullFmt = zhFormatter("yyyy-MM-dd HH:mm")

    static func time(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return timeFmt.string(from: d)
    }
    // 最后成功时间的占位口径：无记录用 "--"（time() 对 nil 返回空串，不适合过期提示行）
    static func lastOK(_ d: Date?) -> String {
        guard let d = d else { return "--" }
        return time(d)
    }
    // 自诊断 JSON 用；仅主线程调用，static 单次构造避免每次刷新重复分配
    static let iso8601 = ISO8601DateFormatter()
    static func dayTime(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return dayTimeFmt.string(from: d)
    }
    // 重置卡/套餐到期提示：今天内 → "今天 HH:mm"；明天 → "明天 HH:mm"；否则完整日期（本地时区）
    static func expires(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return expiresTodayFmt.string(from: d) }
        if cal.isDateInTomorrow(d) { return expiresTomorrowFmt.string(from: d) }
        return expiresFullFmt.string(from: d)
    }
    // 自诊断 / --once 输出用完整日期时间（本地时区）
    static let fullTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    // 套餐到期输出用秒级完整时间（本地时区）
    static let fullSec: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    // token 数量缩写：999 / 12.3K / 1.23M / 1.23B
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
    static func credits(_ v: Double) -> String {
        guard v.isFinite, v >= 0, let n = Int(exactly: v.rounded()) else { return "超出范围" }
        return n.formatted(.number.grouping(.automatic))
    }
    static func count(_ v: Double) -> String {
        guard let n = GLMNumber.integer(v), n >= 0 else { return "超出范围" }
        return String(n)
    }
    static let queryTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"   // 本地时区，服务端按本地时间解释
        return f
    }()
}

// MARK: - 峰谷时段（新版积分制）
//
// 官方规则（docs.bigmodel.cn/cn/coding-plan/overview）：
//   高峰 = 周一~周五 14:00–18:00（北京时间 UTC+8），积分全价抵扣；
//   其余时间（含周末全天）= 非高峰，积分 5 折抵扣。
//   （老版 V1/V2 套餐的 3 倍/1 倍口径不适用于积分制账号）
//   限时活动按官方公告硬编码日期，过期自动失效：
//     双节 2026-09-25 ~ 10-07：全天按非高峰 5 折
//     深夜错峰 2026-09-03 ~ 10-07 每日 23:00~次日09:00：ZCode 内 Flash 0 消耗、其他 Agent 额度 ×2

enum Peak {
    static let tz = TimeZone(identifier: "Asia/Shanghai")!

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }()

    // 两个限时活动同在 2026 年 9 月起、10-07 止，仅 9 月起始日不同
    private static func eventActive(_ dc: DateComponents, fromSepDay startDay: Int) -> Bool {
        dc.year == 2026 && ((dc.month == 9 && dc.day! >= startDay) || (dc.month == 10 && dc.day! <= 7))
    }

    private static func isFestivalDay(_ dc: DateComponents) -> Bool {
        eventActive(dc, fromSepDay: 25)
    }

    private static func isNightWindow(_ date: Date) -> Bool {
        let h = cal.component(.hour, from: date)
        guard h >= 23 || h < 9 else { return false }
        // 凌晨 0~9 点归属前一晚的窗口，起算日期相应前移一天
        let base = h < 9 ? cal.date(byAdding: .day, value: -1, to: date)! : date
        return eventActive(cal.dateComponents([.year, .month, .day], from: base), fromSepDay: 3)
    }

    /// 下一个高峰开始时刻（跳过周末与双节活动日）
    static func nextPeakStart(_ date: Date) -> Date {
        let today = cal.startOfDay(for: date)
        let h = cal.component(.hour, from: date)
        var day = today
        for _ in 0..<20 {   // 双节可连续覆盖 10+ 天，搜索窗口须长于活动跨度
            let dc = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            if (2...6).contains(dc.weekday!), !isFestivalDay(dc), day > today || h < 14 {
                return cal.date(bySettingHour: 14, minute: 0, second: 0, of: day)!
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return date
    }

    /// emoji：⚡ 深夜活动 ＞ 🔥 高峰 ＞ 无（普通非高峰不占宽度）
    static func evaluate(at date: Date = Date()) -> (emoji: String?, line: String, eventLine: String?) {
        let c = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        let festival = isFestivalDay(c)
        let night = isNightWindow(date)
        let peak = !festival && (2...6).contains(c.weekday!) && c.hour! >= 14 && c.hour! < 18

        let np = nextPeakStart(date)
        let npText: String
        if cal.isDate(np, inSameDayAs: date) {
            npText = "今天 14:00"
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: date), cal.isDate(np, inSameDayAs: tomorrow) {
            npText = "明天 14:00"
        } else {
            npText = Fmt.dayTime(np)
        }

        let emoji = night ? "⚡" : (peak ? "🔥" : nil)
        let line = peak
            ? "🔥 高峰期 · 积分全价（18:00 后恢复 5 折）"
            : "⚡ 非高峰 · 积分 5 折（下个高峰 \(npText)）"
        var eventLine: String? = nil
        if festival { eventLine = "🎉 双节活动：全天按非高峰 5 折（至 10-07）" }
        if night { eventLine = "🌙 深夜错峰：Flash 免费 · 其他 Agent 额度 ×2（至 10-07）" }
        return (emoji, line, eventLine)
    }
}


// 更新任务由独立 launchd 作业执行，应用退出换包时作业仍可完成或回滚。
final class UpdateProgressController: NSObject, NSWindowDelegate {
    static let shared = UpdateProgressController()
    private var window: NSWindow?
    private var progress: NSProgressIndicator?
    private var status: NSTextField?
    private var timer: Timer?
    private var directory: URL?

    func start(script: String, tag: String, appPath: String) {
        if let window = window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-update-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = dir
            let copiedScript = dir.appendingPathComponent("update.sh")
            try FileManager.default.copyItem(atPath: script, toPath: copiedScript.path)
            let wrapper = dir.appendingPathComponent("run.sh")
            let wrapperText = """
            #!/bin/bash
            cd "$1" || exit 1
            export UPDATE_PROGRESS_FILE="$1/progress"
            /bin/bash "$1/update.sh" "$3" "$4" > "$1/log" 2>&1
            result=$?
            printf '%s' "$result" > "$1/result"
            if [ "$result" -ne 0 ] && /usr/bin/grep -q '4/5' "$1/log"; then
                /usr/bin/osascript -e 'display dialog "更新失败，已尝试恢复旧版本。请重新打开应用后重试。" with title "更新失败" buttons {"好"} default button 1 with icon caution' >/dev/null 2>&1
            fi
            if [ "$result" -eq 0 ]; then /bin/sleep 5; /bin/rm -rf "$1"; fi
            /bin/launchctl remove "$2" >/dev/null 2>&1
            exit "$result"
            """
            try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
            win.title = "软件更新"
            win.isReleasedWhenClosed = false
            win.delegate = self
            let label = NSTextField(labelWithString: "正在准备更新…")
            label.frame = NSRect(x: 24, y: 78, width: 322, height: 24)
            let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 43, width: 322, height: 18))
            bar.style = .bar; bar.isIndeterminate = true; bar.startAnimation(nil)
            win.contentView?.addSubview(label); win.contentView?.addSubview(bar)
            status = label; progress = bar; window = win
            win.center(); win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            let jobLabel = "com.local.usage-update." + UUID().uuidString
            launch.arguments = ["submit", "-l", jobLabel, "--", "/bin/bash", wrapper.path, dir.path, jobLabel, tag, appPath]
            launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
            try launch.run(); launch.waitUntilExit()
            guard launch.terminationStatus == 0 else { throw NSError(domain: "Update", code: Int(launch.terminationStatus)) }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        } catch {
            finishError("无法启动更新，请稍后重试。")
        }
    }

    private func refresh() {
        guard let dir = directory else { return }
        let log = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        if log.contains("4/5") { status?.stringValue = "正在安装并重启…"; indeterminate() }
        else if log.contains("3/5") { status?.stringValue = "正在准备安装…"; indeterminate() }
        else if log.contains("2/5") { status?.stringValue = "正在校验更新…"; indeterminate() }
        else if log.contains("下载 v") {
            status?.stringValue = "正在下载更新…"
            if let text = try? String(contentsOf: dir.appendingPathComponent("progress"), encoding: .utf8),
               let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#),
               let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text), let value = Double(text[range]) {
                progress?.stopAnimation(nil); progress?.isIndeterminate = false
                progress?.minValue = 0; progress?.maxValue = 100; progress?.doubleValue = value
                status?.stringValue = "正在下载更新… \(Int(value))%"
            }
        }
        if let result = try? String(contentsOf: dir.appendingPathComponent("result"), encoding: .utf8), result != "0" {
            let detail = log.components(separatedBy: .newlines).last(where: { $0.contains("!!") }) ?? "请检查网络后重试。"
            finishError(detail.replacingOccurrences(of: "!! ", with: ""))
        }
    }
    private func indeterminate() {
        guard progress?.isIndeterminate == false else { return }
        progress?.isIndeterminate = true; progress?.startAnimation(nil)
    }
    private func finishError(_ detail: String) {
        timer?.invalidate(); timer = nil
        window?.close(); window = nil
        let alert = NSAlert(); alert.messageText = "更新失败"; alert.informativeText = detail
        alert.addButton(withTitle: "好"); alert.runModal()
        if let dir = directory { try? FileManager.default.removeItem(at: dir) }; directory = nil
    }
}

// MARK: - 版本与更新检查（成熟项目惯例，Sparkle 生态同款语义：只认 GitHub Release，
// 不认 main 分支 commit——日常 push 与用户无关，发布了更高版本才提示。
// build.sh 打包时写 Info.plist 自定义键；就地更新脚本随包内置，见 Resources/update.sh）

/// 构建版本：build.sh 打包时写入产物 Info.plist 自定义键（CUBuildVersion，git describe），
/// 运行时读 Bundle。仓库模板没有该键 → 非 build.sh 产物（直接 swiftc 的裸二进制）为 unknown，
/// 此时更新检查自然禁用、菜单显示「版本 unknown」。不生成第二个 .swift：多文件编译下
/// 只有 main.swift 允许 top-level 代码，本文件的命令行入口依赖 top-level。
enum BuildInfo {
    static let version = (Bundle.main.infoDictionary?["CUBuildVersion"] as? String) ?? "unknown"
}

/// 更新判定的纯逻辑：Release 版本号比较（--self-test 覆盖）。
/// 提示的唯一触发条件是「GitHub 发布了更高版本的 Release」；commit hash 回答的是
/// 「分支动没动」，不代表存在可安装的新版本。
enum UpdateCheck {
    static let apiURL = URL(string: "https://api.github.com/repos/JUNX7764/Glmusage/releases?per_page=20")!
    static let releasesPage = URL(string: "https://github.com/JUNX7764/Glmusage/releases")!
    /// GitHub 匿名限额 60 次/小时/IP，30 分钟一查仅 2 次/小时；ETag/304 条件请求不耗配额
    static let interval: TimeInterval = 30 * 60

    /// 版本号归一化：v1.0.1 / v1.0.1-3-gabc / v1.0.1-dirty → [1, 0, 1]；
    /// 破折号后缀（预发布/dirty/git describe 尾巴）丢弃，任一段非数字视为无法比较
    static func normalized(_ v: String) -> [Int]? {
        var core = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard !core.isEmpty else { return nil }
        if core.hasPrefix("v") { core.removeFirst() }
        if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
        guard !core.isEmpty else { return nil }
        var parts: [Int] = []
        for seg in core.split(separator: ".") {
            guard let n = Int(seg), n >= 0 else { return nil }
            parts.append(n)
        }
        return parts.isEmpty ? nil : parts
    }

    static func canCompare(local: String, remote: String) -> Bool {
        normalized(local) != nil && normalized(remote) != nil
    }

    /// 已装版本是否低于远端 Release 版本。任一侧无法解析（unknown / 裸二进制 / 非法 tag）
    /// = 不提示；逐段数值比较（1.10 > 1.9），短侧补 0（1.2 == 1.2.0）
    static func isOutdated(local: String, remote: String) -> Bool {
        guard var l = normalized(local), var r = normalized(remote) else { return false }
        if l.count < r.count { l.append(contentsOf: repeatElement(0, count: r.count - l.count)) }
        if r.count < l.count { r.append(contentsOf: repeatElement(0, count: l.count - r.count)) }
        for i in 0..<l.count where l[i] != r[i] {
            return l[i] < r[i]
        }
        return false
    }

    /// GitHub 按创建时间倒序返回 Release；空 Release 或附件上传不完整时跳过，
    /// 与 update.sh 选择同一个「最近可安装版本」，避免提示后下载 404。
    static func latestDownloadableTag(in releases: [[String: Any]]) -> String? {
        for release in releases {
            guard let tag = release["tag_name"] as? String, normalized(tag) != nil,
                  release["draft"] as? Bool != true, release["prerelease"] as? Bool != true
            else { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            let names = Set(assets.compactMap { $0["name"] as? String })
            if names.contains("GlmUsage.zip") && names.contains("GlmUsage.zip.sha256") {
                return tag
            }
        }
        return nil
    }
}

/// 更新检查状态：低频匿名请求 GitHub，失败静默保留旧结论（不打扰主刷新，也不弹任何东西）。
/// 状态只在主线程读写（回调统一 dispatch 回主线程），无需加锁。
final class UpdateChecker {
    static let shared = UpdateChecker()
    private(set) var available = false
    private(set) var targetTag: String?
    private var etag: String?
    private var lastCheck: Date?
    private var inFlight = false
    private var completions: [() -> Void] = []
    private var hasValidResult = false
    private(set) var lastError: String?

    /// force=false 时按 interval 节流；completion 固定主线程回调
    func check(force: Bool = false, completion: @escaping () -> Void = {}) {
        if inFlight { completions.append(completion); return }
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < UpdateCheck.interval {
            completion()
            return
        }
        inFlight = true
        completions.append(completion)
        var req = URLRequest(url: UpdateCheck.apiURL, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // ETag/304 语义自己管，不用 URLCache
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GlmUsage/1.0 (menubar; update check)", forHTTPHeaderField: "User-Agent")
        if let etag = etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                self.lastCheck = Date()
                let http = resp as? HTTPURLResponse
                if http?.statusCode == 304 && self.hasValidResult {
                    self.lastError = nil
                    // 内容未变：结论保持
                } else if err == nil, let data = data, http?.statusCode == 200,
                          let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    self.lastError = nil
                    self.hasValidResult = true
                    if let tag = UpdateCheck.latestDownloadableTag(in: releases) {
                        self.available = UpdateCheck.isOutdated(local: BuildInfo.version, remote: tag)
                        self.targetTag = self.available ? tag : nil
                    } else {
                        self.available = false
                        self.targetTag = nil
                    }
                    if let e = http?.value(forHTTPHeaderField: "ETag"), !e.isEmpty { self.etag = e }
                } else { self.lastError = "检查失败，请稍后重试" }
                let callbacks = self.completions; self.completions.removeAll()
                callbacks.forEach { $0() }
            }
        }.resume()
    }
}

// MARK: - App

final class GLMPanelStack: NSStackView { override var isFlipped: Bool { true } }

final class GLMPanelBackground: NSView {
    var opacity: CGFloat = 0.9 { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Colors describe remaining credit, including a neutral unknown state.
enum GLMRemainingColor {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    static func color(_ remaining: Double?) -> NSColor {
        NSColor(name: nil) { appearance in
            color(remaining, appearance: appearance)
        }
    }

    static func color(_ remaining: Double?, appearance: NSAppearance) -> NSColor {
        guard let r = remaining else { return .labelColor }
        let percent = Int((r * 100).rounded())
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if percent >= 80 { return rgb(dark ? 0x96CDA7 : 0x3E8660) }
        if percent >= 40 { return .labelColor }
        if percent >= 20 { return rgb(dark ? 0xE5A37D : 0xB46539) }
        return rgb(dark ? 0xF08B94 : 0xC8404A)
    }
}
final class GLMPanelCard: NSView {
    let content = GLMPanelStack()
    init() {
        super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 12; layer?.borderWidth = 0.5
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 4; content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: topAnchor, constant: 8), content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8), content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor; layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class GLMPanelAction: NSButton {
    var prominent = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor = prominent ? NSColor(calibratedRed: 0.04, green: 0.32, blue: 0.22, alpha: hovered ? 0.8 : 1) : NSColor.labelColor.withAlphaComponent(hovered ? 0.08 : 0)
            layer?.backgroundColor = color.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    // 行内文本和图标只负责显示；整个按钮区域统一接收鼠标事件。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: parent)) ? self : nil
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

final class GLMQuotaBar: NSView {
    let remaining: Double?
    init(_ remaining: Double?) { self.remaining = remaining; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false; heightAnchor.constraint(equalToConstant: 8).isActive = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        if let remaining = remaining {
            GLMRemainingColor.color(remaining).setFill()
            let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(1, remaining))), height: bounds.height)
            NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    // 状态栏底色随全屏进出/深浅模式翻转时，KVO 触发按新外观重画（否则浅色栏上残留白色余量文字）；
    // setImage 也会再次触发 KVO 通知，用明暗主题快照去重防止 renderBar↔KVO 反馈循环
    private var statusItemAppearanceObs: NSKeyValueObservation?
    private var barThemeDark: Bool?
    // NSStatusBarButton.effectiveAppearance 在深→浅方向有数十秒粘滞（退出全屏后按钮仍报深色，
    // 正是"白字要点击才恢复"的根因）：每 5s 对账按钮主题 vs 系统主题，不一致时 isVisible 轻推
    // 强制重解析；轻推限流 30s 防止闪烁。KVO 负责即时响应，对账负责兜底粘滞。
    private var appearancePollTimer: Timer?
    private var lastBarNudge: Date?
    private let popover = NSPopover()
    private let panelController = NSViewController()
    private let panelRoot = GLMPanelStack()
    private let panelScroll = NSScrollView()
    private let panelHeaderSlot = NSView()
    private let panelFooterSlot = NSView()
    private let panelEffect = NSVisualEffectView()
    private let panelBackground = GLMPanelBackground()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var panelConfigured = false
    private var previewWindow: NSWindow?
    private weak var activeScroll: NSScrollView?
    private var tokenExpanded = true
    private var expandedModelWindows: Set<Int> = []
    private var mcpExpanded = true
    private var updateMessage: String?
    private var updateMessageDismissal: DispatchWorkItem?
    private let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-popover") || CommandLine.arguments.contains("--preview-popover-test") || Bundle.main.bundleIdentifier == "com.local.glm-usage.preview" || (Bundle.main.object(forInfoDictionaryKey: "GLMPreviewPopover") as? Bool == true)
    private let previewPopover = CommandLine.arguments.contains("--preview-popover") || CommandLine.arguments.contains("--preview-popover-test") || (Bundle.main.object(forInfoDictionaryKey: "GLMPreviewPopover") as? Bool == true)
    private var timer: Timer?
    private var updateTimer: Timer?
    private var usage = UsageData()
    private var cycle = 0
    private let refreshGate = RefreshGate()
    private let quotaGate = RefreshGate()
    // 菜单打开期间不重建菜单（避免打开中的菜单被替换闪断），关闭时补一次
    private var menuOpen = false
    private var pendingMenuRebuild = false
    private let launchAgentLabel = "com.local.glm-usage"
    // token 统计每 N 个刷新周期拉一次（主循环 30s × 10 = 5 分钟；额度窗口每轮都刷）
    private let tokenEveryCycles = 10
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠️
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = 1800
    private var lastAttemptAt = Date()
    private var fiveHourLastOK: Date?
    private var weekLastOK: Date?
    private var tokensTodayLastOK: Date?
    private var tokens7dLastOK: Date?
    private var tokens30dLastOK: Date?
    private var toolsLastOK: Date?
    private var fiveHourCardsLastOK: Date?
    private var weekCardsLastOK: Date?
    private var subscriptionLastOK: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[GlmUsage] launched, creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        if preview {
            if CommandLine.arguments.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            installPreviewData()
            rebuildMenu()
            statusItem.button?.title = "GLM 预览"
            if previewPopover && CommandLine.arguments.contains("--preview-popover-ui") {
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 60), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "GLM 弹出层测试"
                window.isReleasedWhenClosed = false
                let openButton = NSButton(title: "开合菜单栏预览", target: self, action: #selector(togglePanel))
                openButton.frame = NSRect(x: 60, y: 14, width: 180, height: 32)
                window.contentView?.addSubview(openButton)
                previewWindow = window
                window.makeKeyAndOrderFront(nil)
            }
            if !previewPopover {
                previewWindow?.center()
                previewWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            if CommandLine.arguments.contains("--preview-auto-open") || CommandLine.arguments.contains("--preview-popover-test") || (Bundle.main.object(forInfoDictionaryKey: "GLMPreviewPopover") as? Bool == true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.togglePanel()
                    if CommandLine.arguments.contains("--preview-popover-test") { self?.testPreviewPopover() }
                }
            }
            if let i = CommandLine.arguments.firstIndex(of: "--preview-screenshot"), CommandLine.arguments.count > i + 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let view = self?.previewWindow?.contentView else { return }
                    view.layoutSubtreeIfNeeded()
                    if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        if let data = image.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
                    }
                }
            }
            return
        }
        rebuildMenu()
        renderBar()
        // 状态栏底色变化（全屏进出/深浅模式切换）时立即按新外观重画两行余量，不再等下一次数据刷新；
        // 仅在明暗主题实际变化时执行（setImage 会再次触发 KVO，不去重会形成重画循环）
        attachBarAppearanceObserver()
        appearancePollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reconcileBarAppearance()
        }
        appearancePollTimer?.tolerance = 1
        refresh(tokens: true)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cycle += 1
            self.refresh(tokens: GLMRefreshSchedule.slowItemsDue(cycle: self.cycle,
                every: self.tokenEveryCycles, manual: false))
        }
        // 显式容差让系统合并定时器唤醒（Apple 节能指南建议 ≥间隔 10%；30s → 6s）
        timer?.tolerance = 6
        // 更新检查：启动 20 秒后首查（避开启动网络高峰），此后每 30 分钟；
        // 打开菜单也会触发一次（同一 interval 节流，不增加请求频率）
        updateTimer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.interval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        updateTimer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdate() }
    }

    // 拉取数据
    private func refresh(tokens: Bool, manual: Bool = false) {
        GLMRefreshDispatch.start(slowDue: tokens || manual, quota: { refreshQuota(manual: manual) }, slow: {
            guard refreshGate.begin(manual: manual) else { return }
            performRefresh(tokens: true)
        })
    }

    private func refreshQuota(manual: Bool) {
        guard quotaGate.begin(manual: manual) else { return }
        guard let key = CredStore.loadApiKey() else {
            var failed = UsageData()
            failed.fiveHourError = "未找到 ZCode 凭证"; failed.weekError = failed.fiveHourError
            failed.quotaError = failed.fiveHourError
            finishQuota(failed)
            return
        }
        Fetcher.fetchQuota(apiKey: key) { [weak self] data in
            DispatchQueue.main.async { self?.finishQuota(data) }
        }
    }

    private func finishQuota(_ fresh: UsageData) {
        let now = Date()
        let five = GLMFreshness.apply(fresh: fresh.fiveHour, failure: fresh.fiveHourError,
            old: usage.fiveHour, oldLastOK: fiveHourLastOK, oldError: usage.fiveHourError, now: now)
        usage.fiveHour = five.value; fiveHourLastOK = five.lastOK; usage.fiveHourError = fresh.fiveHour != nil ? fresh.fiveHourError : five.error
        let week = GLMFreshness.apply(fresh: fresh.week, failure: fresh.weekError,
            old: usage.week, oldLastOK: weekLastOK, oldError: usage.weekError, now: now)
        usage.week = week.value; weekLastOK = week.lastOK; usage.weekError = fresh.week != nil ? fresh.weekError : week.error
        if fresh.fiveHour != nil || fresh.week != nil { usage.quotaError = nil }
        else if let error = fresh.quotaError { usage.quotaError = error }
        usage.level = fresh.level ?? usage.level
        updateUI()
        if quotaGate.finish() {
            _ = quotaGate.finish()
            refreshQuota(manual: false)
        }
    }

    private func performRefresh(tokens: Bool) {
        lastAttemptAt = Date()
        guard let key = CredStore.loadApiKey() else {
            var failed = UsageData()
            let error = "未找到 ZCode 凭证（~/.zcode/v2/credentials.json）"
            failed.quotaError = error
            failed.fiveHourError = error
            failed.weekError = error
            if tokens {
                failed.tokensTodayError = error
                failed.tokens7dError = error
                failed.tokens30dError = error
                failed.toolsError = error
                failed.fiveHourCardsError = error
                failed.weekCardsError = error
                failed.resetCardsError = error
                failed.subscriptionError = error
            }
            finishRefresh(failed, tokens: tokens)
            return
        }
        let accumulator = RefreshAccumulator()
        let group = DispatchGroup()

        if tokens {
            let now = Date()
            let dayStart = Calendar.current.startOfDay(for: now)
            let windows: [(label: Int, from: Date, to: Date)] = [
                (0, dayStart, now),
                (1, now.addingTimeInterval(-7 * 86400), now),
                (2, now.addingTimeInterval(-30 * 86400), now)
            ]
            let wg = DispatchGroup()
            for w in windows {
                wg.enter()
                Fetcher.fetchModelUsage(apiKey: key, from: w.from, to: w.to) { r, err in
                    accumulator.update { current in
                        switch w.label {
                        case 0:
                            current.tokensToday = r
                            current.tokensTodayError = r == nil ? (err ?? "no data") : nil
                        case 1:
                            current.tokens7d = r
                            current.tokens7dError = r == nil ? (err ?? "no data") : nil
                        default:
                            current.tokens30d = r
                            current.tokens30dError = r == nil ? (err ?? "no data") : nil
                        }
                    }
                    wg.leave()
                }
            }
            wg.enter()
            Fetcher.fetchToolUsage(apiKey: key, from: now.addingTimeInterval(-30 * 86400), to: now) { r, err in
                accumulator.update { current in
                    current.tools30d = r
                    current.toolsError = r == nil ? (err ?? "no data") : nil
                }
                wg.leave()
            }
            // 重置卡（额度重置卡）：ZCode 登录态 token 缺失/过期时优雅降级为错误提示
            if let (jwt, maas) = CredStore.loadResetTokens() {
                wg.enter()
                Fetcher.fetchResetCards(jwt: jwt, maas: maas) { r in
                    accumulator.update { current in
                        current.resetCards = ResetCards(fiveHour: r.fiveHour, week: r.week)
                        current.fiveHourCardsError = r.fiveHourError
                        current.weekCardsError = r.weekError
                        let errors = [r.fiveHourError, r.weekError].compactMap { $0 }
                        current.resetCardsError = errors.isEmpty ? nil : errors.joined(separator: "; ")
                    }
                    wg.leave()
                }
            } else {
                accumulator.update { current in
                    current.fiveHourCardsError = "未找到 ZCode 登录凭证"
                    current.weekCardsError = "未找到 ZCode 登录凭证"
                    current.resetCardsError = "未找到 ZCode 登录凭证"
                }
            }
            // 套餐到期（与重置卡同周期刷新）
            wg.enter()
            Fetcher.fetchSubscription(apiKey: key) { r, err in
                accumulator.update { current in
                    current.subscription = r
                    current.subscriptionSucceeded = err == nil
                    current.subscriptionError = err
                }
                wg.leave()
            }
            group.enter()
            wg.notify(queue: .global()) { group.leave() }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.finishRefresh(accumulator.snapshot(), tokens: tokens)
        }
    }

    private func finishRefresh(_ fresh: UsageData, tokens: Bool) {
        let now = Date()
        if tokens {
            let today = GLMFreshness.apply(fresh: fresh.tokensToday, failure: fresh.tokensTodayError,
                old: usage.tokensToday, oldLastOK: tokensTodayLastOK, oldError: usage.tokensTodayError, now: now)
            usage.tokensToday = today.value; tokensTodayLastOK = today.lastOK; usage.tokensTodayError = today.error
            let seven = GLMFreshness.apply(fresh: fresh.tokens7d, failure: fresh.tokens7dError,
                old: usage.tokens7d, oldLastOK: tokens7dLastOK, oldError: usage.tokens7dError, now: now)
            usage.tokens7d = seven.value; tokens7dLastOK = seven.lastOK; usage.tokens7dError = seven.error
            let thirty = GLMFreshness.apply(fresh: fresh.tokens30d, failure: fresh.tokens30dError,
                old: usage.tokens30d, oldLastOK: tokens30dLastOK, oldError: usage.tokens30dError, now: now)
            usage.tokens30d = thirty.value; tokens30dLastOK = thirty.lastOK; usage.tokens30dError = thirty.error
            let tools = GLMFreshness.apply(fresh: fresh.tools30d, failure: fresh.toolsError,
                old: usage.tools30d, oldLastOK: toolsLastOK, oldError: usage.toolsError, now: now)
            usage.tools30d = tools.value; toolsLastOK = tools.lastOK; usage.toolsError = tools.error

            let hasCardBatch = fresh.resetCards != nil
            let fiveCards = GLMFreshness.apply(fresh: fresh.resetCards?.fiveHour, failure: fresh.fiveHourCardsError,
                old: usage.resetCards?.fiveHour, oldLastOK: fiveHourCardsLastOK, oldError: usage.fiveHourCardsError, now: now)
            let weekCards = GLMFreshness.apply(fresh: fresh.resetCards?.week, failure: fresh.weekCardsError,
                old: usage.resetCards?.week, oldLastOK: weekCardsLastOK, oldError: usage.weekCardsError, now: now)
            fiveHourCardsLastOK = fiveCards.lastOK; weekCardsLastOK = weekCards.lastOK
            usage.fiveHourCardsError = fiveCards.error; usage.weekCardsError = weekCards.error
            if hasCardBatch || usage.resetCards != nil {
                usage.resetCards = ResetCards(fiveHour: fiveCards.value, week: weekCards.value)
            }
            if let error = fresh.resetCardsError { usage.resetCardsError = error }
            else if fresh.resetCards != nil { usage.resetCardsError = nil }

            let subscription = GLMSubscriptionFreshness.apply(fresh: fresh.subscription, succeeded: fresh.subscriptionSucceeded,
                failure: fresh.subscriptionError, old: usage.subscription, oldLastOK: subscriptionLastOK,
                oldError: usage.subscriptionError, now: now)
            usage.subscription = subscription.0; subscriptionLastOK = subscription.1; usage.subscriptionError = subscription.2
        }

        let tokenErrors = [usage.tokensTodayError, usage.tokens7dError, usage.tokens30dError, usage.toolsError]
            .compactMap { $0 }
        usage.tokensError = tokenErrors.isEmpty ? nil : tokenErrors.joined(separator: "; ")
        updateUI()
        if refreshGate.finish() { performRefresh(tokens: true) }
    }

    /// 菜单栏图标 + 下拉菜单的统一渲染入口；菜单打开期间延迟重建到关闭时
    private func updateUI() {
        renderBar()
        rebuildMenu()
    }

    // 打开菜单即触发一轮全量刷新（RefreshGate 防重入、合并重复请求）与一次节流更新检查；
    // 数据到位时若菜单仍打开，重建延迟到关闭后，下次打开即为最新
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        refresh(tokens: false)
        checkForUpdate()   // 节流共享 30 分钟 interval，不增加 GitHub 请求频率
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if pendingMenuRebuild {
            pendingMenuRebuild = false
            rebuildMenu()
        }
    }

    // 过期判定：距最后成功超过阈值即过期；有数据但 lastOK 为 nil（异常情况）也视为过期。
    // 无数据不算过期——菜单里本就显示"暂无数据"，无需再标注。
    private func isStale(_ lastOK: Date?, hasData: Bool, after: TimeInterval) -> Bool {
        GLMFreshness.isStale(lastSuccess: lastOK, hasData: hasData, now: Date(), after: after)
    }
    private var fiveHourStale: Bool { isStale(fiveHourLastOK, hasData: usage.fiveHour != nil, after: quotaStaleAfter) }
    private var weekStale: Bool { isStale(weekLastOK, hasData: usage.week != nil, after: quotaStaleAfter) }
    private var tokensTodayStale: Bool { isStale(tokensTodayLastOK, hasData: usage.tokensToday != nil, after: tokensStaleAfter) }
    private var tokens7dStale: Bool { isStale(tokens7dLastOK, hasData: usage.tokens7d != nil, after: tokensStaleAfter) }
    private var tokens30dStale: Bool { isStale(tokens30dLastOK, hasData: usage.tokens30d != nil, after: tokensStaleAfter) }
    private var toolsStale: Bool { isStale(toolsLastOK, hasData: usage.tools30d != nil, after: tokensStaleAfter) }
    private var fiveHourCardsStale: Bool {
        isStale(fiveHourCardsLastOK, hasData: usage.resetCards?.fiveHour != nil, after: 900)
    }
    private var weekCardsStale: Bool {
        isStale(weekCardsLastOK, hasData: usage.resetCards?.week != nil, after: 900)
    }
    private var subscriptionStale: Bool {
        isStale(subscriptionLastOK, hasData: usage.subscription != nil, after: 900)
    }

    private func attachBarAppearanceObserver() {
        statusItemAppearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.renderBarIfThemeChanged() }
        }
    }

    /// 按钮/系统主题对账：粘滞（按钮仍报旧主题）时轻推状态栏项强制重解析，再按需重画
    private func reconcileBarAppearance() {
        guard let button = statusItem?.button else { return }
        let appDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let buttonDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if buttonDark != appDark,
           lastBarNudge.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            lastBarNudge = Date()
            statusItem.isVisible = false
            statusItem.isVisible = true
            // isVisible 切换可能重建按钮实例，重新挂 KVO
            attachBarAppearanceObserver()
        }
        renderBarIfThemeChanged()
    }

    /// 仅当按钮解析出的明暗主题与上次渲染快照不同时才重画（防止 setImage↔KVO 循环）
    private func renderBarIfThemeChanged() {
        guard let button = statusItem?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != barThemeDark else { return }
        renderBar()
    }

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）；峰谷/过期 emoji 作为 badge 向左突出，正文列保持对齐
    // （⚠️ 放在峰谷 emoji 之后，不影响 Peak 判定；token 组无菜单栏行，仅在下拉菜单标注）
    private func renderBar() {
        let peak = Peak.evaluate()
        let fiveRemaining = usage.fiveHour?.usedRemainingRatio
        let weekRemaining = usage.week?.usedRemainingRatio
        let marks1 = [peak.emoji, fiveHourStale ? "⚠️" : nil].compactMap { $0 }
        let marks2: [String] = weekStale ? ["⚠️"] : []
        let line1 = StackImage.Line(badge: marks1.joined(), label: "5H",
                                    value: Fmt.pct(fiveRemaining), remaining: fiveRemaining)
        let line2 = StackImage.Line(badge: marks2.joined(), label: "7D",
                                    value: Fmt.pct(weekRemaining), remaining: weekRemaining)
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        barThemeDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "GLM 余额 · 5H最后成功 \(Fmt.lastOK(fiveHourLastOK))"
            + " · 7D最后成功 \(Fmt.lastOK(weekLastOK))"
            + " · 今日Token最后成功 \(Fmt.lastOK(tokensTodayLastOK))"
            + " · 7天Token最后成功 \(Fmt.lastOK(tokens7dLastOK))"
            + " · 30天Token最后成功 \(Fmt.lastOK(tokens30dLastOK))"
            + " · MCP最后成功 \(Fmt.lastOK(toolsLastOK))"
        writeStatus(line1: (marks1.isEmpty ? "" : marks1.joined() + " ") + "\(line1.label) \(line1.value)",
                    line2: (marks2.isEmpty ? "" : marks2.joined() + " ") + "\(line2.label) \(line2.value)",
                    peakLine: peak.line)
    }

    // 自诊断：把渲染内容写到本地，便于排查
    private func writeStatus(line1: String, line2: String, peakLine: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/GlmUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 重置卡/套餐自诊断（只含到期时间与名称，不含任何密钥）
        var cardsStatus: [String] = []
        if let c = usage.resetCards {
            cardsStatus += GLMFreshness.availableCards(c.fiveHour ?? [], now: Date())
                .map { "5h:" + Fmt.fullTime.string(from: $0) }
            cardsStatus += GLMFreshness.availableCards(c.week ?? [], now: Date())
                .map { "week:" + Fmt.fullTime.string(from: $0) }
        }
        let lastSuccess: [String: String] = [
            "fiveHour": fiveHourLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "week": weekLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "tokensToday": tokensTodayLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "tokens7d": tokens7dLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "tokens30d": tokens30dLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "tools30d": toolsLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "fiveHourCards": fiveHourCardsLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "weekCards": weekCardsLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "subscription": subscriptionLastOK.map { Fmt.iso8601.string(from: $0) } ?? ""
        ]
        let stale: [String: Bool] = [
            "fiveHour": fiveHourStale, "week": weekStale,
            "tokensToday": tokensTodayStale, "tokens7d": tokens7dStale,
            "tokens30d": tokens30dStale, "tools30d": toolsStale,
            "fiveHourCards": fiveHourCardsStale, "weekCards": weekCardsStale,
            "subscription": subscriptionStale
        ]
        let errors: [String: String] = [
            "fiveHour": usage.fiveHourError ?? "", "week": usage.weekError ?? "",
            "tokensToday": usage.tokensTodayError ?? "", "tokens7d": usage.tokens7dError ?? "",
            "tokens30d": usage.tokens30dError ?? "", "tools30d": usage.toolsError ?? "",
            "fiveHourCards": usage.fiveHourCardsError ?? "", "weekCards": usage.weekCardsError ?? "",
            "subscription": usage.subscriptionError ?? ""
        ]
        let info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "peak": peakLine,
            "updatedAt": Fmt.iso8601.string(from: lastAttemptAt),
            "lastAttemptAt": Fmt.iso8601.string(from: lastAttemptAt),
            "version": BuildInfo.version,
            "updateAvailable": UpdateChecker.shared.available,
            "lastSuccess": lastSuccess,
            "stale": stale,
            "errors": errors,
            "fiveHourRemaining": usage.fiveHour?.usedRemainingRatio ?? -1,
            "weekRemaining": usage.week?.usedRemainingRatio ?? -1,
            "level": usage.level ?? "",
            "quotaError": usage.quotaError ?? "",
            "tokensError": usage.tokensError ?? "",
            "resetCards": cardsStatus,
            "subscription": usage.subscription?.name ?? "",
            "subscriptionExpire": usage.subscription?.expireDate.map { Fmt.iso8601.string(from: $0) } ?? ""
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/status.json"))
        }
    }

    // 下拉面板
    private func rebuildMenu() {
        let menu = NSMenu()

        // 更新横幅（最上方）：GitHub 发布了更高版本的 Release 才出现（与 commit 动态无关）；
        // 点击运行 .app 内置 update.sh 从 Release 下载替换，内置脚本缺失时退化为打开 Releases 页
        if UpdateChecker.shared.available {
            let banner = NSMenuItem(title: "⬆ 新版本可用，点击更新", action: #selector(onUpdateApp), keyEquivalent: "")
            banner.target = self
            menu.addItem(banner)
            menu.addItem(.separator())
        }

        func info(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        menu.addItem(info("GLM 余额" + (usage.level.map { "（\($0) 套餐）" } ?? "")))
        menu.addItem(.separator())

        func limitLine(_ e: LimitEntry?, label: String, lastOK: Date?, stale: Bool, error: String?) -> String {
            var s = "\(label)："
            if let e = e {
                s += "剩余 \(Fmt.pctLong(e.usedRemainingRatio))"
                if e.limit > 0 { s += "（剩 \(Fmt.credits(e.remaining)) / \(Fmt.credits(e.limit)) credits）" }
                if e.reset != nil { s += e.isFiveHour ? "（\(Fmt.time(e.reset)) 重置）" : "（\(Fmt.dayTime(e.reset)) 重置）" }
            } else { s += "暂无数据" }
            if stale { s += " · ⚠️ 数据已过期" }
            if let error = error { s += " · 刷新失败：\(error)" }
            if lastOK != nil, stale || error != nil { s += " · 最后成功 \(Fmt.lastOK(lastOK))" }
            return s
        }
        menu.addItem(info(limitLine(usage.fiveHour, label: "5 小时窗口", lastOK: fiveHourLastOK,
                                  stale: fiveHourStale, error: usage.fiveHourError)))
        menu.addItem(info(limitLine(usage.week, label: "7 天额度", lastOK: weekLastOK,
                                  stale: weekStale, error: usage.weekError)))

        menu.addItem(.separator())

        // 峰谷状态 + 限时活动
        let pk = Peak.evaluate()
        menu.addItem(info(pk.line))
        if let ev = pk.eventLine { menu.addItem(info(ev)) }

        // 重置卡（额度重置卡）板块：首轮未拉到数据时不画分隔线，避免连续双 separator；≤72 小时临期加 ⚠️
        if usage.resetCards != nil || usage.resetCardsError != nil {
            menu.addItem(.separator())
        }
        func cardLine(_ label: String, _ d: Date) -> String {
            let warn = d.timeIntervalSinceNow <= 72 * 3600
            return (warn ? "⚠️ " : "  ") + "\(label) · \(Fmt.expires(d)) 过期"
        }
        if let cards = usage.resetCards {
            let f5 = GLMFreshness.availableCards(cards.fiveHour ?? [], now: Date())
            let wk = GLMFreshness.availableCards(cards.week ?? [], now: Date())
            var parts: [String] = []
            if cards.fiveHour != nil { parts.append("5 小时 ×\(f5.count)") }
            if cards.week != nil { parts.append("周 ×\(wk.count)") }
            let bothKnownEmpty = cards.fiveHour != nil && cards.week != nil && f5.isEmpty && wk.isEmpty
            if bothKnownEmpty {
                menu.addItem(info("重置卡：暂无可用"))
            } else {
                if !parts.isEmpty { menu.addItem(info("重置卡：" + parts.joined(separator: " · "))) }
                for d in f5 { menu.addItem(info(cardLine("5 小时卡", d))) }
                for d in wk { menu.addItem(info(cardLine("周卡", d))) }
            }
        }
        if let e = usage.fiveHourCardsError {
            let short = e
            menu.addItem(info("5 小时卡获取失败：\(short)（ZCode 登录态可能过期，打开 ZCode 客户端刷新后重试） · 最后成功 \(Fmt.lastOK(fiveHourCardsLastOK))"))
        }
        if fiveHourCardsStale { menu.addItem(info("⚠️ 5 小时卡数据已过期 · 最后成功 \(Fmt.lastOK(fiveHourCardsLastOK))")) }
        if let e = usage.weekCardsError {
            let short = e
            menu.addItem(info("周卡获取失败：\(short)（ZCode 登录态可能过期，打开 ZCode 客户端刷新后重试） · 最后成功 \(Fmt.lastOK(weekCardsLastOK))"))
        }
        if weekCardsStale { menu.addItem(info("⚠️ 周卡数据已过期 · 最后成功 \(Fmt.lastOK(weekCardsLastOK))")) }

        // Token 用量（服务端统计）
        menu.addItem(.separator())
        menu.addItem(info("Token 用量（服务端统计）"))
        func addTokenSection(_ label: String, _ stats: ModelUsage?, lastOK: Date?, stale: Bool, error: String?) {
            var lines: [String]
            if let stats = stats, !stats.isEmpty {
                lines = ["\(label)：\(Fmt.tokens(stats.totalTokens)) tokens · 调用 \(Fmt.count(stats.totalCalls)) 次"]
                lines += TokenModelList.render(stats.byModel)
            } else {
                lines = ["\(label)：暂无记录"]
            }
            if stale { lines[0] += " · ⚠️ 数据已过期" }
            if let error = error { lines[0] += " · 刷新失败：\(error)" }
            if lastOK != nil, stale || error != nil { lines[0] += " · 最后成功 \(Fmt.lastOK(lastOK))" }
            for line in lines { menu.addItem(info(line)) }
        }
        addTokenSection("今日", usage.tokensToday, lastOK: tokensTodayLastOK,
                        stale: tokensTodayStale, error: usage.tokensTodayError)
        addTokenSection("近 7 天", usage.tokens7d, lastOK: tokens7dLastOK,
                        stale: tokens7dStale, error: usage.tokens7dError)
        addTokenSection("近 30 天", usage.tokens30d, lastOK: tokens30dLastOK,
                        stale: tokens30dStale, error: usage.tokens30dError)

        if let t = usage.tools30d {
            menu.addItem(.separator())
            var line = "MCP 工具（近 30 天）：网络搜索 \(Fmt.count(t.networkSearch)) 次 · 网页读取 \(Fmt.count(t.webRead)) 次"
            if toolsStale { line += " · ⚠️ 数据已过期 · 最后成功 \(Fmt.lastOK(toolsLastOK))" }
            menu.addItem(info(line))
        }
        if let e = usage.toolsError { menu.addItem(info("MCP 工具刷新失败：\(e) · 最后成功 \(Fmt.lastOK(toolsLastOK))")) }

        menu.addItem(.separator())
        menu.addItem(info("最近尝试刷新 \(Fmt.fullTime.string(from: lastAttemptAt))"))
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(onRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (!preview && isLoginItemEnabled()) ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(info("版本 \(BuildInfo.version)"))
        let quit = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        buildPanel(menu)

    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        if !preview { refresh(tokens: false); checkForUpdate() }
        rebuildMenu()
        if let button = statusItem.button {
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            panelBackground.opacity = reduceTransparency ? 1 : 0.9
            panelEffect.isHidden = reduceTransparency
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if popover.isShown { installClickMonitors() }
        }
        tracePopover("open")
    }
    private func installClickMonitors() {
        removeClickMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self = self, self.popover.isShown else { return }
                if let button = self.statusItem.button, let window = button.window,
                   window.convertToScreen(button.convert(button.bounds, to: nil)).contains(location) { return }
                self.popover.performClose(nil)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self = self, self.popover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.popover.performClose(nil); return nil }
                return event
            }
            if event.window === self.panelController.view.window || event.window === self.statusItem.button?.window { return event }
            self.popover.performClose(nil)
            return event
        }
    }

    private func removeClickMonitors() {
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor); globalClickMonitor = nil }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor); localClickMonitor = nil }
    }

    func popoverDidClose(_ notification: Notification) {
        removeClickMonitors()
        if previewPopover && CommandLine.arguments.contains("--preview-trace") {
            print("GLM_POPOVER_TRACE closed")
            fflush(stdout)
        }
    }

    @objc private func toggleToken() { tokenExpanded.toggle(); rebuildMenu() }
    @objc private func toggleModels(_ sender: NSButton) {
        let index = sender.tag
        guard (0..<3).contains(index) else { return }
        if expandedModelWindows.contains(index) { expandedModelWindows.remove(index) }
        else { expandedModelWindows.insert(index) }
        rebuildMenu()
    }
    @objc private func toggleMCP() { mcpExpanded.toggle(); rebuildMenu() }
    // 版本点击等临时状态行；dismissAfter 到点后自动清除（与 CodexUsage 一致）
    private func setUpdateMessage(_ message: String?, dismissAfter: TimeInterval? = nil) {
        updateMessageDismissal?.cancel()
        updateMessageDismissal = nil
        updateMessage = message
        rebuildMenu()
        if message != nil, let delay = dismissAfter {
            let dismissal = DispatchWorkItem { [weak self] in self?.setUpdateMessage(nil) }
            updateMessageDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismissal)
        }
    }

    @objc private func manualUpdate() {
        if preview { setUpdateMessage("预览：当前已是最新版本", dismissAfter: 3); return }
        setUpdateMessage("正在检查更新…")
        UpdateChecker.shared.check(force: true) { [weak self] in
            guard let self = self else { return }
            let message = UpdateChecker.shared.lastError ?? (UpdateChecker.shared.available ? "发现新版本" : "当前已是最新版本")
            self.setUpdateMessage(message, dismissAfter: 3)
        }
    }

    private func installPreviewData() {
        let now = Date()
        usage.level = "Pro"
        usage.fiveHour = LimitEntry(label: "5 小时窗口", isFiveHour: true, limit: 2000, used: 640, remaining: 1360, usedRatio: 0.32, reset: now.addingTimeInterval(7200))
        usage.week = LimitEntry(label: "7 天额度", isFiveHour: false, limit: 10000, used: 2700, remaining: 7300, usedRatio: 0.27, reset: now.addingTimeInterval(259200))
        let stats = ModelUsage(totalTokens: 1840000, totalCalls: 142, byModel: [("glm-4.7", 1200000), ("glm-4.5-air", 640000)])
        usage.tokensToday = stats; usage.tokens7d = stats; usage.tokens30d = stats
        usage.tools30d = ToolUsage(networkSearch: 36, webRead: 18)
        usage.resetCards = ResetCards(fiveHour: [now.addingTimeInterval(864000)], week: [now.addingTimeInterval(1728000)])
        fiveHourLastOK = now; weekLastOK = now; tokensTodayLastOK = now; tokens7dLastOK = now; tokens30dLastOK = now; toolsLastOK = now; fiveHourCardsLastOK = now; weekCardsLastOK = now
        if CommandLine.arguments.contains("--preview-quota-alignment") {
            usage.fiveHour = LimitEntry(label: "5 小时窗口", isFiveHour: true, limit: 2000, used: 0, remaining: 2000, usedRatio: 0, reset: nil)
            usage.subscription = SubscriptionInfo(name: "GLM Coding Pro", expireDate: Date(timeIntervalSince1970: 1_820_000_000))
            subscriptionLastOK = now
        }
        if CommandLine.arguments.contains("--preview-empty") {
            usage.tokensToday = nil
            usage.tokens7d = ModelUsage(totalTokens: 0, totalCalls: 0, byModel: [])
        }
        if CommandLine.arguments.contains("--preview-errors") {
            usage.week = nil; usage.weekError = "模拟网络错误：无法获取额度"
            usage.tokensTodayError = "模拟服务端错误，保留上次结果"
            usage.toolsError = "模拟 MCP 认证失败"
            usage.fiveHourCardsError = "模拟登录过期"
        }
        if CommandLine.arguments.contains("--preview-long") {
            expandedModelWindows.insert(0)
            usage.tokensToday = ModelUsage(totalTokens: 9000000, totalCalls: 500, byModel: (1...30).map { ("glm-very-long-model-name-\($0)", Double($0 * 10000)) })
        }
    }

    private func buildPanel(_ menu: NSMenu) {
        let savedOffset = activeScroll?.contentView.bounds.origin ?? .zero
        let width: CGFloat = CommandLine.arguments.contains("--preview-narrow") ? 280 : 336
        let inner = width - 32
        let root = panelRoot
        for view in root.arrangedSubviews { root.removeArrangedSubview(view); view.removeFromSuperview() }
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        func label(_ text: String, size: CGFloat = 11, bold: Bool = false, color: NSColor = .labelColor) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: text); f.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular); f.textColor = color
            f.lineBreakMode = .byWordWrapping; f.maximumNumberOfLines = 0; return f
        }
        func row() -> NSStackView { let r = NSStackView(); r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 4; return r }
        func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.init(1), for: .horizontal); v.setContentCompressionResistancePriority(.init(1), for: .horizontal); return v }
        func symbol(_ name: String, color: NSColor = NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.38, alpha: 1)) -> NSImageView {
            let v = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()); v.contentTintColor = color
            v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular); v.setContentHuggingPriority(.required, for: .horizontal); return v
        }
        func separator() -> NSBox { let line = NSBox(); line.boxType = .separator; line.heightAnchor.constraint(equalToConstant: 1).isActive = true; return line }
        func button(_ title: String, _ action: Selector, prominent: Bool = false) -> GLMPanelAction {
            let b = GLMPanelAction(title: title, target: self, action: action); b.isBordered = false; b.focusRingType = .none; b.wantsLayer = true; b.layer?.cornerRadius = 6; b.prominent = prominent
            b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: prominent ? NSColor.white : NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: prominent ? .semibold : .regular)])
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: prominent ? 30 : 24).isActive = true
            return b
        }
        func section(_ title: String, icon: String, expanded: Bool, action: Selector) -> NSView {
            let header = row(); header.spacing = 6; header.addArrangedSubview(symbol(icon)); header.addArrangedSubview(label(title, size: 12, bold: true)); header.addArrangedSubview(spacer())
            let arrow = NSImageView(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil) ?? NSImage())
            arrow.contentTintColor = .secondaryLabelColor; arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
            arrow.widthAnchor.constraint(equalToConstant: 24).isActive = true; arrow.heightAnchor.constraint(equalToConstant: 22).isActive = true; header.addArrangedSubview(arrow)
            let item = GLMPanelAction(title: "", target: self, action: action)
            item.isBordered = false; item.wantsLayer = true; item.layer?.cornerRadius = 6
            let actionTitle = (expanded ? "收起" : "展开") + title
            item.setAccessibilityLabel(actionTitle)
            item.toolTip = actionTitle
            header.translatesAutoresizingMaskIntoConstraints = false; item.addSubview(header)
            NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: item.leadingAnchor), header.trailingAnchor.constraint(equalTo: item.trailingAnchor), header.centerYAnchor.constraint(equalTo: item.centerYAnchor)])
            item.heightAnchor.constraint(equalToConstant: 26).isActive = true
            return item
        }
        func quota(_ entry: LimitEntry?, _ name: String, _ error: String?, _ last: Date?, _ stale: Bool) {
            let r = row()
            let title = label(name, size: 11, bold: true); title.widthAnchor.constraint(equalToConstant: 36).isActive = true; r.addArrangedSubview(title)
            let ratio = entry?.usedRemainingRatio
            let pct = label(Fmt.pct(ratio), size: 12, bold: true, color: GLMRemainingColor.color(ratio)); pct.widthAnchor.constraint(equalToConstant: 34).isActive = true; r.addArrangedSubview(pct)
            let bar = GLMQuotaBar(ratio); bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true; r.addArrangedSubview(bar)
            let reset = label(entry?.reset.map { Fmt.fullTime.string(from: $0) } ?? "时间未知", size: 10, bold: true)
            reset.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            reset.alignment = .right
            reset.lineBreakMode = .byTruncatingTail
            reset.maximumNumberOfLines = 1
            reset.widthAnchor.constraint(equalToConstant: 110).isActive = true
            reset.setContentCompressionResistancePriority(.required, for: .horizontal); r.addArrangedSubview(reset); add(r)
            if let e = entry { add(label("剩余 \(Fmt.credits(e.remaining)) / \(Fmt.credits(e.limit)) credits", color: .secondaryLabelColor)) }
            else { add(label("暂无数据", color: .secondaryLabelColor)) }
            if let e = error { add(label("\(entry == nil ? "刷新失败" : "部分数据异常")：\(e) · 最后成功 \(Fmt.lastOK(last))", color: .systemRed)) }
            else if stale { add(label("数据已过期 · 最后成功 \(Fmt.lastOK(last))", color: .systemOrange)) }
        }
        if UpdateChecker.shared.available && !preview { add(button("⬆ 新版本可用，点击更新", #selector(onUpdateApp), prominent: true)) }
        let resetHeading = label("重置时间", size: 10, color: .secondaryLabelColor); resetHeading.alignment = .right; add(resetHeading)
        quota(usage.fiveHour, "5 小时", usage.fiveHourError, fiveHourLastOK, fiveHourStale)
        quota(usage.week, "7 天", usage.weekError, weekLastOK, weekStale)
        if let sub = usage.subscription {
            let expiry = sub.expireDate.map { "套餐到期：\(Fmt.fullTime.string(from: $0))" } ?? "套餐到期：暂无数据"
            add(label(expiry, color: .secondaryLabelColor))
        }
        if let error = usage.subscriptionError { add(label("套餐刷新失败：\(error) · 最后成功 \(Fmt.lastOK(subscriptionLastOK))", color: .systemRed)) }
        else if subscriptionStale { add(label("套餐数据已过期 · 最后成功 \(Fmt.lastOK(subscriptionLastOK))", color: .systemOrange)) }
        let peak = Peak.evaluate()
        let peakCard = GLMPanelCard()
        let peakTitle = row(); peakTitle.spacing = 8; peakTitle.addArrangedSubview(symbol("clock")); peakTitle.addArrangedSubview(label("峰谷状态", size: 13, bold: true)); peakTitle.addArrangedSubview(spacer())
        peakCard.content.addArrangedSubview(peakTitle); peakTitle.widthAnchor.constraint(equalTo: peakCard.content.widthAnchor).isActive = true
        for line in [peak.line, peak.eventLine].compactMap({ $0 }) {
            let field = label(line, size: 11); peakCard.content.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: peakCard.content.widthAnchor).isActive = true
        }
        add(peakCard)
        let cards = GLMPanelCard(); let cardHead = row(); cardHead.spacing = 8; cardHead.addArrangedSubview(symbol("calendar")); cardHead.addArrangedSubview(label("重置卡", size: 13, bold: true)); cardHead.addArrangedSubview(spacer())
        cards.content.addArrangedSubview(cardHead); cardHead.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true
        if let c = usage.resetCards {
            for (name, dates) in [("5 小时卡", c.fiveHour), ("周卡", c.week)] {
                if let dates = dates {
                    let available = GLMFreshness.availableCards(dates, now: Date())
                    if available.isEmpty { let l = label("\(name) · 暂无可用", color: .secondaryLabelColor); cards.content.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true }
                    for d in available { let l = label("\(name) · \(Fmt.expires(d)) 过期", color: d.timeIntervalSinceNow <= 72 * 3600 ? .systemOrange : .labelColor); cards.content.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true }
                }
            }
        } else { let l = label("暂无数据", color: .secondaryLabelColor); cards.content.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true }
        for (name, error, stale, last) in [("5 小时卡", usage.fiveHourCardsError, fiveHourCardsStale, fiveHourCardsLastOK), ("周卡", usage.weekCardsError, weekCardsStale, weekCardsLastOK)] {
            let message: String? = error.map { "\(name)获取失败：\($0)（ZCode 登录态可能过期，打开 ZCode 后重试） · 最后成功 \(Fmt.lastOK(last))" } ?? (stale ? "\(name)数据已过期 · 最后成功 \(Fmt.lastOK(last))" : nil)
            if let message = message { let l = label(message, color: .systemRed); cards.content.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true }
        }
        add(cards)
        add(section("Token 用量（服务端统计）", icon: "square.stack.3d.up.fill", expanded: tokenExpanded, action: #selector(toggleToken)))
        let windows: [(String, ModelUsage?, Date?, Bool, String?)] = [
            ("今日", usage.tokensToday, tokensTodayLastOK, tokensTodayStale, usage.tokensTodayError),
            ("近 7 天", usage.tokens7d, tokens7dLastOK, tokens7dStale, usage.tokens7dError),
            ("近 30 天", usage.tokens30d, tokens30dLastOK, tokens30dStale, usage.tokens30dError)]
        func tableCells(_ values: [String], header: Bool, modelDetail: Bool = false) -> NSStackView {
            let r = row(); r.spacing = 4
            let widths = [inner * 0.44, inner * 0.24, inner * 0.20]
            for (index, text) in values.enumerated() {
                let color: NSColor = header || modelDetail ? .secondaryLabelColor : (index == 1 ? NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.38, alpha: 1) : .labelColor)
                let f = label(text, size: header ? 10 : 11, bold: !header && !modelDetail && index > 0, color: color)
                if index > 0 { f.alignment = .right }
                if modelDetail {
                    f.maximumNumberOfLines = 1
                    f.lineBreakMode = index == 0 ? .byTruncatingMiddle : .byTruncatingTail
                    if index == 0 { f.toolTip = text }
                    if index == 1 { f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
                }
                if modelDetail && index == 0 {
                    let cell = row(); cell.spacing = 0
                    cell.widthAnchor.constraint(equalToConstant: widths[index]).isActive = true
                    let indent = spacer(); indent.widthAnchor.constraint(equalToConstant: 12).isActive = true
                    f.widthAnchor.constraint(equalToConstant: widths[index] - 12).isActive = true
                    cell.addArrangedSubview(indent); cell.addArrangedSubview(f); r.addArrangedSubview(cell)
                } else {
                    f.widthAnchor.constraint(equalToConstant: widths[index]).isActive = true
                    r.addArrangedSubview(f)
                }
            }
            return r
        }
        if tokenExpanded {
            let tableHeader = tableCells(["周期", "Token", "调用次数"], header: true); add(tableHeader)
            for (index, window) in windows.enumerated() {
                let (name, stats, _, _, _) = window
                let models = stats.map { TokenModelList.visible($0.byModel) } ?? []
                let expanded = expandedModelWindows.contains(index)
                let cells = tableCells([name, stats.map { Fmt.tokens($0.totalTokens) } ?? "--", stats.map { Fmt.count($0.totalCalls) } ?? "--"], header: false)
                let item = GLMPanelAction(title: "", target: self, action: #selector(toggleModels(_:)))
                item.isBordered = false; item.wantsLayer = true; item.layer?.cornerRadius = 5; item.tag = index
                item.isEnabled = !models.isEmpty
                let summary = "\(name)，Token \(stats.map { Fmt.tokens($0.totalTokens) } ?? "暂无数据")，调用 \(stats.map { Fmt.count($0.totalCalls) } ?? "暂无数据") 次"
                item.setAccessibilityLabel(summary + (models.isEmpty ? "，无模型明细" : "，\(expanded ? "收起" : "展开")模型明细"))
                item.toolTip = models.isEmpty ? "暂无模型明细" : (expanded ? "收起模型明细" : "展开模型明细")
                cells.translatesAutoresizingMaskIntoConstraints = false; item.addSubview(cells)
                NSLayoutConstraint.activate([cells.leadingAnchor.constraint(equalTo: item.leadingAnchor), cells.centerYAnchor.constraint(equalTo: item.centerYAnchor)])
                if !models.isEmpty {
                    let arrow = NSImageView(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil) ?? NSImage())
                    arrow.contentTintColor = .secondaryLabelColor; arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
                    arrow.translatesAutoresizingMaskIntoConstraints = false; item.addSubview(arrow)
                    NSLayoutConstraint.activate([arrow.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: -3), arrow.centerYAnchor.constraint(equalTo: item.centerYAnchor)])
                }
                item.heightAnchor.constraint(equalToConstant: 23).isActive = true; add(item)
                if expanded {
                    root.setCustomSpacing(4, after: item)
                    for (modelIndex, model) in models.enumerated() {
                        let detail = tableCells([model.name, Fmt.tokens(model.tokens), ""], header: false, modelDetail: true)
                        detail.heightAnchor.constraint(equalToConstant: 20).isActive = true
                        add(detail)
                        root.setCustomSpacing(modelIndex == models.count - 1 ? 12 : 4, after: detail)
                    }
                }
            }
        }
        for (name, _, last, stale, error) in windows {
            if let error = error { add(label("\(name)刷新失败：\(error) · 最后成功 \(Fmt.lastOK(last))", color: .systemRed)) }
            else if stale { add(label("\(name)数据已过期 · 最后成功 \(Fmt.lastOK(last))", color: .systemOrange)) }
        }
        add(section("MCP 工具（近 30 天）", icon: "square.stack.3d.up", expanded: mcpExpanded, action: #selector(toggleMCP)))
        if mcpExpanded {
            if let t = usage.tools30d { add(label("网络搜索 \(Fmt.count(t.networkSearch)) 次 · 网页读取 \(Fmt.count(t.webRead)) 次", color: .secondaryLabelColor)) }
            else { add(label("暂无数据", color: .secondaryLabelColor)) }
        }
        if let e = usage.toolsError { add(label("MCP 刷新失败：\(e) · 最后成功 \(Fmt.lastOK(toolsLastOK))", color: .systemRed)) }
        else if toolsStale { add(label("MCP 数据已过期 · 最后成功 \(Fmt.lastOK(toolsLastOK))", color: .systemOrange)) }

        let header = row(); header.spacing = 12
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.widthAnchor.constraint(equalToConstant: 32).isActive = true; icon.heightAnchor.constraint(equalToConstant: 32).isActive = true; header.addArrangedSubview(icon)
        header.addArrangedSubview(label("GLM 余额" + (usage.level.map { "（\($0) 套餐）" } ?? ""), size: 15, bold: true)); header.addArrangedSubview(spacer())
        let scroll = panelScroll
        activeScroll = scroll
        let footer = GLMPanelStack(); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 4
        let meta = row(); meta.spacing = 8
        meta.addArrangedSubview(label("最近尝试刷新 \(Fmt.time(lastAttemptAt))", size: 11, color: .secondaryLabelColor)); meta.addArrangedSubview(spacer())
        let shortVersion = BuildInfo.version.split(separator: "-").first.map(String.init) ?? BuildInfo.version
        let version = button("版本 \(shortVersion)", #selector(manualUpdate)); version.toolTip = "\(BuildInfo.version) · 点击检查更新"; meta.addArrangedSubview(version); footer.addArrangedSubview(meta)
        meta.widthAnchor.constraint(equalToConstant: inner).isActive = true
        if let msg = updateMessage { footer.addArrangedSubview(label(msg, color: .secondaryLabelColor)) }
        let actions = row(); actions.spacing = 6
        let refresh = button("立即刷新", #selector(onRefresh), prominent: true); refresh.keyEquivalent = "r"; refresh.keyEquivalentModifierMask = .command; refresh.widthAnchor.constraint(equalToConstant: 76).isActive = true; actions.addArrangedSubview(refresh)
        let login = NSButton(checkboxWithTitle: "开机自启", target: self, action: #selector(onToggleLogin)); login.font = .systemFont(ofSize: 12); login.state = (!preview && isLoginItemEnabled()) ? .on : .off; actions.addArrangedSubview(login); actions.addArrangedSubview(spacer())
        let quit = button("退出", #selector(onQuit)); quit.keyEquivalent = "q"; quit.keyEquivalentModifierMask = .command; quit.widthAnchor.constraint(equalToConstant: 40).isActive = true; actions.addArrangedSubview(quit)
        footer.addArrangedSubview(actions); actions.widthAnchor.constraint(equalToConstant: inner).isActive = true
        func install(_ view: NSView, in slot: NSView) {
            for old in slot.subviews { old.removeFromSuperview() }
            view.translatesAutoresizingMaskIntoConstraints = false; slot.addSubview(view)
            NSLayoutConstraint.activate([view.topAnchor.constraint(equalTo: slot.topAnchor), view.bottomAnchor.constraint(equalTo: slot.bottomAnchor), view.leadingAnchor.constraint(equalTo: slot.leadingAnchor), view.trailingAnchor.constraint(equalTo: slot.trailingAnchor)])
        }
        if !panelConfigured {
            let container = NSView(); container.translatesAutoresizingMaskIntoConstraints = false
            container.wantsLayer = true
            container.layer?.cornerRadius = 16
            container.layer?.masksToBounds = true
            panelEffect.frame = container.bounds
            panelEffect.autoresizingMask = [.width, .height]
            panelEffect.material = .popover
            panelEffect.blendingMode = .behindWindow
            panelEffect.state = .active
            container.addSubview(panelEffect)
            panelBackground.frame = container.bounds
            panelBackground.autoresizingMask = [.width, .height]
            panelBackground.wantsLayer = true
            container.addSubview(panelBackground)
            let headerLine = separator(); let footerLine = separator()
            for v in [panelHeaderSlot, headerLine, scroll, footerLine, panelFooterSlot] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.documentView = root
            NSLayoutConstraint.activate([
                root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                panelHeaderSlot.topAnchor.constraint(equalTo: container.topAnchor, constant: 12), panelHeaderSlot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14), panelHeaderSlot.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
                headerLine.topAnchor.constraint(equalTo: panelHeaderSlot.bottomAnchor, constant: 12), headerLine.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), headerLine.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                scroll.topAnchor.constraint(equalTo: headerLine.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                footerLine.topAnchor.constraint(equalTo: scroll.bottomAnchor), footerLine.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), footerLine.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
                panelFooterSlot.topAnchor.constraint(equalTo: footerLine.bottomAnchor, constant: 8), panelFooterSlot.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16), panelFooterSlot.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16), panelFooterSlot.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)])
            panelController.view = container
            if !preview || previewPopover { popover.contentViewController = panelController }
            panelConfigured = true
        }
        install(header, in: panelHeaderSlot)
        install(footer, in: panelFooterSlot)
        root.layoutSubtreeIfNeeded(); footer.layoutSubtreeIfNeeded()
        let maxHeight = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let height = min(maxHeight * 0.82, max(250, root.fittingSize.height + footer.fittingSize.height + 78))
        let desiredSize = NSSize(width: width, height: height)
        // A visible popover keeps a fixed frame. Additional content scrolls until the next open.
        if !popover.isShown {
            panelController.preferredContentSize = desiredSize
            if !preview || previewPopover { popover.contentSize = desiredSize }
        }
        DispatchQueue.main.async {
            scroll.layoutSubtreeIfNeeded()
            let maxY = max(0, root.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, max(0, savedOffset.y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if preview && !previewPopover {
            if previewWindow == nil {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "GLM 用量 · 假数据预览"; window.isReleasedWhenClosed = false; previewWindow = window
                window.contentViewController = panelController
            }
            previewWindow?.setContentSize(desiredSize)
        }
        tracePopover("rebuild")
    }

    // Optional geometry trace is confined to the isolated fake-data preview.
    private func tracePopover(_ reason: String) {
        guard previewPopover && CommandLine.arguments.contains("--preview-trace") else { return }
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.popover.isShown, let frame = self.panelController.view.window?.frame else { return }
                print("GLM_POPOVER_TRACE \(reason) +\(delay) x=\(frame.minX) y=\(frame.minY) w=\(frame.width) h=\(frame.height)")
                fflush(stdout)
            }
        }
    }

    // Offline regression: uses the actual NSPopover and its AppKit controls, with fake data only.
    private func testPreviewPopover() {
        guard previewPopover, popover.isShown, let window = panelController.view.window else {
            fputs("GLM popover test: FAIL opening\n", stderr); exit(1)
        }
        let initial = window.frame
        let originalController = popover.contentViewController
        let originalDocument = panelScroll.documentView
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func fail(_ message: String) { fputs("GLM popover test: FAIL \(message)\n", stderr); exit(1) }
        func verify(_ step: String) {
            guard popover.isShown, panelController.view.window === window, window.frame.equalTo(initial),
                  popover.contentViewController === originalController, panelScroll.documentView === originalDocument else {
                fail("frame or view identity changed at \(step)"); return
            }
            print("GLM_POPOVER_TEST \(step): \(NSStringFromRect(window.frame))")
            fflush(stdout)
        }
        func click(_ action: Selector, tag: Int? = nil) {
            guard let button = buttons(panelController.view).first(where: { $0.action == action && (tag == nil || $0.tag == tag!) }) else {
                fail("control missing \(action)"); return
            }
            _ = button.scrollToVisible(button.bounds)
            panelController.view.layoutSubtreeIfNeeded()
            let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    fail("cannot create mouse event for \(action)"); return
                }
                NSApp.sendEvent(event)
            }
        }
        let steps: [() -> Void] = [
            { click(#selector(self.toggleModels(_:)), tag: 0) },
            { click(#selector(self.toggleModels(_:)), tag: 1) },
            { click(#selector(self.toggleModels(_:)), tag: 2) },
            { click(#selector(self.toggleModels(_:)), tag: 1) },
            { click(#selector(self.toggleToken)) },
            { click(#selector(self.toggleToken)) },
            { click(#selector(self.toggleMCP)) },
            { click(#selector(self.toggleMCP)) },
            { click(#selector(self.onRefresh)) }
        ]
        func run(_ index: Int) {
            if index == steps.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    verify("async-refresh")
                    guard self.expandedModelWindows == [0, 2] else { fail("model expansion state lost"); return }
                    self.popover.performClose(nil)
                    guard !self.popover.isShown else { fail("close"); return }
                    self.togglePanel()
                    guard self.popover.isShown, self.expandedModelWindows == [0, 2] else { fail("reopen or state"); return }
                    guard let screen = self.statusItem.button?.window?.screen ?? NSScreen.main else { fail("missing screen"); return }
                    let visible = screen.visibleFrame
                    self.popover.performClose(nil)
                    for x in [visible.minX + 2, visible.maxX - 22] {
                        let host = NSWindow(contentRect: NSRect(x: x, y: visible.maxY - 20, width: 20, height: 18), styleMask: [.borderless], backing: .buffered, defer: false)
                        host.level = .statusBar; host.orderFront(nil)
                        guard let anchor = host.contentView else { fail("edge anchor"); return }
                        self.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                        guard self.popover.isShown, let frame = self.panelController.view.window?.frame,
                              frame.minX >= visible.minX - 1, frame.maxX <= visible.maxX + 1,
                              frame.minY >= visible.minY - 1, frame.maxY <= visible.maxY + 40 else { fail("screen-edge placement"); return }
                        print("GLM_POPOVER_TEST edge: \(NSStringFromRect(frame))")
                        self.popover.performClose(nil); host.orderOut(nil)
                    }
                    print("GLM popover test: PASS (actual popover, controls, async refresh, close/reopen, left/right edges)")
                    exit(0)
                }
                return
            }
            steps[index]()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { verify("step-\(index)"); run(index + 1) }
        }
        run(0)
    }

    // MARK: 开机自启（LaunchAgent）

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func onToggleLogin() {
        if preview { setUpdateMessage("预览模式不会修改开机自启"); return }
        if isLoginItemEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            let exec = Bundle.main.executablePath ?? ""
            // KeepAlive 仅在非正常退出（崩溃/被 kill）时重启：菜单「退出」走 exit 0，launchd 不再复活进程
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key>
                <dict><key>SuccessfulExit</key><false/></dict>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
        updateUI()
    }

    @objc private func onRefresh() {
        if preview {
            if previewPopover {
                setUpdateMessage("正在刷新预览…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    self.setUpdateMessage("预览数据已刷新")
                }
            } else { setUpdateMessage("预览数据已刷新") }
            return
        }
        refresh(tokens: true, manual: true)
    }

    // 更新检查完成后无条件重建菜单：横幅出现/消失都靠它自愈（刷新周期 ≤30s 也会兜底重建）
    private func checkForUpdate() {
        UpdateChecker.shared.check { [weak self] in self?.updateUI() }
    }

    @objc private func onUpdateApp() {
        guard let script = Bundle.main.path(forResource: "update", ofType: "sh") else {
            NSWorkspace.shared.open(UpdateCheck.releasesPage); return
        }
        guard let tag = UpdateChecker.shared.targetTag else { return }
        UpdateProgressController.shared.start(script: script, tag: tag, appPath: Bundle.main.bundleURL.path)
    }

    @objc private func onQuit() { NSApp.terminate(nil) }
}

// MARK: - 入口（支持 --once 命令行自检）

func onceMode() {
    guard let key = CredStore.loadApiKey() else {
        print("no coding-plan api key found"); exit(1)
    }
    let group = DispatchGroup()
    // 与 App 主路径同款：网络回调来自不同线程，全部经加锁 accumulator 合并，
    // 避免 --once 里多线程直接写同一 struct（wait 超时后边写边读的撕裂窗口）
    let acc = RefreshAccumulator()
    group.enter()
    Fetcher.fetchQuota(apiKey: key) { r in
        acc.update { current in
            current.fiveHour = r.fiveHour; current.week = r.week
            current.level = r.level; current.quotaError = r.quotaError
            current.fiveHourError = r.fiveHourError; current.weekError = r.weekError
        }
        group.leave()
    }
    let now = Date()
    let dayStart = Calendar.current.startOfDay(for: now)
    for (label, from) in [("today", dayStart), ("7d", now.addingTimeInterval(-7 * 86400)),
                          ("30d", now.addingTimeInterval(-30 * 86400))] {
        group.enter()
        Fetcher.fetchModelUsage(apiKey: key, from: from, to: now) { r, err in
            if let r = r {
                acc.update { current in
                    switch label {
                    case "today": current.tokensToday = r
                    case "7d": current.tokens7d = r
                    default: current.tokens30d = r
                    }
                }
            } else { print("tokens \(label) error: \(err ?? "?")") }
            group.leave()
        }
    }
    group.enter()
    Fetcher.fetchToolUsage(apiKey: key, from: now.addingTimeInterval(-30 * 86400), to: now) { r, _ in
        if let r = r { acc.update { $0.tools30d = r } }
        group.leave()
    }
    // 重置卡（额度重置卡）+ 套餐到期：与 token 统计同批拉取
    if let (jwt, maas) = CredStore.loadResetTokens() {
        group.enter()
        Fetcher.fetchResetCards(jwt: jwt, maas: maas) { r in
            acc.update { current in
                current.resetCards = ResetCards(fiveHour: r.fiveHour, week: r.week)
                current.fiveHourCardsError = r.fiveHourError
                current.weekCardsError = r.weekError
                current.resetCardsError = [r.fiveHourError, r.weekError].compactMap { $0 }.joined(separator: "; ")
            }
            group.leave()
        }
    } else {
        acc.update { current in
            current.fiveHourCardsError = "未找到 ZCode 登录凭证"
            current.weekCardsError = "未找到 ZCode 登录凭证"
            current.resetCardsError = "未找到 ZCode 登录凭证"
        }
    }
    group.enter()
    Fetcher.fetchSubscription(apiKey: key) { r, err in
        acc.update { current in
            current.subscription = r
            current.subscriptionSucceeded = err == nil
            current.subscriptionError = err
        }
        group.leave()
    }
    _ = group.wait(timeout: .now() + 25)
    let data = acc.snapshot()
    let quotaOK: Date? = (data.fiveHour != nil || data.week != nil) ? Date() : nil
    let tokensOK: Date? = (data.tokensToday != nil || data.tokens7d != nil || data.tokens30d != nil) ? Date() : nil

    func line(_ e: LimitEntry?) -> String {
        guard let e = e else { return "--" }
        var s = "remaining=\(Fmt.pctLong(e.usedRemainingRatio)) used=\(Fmt.credits(e.used))/\(Fmt.credits(e.limit))"
        s += " reset=\(e.reset.map { Fmt.dayTime($0) } ?? "未知")"
        return s
    }
    let pk = Peak.evaluate()
    print("menubar: 5H \(Fmt.pct(data.fiveHour?.usedRemainingRatio)) / 7D \(Fmt.pct(data.week?.usedRemainingRatio))")
    print("peak: \(pk.line)\(pk.eventLine.map { "\n  \($0)" } ?? "")")
    print("level: \(data.level ?? "?")")
    print("5h  \(line(data.fiveHour))")
    print("7d  \(line(data.week))")
    for (label, s) in [("today", data.tokensToday), ("7d", data.tokens7d), ("30d", data.tokens30d)] {
        if let s = s {
            let models = s.byModel.map { "\($0.name)=\(Fmt.tokens($0.tokens))" }.joined(separator: " ")
            print("tokens \(label): total=\(Fmt.tokens(s.totalTokens)) calls=\(Fmt.count(s.totalCalls)) \(models)")
        }
    }
    if let t = data.tools30d {
        print("tools 30d: search=\(Fmt.count(t.networkSearch)) webRead=\(Fmt.count(t.webRead))")
    }
    if let c = data.resetCards {
        let f5Cards = c.fiveHour ?? []
        let weekCards = c.week ?? []
        var s = "cards: 5h x\(f5Cards.count)"
        let f5 = f5Cards.sorted().map { Fmt.fullTime.string(from: $0) }.joined(separator: ", ")
        if !f5.isEmpty { s += " [\(f5)]" }
        s += " week x\(weekCards.count)"
        let wk = weekCards.sorted().map { Fmt.fullTime.string(from: $0) }.joined(separator: ", ")
        if !wk.isEmpty { s += " [\(wk)]" }
        print(s)
    }
    if let e = data.fiveHourCardsError { print("5h cards error: \(e)") }
    if let e = data.weekCardsError { print("week cards error: \(e)") }
    if let sub = data.subscription {
        var s = "subscription: \(sub.name)"
        if let exp = sub.expireDate { s += " expire=\(Fmt.fullSec.string(from: exp))" }
        print(s)
    }
    if data.subscriptionSucceeded && data.subscription == nil { print("subscription: no valid subscription") }
    if let e = data.subscriptionError { print("subscription error: \(e)") }
    if let e = data.fiveHourError { print("5h quota: \(e)") }
    if let e = data.weekError { print("7d quota: \(e)") }
    if let e = data.quotaError { print("quota error: \(e)") }
    print("lastOK: quota=\(Fmt.lastOK(quotaOK)) tokens=\(Fmt.lastOK(tokensOK))")
    exit(0)
}

enum GLMOfflineRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlmUsage-self-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let now = Date(timeIntervalSince1970: 1_800_000_000)

            try expect(GLMNumber.finite(nil) == nil, "missing numeric value became zero")
            try expect(GLMNumber.finite(true) == nil, "boolean numeric value was accepted")
            try expect(GLMNumber.finite(Double.nan) == nil && GLMNumber.finite(Double.infinity) == nil,
                       "non-finite numeric value was accepted")
            try expect(GLMNumber.integer(2.5) == nil && GLMNumber.integer("9223372036854775808") == nil,
                       "fractional or out-of-range integer was accepted")

            let quotaFixture: [String: Any] = ["level": "pro", "limits": [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100,
                 "currentValue": "NaN", "remaining": 50, "percentage": 50],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 7, "usage": 400,
                 "currentValue": 100, "remaining": 300, "percentage": 25,
                 "nextResetTime": now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000]
            ]]
            let fixtureURL = root.appendingPathComponent("quota.json")
            try JSONSerialization.data(withJSONObject: quotaFixture).write(to: fixtureURL)
            let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
            let partial = Fetcher.parseQuota(decoded, error: nil, now: now)
            try expect(partial.fiveHour == nil && partial.fiveHourError != nil,
                       "invalid 5H quota was not rejected")
            try expect(partial.week?.used == 100 && partial.weekError == nil,
                       "valid 7D quota was discarded with invalid 5H")

            let badReset = Fetcher.parseQuota(["limits": [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100,
                 "currentValue": 20, "remaining": 80, "percentage": 20, "nextResetTime": "bad"],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 7, "usage": 400,
                 "currentValue": 100, "remaining": 300, "percentage": 25]
            ]], error: nil, now: now)
            try expect(badReset.fiveHour?.remaining == 80 && badReset.fiveHour?.reset == nil
                       && (badReset.fiveHourError?.contains("nextResetTime") ?? false)
                       && badReset.weekError == nil, "bad reset suppressed quota or contaminated other window")
            for (remaining, percentage, rejected) in [(80.0, 20.0, false), (79.0, 20.4, false),
                                                        (10.0, 20.0, true), (80.0, 80.0, true)] {
                let value = Fetcher.parseQuota(["limits": [["type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                    "usage": 100, "currentValue": 20, "remaining": remaining, "percentage": percentage]]], error: nil, now: now)
                try expect((value.fiveHour == nil) == rejected, "quota consistency/rounding check failed")
            }
            let reverse = Fetcher.parseQuota(["limits": [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100,
                 "currentValue": 0, "remaining": 100, "percentage": 0],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 7, "usage": 400,
                 "currentValue": 10, "remaining": 390, "percentage": true]
            ]], error: nil, now: now)
            try expect(reverse.fiveHour?.usedRatio == 0, "valid zero-use quota was rejected")
            try expect(reverse.week == nil && reverse.weekError != nil,
                       "invalid percentage was treated as zero")
            let missing = Fetcher.parseQuota([:], error: nil, now: now)
            try expect(missing.fiveHour == nil && missing.week == nil
                       && missing.fiveHourError != nil && missing.weekError != nil,
                       "missing quota windows were reported as success")
            for field in ["usage", "currentValue", "remaining"] {
                var row: [String: Any] = ["type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                    "usage": 100, "currentValue": 20, "remaining": 80, "percentage": 20]
                row[field] = 1e100
                let oversized = Fetcher.parseQuota(["limits": [row]], error: nil, now: now)
                try expect(oversized.fiveHour == nil && oversized.fiveHourError != nil,
                           "oversized quota \(field) was accepted")
            }
            try expect(Fmt.credits(1e100) == "超出范围"
                       && Fmt.credits(Double(Int.max)) == "超出范围"
                       && Fmt.credits(1234) != "超出范围"
                       && Fmt.count(1e100) == "超出范围",
                       "credit/count formatting overflowed or changed normal values")

            try expect(Fetcher.parseModelUsage(["totalUsage": ["totalTokensUsage": 0,
                "totalModelCallCount": 0]])?.totalTokens == 0,
                "valid zero model usage was rejected")
            try expect(Fetcher.parseModelUsage(["totalUsage": ["totalTokensUsage": true,
                "totalModelCallCount": 2]]) == nil, "invalid model token count became zero")
            try expect(Fetcher.parseModelUsage(["totalUsage": ["totalTokensUsage": 10]]) == nil,
                       "missing model call count became zero")
            for count: Any in [1e100, Double(Int.max), 1.5] {
                try expect(Fetcher.parseModelUsage(["totalUsage": ["totalTokensUsage": 10,
                    "totalModelCallCount": count]]) == nil,
                    "oversized or fractional model call count was accepted")
            }
            try expect(Fetcher.parseModelUsage(["totalUsage": ["totalTokensUsage": 10,
                "totalModelCallCount": 3]])?.totalCalls == 3,
                "valid model call count changed")
            let visibleModels = TokenModelList.visible([
                (name: "GLM-5.3", tokens: 13_980_000),
                (name: "GLM-5.3-Flash", tokens: 39_830_000),
                (name: "GLM-4.6", tokens: 0)
            ])
            try expect(visibleModels.map { $0.name } == ["GLM-5.3-Flash", "GLM-5.3"]
                       && visibleModels.map { $0.tokens } == [39_830_000, 13_980_000],
                       "token model sorting or zero filter changed")
            let singleModel = TokenModelList.visible([(name: "GLM-5.3", tokens: 5_000)])
            try expect(singleModel.count == 1 && singleModel.first?.name == "GLM-5.3"
                       && singleModel.first?.tokens == 5_000,
                       "single visible model was changed")
            try expect(TokenModelList.visible([]).isEmpty
                       && TokenModelList.visible([(name: "GLM-4.6", tokens: 0)]).isEmpty,
                       "empty or all-zero model list produced detail rows")
            try expect(Fetcher.parseToolUsage(["totalUsage": ["totalNetworkSearchCount": 1,
                "totalWebReadMcpCount": Double.nan]]) == nil, "invalid MCP statistic became zero")
            for count: Any in [1e100, Double(Int.max), 1.5] {
                try expect(Fetcher.parseToolUsage(["totalUsage": ["totalNetworkSearchCount": count,
                    "totalWebReadMcpCount": 2]]) == nil,
                    "oversized or fractional MCP count was accepted")
            }
            try expect(Fetcher.parseToolUsage(["totalUsage": ["totalNetworkSearchCount": 0,
                "totalWebReadMcpCount": 2]])?.networkSearch == 0,
                "valid zero MCP count was rejected")

            let cardPayload: [String: Any] = [
                "available_five_hour_resets": [
                    ["expire_at": now.addingTimeInterval(-1).timeIntervalSince1970 * 1000],
                    ["expire_at": now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000]
                ],
                "available_week_resets": ["invalid row"]
            ]
            let cards = Fetcher.parseResetCards(cardPayload, now: now)
            try expect(cards.fiveHour?.count == 1 && cards.fiveHourError == nil,
                       "expired card was counted or valid list rejected")
            try expect(cards.week == nil && cards.weekError != nil,
                       "malformed week-card list was accepted as empty")
            let missingCards = Fetcher.parseResetCards(["error": "upstream"], now: now)
            try expect(missingCards.fiveHour == nil && missingCards.week == nil
                       && missingCards.fiveHourError != nil && missingCards.weekError != nil,
                       "missing card containers were accepted as an empty response")
            let emptyCards = Fetcher.parseResetCards(["available_five_hour_resets": [],
                "available_week_resets": []], now: now)
            try expect(emptyCards.fiveHour?.isEmpty == true && emptyCards.week?.isEmpty == true
                       && emptyCards.fiveHourError == nil && emptyCards.weekError == nil,
                       "valid empty card lists were not accepted")
            try expect(GLMFreshness.availableCards([now.addingTimeInterval(-1), now.addingTimeInterval(30)],
                now: now).count == 1, "expired cached card remained available")

            let emptySubscription = Fetcher.parseSubscription([["status": "EXPIRED", "productName": "Old"]])
            try expect(emptySubscription.0 == nil && emptySubscription.1 == nil, "no active subscription must be a successful empty result")
            try expect(Fetcher.parseSubscription([["productName": "Old"]]).1 != nil, "missing subscription status accepted")
            let oldSub = SubscriptionInfo(name: "Old", expireDate: now)
            let oldDate = now.addingTimeInterval(-300)
            let cleared = GLMSubscriptionFreshness.apply(fresh: nil, succeeded: true, failure: nil,
                old: oldSub, oldLastOK: oldDate, oldError: "old error", now: now)
            try expect(cleared.0 == nil && cleared.1 == now && cleared.2 == nil, "empty subscription did not clear old data")
            let retained = GLMSubscriptionFreshness.apply(fresh: nil, succeeded: false, failure: "network",
                old: oldSub, oldLastOK: oldDate, oldError: nil, now: now)
            try expect(retained.0?.name == "Old" && retained.0?.expireDate == now && retained.1 == oldDate
                       && retained.2 == "network", "failed subscription did not retain old data and freshness")
            let slowEntered = DispatchSemaphore(value: 0), releaseSlow = DispatchSemaphore(value: 0)
            let quotaArrived = DispatchSemaphore(value: 0)
            GLMRefreshDispatch.start(slowDue: true, quota: {
                DispatchQueue.global().async { quotaArrived.signal() }
            }, slow: {
                DispatchQueue.global().async { slowEntered.signal(); releaseSlow.wait() }
            })
            try expect(slowEntered.wait(timeout: .now() + 2) == .success && quotaArrived.wait(timeout: .now() + 2) == .success,
                       "quota was blocked by delayed slow request")
            releaseSlow.signal()
            let subscription = Fetcher.parseSubscription([[
                "status": "VALID", "productName": "Pro",
                "valid": "2026-09-26 18:18:52-2027-09-26 10:00:00"
            ]])
            try expect(subscription.0?.name == "Pro" && subscription.1 == nil,
                       "valid subscription was not parsed")
            try expect(subscription.0?.expireDate.map { Fmt.fullSec.string(from: $0) }
                       == "2027-09-26 10:00:00",
                       "legacy valid range did not fall back to its end date")
            let currentCycle = Fetcher.parseSubscription([[
                "status": "VALID", "productName": "GLM Coding Lite",
                "valid": "2027-09-26 10:00:00-2028-09-26 10:00:00",
                "nextRenewTime": "2027-09-26", "inCurrentPeriod": 1
            ]])
            try expect(currentCycle.0?.expireDate.map { Fmt.fullSec.string(from: $0) }
                       == "2027-09-26 10:00:00",
                       "nextRenewTime did not select the current cycle boundary")
            try expect(Fetcher.parseSubscription(["error": "upstream"]).0 == nil,
                       "invalid subscription container was accepted")

            let old5 = LimitEntry(label: "5 小时窗口", isFiveHour: true, limit: 100, used: 40,
                                  remaining: 60, usedRatio: 0.4, reset: nil)
            let last5 = now.addingTimeInterval(-1_000)
            let oldCards = [now.addingTimeInterval(3_600)]
            let fiveR = GLMFreshness.apply(fresh: partial.fiveHour, failure: partial.fiveHourError,
                old: old5, oldLastOK: last5, oldError: nil, now: now)
            try expect(fiveR.value?.used == old5.used && fiveR.lastOK == last5 && fiveR.error != nil,
                       "partial quota failure did not preserve its old value/time and expose error")
            let weekR = GLMFreshness.apply(fresh: partial.week, failure: partial.weekError,
                old: nil, oldLastOK: nil, oldError: nil, now: now)
            try expect(weekR.value?.used == 100 && weekR.lastOK == now && weekR.error == nil,
                       "valid quota window did not update independently")
            let cardsR = GLMFreshness.apply(fresh: cards.week, failure: cards.weekError,
                old: oldCards, oldLastOK: last5, oldError: nil, now: now)
            try expect(cardsR.value == oldCards && cardsR.lastOK == last5 && cardsR.error != nil,
                       "invalid card list cleared old cards or advanced last-success")
            let independentR = GLMFreshness.apply(fresh: "ok", failure: nil,
                old: nil as String?, oldLastOK: nil, oldError: nil, now: now)
            try expect(independentR.value == "ok" && independentR.lastOK == now && independentR.lastOK != last5,
                       "independent data item success time was not updated")
            let noopR = GLMFreshness.apply(fresh: nil as String?, failure: nil,
                old: "keep", oldLastOK: last5, oldError: "old error", now: now)
            try expect(noopR.value == "keep" && noopR.lastOK == last5 && noopR.error == "old error",
                       "no-data no-error round mutated retained state")
            try expect(GLMFreshness.isStale(lastSuccess: last5, hasData: true, now: now, after: 600),
                       "retained old value was not marked stale")

            let gate = RefreshGate()
            try expect(gate.begin(manual: false), "initial refresh gate did not open")
            try expect(!gate.begin(manual: false), "overlapping timer refresh started")
            try expect(!gate.begin(manual: true) && !gate.begin(manual: true),
                       "manual overlap started immediately")
            try expect(gate.finish(), "manual overlaps did not coalesce to one follow-up")
            try expect(!gate.begin(manual: false), "gate did not stay held for queued refresh")
            try expect(!gate.finish() && gate.begin(manual: false), "gate was not released after follow-up")
            try expect(!GLMRefreshSchedule.slowItemsDue(cycle: 4, manual: false)
                       && GLMRefreshSchedule.slowItemsDue(cycle: 5, manual: false)
                       && GLMRefreshSchedule.slowItemsDue(cycle: 1, manual: true),
                       "60s/300s/manual schedule is incorrect")

            let accumulator = RefreshAccumulator()
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "GlmUsage.self-test.concurrent", attributes: .concurrent)
            for index in 0..<4 {
                group.enter()
                queue.async {
                    accumulator.update { current in
                        switch index {
                        case 0: current.fiveHour = old5
                        case 1: current.week = old5
                        case 2: current.tokensToday = ModelUsage(totalTokens: 1, totalCalls: 1, byModel: [])
                        default: current.tools30d = ToolUsage(networkSearch: 1, webRead: 1)
                        }
                    }
                    group.leave()
                }
            }
            group.wait()
            let combined = accumulator.snapshot()
            try expect(combined.fiveHour != nil && combined.week != nil
                       && combined.tokensToday != nil && combined.tools30d != nil,
                       "concurrent callback merges lost results")

            // 菜单栏对齐：无 badge 时正文贴左缘（旧布局不变）；有 badge 时两行正文仍同一 x，badge 向左突出
            let plain = StackImage.geometry(badge1Width: 0, badge2Width: 0, text1Width: 30, text2Width: 30)
            try expect(plain.textX == 1 && plain.badge1X == nil && plain.badge2X == nil,
                       "badge-free menubar layout drifted from the flush-left baseline")
            let mark1 = NSAttributedString(string: "⚡⚠️").size().width
            let mark2 = NSAttributedString(string: "⚠️").size().width
            let marked = StackImage.geometry(badge1Width: mark1, badge2Width: mark2,
                                             text1Width: 30, text2Width: 26)
            try expect(marked.badge1X != nil && marked.badge2X != nil && marked.textX > 1
                       && abs((marked.badge1X! + ceil(mark1)) - (marked.badge2X! + ceil(mark2))) < 0.5
                       && marked.badge1X! + ceil(mark1) <= marked.textX
                       && marked.badge2X! + ceil(mark2) <= marked.textX,
                       "badge did not hang left of the aligned 5H/7D text column")
            let line2Only = StackImage.geometry(badge1Width: 0, badge2Width: mark2,
                                                text1Width: 30, text2Width: 26)
            try expect(line2Only.badge1X == nil && line2Only.badge2X != nil
                       && line2Only.badge2X! + ceil(mark2) <= line2Only.textX,
                       "line-2-only badge shifted the shared text column without hanging left")
            let previewLine = StackImage.Line(badge: "", label: "5H", value: "99%", remaining: 0.99)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = NSAppearance(named: name)!
                let green = GLMRemainingColor.color(0.99, appearance: appearance).usingColorSpace(.sRGB)
                try expect(green.map { $0.greenComponent > $0.redComponent
                                      && $0.greenComponent > $0.blueComponent } == true,
                           "99% remaining did not resolve to green for \(name.rawValue)")
                let image = StackImage.make(line1: previewLine, line2: previewLine)
                try expect(!image.isTemplate && image.size.width > 0 && image.tiffRepresentation != nil,
                           "menu bar color image did not render for \(name.rawValue)")
            }

            // 更新检查：Release 版本号比较（v 前缀与 describe/dirty 尾巴剥离、逐段数值、短侧补 0、无法解析不提示）
            try expect(!UpdateCheck.isOutdated(local: "v1.0.1", remote: "v1.0.1"), "same release flagged outdated")
            try expect(UpdateCheck.isOutdated(local: "v1.0.0-1-g95952a1", remote: "v1.0.1"), "newer release not detected")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.1", remote: "v1.0.0"), "older release flagged outdated")
            try expect(UpdateCheck.isOutdated(local: "v1.9", remote: "v1.10"), "segments compared as numbers, not strings")
            try expect(!UpdateCheck.isOutdated(local: "v1.10", remote: "v1.9"), "segments compared as numbers, not strings")
            try expect(!UpdateCheck.isOutdated(local: "v1.2", remote: "v1.2.0"), "shorter version not zero-padded")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.0-dirty", remote: "v1.0.0"), "dirty suffix not stripped")
            try expect(UpdateCheck.isOutdated(local: "v1.0.0", remote: "v1.0.1-beta"), "prerelease suffix not stripped")
            try expect(!UpdateCheck.isOutdated(local: "unknown", remote: "v9.9.9"), "unknown local version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.0", remote: "unknown"), "unknown remote version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "", remote: "v1.0.0"), "empty local version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "abc", remote: "1.2"), "non-numeric local version flagged outdated")
            try expect(!UpdateCheck.canCompare(local: "unknown", remote: "v1.2.0"), "invalid local version accepted")
            try expect(!UpdateCheck.canCompare(local: "v1.2.0", remote: "unknown"), "invalid remote version accepted")
            try expect(UpdateCheck.canCompare(local: "v1.2.0-3-g123", remote: "v1.3.0"), "valid release comparison rejected")

            // 更新检查与脚本都只认附件完整的 Release；最新空 Release 不遮挡最近可安装版本
            let completeRelease: [String: Any] = [
                "tag_name": "v1.0.11", "draft": false, "prerelease": false,
                "assets": [["name": "GlmUsage.zip"], ["name": "GlmUsage.zip.sha256"]],
            ]
            let emptyRelease: [String: Any] = [
                "tag_name": "v1.0.12", "draft": false, "prerelease": false, "assets": [],
            ]
            let zipOnlyRelease: [String: Any] = [
                "tag_name": "v1.0.13", "draft": false, "prerelease": false,
                "assets": [["name": "GlmUsage.zip"]],
            ]
            try expect(UpdateCheck.latestDownloadableTag(in: [emptyRelease, completeRelease]) == "v1.0.11",
                       "empty latest release hid downloadable release")
            try expect(UpdateCheck.latestDownloadableTag(in: [zipOnlyRelease]) == nil,
                       "release without SHA256 accepted")
            try expect(UpdateCheck.latestDownloadableTag(in: [emptyRelease]) == nil,
                       "release without assets accepted")
            var prerelease = completeRelease
            prerelease["prerelease"] = true
            try expect(UpdateCheck.latestDownloadableTag(in: [prerelease, completeRelease]) == "v1.0.11",
                       "prerelease not skipped")

            print("GlmUsage --self-test: PASS (strict quota/remote parsing, partial windows, independent freshness, card expiry/retention, refresh gate/schedule, serialized callback merge, menubar alignment, update check release version compare/assets)")
            return 0
        } catch {
            fputs("GlmUsage --self-test: FAIL: \(error)\n", stderr)
            return 1
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    exit(GLMOfflineRegression.run())
}

if CommandLine.arguments.contains("--peak-test") {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = Peak.tz
    let peakLine = "🔥 高峰期 · 积分全价（18:00 后恢复 5 折）"
    let festivalLine = "🎉 双节活动：全天按非高峰 5 折（至 10-07）"
    let nightLine = "🌙 深夜错峰：Flash 免费 · 其他 Agent 额度 ×2（至 10-07）"
    func offPeak(_ next: String) -> String { "⚡ 非高峰 · 积分 5 折（下个高峰 \(next)）" }
    let cases: [(String, String?, String, String?)] = [
        ("2026-09-24 15:00", "🔥", peakLine, nil),
        ("2026-09-25 15:00", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-26 15:00", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-28 13:59", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-28 14:00", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-28 17:59", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-28 18:00", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-28 22:00", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-09-30 23:30", "⚡", offPeak("10-08 14:00"), nightLine),
        ("2026-10-01 08:59", "⚡", offPeak("10-08 14:00"), nightLine),
        ("2026-10-01 09:00", nil, offPeak("10-08 14:00"), festivalLine),
        ("2026-10-07 15:00", nil, offPeak("明天 14:00"), festivalLine),
        ("2026-10-08 01:00", "⚡", offPeak("今天 14:00"), nightLine),
        ("2026-10-08 09:00", nil, offPeak("今天 14:00"), nil),
        ("2026-10-08 14:00", "🔥", peakLine, nil),
        ("2026-10-08 17:59", "🔥", peakLine, nil),
        ("2026-10-08 18:00", nil, offPeak("明天 14:00"), nil),
        ("2026-10-08 15:00", "🔥", peakLine, nil),
        ("2026-10-08 21:00", nil, offPeak("明天 14:00"), nil),
        ("2026-10-09 01:00", nil, offPeak("今天 14:00"), nil),
    ]
    var failures = 0
    for (c, emoji, line, eventLine) in cases {
        guard let d = f.date(from: c) else {
            fputs("FAIL \(c): invalid fixture\n", stderr)
            failures += 1
            continue
        }
        let r = Peak.evaluate(at: d)
        if r.emoji == emoji && r.line == line && r.eventLine == eventLine {
            print("PASS \(c)")
        } else {
            fputs("FAIL \(c)\n  expected: \(emoji ?? "-") | \(line) | \(eventLine ?? "-")\n  actual:   \(r.emoji ?? "-") | \(r.line) | \(r.eventLine ?? "-")\n", stderr)
            failures += 1
        }
    }
    print("GlmUsage --peak-test: \(cases.count - failures)/\(cases.count) passed")
    exit(failures == 0 ? 0 : 1)
}


if CommandLine.arguments.contains("--once") {
    onceMode()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
