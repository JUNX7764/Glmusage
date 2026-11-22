import Foundation

// MARK: - 面板内容快照（L1 无变化跳过重建 / L2 逐卡增量的比较基准）
//
// 口径（2026-11-21 面板性能加固）：
// - 快照字段 = buildPanel 实际渲染的最终展示值：原始 Date 一律先转成展示字符串
//   （Fmt 系列，分钟粒度），连续比例量化为档位（进度条 0.5%、颜色带取整百分比），
//   保证「快照相等 ⇔ 渲染内容相等」。分钟粒度意味着 lastOK/重置时间等至多每分钟
//   产生一次可感知差异，不会让 10s 刷新把快照每轮都打脏。
// - 全部显式字段 + Equatable；禁止 String(reflecting:) 深比较。
// - 结构层字段（卡片显隐/排序、设置页、更新横幅/进度行/按钮、恢复入口、展开收起、
//   周期切换）单独归类：任一变化必须整棵重建，不走逐卡短路（containsStructuralChange）。
// - 所有子结构字段带默认值：memberwise 空初始化即可构造基线，供 --self-test 等价性断言。

struct GLMPanelSnapshot: Equatable {

    // MARK: 结构层（任一变化 → 整棵重建）

    /// 展开收起与周期切换：行数结构变化，全量重建语义
    struct Structure: Equatable {
        var tokenExpanded = true
        var modelExpandedWindows: Set<Int> = []
        var mcpExpanded = true
        var dailyExpanded = true
        var historyExpanded = true
        var speedExpanded = true
        var cacheExpanded = true
        var speedPeriod = GLMLocalModelStats.Period.sevenDays
        var cachePeriod = GLMLocalModelStats.Period.sevenDays
    }

    struct Confirmation: Equatable {
        var tag: String
        var notes: String
    }

    var layout = GLMPanelLayout.default
    var showingCardSettings = false
    var updateProgressActive = false
    var updateConfirmation: Confirmation?
    var updateButtonVisible = false
    var recoveryAction: GLMConnectionRecovery.Action = .none
    var structure = Structure()

    // MARK: 头部 / 底部（局部更新单元）

    var planTier: GLMPlanTier = .unknown
    var planPillTooltip: String?
    var accountEmail: String?
    var lastAttemptText = ""
    var updateMessage: String?
    // 底栏单行化（2026-11-22）：quotaLastOKText = 主额度（7 天窗口）成功时间展示文案，
    // 空串 = 无数据（底栏显示「—」）；refreshInFlight 仅手动刷新在飞为 true，
    // 自动 10s 轮询不置位。失败信号复用 quota.week.errorLine（含「最后成功」原文）。
    var quotaLastOKText = ""
    var refreshInFlight = false

    // MARK: 额度卡（用量进度）

    struct QuotaCard: Equatable {
        struct Window: Equatable {
            var percentText = "--"
            var bandPercent = -1              // 颜色档判别值：Int((remaining*100).rounded())，与 GLMRemainingColor.color 同判据
            var barFill: Int?                 // 进度条填充 0…200（0.5% 量化）；nil = 无数据不画
            var resetText = "时间未知"
            var remainingLine: String?        // nil = 「暂无数据」
            var errorLine: String?
            var warningLine: String?
            var staleLine: String?
            var lastOKLine: String?           // 连接恢复期的「上次更新」
        }
        var fiveHour = Window()
        var week = Window()
        var subscriptionLine: String?
        var subscriptionErrorLine: String?
        var subscriptionStaleLine: String?
    }

    // MARK: 峰谷卡

    struct PeakCard: Equatable {
        var isPeak = false
        var badge = ""
        var discount = ""
        var nextLabel = ""
        var nextTime = ""
    }

    // MARK: 重置卡卡

    struct ResetCardsCard: Equatable {
        struct Row: Equatable {
            var name: String
            var detail: String
            var warning: Bool
        }
        var loginUnsupported = false
        var countText: String?
        var emptyText: String?                // 登录态不支持 / 暂无数据 的整行文案
        var rows: [Row] = []
        var errorLines: [String] = []
        var useButtonEnabled = true
    }

    // MARK: 用量情况卡

    struct UsageCard: Equatable {
        struct Model: Equatable {
            var name: String
            var tokensText: String
        }
        struct Window: Equatable {
            var totalTokensText = "--"
            var totalCallsText = "--"
            var models: [Model] = []
            var errorLine: String?
            var staleLine: String?
            var lastOKLine: String?
        }
        var today = Window()
        var sevenDays = Window()
        var thirtyDays = Window()
    }

    // MARK: 每日用量卡

    struct DailyCard: Equatable {
        var buckets: [GLMDayBucket]?
        var selectedIndex: Int?
        var pendingNote = false
    }

    // MARK: 额度周期回顾卡

    struct HistoryCard: Equatable {
        var records: [GLMQuotaCycleRecord] = []
        var browser = GLMQuotaHistoryBrowser()
        var pending = false
        var status: String?
    }

    // MARK: MCP 工具卡

    struct MCPCard: Equatable {
        var contentLine: String?              // nil = 收起（展开收起走结构层，此处冗余记录便于核对）
        var errorLine: String?
        var staleLine: String?
        var lastOKLine: String?
    }

    // MARK: 模型速度 / 缓存命中卡

    struct StatsCard: Equatable {
        var period = GLMLocalModelStats.Period.sevenDays
        var errorLine: String?
        var contentLine: String?              // 空窗口文案（「今日样本不足」等）
        var rows: [Row] = []
        struct Row: Equatable {
            var name: String
            var statA: String
            var statB: String
        }
    }

    var quota = QuotaCard()
    var peak = PeakCard()
    var resetCards = ResetCardsCard()
    var usage = UsageCard()
    var daily = DailyCard()
    var history = HistoryCard()
    var mcp = MCPCard()
    var speed = StatsCard()
    var cache = StatsCard()

    // MARK: 渲染判别值（快照构造与 --self-test 共用同一公式）

    /// 额度余量的量化判别值：band = 颜色档取整百分比（GLMRemainingColor.color 判据），
    /// fill = 进度条填充 0…200（0.5% 量化，亚档位漂移视为同一画面）。
    static func quantizedRatio(_ remaining: Double) -> (band: Int, fill: Int) {
        (Int((remaining * 100).rounded()), Int((max(0, min(1, remaining)) * 200).rounded()))
    }

    // MARK: 分类比较

    /// 结构性变化：布局/设置页/横幅/进度行/更新按钮/恢复入口/展开收起/周期切换。
    /// 任一成立必须整棵重建，不得逐卡短路。
    func containsStructuralChange(to other: GLMPanelSnapshot) -> Bool {
        layout != other.layout
            || showingCardSettings != other.showingCardSettings
            || updateProgressActive != other.updateProgressActive
            || updateConfirmation != other.updateConfirmation
            || updateButtonVisible != other.updateButtonVisible
            || recoveryAction != other.recoveryAction
            || structure != other.structure
    }

    /// 指定卡的内容子快照是否变化（逐卡增量更新单位）
    func cardDiffers(from other: GLMPanelSnapshot, id: GLMPanelCardID) -> Bool {
        switch id {
        case .quota: return quota != other.quota
        case .peak: return peak != other.peak
        case .resetCards: return resetCards != other.resetCards
        case .usage: return usage != other.usage
        case .daily: return daily != other.daily
        case .history: return history != other.history
        case .mcp: return mcp != other.mcp
        case .speed: return speed != other.speed
        case .cache: return cache != other.cache
        }
    }
}

// GLMQuotaHistoryBrowser 已在 GLMQuotaCycleHistory.swift 声明 Equatable（同模块合成）。
