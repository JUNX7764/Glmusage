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
        guard let enc = candidates.first?.enc else { return nil }
        return decrypt(enc)
    }

    // 充值卡（额度重置卡）接口所需的两个 ZCode 登录态 token（同一密文格式、同一把密钥）。
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

struct ToolUsage {
    var networkSearch: Double
    var webRead: Double
}

/// 充值卡（官方名：额度重置卡）：按窗口类型分组的未过期卡到期时间（已过滤 expire_at <= now）
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
    var resetCards: ResetCards?        // 充值卡（额度重置卡）可用列表
    var resetCardsError: String?
    var subscription: SubscriptionInfo?
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
//   GET https://zcode.z.ai/api/v1/coding-plan/reset/status  充值卡（额度重置卡），
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
            let invalid = "invalid \(isFive ? "5H" : "7D") quota fields"
            if type == "CREDIT_LIMIT" && (unit == nil || (isFive && number != 5)) {
                if isFive { result.fiveHourError = invalid } else { result.weekError = invalid }
                continue
            }
            guard let limit = GLMNumber.finite(row["usage"]), limit > 0,
                  let used = GLMNumber.finite(row["currentValue"]), used >= 0, used <= limit,
                  let remaining = GLMNumber.finite(row["remaining"]), remaining >= 0, remaining <= limit,
                  GLMNumber.nonnegativeRoundedInteger(limit) != nil,
                  GLMNumber.nonnegativeRoundedInteger(used) != nil,
                  GLMNumber.nonnegativeRoundedInteger(remaining) != nil,
                  let percentage = GLMNumber.finite(row["percentage"]), (0...100).contains(percentage) else {
                if isFive { result.fiveHourError = invalid } else { result.weekError = invalid }
                continue
            }
            let reset: Date?
            if let rawReset = row["nextResetTime"] {
                guard let milliseconds = GLMNumber.finite(rawReset), milliseconds > 0 else {
                    if isFive { result.fiveHourError = invalid } else { result.weekError = invalid }
                    continue
                }
                reset = Date(timeIntervalSince1970: milliseconds / 1000)
            } else { reset = nil }
            let entry = LimitEntry(label: label, isFiveHour: isFive, limit: limit, used: used,
                                   remaining: remaining, usedRatio: percentage / 100, reset: reset)
            if isFive, result.fiveHour == nil {
                result.fiveHour = entry
                result.fiveHourError = nil
            }
            if isWeek, result.week == nil {
                result.week = entry
                result.weekError = nil
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

    // 充值卡（额度重置卡）：ZCode 侧接口，成功码为 code==0（与 open.bigmodel.cn 系的 200 不同）
    static let resetBase = "https://zcode.z.ai"

    /// 查询可用充值卡列表；jwt/maas 为 ZCode 登录态 token，过期/缺失由上层优雅降级
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
        guard let sub = list.first(where: { ($0["status"] as? String) == "VALID" }) else {
            return (nil, "no valid subscription")
        }
        guard let name = sub["productName"] as? String, !name.isEmpty else {
            return (nil, "invalid subscription name")
        }
        return (SubscriptionInfo(name: name,
                                 expireDate: parseValidEnd(sub["valid"] as? String ?? "")), nil)
    }

    // valid 形如 "2026-09-26 18:18:52-2027-09-26 10:00:00"：日期对内部也含 '-'，
    // 用正则取最后一个完整 "yyyy-MM-dd HH:mm:ss"（即到期时间），空格转 T 后按本地时区解析
    private static func parseValidEnd(_ valid: String) -> Date? {
        guard let re = try? NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#) else {
            return nil
        }
        let ns = valid as NSString
        guard let m = re.matches(in: valid, range: NSRange(location: 0, length: ns.length)).last else {
            return nil
        }
        let s = ns.substring(with: m.range).replacingOccurrences(of: " ", with: "T")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"   // 无时区字段，按本地时区解释
        return f.date(from: s)
    }
}

// MARK: - 菜单栏堆叠两行文字渲染

enum StackImage {
    static func make(line1: String, line2: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let s1 = NSAttributedString(string: line1, attributes: attrs)
        let s2 = NSAttributedString(string: line2, attributes: attrs)
        let w = max(s1.size().width, s2.size().width) + 2
        let h: CGFloat = 21
        let img = NSImage(size: NSSize(width: ceil(w), height: h))
        img.lockFocus()
        s1.draw(at: NSPoint(x: 1, y: 10.5))
        s2.draw(at: NSPoint(x: 1, y: 0.5))
        img.unlockFocus()
        img.isTemplate = true   // 自动适配深色/浅色菜单栏
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
    static func time(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
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
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
    // 充值卡/套餐到期提示：今天内 → "今天 HH:mm"；明天 → "明天 HH:mm"；否则完整日期（本地时区）
    static func expires(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "'今天' HH:mm"
        } else if cal.isDateInTomorrow(d) {
            f.dateFormat = "'明天' HH:mm"
        } else {
            f.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return f.string(from: d)
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage = UsageData()
    private var cycle = 0
    private let refreshGate = RefreshGate()
    private let launchAgentLabel = "com.local.glm-usage"
    // token 统计每 N 个刷新周期拉一次（额度窗口仍每 60s 刷新）
    private let tokenEveryCycles = 5
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
        rebuildMenu()
        renderBar()
        refresh(tokens: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cycle += 1
            self.refresh(tokens: GLMRefreshSchedule.slowItemsDue(cycle: self.cycle,
                every: self.tokenEveryCycles, manual: false))
        }
        // 显式容差让系统合并定时器唤醒（Apple 节能指南建议 ≥间隔 10%；60s → 6s）
        timer?.tolerance = 6
    }

    // 拉取数据
    private func refresh(tokens: Bool, manual: Bool = false) {
        guard refreshGate.begin(manual: manual) else { return }
        performRefresh(tokens: tokens || manual)
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

        group.enter()
        Fetcher.fetchQuota(apiKey: key) { r in
            accumulator.update { current in
                current.fiveHour = r.fiveHour
                current.week = r.week
                current.level = r.level
                current.quotaError = r.quotaError
                current.fiveHourError = r.fiveHourError
                current.weekError = r.weekError
            }
            group.leave()
        }

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
            // 充值卡（额度重置卡）：ZCode 登录态 token 缺失/过期时优雅降级为错误提示
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
            // 套餐到期（与充值卡同周期刷新）
            wg.enter()
            Fetcher.fetchSubscription(apiKey: key) { r, err in
                accumulator.update { current in
                    current.subscription = r
                    current.subscriptionError = r == nil ? (err ?? "no data") : nil
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
        let five = GLMFreshness.apply(fresh: fresh.fiveHour, failure: fresh.fiveHourError,
            old: usage.fiveHour, oldLastOK: fiveHourLastOK, oldError: usage.fiveHourError, now: now)
        usage.fiveHour = five.value; fiveHourLastOK = five.lastOK; usage.fiveHourError = five.error
        let week = GLMFreshness.apply(fresh: fresh.week, failure: fresh.weekError,
            old: usage.week, oldLastOK: weekLastOK, oldError: usage.weekError, now: now)
        usage.week = week.value; weekLastOK = week.lastOK; usage.weekError = week.error
        if fresh.fiveHour != nil || fresh.week != nil { usage.quotaError = nil }
        else if let error = fresh.quotaError { usage.quotaError = error }
        usage.level = fresh.level ?? usage.level

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

            let sub = GLMFreshness.apply(fresh: fresh.subscription, failure: fresh.subscriptionError,
                old: usage.subscription, oldLastOK: subscriptionLastOK, oldError: usage.subscriptionError, now: now)
            usage.subscription = sub.value; subscriptionLastOK = sub.lastOK; usage.subscriptionError = sub.error
        }

        let tokenErrors = [usage.tokensTodayError, usage.tokens7dError, usage.tokens30dError, usage.toolsError]
            .compactMap { $0 }
        usage.tokensError = tokenErrors.isEmpty ? nil : tokenErrors.joined(separator: "; ")
        renderBar()
        rebuildMenu()
        if refreshGate.finish() { performRefresh(tokens: true) }
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

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）；峰谷状态加 emoji 前缀；过期组加 ⚠️ 前缀
    // （⚠️ 放在峰谷 emoji 之后、"5H"/"7D" 文本之前，不影响 Peak 判定；token 组无菜单栏行，仅在下拉菜单标注）
    private func renderBar() {
        let peak = Peak.evaluate()
        let line1 = (peak.emoji.map { "\($0) " } ?? "") + (fiveHourStale ? "⚠️ " : "") + "5H \(Fmt.pct(usage.fiveHour?.usedRemainingRatio))"
        let line2 = (weekStale ? "⚠️ " : "") + "7D \(Fmt.pct(usage.week?.usedRemainingRatio))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "GLM 余额 · 5H最后成功 \(Fmt.lastOK(fiveHourLastOK))"
            + " · 7D最后成功 \(Fmt.lastOK(weekLastOK))"
            + " · 今日Token最后成功 \(Fmt.lastOK(tokensTodayLastOK))"
            + " · 7天Token最后成功 \(Fmt.lastOK(tokens7dLastOK))"
            + " · 30天Token最后成功 \(Fmt.lastOK(tokens30dLastOK))"
            + " · MCP最后成功 \(Fmt.lastOK(toolsLastOK))"
        writeStatus(line1: line1, line2: line2, peakLine: peak.line)
    }

    // 自诊断：把渲染内容写到本地，便于排查
    private func writeStatus(line1: String, line2: String, peakLine: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/GlmUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 充值卡/套餐自诊断（只含到期时间与名称，不含任何密钥）
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

        // 峰谷状态 + 限时活动
        let pk = Peak.evaluate()
        menu.addItem(info(pk.line))
        if let ev = pk.eventLine { menu.addItem(info(ev)) }

        // 充值卡（额度重置卡）板块：首轮未拉到数据时不画分隔线，避免连续双 separator；≤72 小时临期加 ⚠️
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
                menu.addItem(info("充值卡（额度重置）：暂无可用"))
            } else {
                if !parts.isEmpty { menu.addItem(info("充值卡（额度重置）：" + parts.joined(separator: " · "))) }
                for d in f5 { menu.addItem(info(cardLine("5 小时卡", d))) }
                for d in wk { menu.addItem(info(cardLine("周卡", d))) }
            }
        }
        if let e = usage.fiveHourCardsError {
            let short = e.count > 60 ? String(e.prefix(60)) + "…" : e
            menu.addItem(info("5 小时卡获取失败：\(short)（ZCode 登录态可能过期，打开 ZCode 客户端刷新后重试）"))
        }
        if fiveHourCardsStale { menu.addItem(info("⚠️ 5 小时卡数据已过期 · 最后成功 \(Fmt.lastOK(fiveHourCardsLastOK))")) }
        if let e = usage.weekCardsError {
            let short = e.count > 60 ? String(e.prefix(60)) + "…" : e
            menu.addItem(info("周卡获取失败：\(short)（ZCode 登录态可能过期，打开 ZCode 客户端刷新后重试）"))
        }
        if weekCardsStale { menu.addItem(info("⚠️ 周卡数据已过期 · 最后成功 \(Fmt.lastOK(weekCardsLastOK))")) }

        // Token 用量（服务端统计）
        menu.addItem(.separator())
        menu.addItem(info("Token 用量（服务端统计）"))
        func tokenLine(_ label: String, _ stats: ModelUsage?, lastOK: Date?, stale: Bool, error: String?) -> String {
            var line: String
            if let stats = stats, !stats.isEmpty {
                line = "\(label)：\(Fmt.tokens(stats.totalTokens)) tokens · 调用 \(Fmt.count(stats.totalCalls)) 次"
                if !stats.byModel.isEmpty {
                    line += "\n  " + stats.byModel.map { "\($0.name) \(Fmt.tokens($0.tokens))" }
                        .joined(separator: " · ")
                }
            } else {
                line = "\(label)：暂无记录"
            }
            if stale { line += " · ⚠️ 数据已过期" }
            if let error = error { line += " · 刷新失败：\(error)" }
            if lastOK != nil, stale || error != nil { line += " · 最后成功 \(Fmt.lastOK(lastOK))" }
            return line
        }
        menu.addItem(info(tokenLine("今日", usage.tokensToday, lastOK: tokensTodayLastOK,
                                 stale: tokensTodayStale, error: usage.tokensTodayError)))
        menu.addItem(info(tokenLine("近 7 天", usage.tokens7d, lastOK: tokens7dLastOK,
                                 stale: tokens7dStale, error: usage.tokens7dError)))
        menu.addItem(info(tokenLine("近 30 天", usage.tokens30d, lastOK: tokens30dLastOK,
                                 stale: tokens30dStale, error: usage.tokens30dError)))

        if let t = usage.tools30d {
            menu.addItem(.separator())
            var line = "MCP 工具（近 30 天）：网络搜索 \(Fmt.count(t.networkSearch)) 次 · 网页读取 \(Fmt.count(t.webRead)) 次"
            if toolsStale { line += " · ⚠️ 数据已过期 · 最后成功 \(Fmt.lastOK(toolsLastOK))" }
            menu.addItem(info(line))
        }
        if let e = usage.toolsError { menu.addItem(info("MCP 工具刷新失败：\(e)")) }

        menu.addItem(.separator())
        menu.addItem(info("最近尝试刷新 \(Fmt.fullTime.string(from: lastAttemptAt))"))
        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(onRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: 开机自启（LaunchAgent）

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func onToggleLogin() {
        if isLoginItemEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            let exec = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
        rebuildMenu()
    }

    @objc private func onRefresh() { refresh(tokens: true, manual: true) }

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
    // 充值卡（额度重置卡）+ 套餐到期：与 token 统计同批拉取
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
            current.subscriptionError = r == nil ? (err ?? "?") : nil
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
        if e.reset != nil { s += " reset=\(Fmt.dayTime(e.reset))" }
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
    if let e = data.subscriptionError { print("subscription error: \(e)") }
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

            let subscription = Fetcher.parseSubscription([[
                "status": "VALID", "productName": "Pro",
                "valid": "2026-09-26 18:18:52-2027-09-26 10:00:00"
            ]])
            try expect(subscription.0?.name == "Pro" && subscription.1 == nil,
                       "valid subscription was not parsed")
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

            print("GlmUsage --self-test: PASS (strict quota/remote parsing, partial windows, independent freshness, card expiry/retention, refresh gate/schedule, serialized callback merge)")
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
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = Peak.tz
    let cases = [
        "2026-09-24 15:00",  // 周四 · 双节前的普通工作日高峰
        "2026-09-25 15:00",  // 周五 · 双节第一天，活动覆盖高峰
        "2026-09-26 15:00",  // 周六下午 · 周末全天非高峰
        "2026-09-28 13:59",  // 周一 · 双节覆盖（常规规则此刻应为高峰前 1 分钟）
        "2026-09-28 14:00",  // 周一 · 双节覆盖（常规规则此刻应进入高峰）
        "2026-09-28 17:59",  // 周一 · 双节覆盖（常规高峰最后一分钟）
        "2026-09-28 18:00",  // 周一 · 双节覆盖（常规高峰结束）
        "2026-09-28 22:00",  // 周一晚 · 下个高峰=双节后首个工作日
        "2026-09-30 23:30",  // 深夜活动开始 + 双节
        "2026-10-01 08:59",  // 深夜活动尾段（归属 9-30 夜）
        "2026-10-01 09:00",  // 深夜结束 · 双节白天
        "2026-10-07 15:00",  // 双节最后一天（周三），活动覆盖
        "2026-10-08 01:00",  // 最后一晚深夜活动的凌晨（归属 10-07 夜）
        "2026-10-08 13:59",  // 双节后首个工作日 · 高峰前 1 分钟，下个高峰=今天
        "2026-10-08 14:00",  // 双节后首个工作日 · 高峰开始
        "2026-10-08 17:59",  // 高峰最后一分钟
        "2026-10-08 18:00",  // 高峰结束
        "2026-10-08 15:00",  // 高峰中（周四）
        "2026-10-09 21:00",  // 周五晚 · 下个高峰=下周一
        "2026-10-09 01:00",  // 活动结束后凌晨 · 无深夜标记
    ]
    for c in cases {
        guard let d = f.date(from: c) else { print("bad case \(c)"); continue }
        let r = Peak.evaluate(at: d)
        print("\(c)  [\(r.emoji ?? "-")] \(r.line)\(r.eventLine.map { " | \($0)" } ?? "")")
    }
    exit(0)
}

if CommandLine.arguments.contains("--once") {
    onceMode()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
