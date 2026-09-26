import Cocoa
import CryptoKit
import Foundation

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
    var fiveHour: [Date]
    var week: [Date]
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
    var updatedAt: Date = Date()
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
            if let code = obj["code"] as? Int, code != 200 {
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
        var result = UsageData()
        fetch(apiKey: apiKey, path: "/api/monitor/usage/quota/limit") { data, err in
            defer { completion(result) }
            if let err = err { result.quotaError = err; return }
            guard let data = data else { result.quotaError = "no data"; return }
            result.level = data["level"] as? String
            guard let limits = data["limits"] as? [[String: Any]] else {
                result.quotaError = "no limits"; return
            }
            for e in limits {
                let type = e["type"] as? String ?? ""
                let unit = e["unit"] as? Int ?? 0
                let number = e["number"] as? Int ?? 0
                // 现行 API：CREDIT_LIMIT + unit 枚举（3=小时, 6=周）——官方套餐为"每 5 小时 + 每周"积分，
                // 旧版插件：TOKENS_LIMIT(5h)/TIME_LIMIT(月度 MCP) 已随 2026-07 积分制改版下线
                let isFiveHour = type == "TOKENS_LIMIT" || (type == "CREDIT_LIMIT" && unit == 3 && number == 5)
                let isWeek = type == "TIME_LIMIT" || (type == "CREDIT_LIMIT" && unit == 6)
                guard isFiveHour || isWeek else { continue }
                let entry = LimitEntry(
                    label: isFiveHour ? "5 小时窗口" : "7 天额度",
                    isFiveHour: isFiveHour,
                    limit: e["usage"] as? Double ?? 0,
                    used: e["currentValue"] as? Double ?? 0,
                    remaining: e["remaining"] as? Double ?? 0,
                    usedRatio: max(0, min(1, (e["percentage"] as? Double ?? 0) / 100)),
                    reset: (e["nextResetTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
                if isFiveHour, result.fiveHour == nil { result.fiveHour = entry }
                if isWeek, result.week == nil { result.week = entry }
            }
            if result.fiveHour == nil && result.week == nil {
                result.quotaError = "unexpected payload"
            }
        }
    }

    /// model-usage：一个时间窗的 token/调用统计
    static func fetchModelUsage(apiKey: String, from: Date, to: Date,
                                completion: @escaping (ModelUsage?, String?) -> Void) {
        fetch(apiKey: apiKey, path: "/api/monitor/usage/model-usage", from: from, to: to) { data, err in
            guard let data = data, err == nil else { completion(nil, err ?? "no data"); return }
            let total = data["totalUsage"] as? [String: Any] ?? [:]
            var byModel: [(String, Double)] = []
            if let list = data["modelSummaryList"] as? [[String: Any]] {
                for m in list {
                    byModel.append((m["modelName"] as? String ?? "?",
                                    m["totalTokens"] as? Double ?? 0))
                }
            }
            completion(ModelUsage(
                totalTokens: total["totalTokensUsage"] as? Double ?? 0,
                totalCalls: total["totalModelCallCount"] as? Double ?? 0,
                byModel: byModel), nil)
        }
    }

    /// tool-usage：MCP 工具次数（网络搜索 / 网页读取）
    static func fetchToolUsage(apiKey: String, from: Date, to: Date,
                               completion: @escaping (ToolUsage?, String?) -> Void) {
        fetch(apiKey: apiKey, path: "/api/monitor/usage/tool-usage", from: from, to: to) { data, err in
            guard let data = data, err == nil else { completion(nil, err ?? "no data"); return }
            let total = data["totalUsage"] as? [String: Any] ?? [:]
            completion(ToolUsage(
                networkSearch: total["totalNetworkSearchCount"] as? Double ?? 0,
                webRead: total["totalWebReadMcpCount"] as? Double ?? 0), nil)
        }
    }

    // 充值卡（额度重置卡）：ZCode 侧接口，成功码为 code==0（与 open.bigmodel.cn 系的 200 不同）
    static let resetBase = "https://zcode.z.ai"

    /// 查询可用充值卡列表；jwt/maas 为 ZCode 登录态 token，过期/缺失由上层优雅降级
    static func fetchResetCards(jwt: String, maas: String,
                                completion: @escaping (ResetCards?, String?) -> Void) {
        guard let url = URL(string: resetBase + "/api/v1/coding-plan/reset/status") else {
            completion(nil, "bad url"); return
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
                completion(nil, err?.localizedDescription ?? "bad response"); return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                completion(nil, "HTTP \(http.statusCode)"); return
            }
            let code = obj["code"] as? Int ?? -1
            guard code == 0 else {
                completion(nil, "code \(code) \(obj["msg"] as? String ?? "")"); return
            }
            guard let d = obj["data"] as? [String: Any] else {
                completion(nil, "no data"); return
            }
            func cards(_ key: String) -> [Date] {
                (d[key] as? [[String: Any]] ?? [])
                    .compactMap { ($0["expire_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
                    .filter { $0 > Date() }   // 只保留未过期
            }
            completion(ResetCards(fiveHour: cards("available_five_hour_resets"),
                                  week: cards("available_week_resets")), nil)
        }.resume()
    }

    /// 套餐订阅：取 status=="VALID" 的第一条；到期时间解析失败时仅降级显示名称
    static func fetchSubscription(apiKey: String,
                                  completion: @escaping (SubscriptionInfo?, String?) -> Void) {
        fetchRaw(apiKey: apiKey, path: "/api/biz/subscription/list") { data, err in
            guard err == nil else { completion(nil, err); return }
            guard let list = data as? [[String: Any]] else {
                completion(nil, "unexpected payload"); return
            }
            guard let sub = list.first(where: { ($0["status"] as? String) == "VALID" }) else {
                completion(nil, "no valid subscription"); return
            }
            completion(SubscriptionInfo(name: sub["productName"] as? String ?? "?",
                                        expireDate: parseValidEnd(sub["valid"] as? String ?? "")), nil)
        }
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
    // token 数量缩写：999 / 12.3K / 1.23M
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000 { return String(format: "%.2fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
        if v >= 1_000 { return String(format: "%.2fK", v / 1_000) }
        return String(format: "%.0f", v)
    }
    static func credits(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n.formatted(.number.grouping(.automatic))
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
    private let launchAgentLabel = "com.local.glm-usage"
    // token 统计每 N 个刷新周期拉一次（额度窗口仍每 60s 刷新）
    private let tokenEveryCycles = 5
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠️
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = 1800
    // 两组数据各自的最后成功拉取时间（5H/7D 同源共用 quotaLastOK；token 三窗口+MCP 共用 tokensLastOK）
    private var quotaLastOK: Date?
    private var tokensLastOK: Date?

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
            self.refresh(tokens: self.cycle % self.tokenEveryCycles == 0)
        }
    }

    // 拉取数据
    private func refresh(tokens: Bool) {
        guard let key = CredStore.loadApiKey() else {
            usage.quotaError = "未找到 ZCode 凭证（~/.zcode/v2/credentials.json）"
            renderBar(); rebuildMenu(); return
        }
        var merged = UsageData()
        let group = DispatchGroup()

        group.enter()
        Fetcher.fetchQuota(apiKey: key) { r in
            merged.fiveHour = r.fiveHour
            merged.week = r.week
            merged.level = r.level
            merged.quotaError = r.quotaError
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
                    if let r = r {
                        switch w.label {
                        case 0: merged.tokensToday = r
                        case 1: merged.tokens7d = r
                        default: merged.tokens30d = r
                        }
                    } else if err != nil {
                        merged.tokensError = err
                    }
                    wg.leave()
                }
            }
            wg.enter()
            Fetcher.fetchToolUsage(apiKey: key, from: now.addingTimeInterval(-30 * 86400), to: now) { r, err in
                if let r = r { merged.tools30d = r }
                else if err != nil, merged.tokensError == nil { merged.tokensError = err }
                wg.leave()
            }
            // 充值卡（额度重置卡）：ZCode 登录态 token 缺失/过期时优雅降级为错误提示
            if let (jwt, maas) = CredStore.loadResetTokens() {
                wg.enter()
                Fetcher.fetchResetCards(jwt: jwt, maas: maas) { r, err in
                    if let r = r { merged.resetCards = r }
                    else if err != nil { merged.resetCardsError = err }
                    wg.leave()
                }
            } else {
                merged.resetCardsError = "未找到 ZCode 登录凭证"
            }
            // 套餐到期（与充值卡同周期刷新）
            wg.enter()
            Fetcher.fetchSubscription(apiKey: key) { r, _ in
                if let r = r { merged.subscription = r }
                wg.leave()
            }
            group.enter()
            wg.notify(queue: .global()) { group.leave() }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            // 必须在旧值回填之前判定：本次新拉到的值非 nil 才算成功、才推进 lastOK，
            // 由旧值回填得来的数据绝不更新 lastOK（否则断网时过期数据会被误标为新鲜）
            if merged.fiveHour != nil || merged.week != nil { self.quotaLastOK = Date() }
            if tokens, merged.tokensToday != nil || merged.tokens7d != nil
                || merged.tokens30d != nil || merged.tools30d != nil {
                self.tokensLastOK = Date()
            }
            // 网络瞬断（如睡眠唤醒）时保留上次成功数据，避免菜单栏闪 "--"
            let old = self.usage
            if merged.fiveHour == nil { merged.fiveHour = old.fiveHour }
            if merged.week == nil { merged.week = old.week }
            if merged.level == nil { merged.level = old.level }
            if !tokens {
                merged.tokensToday = old.tokensToday
                merged.tokens7d = old.tokens7d
                merged.tokens30d = old.tokens30d
                merged.tools30d = old.tools30d
                merged.tokensError = old.tokensError
                merged.resetCards = old.resetCards
                merged.resetCardsError = old.resetCardsError
                merged.subscription = old.subscription
            } else {
                if merged.tokensToday == nil { merged.tokensToday = old.tokensToday }
                if merged.tokens7d == nil { merged.tokens7d = old.tokens7d }
                if merged.tokens30d == nil { merged.tokens30d = old.tokens30d }
                if merged.tools30d == nil { merged.tools30d = old.tools30d }
                if merged.resetCards == nil { merged.resetCards = old.resetCards }
                if merged.subscription == nil { merged.subscription = old.subscription }
            }
            self.usage = merged
            self.renderBar()
            self.rebuildMenu()
        }
    }

    // 过期判定：距最后成功超过阈值即过期；有数据但 lastOK 为 nil（异常情况）也视为过期。
    // 无数据不算过期——菜单里本就显示"暂无数据"，无需再标注。
    private func isStale(_ lastOK: Date?, hasData: Bool, after: TimeInterval) -> Bool {
        guard hasData else { return false }
        guard let t = lastOK else { return true }
        return Date().timeIntervalSince(t) > after
    }
    private var quotaStale: Bool {
        isStale(quotaLastOK, hasData: usage.fiveHour != nil || usage.week != nil, after: quotaStaleAfter)
    }
    private var tokensStale: Bool {
        isStale(tokensLastOK, hasData: usage.tokensToday != nil || usage.tokens7d != nil
            || usage.tokens30d != nil || usage.tools30d != nil, after: tokensStaleAfter)
    }

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）；峰谷状态加 emoji 前缀；过期组加 ⚠️ 前缀
    // （⚠️ 放在峰谷 emoji 之后、"5H"/"7D" 文本之前，不影响 Peak 判定；token 组无菜单栏行，仅在下拉菜单标注）
    private func renderBar() {
        let peak = Peak.evaluate()
        let staleQuota = quotaStale
        let line1 = (peak.emoji.map { "\($0) " } ?? "") + (staleQuota ? "⚠️ " : "") + "5H \(Fmt.pct(usage.fiveHour?.usedRemainingRatio))"
        let line2 = (staleQuota ? "⚠️ " : "") + "7D \(Fmt.pct(usage.week?.usedRemainingRatio))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "GLM 余额 · 额度最后成功 \(Fmt.lastOK(quotaLastOK))"
            + " · Token 最后成功 \(Fmt.lastOK(tokensLastOK))"
        writeStatus(line1: line1, line2: line2, peakLine: peak.line)
    }

    // 自诊断：把渲染内容写到本地，便于排查
    private func writeStatus(line1: String, line2: String, peakLine: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/GlmUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 充值卡/套餐自诊断（只含到期时间与名称，不含任何密钥）
        var cardsStatus: [String] = []
        if let c = usage.resetCards {
            cardsStatus += c.fiveHour.sorted().map { "5h:" + Fmt.fullTime.string(from: $0) }
            cardsStatus += c.week.sorted().map { "week:" + Fmt.fullTime.string(from: $0) }
        }
        let info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "peak": peakLine,
            "updatedAt": Fmt.iso8601.string(from: Date()),
            // 两组数据的最后成功时间（ISO8601，无则空串）与过期标记
            "quotaLastOK": quotaLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "tokensLastOK": tokensLastOK.map { Fmt.iso8601.string(from: $0) } ?? "",
            "quotaStale": quotaStale,
            "tokensStale": tokensStale,
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

        func limitLine(_ e: LimitEntry?) -> String {
            guard let e = e else { return "暂无数据" }
            var s = "\(e.label)：剩余 \(Fmt.pctLong(e.usedRemainingRatio))"
            if e.limit > 0 {
                s += "（剩 \(Fmt.credits(e.remaining)) / \(Fmt.credits(e.limit)) credits）"
            }
            if e.reset != nil {
                s += e.isFiveHour ? "（\(Fmt.time(e.reset)) 重置）" : "（\(Fmt.dayTime(e.reset)) 重置）"
            }
            return s
        }
        menu.addItem(info(limitLine(usage.fiveHour)))
        menu.addItem(info(limitLine(usage.week)))

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
            let f5 = cards.fiveHour.sorted(), wk = cards.week.sorted()
            if f5.isEmpty && wk.isEmpty {
                menu.addItem(info("充值卡（额度重置）：暂无可用"))
            } else {
                var parts: [String] = []
                if !f5.isEmpty { parts.append("5 小时 ×\(f5.count)") }
                if !wk.isEmpty { parts.append("周 ×\(wk.count)") }
                menu.addItem(info("充值卡（额度重置）：" + parts.joined(separator: " · ")))
                for d in f5 { menu.addItem(info(cardLine("5 小时卡", d))) }
                for d in wk { menu.addItem(info(cardLine("周卡", d))) }
            }
        } else if let e = usage.resetCardsError {
            let short = e.count > 60 ? String(e.prefix(60)) + "…" : e
            menu.addItem(info("充值卡获取失败：\(short)（ZCode 登录态可能过期，打开 ZCode 客户端刷新后重试）"))
        }

        // Token 用量（服务端统计）
        menu.addItem(.separator())
        menu.addItem(info("Token 用量（服务端统计）"))
        func tokenLine(_ label: String, _ s: ModelUsage?) -> String {
            guard let s = s, !s.isEmpty else { return "\(label)：暂无记录" }
            var l = "\(label)：\(Fmt.tokens(s.totalTokens)) tokens · 调用 \(Int(s.totalCalls)) 次"
            if !s.byModel.isEmpty {
                l += "\n  " + s.byModel.map { "\($0.name) \(Fmt.tokens($0.tokens))" }
                    .joined(separator: " · ")
            }
            return l
        }
        menu.addItem(info(tokenLine("今日", usage.tokensToday)))
        menu.addItem(info(tokenLine("近 7 天", usage.tokens7d)))
        menu.addItem(info(tokenLine("近 30 天", usage.tokens30d)))

        if let t = usage.tools30d {
            menu.addItem(.separator())
            menu.addItem(info("MCP 工具（近 30 天）：网络搜索 \(Int(t.networkSearch)) 次 · 网页读取 \(Int(t.webRead)) 次"))
        }

        if let e = usage.quotaError {
            menu.addItem(info("额度获取失败：\(e)"))
        }
        if let e = usage.tokensError {
            menu.addItem(info("Token 统计获取失败：\(e)"))
        }

        // 数据过期提示：仅对应组过期时显示，紧贴更新时间行
        if quotaStale {
            menu.addItem(info("⚠️ 额度数据已过期 · 最后成功 \(Fmt.lastOK(quotaLastOK))"))
        }
        if tokensStale {
            menu.addItem(info("⚠️ Token 数据已过期 · 最后成功 \(Fmt.lastOK(tokensLastOK))"))
        }

        menu.addItem(.separator())
        menu.addItem(info("更新于 \(Fmt.time(usage.updatedAt))"))
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

    @objc private func onRefresh() { refresh(tokens: true) }

    @objc private func onQuit() { NSApp.terminate(nil) }
}

// MARK: - 入口（支持 --once 命令行自检）

func onceMode() {
    guard let key = CredStore.loadApiKey() else {
        print("no coding-plan api key found"); exit(1)
    }
    let group = DispatchGroup()
    var data = UsageData()
    // 两组数据的最后成功时间（本次拉到新值才算成功，与 App 内 quotaLastOK/tokensLastOK 口径一致）
    var quotaOK: Date?
    var tokensOK: Date?
    group.enter()
    Fetcher.fetchQuota(apiKey: key) { r in
        if r.fiveHour != nil || r.week != nil { quotaOK = Date() }
        data.fiveHour = r.fiveHour; data.week = r.week
        data.level = r.level; data.quotaError = r.quotaError
        group.leave()
    }
    let now = Date()
    let dayStart = Calendar.current.startOfDay(for: now)
    for (label, from) in [("today", dayStart), ("7d", now.addingTimeInterval(-7 * 86400)),
                          ("30d", now.addingTimeInterval(-30 * 86400))] {
        group.enter()
        Fetcher.fetchModelUsage(apiKey: key, from: from, to: now) { r, err in
            if let r = r {
                tokensOK = Date()
                switch label {
                case "today": data.tokensToday = r
                case "7d": data.tokens7d = r
                default: data.tokens30d = r
                }
            } else { print("tokens \(label) error: \(err ?? "?")") }
            group.leave()
        }
    }
    group.enter()
    Fetcher.fetchToolUsage(apiKey: key, from: now.addingTimeInterval(-30 * 86400), to: now) { r, _ in
        if let r = r { data.tools30d = r }
        group.leave()
    }
    // 充值卡（额度重置卡）+ 套餐到期：与 token 统计同批拉取
    var subErr: String?
    if let (jwt, maas) = CredStore.loadResetTokens() {
        group.enter()
        Fetcher.fetchResetCards(jwt: jwt, maas: maas) { r, err in
            if let r = r { data.resetCards = r }
            else { data.resetCardsError = err ?? "?" }
            group.leave()
        }
    } else {
        data.resetCardsError = "未找到 ZCode 登录凭证"
    }
    group.enter()
    Fetcher.fetchSubscription(apiKey: key) { r, err in
        if let r = r { data.subscription = r }
        else { subErr = err ?? "?" }
        group.leave()
    }
    _ = group.wait(timeout: .now() + 25)

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
            print("tokens \(label): total=\(Fmt.tokens(s.totalTokens)) calls=\(Int(s.totalCalls)) \(models)")
        }
    }
    if let t = data.tools30d {
        print("tools 30d: search=\(Int(t.networkSearch)) webRead=\(Int(t.webRead))")
    }
    if let c = data.resetCards {
        var s = "cards: 5h x\(c.fiveHour.count)"
        let f5 = c.fiveHour.sorted().map { Fmt.fullTime.string(from: $0) }.joined(separator: ", ")
        if !f5.isEmpty { s += " [\(f5)]" }
        s += " week x\(c.week.count)"
        let wk = c.week.sorted().map { Fmt.fullTime.string(from: $0) }.joined(separator: ", ")
        if !wk.isEmpty { s += " [\(wk)]" }
        print(s)
    }
    if let e = data.resetCardsError { print("cards error: \(e)") }
    if let sub = data.subscription {
        var s = "subscription: \(sub.name)"
        if let exp = sub.expireDate { s += " expire=\(Fmt.fullSec.string(from: exp))" }
        print(s)
    }
    if let e = subErr { print("subscription error: \(e)") }
    if let e = data.quotaError { print("quota error: \(e)") }
    print("lastOK: quota=\(Fmt.lastOK(quotaOK)) tokens=\(Fmt.lastOK(tokensOK))")
    exit(0)
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
