import Cocoa
import CryptoKit
import Foundation
import CoreFoundation
import SQLite3

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

    /// 邮箱展示决策（纯函数，self-test 直接覆盖整条 loadAccountEmail 集成路径；
    /// 不触碰真实凭据）。返回 nil = 整行隐藏：
    /// - env 提供过 GLM_API_KEY（非空白）→ 凭据源被覆盖，user_info 与实际 key 无法证明同账号；
    /// - 任何 api-key 候选（含 zai 系、单个或多个）→ 候选归属与 user_info（最后一次 OAuth
    ///   登录写入）无法证明同一账号，唯一候选同样不能证明；
    /// - 仅纯 bigmodel OAuth 回退且 access_token 非空时，user_info 才与该 token 同源；
    /// - 只信 rawProfile.email（username 是 name→email→user_id 回退链，不可靠；顶层 email 无证据）。
    static func resolveAccountEmail(envValue: String?, credentialKeyCandidates: Int,
                                    oauthAccessToken: String?, userInfoJSON: String?) -> String? {
        let trimmedEnv = envValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEnv == nil || trimmedEnv?.isEmpty == true else { return nil }   // env 覆盖 → 隐藏
        guard credentialKeyCandidates == 0 else { return nil }
        guard let token = oauthAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        guard let jsonString = userInfoJSON, !jsonString.isEmpty,
              let info = (try? JSONSerialization.jsonObject(with: Data(jsonString.utf8))) as? [String: Any],
              let profile = info["rawProfile"] as? [String: Any],
              let email = profile["email"] as? String else { return nil }
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isValidEmail(trimmed) ? trimmed : nil
    }

    // 头部可选邮箱：仅从现有凭据库的 oauth:bigmodel:user_info（同一加密格式）读取；
    // 不新增任何网络请求。任一环节失败 → nil（界面整行隐藏，不占空行、不填演示邮箱）。
    // 邮箱不是密钥，但仍只在内存使用：不写 status.json、不打日志。
    static func loadAccountEmail() -> String? {
        let envValue = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if envValue?.isEmpty == false { return nil }   // env 覆盖凭据源 → 隐藏
        guard let data = FileManager.default.contents(atPath: credPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        // 候选口径与 loadApiKey 完全一致（api-key + coding-plan + enc:v1:，zai 系同样命中）
        let candidateCount = obj.filter { key, value in
            key.contains("api-key") && key.contains("coding-plan") && value.hasPrefix("enc:v1:")
        }.count
        let oauthToken = decrypt(obj["oauth:bigmodel:access_token"] ?? "")
        let rawUserInfo = obj["oauth:bigmodel:user_info"] ?? ""
        let userInfoJSON = rawUserInfo.isEmpty ? nil : (rawUserInfo.hasPrefix("enc:v1:") ? decrypt(rawUserInfo) : rawUserInfo)
        return resolveAccountEmail(envValue: envValue, credentialKeyCandidates: candidateCount,
                                   oauthAccessToken: oauthToken, userInfoJSON: userInfoJSON)
    }

    /// 宽松但足够的邮箱格式校验（x@y.z，总长 ≤254），防止把昵称/用户 ID 当邮箱展示
    static func isValidEmail(_ value: String) -> Bool {
        value.count <= 254 && value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) != nil
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
    var usedRatio: Double      // 0..1（由 usage / remaining 推导，保证与剩余 credits 一致）
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

/// 单日用量桶：tokens=nil 表示该自然日无任何记录（缺失），与「有记录的零日」严格区分，
/// 缺失日不参与比较（不得当 0 合成）。
struct GLMDayBucket: Equatable {
    let day: Date
    let tokens: Double?
}

/// Start Plan 通过 ZCode 自有网关计量，未进入 Coding Plan 的 model-usage。
/// balance 仅有额度桶累计值，周期统计必须使用本机逐次请求记录。
enum GLMStartPlanUsage {
    struct ReadFailure: Error {}

    struct Record {
        let startedAt: Date
        let model: String
        let tokens: Double
    }

    struct Snapshot {
        let records: [Record]

        func merging(_ usage: ModelUsage, from: Date, to: Date) -> ModelUsage {
            let included = records.filter { $0.startedAt >= from && $0.startedAt <= to }
            var models: [String: (name: String, tokens: Double)] = [:]
            for model in usage.byModel {
                let key = model.name.lowercased()
                let old = models[key]
                models[key] = (old?.name ?? model.name, (old?.tokens ?? 0) + model.tokens)
            }
            for record in included {
                let key = record.model.lowercased()
                let old = models[key]
                models[key] = (old?.name ?? record.model, (old?.tokens ?? 0) + record.tokens)
            }
            return ModelUsage(totalTokens: usage.totalTokens + included.reduce(0) { $0 + $1.tokens },
                              totalCalls: usage.totalCalls + Double(included.count),
                              byModel: models.keys.sorted().compactMap { models[$0] })
        }

        func merging(_ buckets: [GLMDayBucket], calendar: Calendar = .current) -> [GLMDayBucket] {
            var totals: [Date: Double] = [:]
            for record in records {
                totals[calendar.startOfDay(for: record.startedAt), default: 0] += record.tokens
            }
            // 官方缺失日仍为未知，不能用局部的赠送记录冒充完整日统计。
            return buckets.map { bucket in
                GLMDayBucket(day: bucket.day, tokens: bucket.tokens.map { $0 + (totals[bucket.day] ?? 0) })
            }
        }
    }

    static func load(from: Date, to: Date, databasePath: String = NSHomeDirectory()
                     + "/.zcode/cli/db/db.sqlite", calendar: Calendar = .current) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: databasePath) else { return Snapshot(records: []) }
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else { throw ReadFailure() }
        sqlite3_busy_timeout(database, 1_000)

        // 每个主键对应一次实际请求尝试。重试产生的额外消耗保留，付费订阅不重复计入。
        // provider_total_tokens 已包含缓存输入，不能再累加 cache_read_input_tokens。
        let query = """
            SELECT started_at, model_id, COALESCE(provider_total_tokens, computed_total_tokens)
            FROM model_usage
            WHERE provider_id IN ('account:bigmodel-start-plan', 'builtin:bigmodel-start-plan')
              AND started_at >= ? AND started_at <= ? AND status != 'running'
              AND COALESCE(provider_total_tokens, computed_total_tokens) > 0
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            // 较早的 ZCode 尚未保存逐次请求表，保留原有服务端统计。
            if String(cString: sqlite3_errmsg(database)) == "no such table: model_usage" {
                return Snapshot(records: [])
            }
            throw ReadFailure()
        }
        // 日图的首日沿用官方自然日口径，周期总量再按精确的窗口起点筛选。
        sqlite3_bind_double(statement, 1, calendar.startOfDay(for: from).timeIntervalSince1970 * 1_000)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970 * 1_000)
        var records: [Record] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  let rawModel = sqlite3_column_text(statement, 1),
                  sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { throw ReadFailure() }
            let tokens = sqlite3_column_double(statement, 2)
            let model = String(cString: rawModel).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tokens.isFinite, tokens > 0, !model.isEmpty else { throw ReadFailure() }
            records.append(Record(startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0) / 1_000),
                                  model: model, tokens: tokens))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadFailure() }
        return Snapshot(records: records)
    }
}

// MARK: - 每日用量（近 30 天，含今日未走完的部分累计）
//
// 数据来源：30 天慢刷新的 model-usage 响应 + 本机 Start Plan 逐次用量，不新增请求/定时器。
// 真实接口口径（2026-11-06 只读验收，主会话探针，与 totalUsage 逐日求和精确配平）：
// granularity=daily，x_time 为本地自然日 "yyyy-MM-dd" 标签（30 天窗返回 31 个、
// 严格递增、零缺口、首标签=请求起点日），modelDataList[].tokensUsage 与标签按下标对齐。
// 2026-11-07 起窗口含今日（对齐 KimiUsage/CodexUsage 的「今日」口径），不再止于昨日：
// 今日柱随当日用量增长，比较条同口径（今日 vs 昨日、含今日的 7 日 vs 再前 7 日）。
// 公开实现（CodexBar zai.js）的小时粒度假设与真实响应不符——以验收口径为准。
// 字段依据公开实现交叉证实（CodexBar Sources/CodexBarCore/Resources/Plugins/zai.js：
// data.x_time 时间标签数组 + data.modelDataList[].tokensUsage 与其按下标对齐）；
// 官方 glm-plan-usage 插件对同一响应只 dump 不解析，官方 schema 未公开——
// 真实接口 Gate 未验证，字段缺失/畸形时生产界面显示明确空态（暂不可用/数据不足），绝不造 0。

enum GLMDailyUsage {
    /// 真实接口 Gate：已于 2026-11-06 主会话只读验收确认（本机凭据一次 GET model-usage，
    /// 30 天窗）：HTTP/code 200，data.granularity=daily，x_time 为本地自然日 "yyyy-MM-dd"
    /// 标签（31 个、严格递增、零缺口、首标签=请求起点日、含今日部分累计），
    /// modelDataList[].tokensUsage 与标签按下标对齐且无 null/负值/重名模型，
    /// 逐日求和与 totalUsage.totalTokensUsage 精确配平。此前官方插件对响应只 dump
    /// 不解析、公开实现的小时粒度假设与真实不符，故当时保持空态直到验收。
    /// 解析失败/口径漂移时上层整体拒绝进入空态，绝不造 0。
    static let productionGateConfirmed = true

    /// 严格解析出的日序列：times 与 totals 等长且按时间严格递增
    struct Timeline {
        let times: [Date]
        let totals: [Double]
    }

    /// model-usage 响应 → 日序列。任一异常整体拒绝（返回 nil）：
    /// 标签缺失/非字符串/格式不符/时间重复乱序、tokensUsage 缺失/长度不齐/
    /// null/负值/非有限值、modelDataList 缺失或为空——未知日不得当 0。
    /// 标签为日粒度 "yyyy-MM-dd"（2026-11-06 只读验收口径，granularity=daily）；
    /// 解析失败即整体拒绝进入空态，不猜测。
    static func parseTimeline(_ data: [String: Any], timeZone: TimeZone = .current) -> Timeline? {
        guard let rawLabels = data["x_time"] as? [Any], !rawLabels.isEmpty else { return nil }
        guard let rawModels = data["modelDataList"] as? [[String: Any]], !rawModels.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        var times: [Date] = []
        times.reserveCapacity(rawLabels.count)
        for raw in rawLabels {
            // round-trip 校验：ICU 对分隔符/补零宽松（"2026/11/05" 也能被 "yyyy-MM-dd" 解析），
            // 必须反向格式化后与原文全等，确保标签确实是规定格式，不靠猜
            guard let text = raw as? String, let date = formatter.date(from: text),
                  formatter.string(from: date) == text else { return nil }
            if let last = times.last, date <= last { return nil }   // 严格递增：重复/乱序直接拒绝
            times.append(date)
        }
        var totals = [Double](repeating: 0, count: times.count)
        var seenModelNames = Set<String>()
        for model in rawModels {
            guard let values = model["tokensUsage"] as? [Any], values.count == times.count else { return nil }
            // 同名模型重复行可能把同一用量计入两次（与 totalUsage 配不平且无法归因），整体拒绝
            let name = model["modelName"] as? String ?? "?"
            guard seenModelNames.insert(name).inserted else { return nil }
            for (index, raw) in values.enumerated() {
                guard let number = GLMNumber.finite(raw), number >= 0 else { return nil }
                let next = totals[index] + number
                guard next.isFinite else { return nil }   // 求和溢出（inf）按无效序列拒绝
                totals[index] = next
            }
        }
        return Timeline(times: times, totals: totals)
    }

    /// 日序列 → 最近 days 个自然日桶（旧→新，含今日未走完的部分累计；
    /// 2026-11-07 起不再止于昨日，对齐 KimiUsage/CodexUsage 的「今日」口径）。
    /// 日粒度直映射（2026-11-06 只读验收确认服务端按本地自然日汇总，无需本地小时网格/DST 推断）：
    /// - 桶范围 = today-(days-1) ... today；今日柱为当日部分累计（随用时增长）；窗口外的标签丢弃；
    /// - coverageStart（请求窗口起点）所在日按自然日对齐后准入——服务端日标签
    ///   即该自然日的汇总（今日为部分累计），不再按小时覆盖率判缺失；
    /// - 桶范围内序列缺失的日期 → tokens=nil（数据不足），绝不补 0。
    /// 注意：timeline 求和与响应 totalUsage（周期表数字）不承诺配平，两者来源独立。
    static func frame(from timeline: Timeline, calendar: Calendar = .current,
                      now: Date, days: Int = 30, coverageStart: Date? = nil) -> [GLMDayBucket]? {
        guard days > 0 else { return nil }
        guard let todayStart = calendar.date(from: calendar.dateComponents([.year, .month, .day], from: now)),
              let oldest = calendar.date(byAdding: .day, value: -(days - 1), to: todayStart) else { return nil }
        var sums: [Date: Double] = [:]
        for (index, raw) in timeline.times.enumerated() {
            guard timeline.totals[index].isFinite else { return nil }
            let day = calendar.startOfDay(for: raw)
            let admissible = day >= oldest && day <= todayStart
                && (coverageStart == nil || day >= calendar.startOfDay(for: coverageStart!))
            if admissible { sums[day] = timeline.totals[index] }
        }
        var buckets: [GLMDayBucket] = []
        buckets.reserveCapacity(days)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset - (days - 1), to: todayStart) else { return nil }
            buckets.append(GLMDayBucket(day: day, tokens: sums[day]))
        }
        return buckets
    }
}

/// 每日两项比较的纯逻辑（PRD §6.3，实现规则不进界面脚注）：
/// 百分比 = (当前 − 基期) / 基期 × 100%，一位小数；双方 0 或 |pct|<0.05 → 持平；
/// 基期 0 且当前 > 0 → 「新增 N」；任一必要日缺失 → 「数据不足」。
enum GLMUsageComparison {
    enum Direction { case increase, decrease, neutral }
    enum Outcome: Equatable {
        case percent(String)   // "+7.4%" / "-3.2%"（中性展示，不暗示增减好坏）
        case flat              // 持平
        case added(String)     // 新增 1.2K
        case insufficient      // 数据不足

        var text: String {
            switch self {
            case .percent(let value), .added(let value): return value
            case .flat: return "持平"
            case .insufficient: return "数据不足"
            }
        }

        /// 非数值结果（持平/数据不足）在比较条中用弱化色，数值结果用正常强调色
        var isMuted: Bool {
            switch self {
            case .percent, .added: return false
            case .flat, .insufficient: return true
            }
        }

        var direction: Direction {
            switch self {
            case .percent(let value): return value.hasPrefix("-") ? .decrease : .increase
            case .added: return .increase
            case .flat, .insufficient: return .neutral
            }
        }
    }

    /// 窗口求和：任一日缺失 → nil（缺失不能当 0 参与比较）
    static func sum(_ buckets: [GLMDayBucket?]) -> Double? {
        guard !buckets.isEmpty else { return nil }
        var total: Double = 0
        for bucket in buckets {
            guard let tokens = bucket?.tokens else { return nil }
            total += tokens
        }
        return total
    }

    static func outcome(current: Double?, base: Double?) -> Outcome {
        guard let current = current, let base = base else { return .insufficient }
        if current == 0 && base == 0 { return .flat }
        if base == 0 { return .added("新增 \(Fmt.tokens(current))") }
        let pct = (current - base) / base * 100
        if abs(pct) < 0.05 { return .flat }   // |pct|<0.05 归持平：一位小数下防显示 "-0.0%"
        return .percent(String(format: "%+.1f%%", pct))
    }

    /// 面板两项比较：D=最后一日（今日，未走完的部分累计，与柱图末端一致）；
    /// 较昨日 = 今日 vs 昨日；较前 7 天 = 含今日的 7 日 vs 再前 7 日（14 日全覆盖才比较）
    static func dailyPair(buckets: [GLMDayBucket]) -> (dayOnDay: Outcome, weekOnWeek: Outcome) {
        let dayOnDay = outcome(current: buckets.last?.tokens,
                               base: buckets.count >= 2 ? buckets[buckets.count - 2].tokens : nil)
        let weekCurrent = buckets.count >= 7 ? sum(Array(buckets.suffix(7)).map { Optional($0) }) : nil
        let weekBase = buckets.count >= 14 ? sum(buckets.suffix(14).prefix(7).map { Optional($0) }) : nil
        return (dayOnDay, outcome(current: weekCurrent, base: weekBase))
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

    func availableCount(now: Date) -> Int? {
        guard let fiveHour = fiveHour, let week = week else { return nil }
        return GLMFreshness.availableCards(fiveHour, now: now).count
            + GLMFreshness.availableCards(week, now: now).count
    }
}

/// 重置卡类型（服务器 reset_type 取值）
enum ResetCardType: String {
    case fiveHour = "FIVE_HOUR"
    case week = "WEEK"
    var displayName: String { self == .fiveHour ? "5 小时重置卡" : "周重置卡" }
}

/// 使用重置卡的结果：retryable=true 表示结果未知（网络/5xx/响应不完整），保留同一幂等 key 重试不会重复扣卡
struct ResetUseOutcome {
    var used: Bool
    var error: String?
    var retryable: Bool
}

/// 重置卡幂等 key 的跨进程持久化：「结果未知」后进程可能被 launchd 重启，key 只存内存会在
/// 重启边界失效、重试生成新 key 导致重复扣卡。文件仅含 类型→{key, createdAt}，不含任何凭据。
enum GLMPendingResetStore {
    /// 未决 key 保留期：幂等复用只需覆盖结果未知后的短期重试，超期自动剪枝
    static let retention: TimeInterval = 7 * 24 * 3600

    struct Entry: Equatable {
        let key: String
        let createdAt: Date
    }

    static func load(dir: String, now: Date = Date()) -> [String: Entry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/pending-resets.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: Entry] = [:]
        for (type, value) in obj {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty,
                  let at = entry["at"] as? Double,
                  now.timeIntervalSince1970 - at < retention else { continue }
            out[type] = Entry(key: key, createdAt: Date(timeIntervalSince1970: at))
        }
        return out
    }

    static func save(_ keys: [String: Entry], dir: String) {
        var obj: [String: [String: Any]] = [:]
        for (type, e) in keys {
            obj[type] = ["key": e.key, "at": e.createdAt.timeIntervalSince1970]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // .atomic：写盘中途被杀不留半截文件——半截文件会让 load 兜底清空未决 key，恰是本功能要防的重复扣卡窗口
        try? data.write(to: URL(fileURLWithPath: dir + "/pending-resets.json"), options: [.atomic])
    }
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
    var dailyTokens: [GLMDayBucket]?   // 每日用量：近 30 完整自然日桶（缺失日=nil≠0；未过真实接口 Gate 前生产恒为 nil）
    var dailyTokensError: String?      // 仅用于 freshness 保留旧值，界面不显示技术错误
    var accountEmail: String?          // 头部可选邮箱（仅现有凭据内可靠可得；绝不写 status.json/日志）
    var tools30d: ToolUsage?
    var resetCards: ResetCards?        // 重置卡（额度重置卡）可用列表
    var resetCardsError: String?
    var subscription: SubscriptionInfo?
    var subscriptionSucceeded = false
    var quotaError: String?
    var tokensError: String?
    var fiveHourError: String?
    var weekError: String?
    var fiveHourWarning: String?
    var weekWarning: String?
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
            // 超额时 currentValue 可大于 usage，仍保留窗口。
            let fields = ["usage", "currentValue", "remaining", "percentage"]
            let bad = fields.filter { GLMNumber.finite(row[$0]) == nil }
            guard bad.isEmpty, let limit = GLMNumber.finite(row["usage"]), limit > 0,
                  let used = GLMNumber.finite(row["currentValue"]), used >= 0,
                  let remaining = GLMNumber.finite(row["remaining"]), remaining >= 0, remaining <= limit,
                  GLMNumber.nonnegativeRoundedInteger(limit) != nil,
                  GLMNumber.nonnegativeRoundedInteger(used) != nil,
                  GLMNumber.nonnegativeRoundedInteger(remaining) != nil,
                  let percentage = GLMNumber.finite(row["percentage"]), (0...100).contains(percentage) else {
                var invalidFields = bad
                if let n = GLMNumber.finite(row["usage"]), n <= 0 || GLMNumber.nonnegativeRoundedInteger(n) == nil { invalidFields.append("usage") }
                if let n = GLMNumber.finite(row["currentValue"]), n < 0 || GLMNumber.nonnegativeRoundedInteger(n) == nil { invalidFields.append("currentValue") }
                if let n = GLMNumber.finite(row["remaining"]), n < 0 || n > (GLMNumber.finite(row["usage"]) ?? 0) || GLMNumber.nonnegativeRoundedInteger(n) == nil { invalidFields.append("remaining") }
                if let n = GLMNumber.finite(row["percentage"]), !(0...100).contains(n) { invalidFields.append("percentage") }
                let detail = invalidFields.joined(separator: ", ")
                if isFive { result.fiveHourError = "invalid \(window): \(detail)" } else { result.weekError = "invalid \(window): \(detail)" }
                continue
            }
            // 服务端的 currentValue / remaining 分别取整，percentage 也会截断或向上取整。
            // 按余额计算进度，允许 1 个百分点的取整差异；明显矛盾仍提示警告。
            var warnings: [String] = []
            let usedRatio = (limit - remaining) / limit
            if abs((min(used, limit) + remaining) - limit) > max(1.5, limit * 0.000001)
                || abs(percentage - usedRatio * 100) > 1.000001 {
                warnings.append("invalid \(window): inconsistent usage/currentValue/remaining/percentage")
            }
            let reset: Date?
            if let rawReset = row["nextResetTime"] {
                if let milliseconds = GLMNumber.finite(rawReset), milliseconds > 0 {
                    reset = Date(timeIntervalSince1970: milliseconds / 1000)
                } else { reset = nil; warnings.append("invalid \(window): nextResetTime") }
            } else { reset = nil }
            let entry = LimitEntry(label: label, isFiveHour: isFive, limit: limit, used: used,
                                   remaining: remaining, usedRatio: usedRatio, reset: reset)
            let warning = warnings.isEmpty ? nil : warnings.joined(separator: "; ")
            if isFive, result.fiveHour == nil {
                result.fiveHour = entry
                result.fiveHourWarning = warning
            }
            if isWeek, result.week == nil {
                result.week = entry
                result.weekWarning = warning
            }
        }
        if result.fiveHour == nil && !sawFive { result.fiveHourError = "missing 5H quota" }
        if result.week == nil && !sawWeek { result.weekError = "missing 7D quota" }
        if result.fiveHour == nil && result.week == nil {
            result.quotaError = [result.fiveHourError, result.weekError].compactMap { $0 }.joined(separator: "; ")
        }
        return result
    }

    /// model-usage：一个时间窗的 token/调用统计；第二/三参数为每日桶与其解析失败标记
    /// （复用同一响应，不新增请求；Gate 已于 2026-11-06 真实验收确认，解析失败仍整体拒绝）
    static func fetchModelUsage(apiKey: String, from: Date, to: Date,
                                completion: @escaping (ModelUsage?, [GLMDayBucket]?, Bool, String?) -> Void) {
        // 环境变量可指向其他账号，其用量不能与当前 ZCode 的本机记录直接合并。
        let externalKey = ProcessInfo.processInfo.environment[CredStore.envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fetch(apiKey: apiKey, path: "/api/monitor/usage/model-usage", from: from, to: to) { data, err in
            guard let data = data, err == nil else { completion(nil, nil, false, err ?? "no data"); return }
            guard let usage = parseModelUsage(data) else {
                completion(nil, nil, false, "missing or invalid model usage fields"); return
            }
            let daily = Self.dailyBuckets(from: data, windowStart: from, now: Date())
            guard externalKey?.isEmpty != false else {
                completion(usage, daily.buckets, daily.parseFailed, nil)
                return
            }
            do {
                let startPlan = try GLMStartPlanUsage.load(from: from, to: to)
                completion(startPlan.merging(usage, from: from, to: to),
                           daily.buckets.map { startPlan.merging($0) }, daily.parseFailed, nil)
            } catch {
                // 整次合并失败，沿用现有 freshness 逻辑保留上次完整统计。
                completion(nil, nil, false, "赠送用量暂不可用")
            }
        }
    }

    /// 同一响应 → 每日桶。三分语义：
    /// - buckets 非 nil：Gate 开启且解析/聚合成功；
    /// - buckets nil + parseFailed=false：Gate 未确认（生产正常空态「暂不可用」，非错误、不提示待更新）；
    /// - buckets nil + parseFailed=true：Gate 开启但响应无字段/解析失败 → 上层按失败保留旧值并给简短「待更新」，
    ///   不得静默拿旧图冒充新数据，也不显示技术细节。
    static func dailyBuckets(from data: [String: Any], windowStart: Date, now: Date) -> (buckets: [GLMDayBucket]?, parseFailed: Bool) {
        guard GLMDailyUsage.productionGateConfirmed else { return (nil, false) }
        guard let timeline = GLMDailyUsage.parseTimeline(data),
              let buckets = GLMDailyUsage.frame(from: timeline, now: now, coverageStart: windowStart) else {
            return (nil, true)
        }
        return (buckets, false)
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

    /// 重置卡接口统一请求构造（GET status / POST use 共用同一套双 token 认证头）
    private static func resetRequest(_ path: String, jwt: String, maas: String,
                                     method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: resetBase + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        // zcodejwttoken 明文可能已自带 "Bearer " 前缀，避免重复拼接
        let auth = jwt.lowercased().hasPrefix("bearer ") ? jwt : "Bearer \(jwt)"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue(maas, forHTTPHeaderField: "X-Bigmodel-Authorization")
        req.setValue("PERSONAL", forHTTPHeaderField: "Bigmodel-Target-Type")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("GlmUsage-Menubar/1.0", forHTTPHeaderField: "User-Agent")
        if let body { req.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        return req
    }

    /// 查询可用重置卡列表；jwt/maas 为 ZCode 登录态 token，过期/缺失由上层优雅降级
    static func fetchResetCards(jwt: String, maas: String,
                                completion: @escaping (ResetCardsResult) -> Void) {
        guard let req = resetRequest("/api/v1/coding-plan/reset/status", jwt: jwt, maas: maas) else {
            completion(ResetCardsResult(fiveHourError: "bad url", weekError: "bad url")); return
        }
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

    /// 使用一张重置卡（写操作；仅由用户在界面上确认后调用，绝不自动触发）
    /// idempotencyKey 由调用方生成并在结果未知时保留复用——服务器按 key 幂等，重试不会重复扣卡
    static func useResetCard(jwt: String, maas: String, resetType: ResetCardType,
                             idempotencyKey: String,
                             completion: @escaping (ResetUseOutcome) -> Void) {
        let trimmed = idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64,
              let req = resetRequest("/api/v1/coding-plan/reset/use", jwt: jwt, maas: maas,
                                     method: "POST",
                                     body: ["idempotency_key": trimmed,
                                            "reset_type": resetType.rawValue]) else {
            completion(ResetUseOutcome(used: false, error: "bad request", retryable: false)); return
        }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(ResetUseOutcome(used: false, error: err.localizedDescription, retryable: true)); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(ResetUseOutcome(used: false, error: "bad response", retryable: true)); return
            }
            completion(parseResetUseResponse(obj, httpStatus: (resp as? HTTPURLResponse)?.statusCode))
        }.resume()
    }

    /// 纯解析：成功 = code==0 且 data.used==true；服务端明确拒绝不可重试，
    /// 网络/5xx/code==0 但缺 used==true 均视为结果未知、可安全重试（复用同一幂等 key）
    static func parseResetUseResponse(_ obj: [String: Any], httpStatus: Int?) -> ResetUseOutcome {
        if let http = httpStatus, http != 200 {
            return ResetUseOutcome(used: false, error: "HTTP \(http)", retryable: http >= 500)
        }
        let code = GLMNumber.integer(obj["code"]) ?? -1
        guard code == 0 else {
            let msg = (obj["msg"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return ResetUseOutcome(used: false, error: "code \(code)\(msg.isEmpty ? "" : " \(msg)")",
                                   retryable: false)
        }
        guard let d = obj["data"] as? [String: Any] else {
            return ResetUseOutcome(used: false, error: "no data", retryable: true)
        }
        if (d["used"] as? Bool) == true {
            return ResetUseOutcome(used: true, error: nil, retryable: false)
        }
        // code==0 但服务端未确认 used==true：消费状态未知，必须保留幂等 key（协议异常 ≠ 明确拒绝）
        return ResetUseOutcome(used: false, error: "服务器未确认使用结果", retryable: true)
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

    static func make(line1: Line, line2: Line, appearance: NSAppearance? = nil) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
        let s1 = attributed(line1, font: font)
        let s2 = attributed(line2, font: font)
        let badgeAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let b1 = line1.badge.isEmpty ? nil : NSAttributedString(string: line1.badge, attributes: badgeAttrs)
        let b2 = line2.badge.isEmpty ? nil : NSAttributedString(string: line2.badge, attributes: badgeAttrs)
        let g = geometry(badge1Width: b1?.size().width ?? 0, badge2Width: b2?.size().width ?? 0,
                         text1Width: s1.size().width, text2Width: s2.size().width)
        let draw = {
            if let x = g.badge1X { b1?.draw(at: NSPoint(x: x, y: 10.5)) }
            if let x = g.badge2X { b2?.draw(at: NSPoint(x: x, y: 0.5)) }
            s1.draw(at: NSPoint(x: g.textX, y: 10.5))
            s2.draw(at: NSPoint(x: g.textX, y: 0.5))
        }
        let img = NSImage(size: NSSize(width: ceil(g.width), height: 21), flipped: false) { _ in
            // 正常时不钉死绘制外观，由系统按每条菜单栏各自解析动态颜色，兼容双屏不同底色。
            // 显式外观仅供离线像素测试使用，生产渲染始终跟随菜单栏自身外观。
            if let appearance = appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        img.isTemplate = false   // 保留百分比余量颜色
        img.cacheMode = .never   // 小图直接重绘，避免菜单栏外观变化后复用旧颜色位图
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
    private static let weekDayTimeFmt = zhFormatter("MM-dd E HH:mm")
    private static let expiresTodayFmt = zhFormatter("'今天' HH:mm")
    private static let expiresTomorrowFmt = zhFormatter("'明天' HH:mm")
    private static let expiresFullFmt = zhFormatter("yyyy-MM-dd HH:mm")
    private static let monthDayFmt = zhFormatter("M月d日")   // 每日用量选中日期
    private static let dayTickFmt = zhFormatter("M/d")       // 每日用量横轴刻度

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
    // 额度窗口重置时间（5 小时/7 天统一格式）：带周几，如 "12-06 周六 13:46"
    static func weekDayTime(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return weekDayTimeFmt.string(from: d)
    }
    // 每日用量选中日期，如 "11月5日"
    static func monthDay(_ d: Date) -> String { monthDayFmt.string(from: d) }
    // 每日用量横轴刻度，如 "10/7"
    static func dayTick(_ d: Date) -> String { dayTickFmt.string(from: d) }
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

    /// 高峰时刻判定（工作日 14:00–18:00，双节活动日全天非高峰）；evaluate 与面板 display 共用
    private static func isPeakMoment(_ c: DateComponents, festival: Bool) -> Bool {
        !festival && (2...6).contains(c.weekday!) && c.hour! >= 14 && c.hour! < 18
    }

    /// 目标时刻落在今天/明天时用相对表述，否则「MM-dd HH:mm」；文案口径与 evaluate 现有输出一致
    private static func relativeDayText(_ target: Date, time: String, at date: Date) -> String {
        if cal.isDate(target, inSameDayAs: date) { return "今天 \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: date), cal.isDate(target, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        return Fmt.dayTime(target)
    }

    /// emoji：⚡ 深夜活动 ＞ 🔥 高峰 ＞ 无（普通非高峰不占宽度）
    static func evaluate(at date: Date = Date()) -> (emoji: String?, line: String, eventLine: String?) {
        let c = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        let festival = isFestivalDay(c)
        let night = isNightWindow(date)
        let peak = isPeakMoment(c, festival: festival)

        let npText = relativeDayText(nextPeakStart(date), time: "14:00", at: date)

        let emoji = night ? "⚡" : (peak ? "🔥" : nil)
        let line = peak
            ? "🔥 高峰期 · 积分全价（18:00 后恢复 5 折）"
            : "⚡ 非高峰 · 积分 5 折（下个高峰 \(npText)）"
        return (emoji, line, eventLine(festival: festival, night: night))
    }

    /// 限时活动行：深夜错峰优先于双节（两者重叠时深夜窗口覆盖全天文案）
    private static func eventLine(festival: Bool, night: Bool) -> String? {
        if night { return "🌙 深夜错峰：Flash 免费 · 其他 Agent 额度 ×2（至 10-07）" }
        if festival { return "🎉 双节活动：全天按非高峰 5 折（至 10-07）" }
        return nil
    }

    /// 面板峰谷卡的结构化展示数据：与 evaluate 共用同一套判定、时间措辞与活动行，只省去整句拼装
    struct Display {
        let isPeak: Bool
        let badge: String        // 非高峰 / 高峰中
        let discount: String     // 5 折 / 原价
        let nextLabel: String    // 下次高峰开始 / 下次非高峰开始
        let nextTime: String     // 今天 14:00 / 明天 14:00 / 11-09 14:00 / 今天 18:00
        let eventLine: String?
    }

    static func display(at date: Date = Date()) -> Display {
        let c = cal.dateComponents([.year, .month, .day, .hour, .weekday], from: date)
        let festival = isFestivalDay(c)
        let night = isNightWindow(date)
        let event = eventLine(festival: festival, night: night)
        if isPeakMoment(c, festival: festival) {
            // 高峰窗口固定 14:00–18:00，结束时刻即当天 18:00（与 evaluate 文案「18:00 后恢复 5 折」同源）
            let end = cal.date(bySettingHour: 18, minute: 0, second: 0, of: date)!
            return Display(isPeak: true, badge: "高峰中", discount: "原价",
                           nextLabel: "下次非高峰开始", nextTime: relativeDayText(end, time: "18:00", at: date), eventLine: event)
        }
        return Display(isPeak: false, badge: "非高峰", discount: "5 折",
                       nextLabel: "下次高峰开始", nextTime: relativeDayText(nextPeakStart(date), time: "14:00", at: date), eventLine: event)
    }
}


// 从应用直接启动更新子进程，保留 TCC 的责任应用归属。
// nohup 与独立的临时脚本确保应用退出换包后，子进程仍能完成更新或回滚。
// 进度在下拉面板内原位展示（更新按钮变进度行），不再弹独立窗口、不抢占焦点：
// 任务与 UI 解耦，关闭面板不影响更新，重开面板时根据这里的状态恢复进度行；
// 失败另用 alert 兜底，因为那一刻面板可能已经关闭。
final class UpdateProgressController: NSObject {
    static let shared = UpdateProgressController()
    static let didChangeNotification = Notification.Name("GlmUsage.UpdateProgress.didChange")

    enum Phase: Equatable {
        case idle, preparing, downloading, verifying, staging, installing, finished, failed
    }

    private(set) var phase: Phase = .idle
    private(set) var fraction: Double = 0   // 仅 downloading 阶段有意义，0–100
    /// 进行中（含安装重启阶段）；失败/结束后恢复为可点击的更新按钮
    var isActive: Bool { [.preparing, .downloading, .verifying, .staging, .installing].contains(phase) }
    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "正在准备更新…"
        case .downloading: return "正在下载更新… \(Int(fraction))%"
        case .verifying: return "正在校验更新…"
        case .staging: return "正在准备安装…"
        case .installing: return "正在安装并重启…"
        case .finished: return "更新完成，正在重启…"
        case .failed: return "更新失败"
        }
    }
    /// 安装阶段的重启预告：用户需要知道应用即将自己退出，不是异常消失
    var detailLine: String? {
        phase == .installing ? "应用将自动退出并重启，无需手动操作" : nil
    }

    private var timer: Timer?
    private var directory: URL?

    func start(script: String, tag: String, appPath: String) {
        guard !isActive else { return }   // 进度行已替换按钮，这里再兜底防重入
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
            /bin/bash "$1/update.sh" "$2" "$3" > "$1/log" 2>&1
            result=$?
            printf '%s' "$result" > "$1/result"
            if [ "$result" -ne 0 ] && /usr/bin/grep -q '4/5' "$1/log"; then
                detail=$(/usr/bin/grep '!!' "$1/log" | /usr/bin/tail -1)
                /usr/bin/osascript - "${detail:-更新未完成，请查看日志。}" "$1/log" <<'APPLESCRIPT' >/dev/null 2>&1
            on run argv
                display dialog ((item 1 of argv) & return & return & "日志：" & (item 2 of argv)) with title "更新失败" buttons {"好"} default button 1 with icon caution
            end run
            APPLESCRIPT
            fi
            if [ "$result" -eq 0 ]; then /bin/sleep 5; /bin/rm -rf "$1"; fi
            exit "$result"
            """
            try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
            phase = .preparing
            fraction = 0
            notify()
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            launch.arguments = ["/bin/bash", wrapper.path, dir.path, tag, appPath]
            launch.currentDirectoryURL = dir
            launch.standardInput = FileHandle.nullDevice
            launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
            try launch.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        } catch {
            finishError("无法启动更新，请稍后重试。")
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func setPhase(_ newPhase: Phase, fraction newFraction: Double? = nil) {
        let changed = phase != newPhase || (newFraction.map { $0 != fraction } ?? false)
        phase = newPhase
        if let newFraction = newFraction { fraction = newFraction }
        if changed { notify() }
    }

    private func refresh() {
        guard let dir = directory else { return }
        let log = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        if log.contains("4/5") || log.contains("5/5") { setPhase(.installing) }
        else if log.contains("3/5") { setPhase(.staging) }
        else if log.contains("2/5") { setPhase(.verifying) }
        else if log.contains("下载 v") {
            var value: Double?
            if let text = try? String(contentsOf: dir.appendingPathComponent("progress"), encoding: .utf8),
               let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#),
               let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text) {
                value = Double(text[range])
            }
            setPhase(.downloading, fraction: value)   // 百分比尚未写出时保留旧值
        }
        if let result = try? String(contentsOf: dir.appendingPathComponent("result"), encoding: .utf8) {
            if result != "0" {
                let detail = log.components(separatedBy: .newlines).last(where: { $0.contains("!!") }) ?? "更新未完成，请查看日志。"
                finishError(detail.replacingOccurrences(of: "!! ", with: ""))
            } else {
                // 正常路径下旧进程已被脚本替换重启，走不到这里；兜底停止轮询
                timer?.invalidate(); timer = nil
                setPhase(.finished)
            }
        }
    }

    private func finishError(_ detail: String) {
        timer?.invalidate(); timer = nil
        phase = .failed
        notify()   // 先恢复面板里的更新按钮，再模态弹窗
        let alert = NSAlert(); alert.messageText = "更新失败"; alert.informativeText = detail
        if let dir = directory { alert.informativeText += "\n\n日志：\(dir.appendingPathComponent("log").path)" }
        alert.addButton(withTitle: "好"); alert.runModal()
        directory = nil
    }

    /// 视觉预览专用：不启动子进程，仅呈现进行中的进度行。
    func simulateForPreview(phase previewPhase: Phase, fraction previewFraction: Double) {
        phase = previewPhase
        fraction = previewFraction
    }
}

/// 下拉面板内的更新进度行：原位替换「新版本可用」按钮。
/// 自身订阅进度通知刷新文本与进度条，避免每 0.25s 重建整个面板；
/// 面板关闭后重开，buildPanel 会新建本行并同步到当前进度。
final class UpdateProgressRowView: NSView {
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.maximumNumberOfLines = 1
        status.alignment = .left
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left
        bar.style = .bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [status, bar, detail] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        observer = NotificationCenter.default.addObserver(
            forName: UpdateProgressController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func sync() {
        let controller = UpdateProgressController.shared
        status.stringValue = controller.statusLine
        detail.stringValue = controller.detailLine ?? ""
        detail.isHidden = controller.detailLine == nil
        if controller.phase == .downloading {
            if bar.isIndeterminate { bar.stopAnimation(nil) }
            bar.isIndeterminate = false
            bar.minValue = 0; bar.maxValue = 100
            bar.doubleValue = controller.fraction
        } else {
            if !bar.isIndeterminate { bar.isIndeterminate = true }
            bar.startAnimation(nil)
        }
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

    /// 明暗两态动态色：余量色阶与峰谷卡主题色（GLMPeakTint）共用同一解码与外观解析
    static func dynamic(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
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
    static let contentInset: CGFloat = 14
    static let verticalInset: CGFloat = 12

    let content = GLMPanelStack()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // 阴影在卡片自身 layer 上绘制，绝不能因 masksToBounds 被圆角背景一起裁掉。
        layer?.cornerRadius = 14
        layer?.borderWidth = 0.5
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 11
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // popover 材质之上只叠语义化动态色：浅色拉开层级，深色以细微色差和描边为主。
            layer?.backgroundColor = (dark
                ? NSColor.labelColor.withAlphaComponent(0.055)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.82)).cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(dark ? 0.14 : 0.09).cgColor
            layer?.shadowOpacity = dark ? 0.03 : 0.06
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class GLMPanelAction: NSButton {
    var prominent = false { didSet { needsDisplay = true } }
    var subtleBackground = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if prominent {
                color = NSColor(calibratedRed: 0.04, green: 0.32, blue: 0.22, alpha: hovered ? 0.8 : 1)
            } else if subtleBackground {
                color = NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.38, alpha: hovered ? 0.28 : 0.18)
            } else {
                color = NSColor.labelColor.withAlphaComponent(hovered ? 0.10 : 0)
            }
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

// 峰谷卡状态胶囊：非高峰绿 / 高峰低饱和暖色，浅底深字（色值与 GLMRemainingColor 同源，共用其动态色解码）
enum GLMPeakTint {
    static var accent: NSColor { GLMRemainingColor.dynamic(0x96CDA7, 0x3E8660) }   // 主题绿：折扣数字、非高峰胶囊
    static var warm: NSColor { GLMRemainingColor.dynamic(0xE5A37D, 0xB46539) }     // 低饱和暖色：高峰胶囊
}

// 只读胶囊，不接收鼠标事件；底色与文字色在 updateLayer 内按当前外观解析，明暗切换即时生效
final class GLMPeakBadge: NSView {
    private let textField: NSTextField
    let isPeak: Bool

    init(isPeak: Bool, text: String) {
        self.isPeak = isPeak
        textField = NSTextField(labelWithString: text)
        textField.font = .systemFont(ofSize: 10, weight: .semibold)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8.5
        layer?.masksToBounds = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2.5),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        setAccessibilityLabel(isPeak ? "当前高峰，积分全价" : "当前非高峰，积分 5 折")
    }

    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let tint = isPeak ? GLMPeakTint.warm : GLMPeakTint.accent
            layer?.backgroundColor = tint.withAlphaComponent(dark ? 0.16 : 0.13).cgColor
            textField.textColor = tint
        }
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class GLMQuotaBar: NSView {
    private static let barHeight: CGFloat = 6
    let remaining: Double?
    init(_ remaining: Double?) { self.remaining = remaining; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false; heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let radius = Self.barHeight / 2
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        if let remaining = remaining {
            GLMRemainingColor.color(remaining).setFill()
            let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(max(0, min(1, remaining))), height: bounds.height)
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

// 浅底圆角小底座：头部套餐 badge 与两项比较条共用（跟随明暗外观重画）
final class GLMPillBackground: NSView {
    var radius: CGFloat = 5
    var backgroundAlpha: CGFloat = 0.10
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // wantsLayer 必须自建：updateLayer 只在 layer-backed 时被调用，
        // cornerRadius 不设会退化成直角矩形（badge 参考图为圆角 pill）
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = radius   // radius 运行时可改（比较条 7 / badge 5）
            layer?.masksToBounds = true
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(backgroundAlpha).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

// MARK: - 每日用量柱状图（近 30 天，含今日部分累计）
//
// 数据只来自慢项刷新缓存（GLMDayBucket）：悬停/点击/键盘选择全部读内存，
// 不联网、不重算历史、无独立定时器。命中区域覆盖整天宽度（缺失/零值日也能读取）；
// 鼠标离开保留最后选中值；左右方向键切换日期。

final class GLMDailyChartCanvas: NSView {
    private var buckets: [GLMDayBucket] = []
    private(set) var selectedIndex = 0
    /// 选中变化回调（含键盘/鼠标）；上层仅记录状态用于面板重建，不触发刷新
    var onSelect: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill() }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { noteFocusRingMaskChanged() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { noteFocusRingMaskChanged() }
        return accepted
    }

    /// 当前全部日桶（只读暴露给区块视图与离线测试）
    var dayBuckets: [GLMDayBucket] { buckets }

    func configure(buckets: [GLMDayBucket], initialIndex: Int) {
        self.buckets = buckets
        selectedIndex = clamped(initialIndex)
        needsDisplay = true
        updateAccessibilityValue()
    }

    private func clamped(_ index: Int) -> Int {
        guard !buckets.isEmpty else { return 0 }
        return max(0, min(buckets.count - 1, index))
    }

    private var columnWidth: CGFloat {
        bounds.width / CGFloat(max(1, buckets.count))
    }

    private func dayIndex(atX x: CGFloat) -> Int {
        clamped(Int(x / max(1, columnWidth)))
    }

    private func select(_ index: Int) {
        let next = clamped(index)
        guard next != selectedIndex else { return }
        selectedIndex = next
        needsDisplay = true
        updateAccessibilityValue()
        onSelect?(next)
    }

    private var accent: NSColor { NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.38, alpha: 1) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        guard !buckets.isEmpty else { return }
        let maxTokens = buckets.compactMap { $0.tokens }.max() ?? 0
        let chartHeight = bounds.height - 3
        let width = min(6, columnWidth)
        let inset = (columnWidth - width) / 2
        for (index, bucket) in buckets.enumerated() {
            guard let tokens = bucket.tokens else { continue }   // 缺失日 = 缺口，不画、不当 0
            let x = CGFloat(index) * columnWidth + inset
            accent.withAlphaComponent(index == selectedIndex ? 1 : 0.4).setFill()
            if tokens == 0 {
                NSRect(x: x, y: 1, width: width, height: 2).fill()   // 有记录的零日 = 基线短柱
            } else {
                let height = maxTokens > 0 ? max(3, chartHeight * CGFloat(tokens / maxTokens)) : 3
                NSRect(x: x, y: 1, width: width, height: min(chartHeight, height)).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    // 面板每 10s 重建、Popover 关开切换：不依赖 AppKit 时机，入窗/布局时主动重挂
    // （.inVisibleRect 让命中区跟随可见矩形，滚动后无需重建）
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTrackingArea()
    }

    override func layout() {
        super.layout()
        installTrackingArea()
    }

    private func installTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old); trackingArea = nil }
        guard window != nil else { return }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let localX = convert(event.locationInWindow, from: nil).x
        if ProcessInfo.processInfo.environment["GLM_DAILY_DEBUG"] != nil {
            NSLog("GLM_DAILY_DEBUG mouseMoved localX=\(localX) idx=\(dayIndex(atX: localX))")
        }
        select(dayIndex(atX: localX))
    }

    override func mouseDown(with event: NSEvent) {
        let localX = convert(event.locationInWindow, from: nil).x
        if ProcessInfo.processInfo.environment["GLM_DAILY_DEBUG"] != nil {
            NSLog("GLM_DAILY_DEBUG mouseDown localX=\(localX) idx=\(dayIndex(atX: localX))")
        }
        select(dayIndex(atX: localX))
        window?.makeFirstResponder(self)   // 点击后即可用方向键继续切换
    }

    // 鼠标离开图表：保留最后选中值，不跳回末日
    override func mouseExited(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: select(selectedIndex - 1)   // ←
        case 124: select(selectedIndex + 1)   // →
        default: super.keyDown(with: event)
        }
    }

    private func updateAccessibilityValue() {
        guard let bucket = buckets.indices.contains(selectedIndex) ? buckets[selectedIndex] : nil else {
            setAccessibilityValue(""); return
        }
        let tokens = bucket.tokens.map { "\(Fmt.tokens($0)) tokens" } ?? "数据不足"
        setAccessibilityValue("\(GLMDailyUsageSectionView.dayText(for: bucket.day)) \(tokens)")
    }
}

// 两项比较：单行浅底圆角条 + 中间竖分隔线，两半各「标签+数值」靠近并整体居中，
// 高约 30pt；数值按变化方向着色，缺数文案留在对应半区，不串组。
final class GLMComparisonStrip: NSView {
    init(pairs: [(label: String, outcome: GLMUsageComparison.Outcome)]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        let strip = GLMPillBackground()
        strip.radius = 7
        strip.backgroundAlpha = 0.055
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([strip.topAnchor.constraint(equalTo: topAnchor), strip.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     strip.leadingAnchor.constraint(equalTo: leadingAnchor), strip.trailingAnchor.constraint(equalTo: trailingAnchor)])
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     stack.heightAnchor.constraint(equalToConstant: 30),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                                     stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)])
        for (index, pair) in pairs.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 16).isActive = true
            }
            let half = NSView()
            half.translatesAutoresizingMaskIntoConstraints = false
            half.toolTip = index == 0 ? "最新完整日与前一日比较" : "最近 7 个完整日与此前 7 个完整日比较"
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            row.translatesAutoresizingMaskIntoConstraints = false
            let caption = NSTextField(wrappingLabelWithString: pair.label)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .secondaryLabelColor
            caption.lineBreakMode = .byTruncatingTail
            caption.maximumNumberOfLines = 1
            let value = NSTextField(wrappingLabelWithString: pair.outcome.text)
            value.font = .systemFont(ofSize: 11, weight: .semibold)
            switch pair.outcome.direction {
            case .increase:
                value.textColor = NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return dark ? NSColor(srgbRed: 0.44, green: 0.78, blue: 0.61, alpha: 1)
                                : NSColor(srgbRed: 0.13, green: 0.45, blue: 0.31, alpha: 1)
                }
            case .decrease:
                value.textColor = NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return dark ? NSColor(srgbRed: 0.91, green: 0.64, blue: 0.37, alpha: 1)
                                : NSColor(srgbRed: 0.64, green: 0.32, blue: 0.08, alpha: 1)
                }
            case .neutral:
                value.textColor = .secondaryLabelColor
            }
            value.lineBreakMode = .byTruncatingTail
            value.maximumNumberOfLines = 1
            row.addArrangedSubview(caption)
            row.addArrangedSubview(value)
            half.addSubview(row)
            NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: half.centerXAnchor),
                                         row.centerYAnchor.constraint(equalTo: half.centerYAnchor)])
            stack.addArrangedSubview(half)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// 「每日用量」整块：标题行 + 选中行 + 柱图 + 刻度 + 比较条。
// buckets=nil（未过真实接口 Gate 或无数据）显示明确空态：暂不可用 + 两项数据不足，
// 不画假柱、不补零、不写开发说明。
final class GLMDailyUsageSectionView: NSView {
    static let dateLabelIdentifier = NSUserInterfaceItemIdentifier("GLMDailyDateLabel")
    static let valueLabelIdentifier = NSUserInterfaceItemIdentifier("GLMDailyValueLabel")

    /// 选中日文案：今日柱为未走完的部分累计，日期加「（今日未结束）」后缀
    /// （CodexUsage 简析图同款口径）；跨午夜后选中的昨日自动不再带后缀。
    static func dayText(for day: Date, now: Date = Date()) -> String {
        let text = Fmt.monthDay(day)
        return day == Calendar.current.startOfDay(for: now) ? text + "（今日未结束）" : text
    }

    private let dateLabel = NSTextField(wrappingLabelWithString: "")
    private let valueLabel = NSTextField(wrappingLabelWithString: "")
    private let canvas = GLMDailyChartCanvas()

    /// 柱图（供面板把每日图接进 key view loop，Tab/FKA 可达）
    var chartCanvas: GLMDailyChartCanvas { canvas }

    init(buckets: [GLMDayBucket]?, selectedIndex: Int?, expanded: Bool,
         toggleTarget: AnyObject?, toggleAction: Selector, pendingNote: Bool = false, onSelect: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = GLMPanelStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor)])

        // 标题行：折叠按钮与用量情况/MCP 同款（chevron + 整行可点，PRD §6.4）
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.38, alpha: 1)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let title = NSTextField(wrappingLabelWithString: "每日用量")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let chevron = NSImageView(image: NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil) ?? NSImage())
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        chevron.widthAnchor.constraint(equalToConstant: 24).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 22).isActive = true
        // 旧值保留期间的简短提示（PRD §9「必要时显示简短待更新」；非技术脚注）
        if pendingNote {
            let pending = NSTextField(wrappingLabelWithString: "待更新")
            pending.font = .systemFont(ofSize: 10)
            pending.textColor = .secondaryLabelColor
            pending.lineBreakMode = .byTruncatingTail
            pending.maximumNumberOfLines = 1
            pending.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            header.addArrangedSubview(pending)
        }
        header.addArrangedSubview(icon)
        header.addArrangedSubview(title)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(chevron)
        // 整行可点折叠（与 section() 的板块标题同款）；状态在 AppDelegate，点击走 rebuildMenu
        header.translatesAutoresizingMaskIntoConstraints = false
        let toggle = GLMPanelAction(title: "", target: toggleTarget, action: toggleAction)
        toggle.isBordered = false
        toggle.wantsLayer = true
        toggle.layer?.cornerRadius = 6
        let actionTitle = (expanded ? "收起" : "展开") + "每日用量"
        toggle.setAccessibilityLabel(actionTitle)
        toggle.toolTip = actionTitle
        toggle.addSubview(header)
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo: toggle.leadingAnchor),
                                     header.trailingAnchor.constraint(equalTo: toggle.trailingAnchor),
                                     header.centerYAnchor.constraint(equalTo: toggle.centerYAnchor)])
        toggle.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.addArrangedSubview(toggle)
        toggle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 折叠：仅保留标题行（待更新提示仍在），日期/柱图/刻度/比较条全部不入层级
        guard expanded else { return }

        // 选中行：所选日期 + Token 值；悬停立即切换，缺数据时显示「暂不可用」
        dateLabel.identifier = Self.dateLabelIdentifier
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.maximumNumberOfLines = 1
        valueLabel.identifier = Self.valueLabelIdentifier
        valueLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.maximumNumberOfLines = 1
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let selectionRow = NSStackView()
        selectionRow.orientation = .horizontal
        selectionRow.alignment = .centerY
        selectionRow.spacing = 6
        selectionRow.translatesAutoresizingMaskIntoConstraints = false
        selectionRow.addArrangedSubview(dateLabel)
        let midSpacer = NSView()
        midSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        midSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        selectionRow.addArrangedSubview(midSpacer)
        selectionRow.addArrangedSubview(valueLabel)
        stack.addArrangedSubview(selectionRow)
        selectionRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        guard let buckets = buckets, !buckets.isEmpty else {
            dateLabel.stringValue = "暂不可用"
            valueLabel.stringValue = ""
            canvas.isHidden = true
            let strip = GLMComparisonStrip(pairs: comparisonPairs(for: nil))
            stack.addArrangedSubview(strip)
            strip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }

        // 默认选中最新一日（含今日窗口下即今日，未走完的部分累计），即使数据缺失也展示该日状态；
        // 面板打开期间重建保留选择。
        let defaultIndex = selectedIndex ?? buckets.count - 1
        canvas.configure(buckets: buckets, initialIndex: defaultIndex)
        canvas.focusRingType = .default
        canvas.onSelect = { [weak self] index in
            self?.syncSelection(index)
            onSelect(index)
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.setAccessibilityLabel("近 30 天每日用量柱状图，可用左右方向键选择日期")
        // 有意不设 setAccessibilityElement(true)：实测会让 Full Keyboard Access 的 Tab 遍历
        // （走 a11y 树选焦点候选）跳过本视图，破坏 --preview-daily-test 的 Tab 可达硬门槛；
        // VoiceOver 用户仍可经日期/数值两个文本标签获取选中日信息
        canvas.heightAnchor.constraint(equalToConstant: 62).isActive = true
        stack.addArrangedSubview(canvas)
        canvas.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // 日期刻度：首/中/末（与柱图两端对齐）
        let ticks = NSStackView()
        ticks.orientation = .horizontal
        ticks.distribution = .fillEqually
        ticks.spacing = 0
        ticks.translatesAutoresizingMaskIntoConstraints = false
        let tickDates = [buckets.first?.day, buckets[buckets.count / 2].day, buckets.last?.day].compactMap { $0 }
        let alignments: [NSTextAlignment] = [.left, .center, .right]
        for (tickDate, alignment) in zip(tickDates, alignments) {
            let tick = NSTextField(wrappingLabelWithString: Fmt.dayTick(tickDate))
            tick.font = .systemFont(ofSize: 10)
            tick.textColor = .secondaryLabelColor
            tick.alignment = alignment
            tick.lineBreakMode = .byTruncatingTail
            tick.maximumNumberOfLines = 1
            ticks.addArrangedSubview(tick)
        }
        stack.addArrangedSubview(ticks)
        ticks.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let strip = GLMComparisonStrip(pairs: comparisonPairs(for: buckets))
        stack.addArrangedSubview(strip)
        strip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(6, after: ticks)
        syncSelection(canvas.selectedIndex)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func syncSelection(_ index: Int) {
        // 由 canvas 在选中变化时调用（含键盘/悬停）；直接改本块标签，不重建面板、不发请求
        let buckets = canvas.dayBuckets
        guard buckets.indices.contains(index) else { return }
        let bucket = buckets[index]
        dateLabel.stringValue = Self.dayText(for: bucket.day)
        if let tokens = bucket.tokens {
            valueLabel.stringValue = "\(Fmt.tokens(tokens)) Token"
            valueLabel.textColor = .labelColor
        } else {
            valueLabel.stringValue = "数据不足"
            valueLabel.textColor = .secondaryLabelColor
        }
    }

    private func comparisonPairs(for buckets: [GLMDayBucket]?) -> [(label: String, outcome: GLMUsageComparison.Outcome)] {
        let outcomes = GLMUsageComparison.dailyPair(buckets: buckets ?? [])
        return [("日环比", outcomes.dayOnDay), ("7日环比", outcomes.weekOnWeek)]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    // 状态栏底色随全屏进出/深浅模式翻转时，KVO 触发按新外观重画（否则浅色栏上残留白色余量文字）；
    // setImage 也会再次触发 KVO 通知，用明暗主题快照去重防止 renderBar↔KVO 反馈循环
    private var statusItemAppearanceObs: NSKeyValueObservation?
    private var barThemeDark: Bool?
    // 菜单栏可因深色壁纸、双屏或全屏而与 App 外观合法地不同，不能用 App 外观覆盖菜单栏。
    // 每 5s 对账，不一致时仅重建不缓存的动态颜色图片，不切换 isVisible、不钉死绘制外观。
    private var appearancePollTimer: Timer?
    // 重置卡使用：进行中防重入；结果未知（网络/5xx）时按类型保留同一幂等 key，重试不重复扣卡
    private var resetUseInFlight = false
    private var pendingResetKeys: [String: GLMPendingResetStore.Entry] = [:]
    // 自诊断与幂等 key 持久化目录（与 status.json 同目录；key 文件不含任何凭据）
    private static let supportDir = NSHomeDirectory() + "/Library/Application Support/GlmUsage"

    // 幂等 key 变更即落盘：结果未知后即使进程重启，重试仍复用同一 key
    private func persistPendingResetKeys() {
        GLMPendingResetStore.save(pendingResetKeys, dir: Self.supportDir)
    }
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
    private var dailyExpanded = true
    private var updateMessage: String?
    private var updateMessageDismissal: DispatchWorkItem?
    private var updateProgressObserver: NSObjectProtocol?
    private var updateProgressWasActive = false
    private let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--preview-popover") || CommandLine.arguments.contains("--preview-popover-test") || CommandLine.arguments.contains("--preview-daily-test") || Bundle.main.bundleIdentifier == "com.local.glm-usage.preview" || (Bundle.main.object(forInfoDictionaryKey: "GLMPreviewPopover") as? Bool == true)
    private let previewPopover = CommandLine.arguments.contains("--preview-popover") || CommandLine.arguments.contains("--preview-popover-test") || CommandLine.arguments.contains("--preview-daily-test") || (Bundle.main.object(forInfoDictionaryKey: "GLMPreviewPopover") as? Bool == true)
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
    // token 统计每 N 个刷新周期拉一次（主循环 10s × 30 = 5 分钟；额度窗口每轮都刷）
    private let tokenEveryCycles = 30
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
    private var dailyLastOK: Date?
    // 每日图选中日（面板每 10s 重建后沿用；nil = 用默认最新有记录日，通常为今日）
    private var dailySelectedIndex: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 恢复上次「结果未知」遗留的幂等 key：跨重启防重复扣卡
        pendingResetKeys = GLMPendingResetStore.load(dir: Self.supportDir)
        NSLog("[GlmUsage] launched, creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        // 仅离线 GUI 回归进程：改用 applicationDefined，避免测试期间的真实鼠标点击
        // （用户正在用机）把 transient Popover 关掉造成几何断言误报；生产与普通预览不变
        if CommandLine.arguments.contains("--preview-popover-test") || CommandLine.arguments.contains("--preview-daily-test") {
            popover.behavior = .applicationDefined
        }
        if preview {
            if CommandLine.arguments.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            // 几何测试需保留展开模型所需的高度余量；每日图交互由独立测试覆盖。
            if CommandLine.arguments.contains("--preview-popover-test") { dailyExpanded = false }
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
            if CommandLine.arguments.contains("--preview-auto-open") || CommandLine.arguments.contains("--preview-popover-test") || CommandLine.arguments.contains("--preview-daily-test") || (Bundle.main.object(forInfoDictionaryKey: "GLMPreviewPopover") as? Bool == true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else { return }
                    self.togglePanel()
                    if CommandLine.arguments.contains("--preview-popover-test") {
                        // 等初始 Popover 布局稳定后再量高，避免把打开时的尺寸校正算成展开明细。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.testPreviewPopover() }
                    }
                    if CommandLine.arguments.contains("--preview-daily-test") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.testDailyInteraction() }
                    }
                }
            }
            if let i = CommandLine.arguments.firstIndex(of: "--preview-screenshot"), CommandLine.arguments.count > i + 1 {
                let shotPath = CommandLine.arguments[i + 1]
                fputs("GLM preview screenshot: scheduled\n", stderr)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    fputs("GLM preview screenshot: fired\n", stderr)
                    guard let view = self?.previewWindow?.contentView else {
                        fputs("GLM preview screenshot: FAIL no preview window\n", stderr); exit(1)
                    }
                    view.layoutSubtreeIfNeeded()
                    if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds), image.pixelsWide > 0 {
                        view.cacheDisplay(in: view.bounds, to: image)
                        if let data = image.representation(using: .png, properties: [:]), !data.isEmpty {
                            do { try data.write(to: URL(fileURLWithPath: shotPath), options: .atomic); print("GLM preview screenshot: wrote \(shotPath)"); exit(0) }
                            catch { fputs("GLM preview screenshot: FAIL write \(error)\n", stderr); exit(1) }
                        }
                    }
                    fputs("GLM preview screenshot: FAIL render bounds=\(view.bounds)\n", stderr); exit(1)
                }
            }
            return
        }
        rebuildMenu()
        renderBar()
        // 面板内更新进度：状态翻转时重建面板（按钮↔进度行），进度百分比由进度行自刷；
        // 菜单栏 toolTip 同步更新状态，面板关闭时更新也在后台继续
        updateProgressObserver = NotificationCenter.default.addObserver(
            forName: UpdateProgressController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateProgressDidChange() }
        // 状态栏底色变化（全屏进出/深浅模式切换）时立即按新外观重画两行余量，不再等下一次数据刷新；
        // 仅在明暗主题实际变化时执行（setImage 会再次触发 KVO，不去重会形成重画循环）
        attachBarAppearanceObserver()
        appearancePollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reconcileBarAppearance()
        }
        appearancePollTimer?.tolerance = 1
        refresh(tokens: true)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cycle += 1
            self.refresh(tokens: GLMRefreshSchedule.slowItemsDue(cycle: self.cycle,
                every: self.tokenEveryCycles, manual: false))
        }
        // 显式容差让系统合并定时器唤醒（Apple 节能指南建议 ≥间隔 10%；10s → 3s）
        timer?.tolerance = 3
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
        performQuotaRefresh()
    }

    private func performQuotaRefresh() {
        lastAttemptAt = Date()
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
        usage.fiveHour = five.value; fiveHourLastOK = five.lastOK; usage.fiveHourError = five.error
        if fresh.fiveHour != nil { usage.fiveHourWarning = fresh.fiveHourWarning }
        let week = GLMFreshness.apply(fresh: fresh.week, failure: fresh.weekError,
            old: usage.week, oldLastOK: weekLastOK, oldError: usage.weekError, now: now)
        usage.week = week.value; weekLastOK = week.lastOK; usage.weekError = week.error
        if fresh.week != nil { usage.weekWarning = fresh.weekWarning }
        if fresh.fiveHour != nil || fresh.week != nil { usage.quotaError = nil }
        else if let error = fresh.quotaError { usage.quotaError = error }
        usage.level = fresh.level ?? usage.level
        updateUI()
        if quotaGate.finish() { performQuotaRefresh() }
    }

    private func performRefresh(tokens: Bool) {
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
                failed.dailyTokensError = error
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
                Fetcher.fetchModelUsage(apiKey: key, from: w.from, to: w.to) { r, daily, dailyFailed, err in
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
                        // 每日桶只来自 30 天窗（复用同一响应，不新增请求）。
                        // Gate 关闭 → 空态（非错误）；Gate 开但解析失败 → 标记失败保留旧值
                        // （界面给简短「待更新」，不显示技术细节）；请求失败 → 同样保留旧值。
                        if w.label == 2 {
                            current.dailyTokens = daily
                            if r == nil {
                                current.dailyTokensError = err ?? "no data"
                            } else if dailyFailed {
                                current.dailyTokensError = "每日数据解析失败"
                            } else {
                                current.dailyTokensError = nil
                            }
                        }
                    }
                    wg.leave()
                }
            }
            // 头部可选邮箱：读现有凭据库（本地文件、无网络），不可得 → nil → 整行隐藏。
            // 双保险：本方法在 preview 下不会被调用（启动即 return），此处再显式断开
            // 预览路径与凭据读取的关联，防止未来重构把凭据读取带进假数据预览。
            let accountEmail = preview ? nil : CredStore.loadAccountEmail()
            accumulator.update { current in
                current.accountEmail = accountEmail
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

            // 每日桶：失败保留旧值（不显示技术错误行）；结果未知时沿用上次图表
            let daily = GLMFreshness.apply(fresh: fresh.dailyTokens, failure: fresh.dailyTokensError,
                old: usage.dailyTokens, oldLastOK: dailyLastOK, oldError: usage.dailyTokensError, now: now)
            usage.dailyTokens = daily.value; dailyLastOK = daily.lastOK; usage.dailyTokensError = daily.error
            // 头部可选邮箱（本地凭据读取结果，无网络语义；nil → 隐藏整行）
            usage.accountEmail = fresh.accountEmail

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
    // 每日桶：与慢项同节奏刷新；超过 30 分钟未成功视为过期（仅用于简短「待更新」提示）
    private var dailyStale: Bool {
        isStale(dailyLastOK, hasData: usage.dailyTokens != nil, after: tokensStaleAfter)
    }

    private func attachBarAppearanceObserver() {
        statusItemAppearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.renderBarIfThemeChanged() }
        }
    }

    private func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 外观不一致既可能是按钮粘滞，也可能是深色壁纸或双屏的正常状态。
    /// 因此只重建不缓存的动态颜色图片，让实际菜单栏绘制上下文决定颜色。
    private func reconcileBarAppearance() {
        guard let button = statusItem?.button else { return }
        let appDark = isDark(NSApp.effectiveAppearance)
        let buttonDark = isDark(button.effectiveAppearance)
        if buttonDark != appDark {
            renderBar()
        } else {
            renderBarIfThemeChanged()
        }
    }

    /// 仅当按钮解析出的明暗主题与上次渲染快照不同时才重画（防止 setImage↔KVO 循环）。
    private func renderBarIfThemeChanged() {
        guard let button = statusItem?.button else { return }
        let dark = isDark(button.effectiveAppearance)
        guard dark != barThemeDark else { return }
        renderBar()
    }

    // 菜单栏显示：5H / 7D 两行堆叠（显示余额）；峰谷/过期 emoji 作为 badge 向左突出，正文列保持对齐
    // （⚠️ 放在峰谷 emoji 之后，不影响 Peak 判定；token 组无菜单栏行，仅在下拉菜单标注）
    /// 进度行自己刷新文本与百分比；这里只在「进行中」状态翻转时重建面板（按钮↔进度行），
    /// 并刷新菜单栏 toolTip。失败时面板若开着，额外给一条可重试的提示。
    private func updateProgressDidChange() {
        let active = UpdateProgressController.shared.isActive
        if active != updateProgressWasActive {
            updateProgressWasActive = active
            rebuildMenu()
            if !active, UpdateProgressController.shared.phase == .failed {
                setUpdateMessage("更新失败，详见弹窗提示", dismissAfter: 8)
            }
        }
        renderBar()
    }

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
        barThemeDark = isDark(appearance)
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "GLM 余额 · 5H最后成功 \(Fmt.lastOK(fiveHourLastOK))"
            + " · 7D最后成功 \(Fmt.lastOK(weekLastOK))"
            + " · 今日Token最后成功 \(Fmt.lastOK(tokensTodayLastOK))"
            + " · 7天Token最后成功 \(Fmt.lastOK(tokens7dLastOK))"
            + " · 30天Token最后成功 \(Fmt.lastOK(tokens30dLastOK))"
            + " · MCP最后成功 \(Fmt.lastOK(toolsLastOK))"
        if UpdateProgressController.shared.isActive {
            statusItem.button?.toolTip = (statusItem.button?.toolTip ?? "")
                + " · \(UpdateProgressController.shared.statusLine)"
        }
        writeStatus(line1: (marks1.isEmpty ? "" : marks1.joined() + " ") + "\(line1.label) \(line1.value)",
                    line2: (marks2.isEmpty ? "" : marks2.joined() + " ") + "\(line2.label) \(line2.value)",
                    peakLine: peak.line)
    }

    // 自诊断：把渲染内容写到本地，便于排查
    private func writeStatus(line1: String, line2: String, peakLine: String) {
        let dir = Self.supportDir
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
            "warnings": ["fiveHour": usage.fiveHourWarning ?? "", "week": usage.weekWarning ?? ""],
            "fiveHourRemaining": usage.fiveHour?.usedRemainingRatio ?? -1,
            "weekRemaining": usage.week?.usedRemainingRatio ?? -1,
            "level": usage.level ?? "",
            "quotaError": usage.quotaError ?? "",
            "tokensError": usage.tokensError ?? "",
            "resetCards": cardsStatus,
            "pendingResets": pendingResetKeys.keys.sorted(),
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

        func limitLine(_ e: LimitEntry?, label: String, lastOK: Date?, stale: Bool, error: String?, warning: String?) -> String {
            var s = "\(label)："
            if let e = e {
                s += "剩余 \(Fmt.pctLong(e.usedRemainingRatio))"
                if e.limit > 0 { s += "（剩 \(Fmt.credits(e.remaining)) / \(Fmt.credits(e.limit)) credits）" }
                if e.reset != nil { s += "（\(Fmt.weekDayTime(e.reset)) 重置）" }
            } else { s += "暂无数据" }
            if stale { s += " · ⚠️ 数据已过期" }
            if let error = error { s += " · 刷新失败：\(error)" }
            if let warning = warning { s += " · 部分数据异常：\(warning)" }
            if lastOK != nil, stale || error != nil { s += " · 最后成功 \(Fmt.lastOK(lastOK))" }
            return s
        }
        menu.addItem(info(limitLine(usage.fiveHour, label: "5 小时窗口", lastOK: fiveHourLastOK,
                                  stale: fiveHourStale, error: usage.fiveHourError, warning: usage.fiveHourWarning)))
        menu.addItem(info(limitLine(usage.week, label: "7 天额度", lastOK: weekLastOK,
                                  stale: weekStale, error: usage.weekError, warning: usage.weekWarning)))

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
                // 使用入口（写操作）：仅在确有可用卡时出现，点击后弹确认框
                func useItem(_ type: ResetCardType, count: Int) {
                    let item = NSMenuItem(title: resetUseInFlight
                        ? "\(type.displayName)使用中…"
                        : "使用\(type.displayName)（剩 \(count) 张）…",
                        action: #selector(onUseReset(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = type.rawValue
                    item.isEnabled = !resetUseInFlight
                    menu.addItem(item)
                }
                if !f5.isEmpty { useItem(.fiveHour, count: f5.count) }
                if !wk.isEmpty { useItem(.week, count: wk.count) }
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

        // 用量情况（与面板 section 同名；此 NSMenu 为 fallback 死代码，仅防漂移）
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
        dailySelectedIndex = nil
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
            // 合成事件（离线回归）可能没有 event.window，按 windowNumber 解析；
            // 真实用户事件语义不变：点击面板/状态栏窗口内不关，窗外关闭
            let eventWindow = event.window ?? NSApp.window(withWindowNumber: event.windowNumber)
            if eventWindow === self.panelController.view.window || eventWindow === self.statusItem.button?.window { return event }
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

    // 面板标题行的小重置图标：一类卡可用直接确认；两类都有先选类型；无卡提示
    @objc private func onResetCardIcon(_ sender: NSButton) {
        guard !resetUseInFlight else { return }
        let f5 = GLMFreshness.availableCards(usage.resetCards?.fiveHour ?? [], now: Date())
        let wk = GLMFreshness.availableCards(usage.resetCards?.week ?? [], now: Date())
        switch (f5.isEmpty, wk.isEmpty) {
        case (true, true):
            setUpdateMessage("重置卡：暂无可用", dismissAfter: 4)
        case (false, true):
            beginUseReset(.fiveHour)
        case (true, false):
            beginUseReset(.week)
        case (false, false):
            let picker = NSMenu()
            let five = NSMenuItem(title: "使用 5 小时重置卡（剩 \(f5.count) 张）",
                                  action: #selector(onUseReset(_:)), keyEquivalent: "")
            five.target = self; five.representedObject = ResetCardType.fiveHour.rawValue
            let week = NSMenuItem(title: "使用周重置卡（剩 \(wk.count) 张）",
                                  action: #selector(onUseReset(_:)), keyEquivalent: "")
            week.target = self; week.representedObject = ResetCardType.week.rawValue
            picker.addItem(five); picker.addItem(week)
            picker.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
        }
    }

    // 重置卡使用入口（菜单项 representedObject → 类型）
    @objc private func onUseReset(_ sender: Any) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let type = ResetCardType(rawValue: raw) else { return }
        beginUseReset(type)
    }

    /// 使用一张重置卡：二次确认 → 写接口 → 刷新对账；绝不自动触发
    private func beginUseReset(_ type: ResetCardType) {
        guard !resetUseInFlight else { return }
        if preview { setUpdateMessage("预览模式：不执行真实重置卡操作", dismissAfter: 3); return }
        guard let (jwt, maas) = CredStore.loadResetTokens() else {
            setUpdateMessage("使用\(type.displayName)失败：未找到 ZCode 登录凭证", dismissAfter: 5); return
        }
        let available = GLMFreshness.availableCards(
            type == .fiveHour ? (usage.resetCards?.fiveHour ?? []) : (usage.resetCards?.week ?? []),
            now: Date())
        guard let nearest = available.min() else {
            setUpdateMessage("\(type.displayName)：暂无可用", dismissAfter: 4); return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "使用一张\(type.displayName)？"
        alert.informativeText = "剩余 \(available.count) 张，最近一张 \(Fmt.expires(nearest)) 到期。\n使用后立即重置对应额度窗口，操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "使用")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        resetUseInFlight = true
        // 上次结果未知则复用同一幂等 key（服务器按 key 幂等，重试不会重复扣卡）
        let key: String
        if let existing = pendingResetKeys[type.rawValue] {
            key = existing.key
        } else {
            let fresh = UUID().uuidString
            pendingResetKeys[type.rawValue] = .init(key: fresh, createdAt: Date())
            persistPendingResetKeys()
            key = fresh
        }
        rebuildMenu()
        Fetcher.useResetCard(jwt: jwt, maas: maas, resetType: type, idempotencyKey: key) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.resetUseInFlight = false
                if outcome.used {
                    self.pendingResetKeys.removeValue(forKey: type.rawValue)
                    self.persistPendingResetKeys()
                    self.setUpdateMessage("已使用\(type.displayName) ✓", dismissAfter: 3)
                } else {
                    if !outcome.retryable {
                        self.pendingResetKeys.removeValue(forKey: type.rawValue)
                        self.persistPendingResetKeys()
                    }
                    let suffix = outcome.retryable ? "（结果未知，已保留防重扣凭证，可安全重试）" : ""
                    self.setUpdateMessage("使用\(type.displayName)失败：\(outcome.error ?? "未知错误")\(suffix)", dismissAfter: 6)
                }
                // 成功/失败都刷新额度与卡数：成功立刻反映新窗口，结果未知用于对账
                self.refresh(tokens: false, manual: true)
                // 服务端从确认用卡到额度接口反映新窗口可能有秒级延迟：成功后 3 秒补刷一次，避免用量条短暂停在旧值
                if outcome.used {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.refresh(tokens: false)
                    }
                }
            }
        }
    }
    @objc private func toggleModels(_ sender: NSButton) {
        let index = sender.tag
        guard (0..<3).contains(index) else { return }
        if expandedModelWindows.contains(index) { expandedModelWindows.remove(index) }
        else { expandedModelWindows.insert(index) }
        rebuildMenu()
    }
    @objc private func toggleMCP() { mcpExpanded.toggle(); rebuildMenu() }
    @objc private func toggleDaily() { dailyExpanded.toggle(); rebuildMenu() }
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
        usage.subscription = SubscriptionInfo(name: "GLM Coding Pro", expireDate: now.addingTimeInterval(31_536_000))
        usage.fiveHour = LimitEntry(label: "5 小时窗口", isFiveHour: true, limit: 2000, used: 640, remaining: 1360, usedRatio: 0.32, reset: now.addingTimeInterval(7200))
        usage.week = LimitEntry(label: "7 天额度", isFiveHour: false, limit: 10000, used: 2700, remaining: 7300, usedRatio: 0.27, reset: now.addingTimeInterval(259200))
        let stats = ModelUsage(totalTokens: 1840000, totalCalls: 142, byModel: [("glm-4.7", 1200000), ("glm-4.5-air", 640000)])
        usage.tokensToday = stats; usage.tokens7d = stats; usage.tokens30d = stats
        usage.tools30d = ToolUsage(networkSearch: 36, webRead: 18)
        usage.resetCards = ResetCards(fiveHour: [now.addingTimeInterval(864000)], week: [now.addingTimeInterval(1728000)])
        fiveHourLastOK = now; weekLastOK = now; tokensTodayLastOK = now; tokens7dLastOK = now; tokens30dLastOK = now; toolsLastOK = now; fiveHourCardsLastOK = now; weekCardsLastOK = now
        dailyLastOK = now   // 预览每日桶视为新鲜，避免误显「待更新」
        subscriptionLastOK = now
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
            // 头部长套餐名：验证 badge 截断不挤压标题（280/336 截图矩阵用）
            usage.subscription = SubscriptionInfo(
                name: "GLM Coding Plan Max 年度订阅超长套餐名称示例用于截断验证",
                expireDate: now.addingTimeInterval(31_536_000))
            subscriptionLastOK = now
        }
        // 更新进度行预览：updating 为下载中 62%；updating-install 为安装重启阶段（含重启预告）
        if CommandLine.arguments.contains("--preview-updating-install") {
            UpdateProgressController.shared.simulateForPreview(phase: .installing, fraction: 100)
        } else if CommandLine.arguments.contains("--preview-updating") {
            UpdateProgressController.shared.simulateForPreview(phase: .downloading, fraction: 62)
        }
        // 每日用量预览：合成 30 个完整自然日桶（今日未走完不进图，与生产 frame 规则一致）。
        // 生产界面因真实接口 Gate 未确认恒为空态；预览仅展示目标体验，不代表接口已验证。
        usage.dailyTokens = CommandLine.arguments.contains("--preview-daily-unavailable")
            ? nil : previewDailyBuckets()
        // 头部邮箱预览（假数据；生产邮箱只来自现有凭据库且不可得即隐藏）
        if CommandLine.arguments.contains("--preview-email") {
            usage.accountEmail = CommandLine.arguments.contains("--preview-email-long")
                ? "long-username.glm.account@example-mail.cn" : "preview@example.com"
        }
    }

    /// 合成每日桶（仅预览/离线测试）：确定性伪随机高度 + 固定零日/缺日位点，
    /// 窗口与生产一致（今日-29 ... 今日，含今日部分累计），
    /// 交互测试依赖位点稳定，改位点必须同步 --preview-daily-test 的断言
    private func previewDailyBuckets() -> [GLMDayBucket] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        var buckets: [GLMDayBucket] = []
        for index in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: index - 29, to: todayStart) else { continue }
            var tokens: Double? = 900_000 + Double((index * 137_917) % 1_400_000)
            if index == 10 || index == 24 { tokens = 0 }                       // 有记录的零日
            if index == 29 { tokens = 2_000_000 }                              // 今日（部分累计，较昨日当前项）
            if index == 28 { tokens = 1_000_000 }                              // 昨日（较昨日基准）
            if CommandLine.arguments.contains("--preview-daily-gaps"), index == 3 || index == 4 || index == 17 {
                tokens = nil                                                   // 缺失日（缺口）
            }
            if CommandLine.arguments.contains("--preview-daily-insufficient"), index < 25 {
                tokens = nil                                                   // 仅近 5 日有记录 → 较前 7 天数据不足
            }
            if CommandLine.arguments.contains("--preview-daily-basezero") {
                if index == 28 { tokens = 0 }                                  // 基期 0 → 「新增 N」
            }
            buckets.append(GLMDayBucket(day: day, tokens: tokens))
        }
        return buckets
    }

    private func buildPanel(_ menu: NSMenu) {
        let savedOffset = activeScroll?.contentView.bounds.origin ?? .zero
        let width: CGFloat = CommandLine.arguments.contains("--preview-narrow") ? 280 : 336
        let inner = width - 32
        let root = panelRoot
        for view in root.arrangedSubviews { root.removeArrangedSubview(view); view.removeFromSuperview() }
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        // 给卡片阴影留出绘制空间；scroll 只裁主容器边缘，不裁卡片自身阴影。
        root.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        func add(_ v: NSView) { root.addArrangedSubview(v); v.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        func addContent(_ v: NSView, to card: GLMPanelCard) {
            card.content.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: card.content.widthAnchor).isActive = true
        }
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
            let b = GLMPanelAction(title: title, target: self, action: action); b.isBordered = false; b.focusRingType = .default; b.wantsLayer = true; b.layer?.cornerRadius = 6; b.prominent = prominent
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
        // 更新进行中：原按钮位置换成进度行（重开面板也在此恢复）；空闲时才显示更新按钮
        if UpdateProgressController.shared.isActive { add(UpdateProgressRowView()) }
        else if UpdateChecker.shared.available && !preview { add(button("⬆ 新版本可用，点击更新", #selector(onUpdateApp), prominent: true)) }

        let quotaCard = GLMPanelCard()
        quotaCard.content.spacing = 6
        // 卡片标题行（CodexUsage 同款布局、自家绿色系）：图标+标题居左，「重置时间」列头居右
        let quotaHead = row()
        quotaHead.spacing = 8
        quotaHead.addArrangedSubview(symbol("stopwatch"))
        quotaHead.addArrangedSubview(label("用量进度", size: 13, bold: true))
        quotaHead.addArrangedSubview(spacer())
        let resetHeading = label("重置时间", size: 10, color: .secondaryLabelColor)
        resetHeading.alignment = .right
        quotaHead.addArrangedSubview(resetHeading)
        addContent(quotaHead, to: quotaCard)

        func quota(_ entry: LimitEntry?, _ name: String, _ error: String?, _ warning: String?, _ last: Date?, _ stale: Bool) {
            let group = GLMPanelStack()
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 5
            func addToGroup(_ view: NSView) {
                group.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            }

            // 周期、百分比、进度条与重置时间共用一行，避免为进度条额外占用一行高度。
            let heading = row()
            heading.spacing = 4
            let title = label(name, size: 11, bold: true)
            title.widthAnchor.constraint(equalToConstant: 36).isActive = true
            heading.addArrangedSubview(title)
            let ratio = entry?.usedRemainingRatio
            let pct = label(Fmt.pct(ratio), size: 12, bold: true, color: GLMRemainingColor.color(ratio))
            pct.widthAnchor.constraint(equalToConstant: 34).isActive = true
            heading.addArrangedSubview(pct)
            let bar = GLMQuotaBar(ratio)
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
            heading.addArrangedSubview(bar)
            let reset = label(entry?.reset.map { Fmt.weekDayTime($0) } ?? "时间未知", size: 10, bold: true)
            reset.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
            reset.alignment = .right
            reset.lineBreakMode = .byTruncatingTail
            reset.maximumNumberOfLines = 1
            reset.widthAnchor.constraint(equalToConstant: 110).isActive = true
            reset.setContentCompressionResistancePriority(.required, for: .horizontal)
            heading.addArrangedSubview(reset)
            addToGroup(heading)

            // 余量和所有异常文本独占卡片全宽，不参与右侧时间列的宽度竞争。
            if let e = entry { addToGroup(label("剩余 \(Fmt.credits(e.remaining)) / \(Fmt.credits(e.limit)) credits", color: .secondaryLabelColor)) }
            else { addToGroup(label("暂无数据", color: .secondaryLabelColor)) }
            if let e = error { addToGroup(label("刷新失败：\(e) · 最后成功 \(Fmt.lastOK(last))", color: .systemRed)) }
            if let warning = warning { addToGroup(label("部分数据异常：\(warning)", color: .systemOrange)) }
            if error == nil && stale { addToGroup(label("数据已过期 · 最后成功 \(Fmt.lastOK(last))", color: .systemOrange)) }
            addContent(group, to: quotaCard)
        }
        quota(usage.fiveHour, "5 小时", usage.fiveHourError, usage.fiveHourWarning, fiveHourLastOK, fiveHourStale)
        if let fiveHourGroup = quotaCard.content.arrangedSubviews.last {
            quotaCard.content.setCustomSpacing(10, after: fiveHourGroup)
        }
        quota(usage.week, "7 天", usage.weekError, usage.weekWarning, weekLastOK, weekStale)
        if usage.subscription != nil || usage.subscriptionError != nil || subscriptionStale {
            addContent(separator(), to: quotaCard)
        }
        if let sub = usage.subscription {
            let expiry = sub.expireDate.map { "套餐到期：\(Fmt.fullTime.string(from: $0))" } ?? "套餐到期：暂无数据"
            addContent(label(expiry, color: .secondaryLabelColor), to: quotaCard)
        }
        if let error = usage.subscriptionError { addContent(label("套餐刷新失败：\(error) · 最后成功 \(Fmt.lastOK(subscriptionLastOK))", color: .systemRed), to: quotaCard) }
        else if subscriptionStale { addContent(label("套餐数据已过期 · 最后成功 \(Fmt.lastOK(subscriptionLastOK))", color: .systemOrange), to: quotaCard) }
        add(quotaCard)
        // 峰谷卡＝极简状态条：标题+状态胶囊一行，折扣与下次切换一行；限时活动行沿用旧版追加在下方。
        // 视觉回归可用 --preview-peak 强制按高峰时刻渲染（下个工作日 14:00）
        let peakNow = CommandLine.arguments.contains("--preview-peak") ? Peak.nextPeakStart(Date()) : Date()
        let peakInfo = Peak.display(at: peakNow)
        let peakCard = GLMPanelCard()
        let peakTitle = row(); peakTitle.spacing = 8
        peakTitle.addArrangedSubview(symbol("clock"))
        peakTitle.addArrangedSubview(label("峰谷状态", size: 13, bold: true))
        peakTitle.addArrangedSubview(spacer())
        peakTitle.addArrangedSubview(GLMPeakBadge(isPeak: peakInfo.isPeak, text: peakInfo.badge))
        peakCard.content.addArrangedSubview(peakTitle); peakTitle.widthAnchor.constraint(equalTo: peakCard.content.widthAnchor).isActive = true
        peakCard.content.setCustomSpacing(5, after: peakTitle)
        // 折扣组基线对齐读作一个短语；右列右对齐，标签弱、时间强调但低于折扣
        let discountGroup = NSStackView(views: [
            label(peakInfo.discount, size: 18, bold: true, color: peakInfo.isPeak ? .labelColor : GLMPeakTint.accent),
            label("积分消耗", size: 10.5, color: .secondaryLabelColor)])
        discountGroup.orientation = .horizontal; discountGroup.alignment = .firstBaseline; discountGroup.spacing = 5
        let nextTime = label(peakInfo.nextTime, size: 12.5, bold: true)
        nextTime.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        nextTime.setContentCompressionResistancePriority(.required, for: .horizontal)
        let nextGroup = NSStackView(views: [label(peakInfo.nextLabel, size: 10, color: .secondaryLabelColor), nextTime])
        nextGroup.orientation = .vertical; nextGroup.alignment = .trailing; nextGroup.spacing = 1.5
        let peakInfoRow = row(); peakInfoRow.spacing = 4
        peakInfoRow.addArrangedSubview(discountGroup)
        peakInfoRow.addArrangedSubview(spacer())
        peakInfoRow.addArrangedSubview(nextGroup)
        addContent(peakInfoRow, to: peakCard)
        if let event = peakInfo.eventLine {
            let field = label(event, size: 11); peakCard.content.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: peakCard.content.widthAnchor).isActive = true
        }
        add(peakCard)
        let cards = GLMPanelCard(); let cardHead = row(); cardHead.spacing = 8; cardHead.addArrangedSubview(symbol("calendar")); cardHead.addArrangedSubview(label("重置卡", size: 13, bold: true))
        if let count = usage.resetCards?.availableCount(now: Date()), count > 0 {
            let countLabel = label("×\(count)", size: 12, bold: true, color: NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.38, alpha: 1))
            countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            countLabel.setAccessibilityLabel("\(count) 张可用重置卡")
            cardHead.addArrangedSubview(countLabel)
        }
        // 「🎫 使用重置卡」按钮（图标+文字，表意=消耗一张卡）：一类卡可用直接确认，两类都有先选类型，无卡提示；使用中不可点
        let resetBtn = GLMPanelAction(title: "使用重置卡", target: self, action: #selector(onResetCardIcon(_:)))
        resetBtn.isBordered = false
        resetBtn.focusRingType = .default
        resetBtn.subtleBackground = true
        resetBtn.wantsLayer = true
        resetBtn.layer?.cornerRadius = 5
        resetBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
        resetBtn.image = NSImage(systemSymbolName: "ticket.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        resetBtn.imagePosition = .imageLeft
        resetBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        resetBtn.contentTintColor = .secondaryLabelColor
        resetBtn.heightAnchor.constraint(equalToConstant: 20).isActive = true
        resetBtn.isEnabled = !resetUseInFlight
        resetBtn.toolTip = resetUseInFlight ? "重置卡使用中…" : "使用一张重置卡，立即重置对应额度窗口"
        resetBtn.setAccessibilityLabel(resetUseInFlight ? "重置卡使用中" : "使用重置卡")
        cardHead.addArrangedSubview(spacer())
        cardHead.addArrangedSubview(resetBtn)
        cards.content.addArrangedSubview(cardHead); cardHead.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true
        if let c = usage.resetCards {
            func cardRow(_ name: String, _ detail: String, color: NSColor) {
                let line = row()
                let nameLabel = label(name, color: .secondaryLabelColor)
                nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                let detailLabel = label(detail, color: color)
                detailLabel.alignment = .right
                detailLabel.maximumNumberOfLines = 1
                detailLabel.lineBreakMode = .byTruncatingTail
                line.addArrangedSubview(nameLabel)
                line.addArrangedSubview(spacer())
                line.addArrangedSubview(detailLabel)
                cards.content.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true
            }
            for (name, dates) in [("5 小时卡", c.fiveHour), ("周卡", c.week)] {
                if let dates = dates {
                    let available = GLMFreshness.availableCards(dates, now: Date())
                    if available.isEmpty { cardRow(name, "暂无可用", color: .secondaryLabelColor) }
                    for d in available { cardRow(name, "\(Fmt.expires(d)) 过期", color: d.timeIntervalSinceNow <= 72 * 3600 ? .systemOrange : .labelColor) }
                }
            }
        } else { let l = label("暂无数据", color: .secondaryLabelColor); cards.content.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true }
        for (name, error, stale, last) in [("5 小时卡", usage.fiveHourCardsError, fiveHourCardsStale, fiveHourCardsLastOK), ("周卡", usage.weekCardsError, weekCardsStale, weekCardsLastOK)] {
            let message: String? = error.map { "\(name)获取失败：\($0)（ZCode 登录态可能过期，打开 ZCode 后重试） · 最后成功 \(Fmt.lastOK(last))" } ?? (stale ? "\(name)数据已过期 · 最后成功 \(Fmt.lastOK(last))" : nil)
            if let message = message { let l = label(message, color: .systemRed); cards.content.addArrangedSubview(l); l.widthAnchor.constraint(equalTo: cards.content.widthAnchor).isActive = true }
        }
        add(cards)
        let usageCard = GLMPanelCard()
        usageCard.content.spacing = 4
        let usageSection = section("用量情况", icon: "square.stack.3d.up.fill", expanded: tokenExpanded, action: #selector(toggleToken))
        addContent(usageSection, to: usageCard)
        let windows: [(String, ModelUsage?, Date?, Bool, String?)] = [
            ("今日", usage.tokensToday, tokensTodayLastOK, tokensTodayStale, usage.tokensTodayError),
            ("近 7 天", usage.tokens7d, tokens7dLastOK, tokens7dStale, usage.tokens7dError),
            ("近 30 天", usage.tokens30d, tokens30dLastOK, tokens30dStale, usage.tokens30dError)]
        func tableCells(_ values: [String], header: Bool, modelDetail: Bool = false) -> NSStackView {
            let r = row(); r.spacing = 4
            // 三列与两个间距填满卡片内容宽；展开指示仍保留在行首。
            let tableWidth = inner - GLMPanelCard.contentInset * 2 - 8
            // 明细行将调用次数列之前的空间更多留给模型名；Token 右边缘保持与汇总行对齐。
            let widths = modelDetail
                ? [tableWidth * 0.46, tableWidth * 0.20, tableWidth * 0.34]
                : [tableWidth * 0.32, tableWidth * 0.34, tableWidth * 0.34]
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
            let tableHeader = tableCells(["周期", "Token", "调用次数"], header: true)
            addContent(tableHeader, to: usageCard)
            // 参考 CodexUsage：普通汇总行紧凑排列，展开的明细组末留出间隔。
            var previous: NSView? = tableHeader
            var previousEndsGroup = false
            func tighten(after view: NSView?, gap: CGFloat) {
                if let view = view { usageCard.content.setCustomSpacing(gap, after: view) }
            }
            for (index, window) in windows.enumerated() {
                let (name, stats, _, _, _) = window
                let models = stats.map { TokenModelList.visible($0.byModel) } ?? []
                let expanded = expandedModelWindows.contains(index)
                // 折叠指示符在行首（周期名前缀，CodexUsage 同款）；无明细不加
                let nameLabel = models.isEmpty ? name : (expanded ? "⌄ " : "› ") + name
                let cells = tableCells([nameLabel, stats.map { Fmt.tokens($0.totalTokens) } ?? "--", stats.map { Fmt.count($0.totalCalls) } ?? "--"], header: false)
                let item = GLMPanelAction(title: "", target: self, action: #selector(toggleModels(_:)))
                item.isBordered = false; item.wantsLayer = true; item.layer?.cornerRadius = 5; item.tag = index
                item.isEnabled = !models.isEmpty
                let summary = "\(name)，Token \(stats.map { Fmt.tokens($0.totalTokens) } ?? "暂无数据")，调用 \(stats.map { Fmt.count($0.totalCalls) } ?? "暂无数据") 次"
                item.setAccessibilityLabel(summary + (models.isEmpty ? "，无模型明细" : "，\(expanded ? "收起" : "展开")模型明细"))
                item.toolTip = models.isEmpty ? "暂无模型明细" : (expanded ? "收起模型明细" : "展开模型明细")
                cells.translatesAutoresizingMaskIntoConstraints = false; item.addSubview(cells)
                NSLayoutConstraint.activate([cells.leadingAnchor.constraint(equalTo: item.leadingAnchor), cells.centerYAnchor.constraint(equalTo: item.centerYAnchor)])
                item.heightAnchor.constraint(equalToConstant: 23).isActive = true
                addContent(item, to: usageCard)
                tighten(after: previous, gap: previous === tableHeader ? 3 : (previousEndsGroup ? 8 : 4))
                previous = item
                previousEndsGroup = false
                if expanded {
                    for (modelIndex, model) in models.enumerated() {
                        let detail = tableCells([model.name, Fmt.tokens(model.tokens), ""], header: false, modelDetail: true)
                        detail.heightAnchor.constraint(equalToConstant: 20).isActive = true
                        addContent(detail, to: usageCard)
                        tighten(after: previous, gap: 3)
                        previous = detail
                        previousEndsGroup = modelIndex == models.count - 1
                    }
                }
            }
        }
        for (name, _, last, stale, error) in windows {
            if let error = error { addContent(label("\(name)刷新失败：\(error) · 最后成功 \(Fmt.lastOK(last))", color: .systemRed), to: usageCard) }
            else if stale { addContent(label("\(name)数据已过期 · 最后成功 \(Fmt.lastOK(last))", color: .systemOrange), to: usageCard) }
        }
        add(usageCard)

        // 每日用量：标题、选中行、图表和比较条作为一个完整模块进入独立卡片。
        let dailyCard = GLMPanelCard()
        dailyCard.content.spacing = 4
        let dailyPending = usage.dailyTokens != nil && (usage.dailyTokensError != nil || dailyStale)
        let dailySection = GLMDailyUsageSectionView(buckets: usage.dailyTokens, selectedIndex: dailySelectedIndex,
                                                    expanded: dailyExpanded, toggleTarget: self,
                                                    toggleAction: #selector(toggleDaily), pendingNote: dailyPending) { [weak self] index in
            self?.dailySelectedIndex = index
        }
        addContent(dailySection, to: dailyCard)
        add(dailyCard)

        let mcpCard = GLMPanelCard()
        mcpCard.content.spacing = 4
        let mcpSection = section("MCP 工具（近 30 天）", icon: "square.stack.3d.up", expanded: mcpExpanded, action: #selector(toggleMCP))
        addContent(mcpSection, to: mcpCard)
        // 键盘可达（PRD §6.2 支持键盘切换日期）：把柱图接进 key view loop——
        // 「用量情况」标题 → 柱图 → 「MCP 工具」标题为显式顺序，其余环节按几何自动；
        // Full Keyboard Access 下 Tab 即可到达柱图，左右方向键切换日期
        if dailyExpanded {
            usageSection.nextKeyView = dailySection.chartCanvas
            dailySection.chartCanvas.nextKeyView = mcpSection
        } else {
            usageSection.nextKeyView = mcpSection   // 折叠时柱图不在视图层级，直接桥接相邻板块
        }
        if mcpExpanded {
            if let t = usage.tools30d { addContent(label("网络搜索 \(Fmt.count(t.networkSearch)) 次 · 网页读取 \(Fmt.count(t.webRead)) 次", color: .secondaryLabelColor), to: mcpCard) }
            else { addContent(label("暂无数据", color: .secondaryLabelColor), to: mcpCard) }
        }
        if let e = usage.toolsError { addContent(label("MCP 刷新失败：\(e) · 最后成功 \(Fmt.lastOK(toolsLastOK))", color: .systemRed), to: mcpCard) }
        else if toolsStale { addContent(label("MCP 数据已过期 · 最后成功 \(Fmt.lastOK(toolsLastOK))", color: .systemOrange), to: mcpCard) }
        add(mcpCard)

        let header = row(); header.spacing = 12
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.widthAnchor.constraint(equalToConstant: 32).isActive = true; icon.heightAnchor.constraint(equalToConstant: 32).isActive = true; header.addArrangedSubview(icon)
        // 头部（PRD §2.1）：GLM 自己的图标 + 「GLM 用量」 + 独立套餐 badge（服务端名称，
        // 不硬编码、不按套餐换图标）；第二行仅当前 GLM 账号邮箱可靠可得时显示，否则整行
        // 隐藏不占空高。套餐到期仍在冻结区原位置显示。
        let headerText = GLMPanelStack(); headerText.orientation = .vertical; headerText.alignment = .leading; headerText.spacing = 2
        let titleRow = row(); titleRow.spacing = 6
        let title = label("GLM 用量", size: 15, bold: true)
        title.lineBreakMode = .byTruncatingTail; title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.init(751), for: .horizontal)
        titleRow.addArrangedSubview(title)
        if let planName = usage.subscription?.name, !planName.isEmpty {
            let pillText = label(planName, size: 10, bold: true, color: .secondaryLabelColor)
            pillText.lineBreakMode = .byTruncatingTail; pillText.maximumNumberOfLines = 1
            pillText.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            let pill = GLMPillBackground(); pill.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(pillText); pillText.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                pillText.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2), pillText.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
                pillText.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6), pillText.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6)])
            // 超长套餐名截断在 badge 内：上限保证「GLM 用量」标题至少保留可读宽度（≈标题全宽），
            // title(751) > pillText(750)，两者都超宽时先截 badge，再截标题，绝不溢出容器
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 44 - 70).isActive = true
            titleRow.addArrangedSubview(pill)
        }
        headerText.addArrangedSubview(titleRow)
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        if let email = usage.accountEmail {
            let emailLabel = label(email, size: 10, color: .secondaryLabelColor)
            emailLabel.lineBreakMode = .byTruncatingMiddle; emailLabel.maximumNumberOfLines = 1
            emailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 44).isActive = true
            emailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headerText.addArrangedSubview(emailLabel)
        }
        header.addArrangedSubview(headerText); headerText.translatesAutoresizingMaskIntoConstraints = false
        headerText.widthAnchor.constraint(equalToConstant: inner - 44).isActive = true
        header.addArrangedSubview(spacer())
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
            container.layer?.cornerRadius = 20
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
            // 固定 overlay 滚动条：legacy 滚动条样式下出现/消失会让文档宽度抖动（370↔362），
            // 引发 Popover 重新定位 ±1pt 漂移（面板高度随每日用量增加后更常越过滚动阈值）
            scroll.scrollerStyle = .overlay
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
        let rawHeight = min(maxHeight * 0.82, max(250, root.fittingSize.height + footer.fittingSize.height + 78))
        // 量化为偶数点：Popover 顶部锚定状态栏，高度奇偶变化会让 AppKit 重新取整 ±1pt
        // （面板加每日用量后高度更常变化，回归曾抓到 anchor 漂移）；偶数高度保持取整稳定
        let height = (rawHeight / 2).rounded(.down) * 2
        let desiredSize = NSSize(width: width, height: height)
        // 展开/收起明细时也更新已打开的 Popover；超过最大高度后仍由 scroll view 承接。
        panelController.preferredContentSize = desiredSize
        if !preview || previewPopover {
            popover.contentSize = desiredSize
            panelController.view.layoutSubtreeIfNeeded()
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
                guard let self = self, self.popover.isShown, let window = self.panelController.view.window else { return }
                let frame = window.frame
                print("GLM_POPOVER_TRACE \(reason) +\(delay) id=\(window.windowNumber) x=\(frame.minX) y=\(frame.minY) w=\(frame.width) h=\(frame.height)")
                fflush(stdout)
            }
        }
    }

    // Offline regression: uses the actual NSPopover and its AppKit controls, with fake data only.
    private func testPreviewPopover() {
        // 前一实例刚退出或环境 busy 时 popover 可能未及弹出：重试打开并等待（≤2s）
        if !popover.isShown { togglePanel() }
        var openWaited = 0.0
        while !popover.isShown && openWaited < 2.0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            openWaited += 0.1
            if !popover.isShown { togglePanel() }
        }
        guard previewPopover, popover.isShown, let window = panelController.view.window else {
            fputs("GLM popover test: FAIL opening\n", stderr); exit(1)
        }
        let initial = window.frame
        let initialTop = initial.maxY
        var previousHeight = initial.height
        var clickOffset = NSPoint.zero
        let originalController = popover.contentViewController
        let originalDocument = panelScroll.documentView
        enum HeightChange { case increase, decrease, same }
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func fail(_ message: String) { fputs("GLM popover test: FAIL \(message)\n", stderr); exit(1) }
        // 环境扰动恢复标记：测试期间用户真实点击/激活切换可能把 popover 关掉（生产语义正确），
        // 此时重开并以当前高度为新基线继续；视图身份变化仍是硬失败
        var envRecovered = false
        func verify(_ step: String, _ change: HeightChange, strictAnchor: Bool = true) {
            guard popover.contentViewController === originalController, panelScroll.documentView === originalDocument else {
                fail("view identity changed at \(step)"); return
            }
            if !popover.isShown {
                togglePanel()
                guard popover.isShown else { fail("reopen at \(step)"); return }
                envRecovered = true
                print("GLM_POPOVER_TEST \(step): env-close recovered")
            }
            guard panelController.view.window === window else {
                fail("window identity changed at \(step)"); return
            }
            if envRecovered {
                previousHeight = window.frame.height
            } else {
                // async-refresh 的锚点免检：菜单栏邻居宽度变化会平移锚点（环境噪声），
                // 锚点稳定性已由前面每步与两侧边缘放置检查覆盖
                if strictAnchor, abs(window.frame.maxY - initialTop) >= 1 {
                    fail("popover anchor moved at \(step)"); return
                }
                let delta = window.frame.height - previousHeight
                let heightIsCorrect: Bool
                switch change {
                case .increase: heightIsCorrect = delta > 0.5
                case .decrease: heightIsCorrect = delta < -0.5
                case .same: heightIsCorrect = abs(delta) <= 0.5
                }
                guard heightIsCorrect else {
                    fail("unexpected height change \(delta) at \(step)"); return
                }
                previousHeight = window.frame.height
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
            clickOffset = panelScroll.contentView.bounds.origin
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
        // 六张卡片增加了固定外框高度：连续展开多个模型窗会顶到最大高度，
        // 截断区内继续展开不会改变窗口高。逐项开/收可让每步都在非截断区验证真实增减；
        // 收起 Token 表后，再验证 MCP 与 footer（刷新提示行）的增减。
        let steps: [(HeightChange, () -> Void)] = [
            (.increase, { click(#selector(self.toggleModels(_:)), tag: 0) }),
            (.decrease, { click(#selector(self.toggleModels(_:)), tag: 0) }),
            (.increase, { click(#selector(self.toggleModels(_:)), tag: 1) }),
            (.decrease, { click(#selector(self.toggleModels(_:)), tag: 1) }),
            (.increase, { click(#selector(self.toggleModels(_:)), tag: 2) }),
            (.decrease, { click(#selector(self.toggleModels(_:)), tag: 2) }),
            (.decrease, { click(#selector(self.toggleToken)) }),
            (.decrease, { click(#selector(self.toggleMCP)) }),
            (.increase, { click(#selector(self.toggleMCP)) }),
            (.increase, { click(#selector(self.onRefresh)) })
        ]
        func run(_ index: Int) {
            if index == steps.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    verify("async-refresh", .same, strictAnchor: false)
                    // 多窗展开状态单独做重开保持回归；这里直接布置终态，避免在截断区追加无高度变化的点击。
                    self.expandedModelWindows = [0, 2]
                    self.rebuildMenu()
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
                    print("GLM popover test: PASS (live resize, stable anchor, scroll restoration, controls, async refresh, close/reopen, left/right edges)")
                    exit(0)
                }
                return
            }
            steps[index].1()
            // 0.25s：步进过紧时下一次点击可能落在上一步布局收敛前（偶发 0 高度差误报）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                verify("step-\(index)", steps[index].0)
                if envRecovered {
                    envRecovered = false   // 环境关闭后重开，滚动基线已失效，本步跳过滚动断言
                } else {
                    self.panelScroll.layoutSubtreeIfNeeded()
                    let clip = self.panelScroll.contentView
                    let documentHeight = self.panelScroll.documentView?.frame.height ?? clip.bounds.height
                    let maxY = max(0, documentHeight - clip.bounds.height)
                    let expectedY = min(maxY, max(0, clickOffset.y))
                    guard abs(clip.bounds.origin.y - expectedY) < 1 else {
                        fail("scroll offset changed at step-\(index)"); return
                    }
                }
                run(index + 1)
            }
        }
        run(0)
    }

    // 离线回归：每日用量交互（合成数据）。鼠标事件经 NSApp.sendEvent 真实派发
    // （悬停命中整天宽列、缺失/零日可读、离开保留选中、点击选日、键盘切换），非直接调内部方法。
    private func testDailyInteraction() {
        func fail(_ message: String) -> Never {
            fputs("GLM daily test: FAIL \(message)\n", stderr)
            try? "FAIL \(message)".write(toFile: "/tmp/glm_daily_test_result.txt", atomically: true, encoding: .utf8)
            exit(1)
        }
        // 前一实例刚退出时 popover 偶发未及弹出：重试打开并轮询等待（≤2s），避免启动竞态误报
        if !popover.isShown { togglePanel() }
        var waited = 0.0
        while !popover.isShown && waited < 2.0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            waited += 0.1
            if !popover.isShown { togglePanel() }
        }
        // 测试前置条件：popover 窗口必须成为 key window，否则键盘事件（Tab）会被整体
        // 丢弃（2026-11-07 实测）。非激活 app 不允许持有 key window：先激活应用；
        // popover 若在激活前已弹出，其窗口不会事后补拿 key，需关掉重开（重开须在
        // 捕获视图引用之前，重开后引用才是新视图）。只修测试前置条件，不改断言本身。
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if !(panelController.view.window?.isKeyWindow ?? false) {
            popover.performClose(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            togglePanel()
            var keyWait = 0.0
            while (panelController.view.window?.isKeyWindow != true) && keyWait < 2.0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                keyWait += 0.1
                if !popover.isShown { togglePanel() }
            }
        }
        guard popover.isShown, let window = panelController.view.window, window.isKeyWindow else {
            fail("opening/key-window"); exit(1)
        }
        func findView<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews {
                if let match = findView(child, type) { return match }
            }
            return nil
        }
        func findLabel(_ root: NSView, _ identifier: NSUserInterfaceItemIdentifier) -> NSTextField? {
            if root is NSTextField && root.identifier == identifier { return root as? NSTextField }
            for child in root.subviews {
                if let match = findLabel(child, identifier) { return match }
            }
            return nil
        }
        guard let canvas = findView(panelController.view, GLMDailyChartCanvas.self),
              let dateLabel = findLabel(panelController.view, GLMDailyUsageSectionView.dateLabelIdentifier),
              let valueLabel = findLabel(panelController.view, GLMDailyUsageSectionView.valueLabelIdentifier) else {
            fail("daily section views missing"); exit(1)
        }
        let buckets = canvas.dayBuckets
        guard buckets.count == 30 else { fail("bucket count \(buckets.count)"); exit(1) }
        window.acceptsMouseMovedEvents = true
        canvas.scrollToVisible(canvas.bounds)
        panelController.view.layoutSubtreeIfNeeded()
        func sendMouse(_ type: NSEvent.EventType, atViewPoint point: NSPoint) {
            let location = canvas.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: type == .leftMouseDown ? 1 : 0, pressure: 1) else {
                fail("cannot create \(type.rawValue) event"); exit(1)
            }
            NSApp.sendEvent(event)
        }
        func sendKey(_ keyCode: UInt16, characters: String = "") {
            let location = NSPoint(x: 10, y: 10)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode) else {
                fail("cannot create key event"); exit(1)
            }
            NSApp.sendEvent(event)
        }
        func hover(_ index: Int, edge: Bool = false) {
            let column = canvas.bounds.width / 30
            let x = column * CGFloat(index) + (edge ? column - 0.5 : 1)
            sendMouse(.mouseMoved, atViewPoint: NSPoint(x: x, y: canvas.bounds.midY))
        }
        func verify(_ step: String, index: Int) {
            let bucket = buckets[index]
            let expectedDate = GLMDailyUsageSectionView.dayText(for: bucket.day)
            let expectedValue = bucket.tokens.map { "\(Fmt.tokens($0)) Token" } ?? "数据不足"
            guard dateLabel.stringValue == expectedDate else {
                fail("\(step): date \(dateLabel.stringValue) != \(expectedDate)"); exit(1)
            }
            guard valueLabel.stringValue == expectedValue else {
                fail("\(step): value \(valueLabel.stringValue) != \(expectedValue)"); exit(1)
            }
            print("GLM_DAILY_TEST \(step): \(expectedDate) \(expectedValue)")
            fflush(stdout)
        }
        // 用 DispatchMain 上的异步链执行（事件需要主循环处理窗口）
        typealias Step = () -> Void
        var steps: [Step] = []
        steps.append {
            // 键盘可达性：不点击、不强设 first responder，模拟 Full Keyboard Access 下
            // Tab 沿 key view loop 走到柱图（面板已显式接线「用量情况」→ 柱图 → 「MCP 工具」）
            var reached = canvas === window.firstResponder
            for _ in 0..<20 where !reached {
                sendKey(48, characters: "\t")   // Tab
                reached = canvas === window.firstResponder
            }
            guard reached else {
                fail("canvas not reachable via Tab within 20 hops (firstResponder=\(String(describing: window.firstResponder)), isKeyWindow=\(window.isKeyWindow))"); exit(1)
            }
            print("GLM_DAILY_TEST tab-reachable: PASS")
            fflush(stdout)
        }
        steps.append {
            hover(5)
            print("GLM_DAILY_DEBUG selected=\(canvas.selectedIndex) firstResponder=\(String(describing: window.firstResponder)) canvasInWindow=\(canvas.convert(canvas.bounds, to: nil)) acceptsMoved=\(window.acceptsMouseMovedEvents) tracking=\(canvas.trackingAreas.count)")
            verify("hover-day", index: 5)
        }
        steps.append { hover(10); verify("hover-zero-day", index: 10) }            // 零值日可命中
        steps.append { hover(17); verify("hover-missing-day", index: 17) }         // 缺失日=数据不足（非 0）
        steps.append { hover(17, edge: true); verify("hover-column-edge", index: 17) }  // 整天宽命中
        steps.append { hover(20); verify("hover-move", index: 20) }
        steps.append {
            // NSEvent.mouseEventWithType 只接受 MouseMask/MouseMoved；离开事件须用
            // enterExitEvent 合成（与真实 tracking-area 离开事件同类型）
            let location = canvas.convert(NSPoint(x: -50, y: -50), to: nil)
            guard let exitEvent = NSEvent.enterExitEvent(with: .mouseExited, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 1, userData: nil) else {
                fail("cannot create exit event"); exit(1)
            }
            NSApp.sendEvent(exitEvent)
            // 离开图表保留最后选中值
            guard dateLabel.stringValue == GLMDailyUsageSectionView.dayText(for: buckets[20].day) else {
                fail("mouse-exited: selection jumped"); exit(1)
            }
            print("GLM_DAILY_TEST mouse-exited-keeps-selection: PASS"); fflush(stdout)
        }
        steps.append {
            sendMouse(.leftMouseDown, atViewPoint: NSPoint(x: canvas.bounds.width / 30 * 22 + 1, y: canvas.bounds.midY))
            sendMouse(.leftMouseUp, atViewPoint: NSPoint(x: canvas.bounds.width / 30 * 22 + 1, y: canvas.bounds.midY))
        }
        steps.append { verify("click-select", index: 22) }
        steps.append {
            _ = window.makeFirstResponder(canvas)
            guard canvas === window.firstResponder else {
                fail("canvas first responder"); exit(1)
            }
            sendKey(123)   // ←
        }
        steps.append { verify("key-left", index: 21) }
        steps.append { sendKey(124) }   // →
        steps.append { sendKey(124) }   // →
        steps.append {
            verify("key-right-x2", index: 23)
            guard let accessibilityText = canvas.accessibilityValue() as? String, !accessibilityText.isEmpty else {
                fail("accessibility value empty"); exit(1)
            }
            self.togglePanel()
            self.togglePanel()
        }
        steps.append {
            guard let reopenedCanvas = findView(self.panelController.view, GLMDailyChartCanvas.self),
                  let reopenedDate = findLabel(self.panelController.view, GLMDailyUsageSectionView.dateLabelIdentifier),
                  reopenedCanvas.selectedIndex == buckets.count - 1,
                  reopenedDate.stringValue == GLMDailyUsageSectionView.dayText(for: buckets[buckets.count - 1].day) else {
                fail("reopened panel did not select latest day")
            }
            print("GLM_DAILY_TEST reopen-selects-latest: PASS")
            print("GLM daily test: PASS (hover hit columns, zero/missing readable, exit keeps selection, click, keyboard, a11y, reopen)")
            fflush(stdout)
            try? "PASS".write(toFile: "/tmp/glm_daily_test_result.txt", atomically: true, encoding: .utf8)
            exit(0)
        }
        func runStep(_ index: Int) {
            guard index < steps.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self = self, self.popover.isShown else { fail("popover closed mid-test"); exit(1) }
                steps[index]()
                runStep(index + 1)
            }
        }
        runStep(0)
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

    // 更新检查完成后无条件重建菜单：横幅出现/消失都靠它自愈（刷新周期 ≤10s 也会兜底重建）
    private func checkForUpdate() {
        UpdateChecker.shared.check { [weak self] in self?.updateUI() }
    }

    @objc private func onUpdateApp() {
        // App Translocation：从下载目录直接运行的应用被挂载到只读位置，原地更新必然失败，
        // 在发起更新前拦截并给出安装指引，而不是让脚本在暂存阶段报错。
        if Bundle.main.bundleURL.path.contains("/AppTranslocation/") {
            let alert = NSAlert()
            alert.messageText = "无法原地更新"
            alert.informativeText = "GlmUsage 正在从临时位置运行（App Translocation），无法原地替换。\n请退出应用，把 GlmUsage.app 拖入「应用程序」文件夹后从那里打开。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
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
            current.fiveHourWarning = r.fiveHourWarning; current.weekWarning = r.weekWarning
        }
        group.leave()
    }
    let now = Date()
    let dayStart = Calendar.current.startOfDay(for: now)
    for (label, from) in [("today", dayStart), ("7d", now.addingTimeInterval(-7 * 86400)),
                          ("30d", now.addingTimeInterval(-30 * 86400))] {
        group.enter()
        Fetcher.fetchModelUsage(apiKey: key, from: from, to: now) { r, _, _, err in
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
    if let w = data.fiveHourWarning { print("5h quota warning: \(w)") }
    if let w = data.weekWarning { print("7d quota warning: \(w)") }
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
            // 超额用尽（currentValue > usage）是服务端合法状态：应保留窗口并显示 100% 已用
            let overUsed = Fetcher.parseQuota(["limits": [
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 60_000,
                 "currentValue": 60_004, "remaining": 0, "percentage": 100]
            ]], error: nil, now: now)
            try expect(overUsed.week?.usedRatio == 1 && overUsed.week?.remaining == 0
                       && overUsed.weekError == nil,
                       "over-quota (currentValue > usage) window was rejected")

            let badReset = Fetcher.parseQuota(["limits": [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 100,
                 "currentValue": 20, "remaining": 80, "percentage": 20, "nextResetTime": "bad"],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 7, "usage": 400,
                 "currentValue": 100, "remaining": 300, "percentage": 25]
            ]], error: nil, now: now)
            try expect(badReset.fiveHour?.remaining == 80 && badReset.fiveHour?.reset == nil
                       && (badReset.fiveHourWarning?.contains("nextResetTime") ?? false)
                       && badReset.fiveHourError == nil && badReset.weekError == nil && badReset.weekWarning == nil, "bad reset suppressed quota or contaminated other window")
            let warningFresh = GLMFreshness.apply(fresh: badReset.fiveHour, failure: badReset.fiveHourError,
                old: nil, oldLastOK: nil, oldError: "previous failure", now: now)
            try expect(warningFresh.value != nil && warningFresh.lastOK == now && warningFresh.error == nil,
                       "valid quota with reset warning was treated as a failed refresh")
            // 2026-11-04 实际接口的脱敏额度字段：两窗口均有效，不应出现橙色异常提示。
            let roundedQuotaJSON = """
            {"limits":[
              {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,
               "currentValue":0,"remaining":1999,"percentage":1},
              {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,
               "currentValue":2961,"remaining":7038,"percentage":29}
            ]}
            """
            let roundedQuota = try JSONSerialization.jsonObject(with: Data(roundedQuotaJSON.utf8)) as! [String: Any]
            let rounded = Fetcher.parseQuota(roundedQuota, error: nil, now: now)
            try expect(rounded.fiveHour?.remaining == 1999 && rounded.week?.remaining == 7038
                       && rounded.fiveHourWarning == nil && rounded.weekWarning == nil
                       && rounded.fiveHourError == nil && rounded.weekError == nil,
                       "server-rounded 5H/7D quota fields caused false warnings")
            try expect(abs((rounded.fiveHour?.usedRemainingRatio ?? -1) - 0.9995) < 0.000001
                       && abs((rounded.week?.usedRemainingRatio ?? -1) - 0.7038) < 0.000001,
                       "rounded quota did not preserve remaining-credit progress")
            for (remaining, percentage, warned) in [(80.0, 20.0, false), (79.0, 20.4, false),
                                                      (80.0, 19.0, false), (80.0, 21.0, false),
                                                      (80.0, 18.99, true), (80.0, 21.01, true),
                                                      (10.0, 20.0, true), (80.0, 80.0, true)] {
                let value = Fetcher.parseQuota(["limits": [["type": "CREDIT_LIMIT", "unit": 3, "number": 5,
                    "usage": 100, "currentValue": 20, "remaining": remaining, "percentage": percentage]]], error: nil, now: now)
                let ratioMatches = value.fiveHour.map { abs($0.usedRemainingRatio - remaining / 100) < 0.000001 } ?? false
                let hasWarning = value.fiveHourWarning?.contains("inconsistent") ?? false
                try expect(ratioMatches && value.fiveHourError == nil && hasWarning == warned,
                           "quota rounding tolerance hid an inconsistency or raised a false warning")
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

            // 临时 SQLite 覆盖真实读取 → 周期总量/模型合并 → 日图的整条补统计路径。
            let startPlanPath = root.appendingPathComponent("zcode.sqlite").path
            var fixtureDB: OpaquePointer?
            try expect(sqlite3_open(startPlanPath, &fixtureDB) == SQLITE_OK, "cannot create usage fixture")
            defer { sqlite3_close(fixtureDB) }
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: now)
            let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
            let sevenStart = now.addingTimeInterval(-7 * 86_400)
            let thirtyStart = now.addingTimeInterval(-30 * 86_400)
            func insertUsage(_ id: Int, _ date: Date, _ provider: String, _ model: String,
                             _ status: String, _ reported: String, _ computed: Int) throws {
                let sql = """
                    INSERT INTO model_usage VALUES (\(id), \(Int64(date.timeIntervalSince1970 * 1_000)),
                    '\(provider)', '\(model)', '\(status)', \(reported), \(computed));
                    """
                try expect(sqlite3_exec(fixtureDB, sql, nil, nil, nil) == SQLITE_OK, "cannot insert usage fixture")
            }
            try expect(sqlite3_exec(fixtureDB, """
                CREATE TABLE model_usage (id INTEGER PRIMARY KEY, started_at INTEGER, provider_id TEXT,
                    model_id TEXT, status TEXT, provider_total_tokens INTEGER, computed_total_tokens INTEGER);
                """, nil, nil, nil) == SQLITE_OK, "cannot create usage table")
            try insertUsage(1, todayStart, "account:bigmodel-start-plan", "glm-5.3-flash", "completed", "100", 900)
            try insertUsage(2, now, "builtin:bigmodel-start-plan", "GLM-5.3-Flash", "error", "NULL", 40)
            try insertUsage(3, yesterdayStart, "account:bigmodel-start-plan", "GLM-5.3-Flash", "completed", "200", 200)
            try insertUsage(4, sevenStart.addingTimeInterval(-1), "account:bigmodel-start-plan", "GLM-5.3", "completed", "300", 300)
            try insertUsage(5, thirtyStart.addingTimeInterval(-1), "account:bigmodel-start-plan", "GLM-5.3", "completed", "400", 400)
            try insertUsage(6, now, "account:bigmodel-individual-coding-plan", "GLM-5.3-Flash", "completed", "9999", 9999)
            try insertUsage(7, now, "account:zai-start-plan", "GLM-5.3-Flash", "completed", "9999", 9999)
            try insertUsage(8, now, "account:bigmodel-start-plan", "GLM-5.3-Flash", "running", "9999", 9999)
            try insertUsage(9, now, "account:bigmodel-start-plan", "GLM-5.3-Flash", "cancelled", "NULL", 0)
            try insertUsage(10, now.addingTimeInterval(1), "account:bigmodel-start-plan", "GLM-5.3-Flash", "completed", "9999", 9999)
            let startPlan = try GLMStartPlanUsage.load(from: thirtyStart, to: now, databasePath: startPlanPath)
            let officialUsage = ModelUsage(totalTokens: 10, totalCalls: 1, byModel: [("GLM-5.3-Flash", 10)])
            let mergedToday = startPlan.merging(officialUsage, from: todayStart, to: now)
            try expect(mergedToday.totalTokens == 150 && mergedToday.totalCalls == 3
                       && mergedToday.byModel.count == 1 && mergedToday.byModel[0].name == "GLM-5.3-Flash"
                       && mergedToday.byModel[0].tokens == 150,
                       "Start Plan today/provider filtering/cache accounting/model merge changed")
            let mergedSeven = startPlan.merging(officialUsage, from: sevenStart, to: now)
            let mergedThirty = startPlan.merging(officialUsage, from: thirtyStart, to: now)
            try expect(mergedSeven.totalTokens == 350 && mergedSeven.totalCalls == 4
                       && mergedThirty.totalTokens == 650 && mergedThirty.totalCalls == 5,
                       "Start Plan rolling window boundaries changed")
            try expect(startPlan.merging(officialUsage, from: todayStart, to: now).totalTokens == 150,
                       "refresh counted Start Plan more than once")
            let mergedDays = startPlan.merging([GLMDayBucket(day: yesterdayStart, tokens: 20),
                                                GLMDayBucket(day: todayStart, tokens: nil)])
            try expect(mergedDays[0].tokens == 220 && mergedDays[1].tokens == nil,
                       "Start Plan daily merge lost a day or fabricated complete missing data")
            let oldestDay = calendar.startOfDay(for: thirtyStart)
            try expect(startPlan.merging([GLMDayBucket(day: oldestDay, tokens: 0)])[0].tokens == 400,
                       "Start Plan day chart lost the partial rolling window's full natural day")
            let missingStartPlan = try GLMStartPlanUsage.load(from: thirtyStart, to: now,
                databasePath: root.appendingPathComponent("missing.sqlite").path)
            try expect(missingStartPlan.records.isEmpty, "missing optional ZCode database was rejected")
            try expect(sqlite3_exec(fixtureDB, "DROP TABLE model_usage", nil, nil, nil) == SQLITE_OK,
                       "cannot prepare older ZCode fixture")
            let olderStartPlan = try GLMStartPlanUsage.load(from: thirtyStart, to: now, databasePath: startPlanPath)
            try expect(olderStartPlan.records.isEmpty, "older ZCode broke existing server usage")
            try expect(sqlite3_exec(fixtureDB, "CREATE TABLE model_usage (unrecognized TEXT)", nil, nil, nil) == SQLITE_OK,
                       "cannot prepare incompatible ZCode fixture")
            var rejectedStartPlanSchema = false
            do { _ = try GLMStartPlanUsage.load(from: thirtyStart, to: now, databasePath: startPlanPath) }
            catch { rejectedStartPlanSchema = true }
            try expect(rejectedStartPlanSchema, "unreadable Start Plan silently became zero")

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
            try expect(ResetCards(fiveHour: [now.addingTimeInterval(-1), now.addingTimeInterval(30)],
                                  week: [now.addingTimeInterval(60), now]).availableCount(now: now) == 2,
                       "reset card count included expired cards or missed a type")
            try expect(ResetCards(fiveHour: [], week: []).availableCount(now: now) == 0,
                       "empty reset card count was not zero")
            try expect(ResetCards(fiveHour: nil, week: [now.addingTimeInterval(30)]).availableCount(now: now) == nil,
                       "incomplete reset card data was counted as a total")

            // 使用重置卡响应解析：成功 / 明确拒绝不可重试 / 5xx 可重试 / code==0 缺 used=结果未知必须可重试
            let useOK = Fetcher.parseResetUseResponse(["code": 0, "data": ["used": true]], httpStatus: 200)
            try expect(useOK.used && useOK.error == nil && !useOK.retryable,
                       "successful reset use response was rejected")
            let useRejected = Fetcher.parseResetUseResponse(["code": 40_001, "msg": "no available reset"], httpStatus: 200)
            try expect(!useRejected.used && !useRejected.retryable
                       && (useRejected.error?.contains("no available reset") ?? false),
                       "definitive reset use rejection was treated as retryable")
            let use5xx = Fetcher.parseResetUseResponse([:], httpStatus: 502)
            try expect(!use5xx.used && use5xx.retryable, "5xx reset use response was not retryable")
            let useNoFlag = Fetcher.parseResetUseResponse(["code": 0, "data": [String: Any]()], httpStatus: 200)
            try expect(!useNoFlag.used && useNoFlag.retryable,
                       "code==0 without used=true must stay retryable (unknown outcome)")
            let useFalseFlag = Fetcher.parseResetUseResponse(["code": 0, "data": ["used": false]], httpStatus: 200)
            try expect(!useFalseFlag.used && useFalseFlag.retryable,
                       "code==0 with used=false must stay retryable (unknown outcome)")
            try expect(ResetCardType.fiveHour.rawValue == "FIVE_HOUR" && ResetCardType.week.rawValue == "WEEK",
                       "reset card type wire values changed")
            // 幂等 key 跨进程持久化：读写往返 / 过期剪枝 / 损坏文件兜底
            let storeDir = root.appendingPathComponent("pending-resets", isDirectory: true).path
            GLMPendingResetStore.save(["FIVE_HOUR": .init(key: "k-fresh", createdAt: now),
                                       "WEEK": .init(key: "k-stale", createdAt: now.addingTimeInterval(-8 * 86_400))],
                                      dir: storeDir)
            let reloaded = GLMPendingResetStore.load(dir: storeDir, now: now)
            try expect(reloaded["FIVE_HOUR"]?.key == "k-fresh" && reloaded["WEEK"] == nil,
                       "pending reset store lost fresh key or kept expired one")
            try JSONSerialization.data(withJSONObject: ["unexpected": true])
                .write(to: URL(fileURLWithPath: storeDir + "/pending-resets.json"))
            try expect(GLMPendingResetStore.load(dir: storeDir, now: now).isEmpty,
                       "corrupt pending reset store was not rejected safely")

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
                let image = StackImage.make(line1: previewLine, line2: previewLine, appearance: appearance)
                try expect(!image.isTemplate && image.cacheMode == .never
                           && image.size.width > 0 && image.tiffRepresentation != nil,
                           "menu bar uncached color image did not render for \(name.rawValue)")
            }

            // 外观重绘必须真正改变文字颜色：浅色外观画深字，深色外观画浅字。
            func neutralInkCount(_ image: NSImage, white: Bool) -> Int {
                guard let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data) else { return 0 }
                var count = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.8 else { continue }
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        let brightness = (channels[0] + channels[1] + channels[2]) / 3
                        let grayscale = channels.allSatisfy { abs($0 - brightness) < 0.02 }
                        if grayscale && (white ? brightness > 0.8 : brightness < 0.2) { count += 1 }
                    }
                }
                return count
            }
            let neutralLine = StackImage.Line(badge: "", label: "5H", value: "50%", remaining: 0.5)
            let lightImage = StackImage.make(line1: neutralLine, line2: neutralLine,
                                             appearance: NSAppearance(named: .aqua)!)
            let darkImage = StackImage.make(line1: neutralLine, line2: neutralLine,
                                            appearance: NSAppearance(named: .darkAqua)!)
            try expect(neutralInkCount(lightImage, white: false) > 0,
                       "light appearance override did not draw dark menu bar text")
            try expect(neutralInkCount(darkImage, white: true) > 0,
                       "dark appearance override did not draw light menu bar text")

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

            // ---- 每日用量：严格解析/聚合/比较（合成 fixture；2026-11-06 真实接口只读验收已过）----
            // 生产 Gate 已开启，口径 = 验收口径（granularity=daily、"yyyy-MM-dd" 日标签）；
            // 此断言防止口径漂移时无人察觉：若未来验收推翻日粒度口径，须同步翻转此断言
            try expect(GLMDailyUsage.productionGateConfirmed == true,
                       "production daily gate must stay on after 2026-11-06 real-interface verification")
            let shanghai = TimeZone(identifier: "Asia/Shanghai")!
            var shanghaiCal = Calendar(identifier: .gregorian)
            shanghaiCal.timeZone = shanghai
            func shDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
                shanghaiCal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
            }
            // 合法序列：两模型按下标对齐 → 逐日求和（2026-11-06 真实验收口径：日粒度 yyyy-MM-dd）
            let okTimeline = GLMDailyUsage.parseTimeline([
                "x_time": ["2026-11-03", "2026-11-04", "2026-11-05"],
                "modelDataList": [
                    ["modelName": "glm-5.3", "tokensUsage": [100, 200, 0]],
                    ["modelName": "glm-5.3-flash", "tokensUsage": [0, 50, 50]]
                ]
            ], timeZone: shanghai)
            try expect(okTimeline?.totals == [100, 250, 50], "valid timeline totals wrong")

            // 异常序列整体拒绝（未知不得当 0）
            func rejected(_ mutate: (inout [String: Any]) -> Void) -> Bool {
                var payload: [String: Any] = [
                    "x_time": ["2026-11-04", "2026-11-05"],
                    "modelDataList": [["modelName": "m", "tokensUsage": [1, 2]]]
                ]
                mutate(&payload)
                return GLMDailyUsage.parseTimeline(payload, timeZone: shanghai) == nil
            }
            try expect(rejected { $0.removeValue(forKey: "x_time") }, "missing x_time accepted")
            try expect(rejected { $0["x_time"] = "oops" }, "non-array x_time accepted")
            try expect(rejected { $0.removeValue(forKey: "modelDataList") }, "missing modelDataList accepted")
            try expect(rejected { $0["modelDataList"] = [] }, "empty modelDataList accepted")
            try expect(rejected { $0["modelDataList"] = "oops" }, "non-array modelDataList accepted")
            try expect(rejected {
                var labels = $0["x_time"] as? [String] ?? []
                labels[1] = "2026/11/05"
                $0["x_time"] = labels
            }, "separator-loose label accepted")
            try expect(rejected {
                var labels = $0["x_time"] as? [String] ?? []
                labels[1] = "2026-11-5"
                $0["x_time"] = labels
            }, "non-zero-padded label accepted")
            try expect(rejected {
                var labels = $0["x_time"] as? [String] ?? []
                labels[1] = "2026-11-05 01:00:00"
                $0["x_time"] = labels
            }, "hour-format label accepted")
            try expect(rejected {
                var labels = $0["x_time"] as? [String] ?? []
                labels[1] = "garbage"
                $0["x_time"] = labels
            }, "garbage label accepted")
            try expect(rejected {
                var labels = $0["x_time"] as? [String] ?? []
                labels[1] = labels[0]
                $0["x_time"] = labels
            }, "duplicate label accepted")
            try expect(rejected {
                var models = $0["modelDataList"] as? [[String: Any]] ?? []
                models[0]["tokensUsage"] = [1]
                $0["modelDataList"] = models
            }, "tokensUsage length mismatch accepted")
            try expect(rejected {
                var models = $0["modelDataList"] as? [[String: Any]] ?? []
                models[0]["tokensUsage"] = [1, -2]
                $0["modelDataList"] = models
            }, "negative token accepted")
            try expect(rejected {
                var models = $0["modelDataList"] as? [[String: Any]] ?? []
                models[0]["tokensUsage"] = [1, NSNull()]
                $0["modelDataList"] = models
            }, "null token accepted")
            try expect(rejected {
                var models = $0["modelDataList"] as? [[String: Any]] ?? []
                models[0]["tokensUsage"] = [1, true]
                $0["modelDataList"] = models
            }, "boolean token accepted")
            try expect(rejected {
                var models = $0["modelDataList"] as? [[String: Any]] ?? []
                models[0]["tokensUsage"] = [1, "NaN"]
                $0["modelDataList"] = models
            }, "non-finite token accepted")

            // 同名模型重复行 → 双计风险，整体拒绝；求和溢出 → 拒绝
            try expect(rejected {
                $0["modelDataList"] = [["modelName": "glm-5.3", "tokensUsage": [1, 2]],
                                       ["modelName": "glm-5.3", "tokensUsage": [3, 4]]]
            }, "duplicate model name accepted")
            try expect(rejected {
                $0["x_time"] = ["2026-11-05"]
                $0["modelDataList"] = [["modelName": "a", "tokensUsage": [1e308]],
                                       ["modelName": "b", "tokensUsage": [1e308]]]
            }, "overflowing model sum accepted")

            // 聚合（日粒度直映射口径）：桶 = 今日-29 ... 今日（含今日部分累计）；窗口外丢弃；缺日 = nil
            let frameNow = shDate(2026, 11, 6, 15)
            let windowStart = frameNow.addingTimeInterval(-30 * 86400)   // 2026-10-07 15:00 → 起点日=今日-30，止步窗外
            let frameTimes: [Date] = [shDate(2026, 10, 6), shDate(2026, 10, 7),
                                      shDate(2026, 11, 5), shDate(2026, 11, 6)]
            let frameTotals: [Double] = [100, 7, 240, 999]
            let frame = GLMDailyUsage.frame(from: GLMDailyUsage.Timeline(times: frameTimes, totals: frameTotals),
                                            calendar: shanghaiCal, now: frameNow, coverageStart: windowStart)
            try expect(frame?.count == 30, "daily frame must have 30 buckets")
            try expect(frame?.first?.day == shDate(2026, 10, 8) && frame?.first?.tokens == nil,
                       "oldest bucket must be today-29 without records (nil, not zero)")
            try expect(frame?.last?.day == shDate(2026, 11, 6) && frame?.last?.tokens == 999,
                       "last bucket must be today with its partial-day total")
            try expect(frame?.contains(where: { $0.day == shDate(2026, 11, 5) && $0.tokens == 240 }) == true,
                       "yesterday bucket wrong")
            try expect(frame?.contains(where: { $0.day == shDate(2026, 10, 6) }) == false,
                       "label before oldest leaked into frame")
            try expect(frame?.contains(where: { $0.day == shDate(2026, 10, 7) }) == false,
                       "window-start day (today-30) must stay outside the today-inclusive frame")
            try expect(frame?.contains(where: { $0.day == shDate(2026, 11, 4) && $0.tokens == nil }) == true,
                       "day without records became zero")
            // 非有限日总量防御（直接构造 Timeline 的越界用法也不得漏过）
            let badFrame = GLMDailyUsage.frame(
                from: GLMDailyUsage.Timeline(times: [shDate(2026, 11, 5)], totals: [.infinity]),
                calendar: shanghaiCal, now: frameNow)
            try expect(badFrame == nil, "non-finite day total accepted")

            // 日粒度口径下无小时网格/DST 敏感逻辑（原 23/25 小时日用例随网格推断一并移除；
            // 标签→日期换算由 parseTimeline 的 round-trip 校验与 timeZone 参数保证）

            // 比较（PRD §6.3）：持平/新增/百分比/缺失；缺失不能当 0
            func bucket(_ tokens: Double?) -> GLMDayBucket {
                GLMDayBucket(day: shDate(2026, 11, 5), tokens: tokens)
            }
            try expect(GLMUsageComparison.outcome(current: 0, base: 0) == .flat, "both-zero must be 持平")
            try expect(GLMUsageComparison.outcome(current: 1500, base: 0).text == "新增 1.50K", "base-zero must be 新增")
            try expect(GLMUsageComparison.outcome(current: 1074, base: 1000).text == "+7.4%", "percent text wrong")
            try expect(GLMUsageComparison.outcome(current: 926, base: 1000).text == "-7.4%", "negative percent text wrong")
            try expect(GLMUsageComparison.outcome(current: 1074, base: 1000).direction == .increase
                       && GLMUsageComparison.outcome(current: 926, base: 1000).direction == .decrease
                       && GLMUsageComparison.outcome(current: 1, base: 0).direction == .increase
                       && GLMUsageComparison.outcome(current: 0, base: 0).direction == .neutral
                       && GLMUsageComparison.outcome(current: nil, base: 1).direction == .neutral,
                       "comparison direction classification wrong")
            try expect(GLMUsageComparison.outcome(current: 1000, base: 1000) == .flat, "equal values must be 持平")
            try expect(GLMUsageComparison.outcome(current: 9998, base: 10000) == .flat, "tiny negative pct must be flat (no -0.0%)")
            try expect(GLMUsageComparison.outcome(current: 10002, base: 10000) == .flat, "tiny positive pct must be flat")
            try expect(GLMUsageComparison.outcome(current: 9990, base: 10000).text == "-0.1%", "just above flat threshold must still show percent")
            try expect(GLMUsageComparison.outcome(current: 1000, base: nil) == .insufficient, "missing base became zero")
            try expect(GLMUsageComparison.sum([bucket(1), bucket(nil), bucket(1)]) == nil,
                       "sum treated missing day as zero")
            try expect(GLMUsageComparison.sum([bucket(0), bucket(0)]) == 0, "zero-day sum rejected")
            let sparsePair = GLMUsageComparison.dailyPair(buckets: [bucket(nil), bucket(1), bucket(2), bucket(nil),
                bucket(nil), bucket(nil), bucket(nil), bucket(nil), bucket(nil), bucket(nil), bucket(nil), bucket(nil),
                bucket(10), bucket(10), bucket(10), bucket(10), bucket(10), bucket(10), bucket(10)])
            try expect(sparsePair.weekOnWeek == .insufficient, "14-day coverage not proven but compared")
            let fullPair = GLMUsageComparison.dailyPair(buckets:
                Array(repeating: bucket(10), count: 13) + [bucket(20)])
            try expect(fullPair.dayOnDay.text == "+100.0%" && fullPair.weekOnWeek.text == "+14.3%",
                       "dailyPair math wrong (20v10 day, 80v70 week)")
            try expect(fullPair.dayOnDay.isMuted == false && sparsePair.weekOnWeek.isMuted == true,
                       "comparison muted flag wrong")

            // 头部邮箱门禁（resolveAccountEmail 全集成路径，不读真实凭据）：
            // env 覆盖 / 单候选 / 多候选 / 无有效 OAuth → 一律隐藏；仅纯 OAuth 回退 + rawProfile.email 展示
            let userEmailJSON = #"{"id":"x","username":"User","displayName":"User","rawProfile":{"email":"User@Example.com"}}"#
            let userNameLikeJSON = #"{"id":"x","username":"user@example.com","displayName":"user@example.com","rawProfile":{"name":"user@example.com"}}"#
            let topLevelEmailJSON = #"{"id":"x","email":"user@example.com"}"#
            try expect(CredStore.resolveAccountEmail(envValue: "sk-key", credentialKeyCandidates: 0,
                       oauthAccessToken: "token", userInfoJSON: userEmailJSON) == nil,
                       "env key override still allowed email")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 1,
                       oauthAccessToken: "token", userInfoJSON: userEmailJSON) == nil,
                       "single api-key candidate was treated as same account")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 3,
                       oauthAccessToken: "token", userInfoJSON: userEmailJSON) == nil,
                       "multiple api-key candidates were treated as same account")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 0,
                       oauthAccessToken: nil, userInfoJSON: userEmailJSON) == nil,
                       "missing oauth token allowed email")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 0,
                       oauthAccessToken: "  ", userInfoJSON: userEmailJSON) == nil,
                       "blank oauth token allowed email")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 0,
                       oauthAccessToken: "token", userInfoJSON: nil) == nil,
                       "missing user_info allowed email")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 0,
                       oauthAccessToken: "token", userInfoJSON: userNameLikeJSON) == nil,
                       "username fallback email accepted without schema evidence")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 0,
                       oauthAccessToken: "token", userInfoJSON: topLevelEmailJSON) == nil,
                       "top-level email accepted without schema evidence")
            try expect(CredStore.resolveAccountEmail(envValue: nil, credentialKeyCandidates: 0,
                       oauthAccessToken: "token", userInfoJSON: userEmailJSON) == "user@example.com",
                       "pure oauth fallback with rawProfile.email wrongly hidden")
            try expect(CredStore.resolveAccountEmail(envValue: "", credentialKeyCandidates: 0,
                       oauthAccessToken: "token", userInfoJSON: userEmailJSON) == "user@example.com",
                       "blank env value wrongly treated as override")

            // 头部邮箱格式校验（读取路径不可得即整行隐藏，不在离线测试触碰真实凭据）
            try expect(CredStore.isValidEmail("user@example.com"), "valid email rejected")
            try expect(!CredStore.isValidEmail("not-an-email"), "invalid email accepted")
            try expect(!CredStore.isValidEmail("a@b"), "tld-less email accepted")
            try expect(!CredStore.isValidEmail("has space@example.com"), "spaced email accepted")
            try expect(!CredStore.isValidEmail(String(repeating: "a", count: 250) + "@example.com"),
                       "over-length email accepted")

            print("GlmUsage --self-test: PASS (strict quota/remote parsing, Start Plan SQLite/window/model/daily merge, partial windows, independent freshness, card expiry/retention, refresh gate/schedule, serialized callback merge, menubar alignment, update check release version compare/assets, daily timeline/frame/comparison fixtures, reset-card idempotency outcome/persistence)")
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
