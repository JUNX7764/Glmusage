import Foundation

struct GLMQuotaObservation: Codable, Equatable {
    let requestStartedAt: Date
    let observedAt: Date
    let limitCredits: Double
    let reportedUsedCredits: Double
    let remainingCredits: Double
    let resetAt: Date
    let planLevel: String?

    var usedPercent: Double { 100 * (limitCredits - remainingCredits) / limitCredits }
    var isValid: Bool {
        [requestStartedAt, observedAt, resetAt].allSatisfy { $0.timeIntervalSince1970.isFinite }
        && requestStartedAt <= observedAt && resetAt.timeIntervalSince1970 > 0
        && limitCredits.isFinite && limitCredits > 0
        && reportedUsedCredits.isFinite && reportedUsedCredits >= 0
        && remainingCredits.isFinite && (0...limitCredits).contains(remainingCredits)
    }
}

enum GLMQuotaCycleStart: String, Codable { case firstObserved, observedTransition, redeemed, afterGap, specificationChanged }
enum GLMQuotaCycleEnd: String, Codable { case natural, redeemed, unknownChange, gap, specificationChanged }

struct GLMQuotaCycleRecord: Codable, Equatable {
    let id: UUID
    let startKind: GLMQuotaCycleStart
    let firstObservedAt: Date
    let expectedResetAt: Date
    var lastObservation: GLMQuotaObservation
    var knownPlanLevel: String?
    var end: GLMQuotaCycleEnd?
    var boundaryLower: Date?
    var boundaryUpper: Date?
    var rollbackEvidence: [GLMQuotaObservation] = []
    init(_ observation: GLMQuotaObservation, startKind: GLMQuotaCycleStart) {
        id = UUID(); self.startKind = startKind
        firstObservedAt = observation.observedAt
        expectedResetAt = observation.resetAt
        lastObservation = observation
        knownPlanLevel = observation.planLevel.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct GLMQuotaCyclePolicy {
    var resetJitter: TimeInterval = 2
    var meaningfulDropPP: Double = 1
    var confirmationMinDelay: TimeInterval = 10
    var confirmationMaxDelay: TimeInterval = 180
    var maximumContinuousGap: TimeInterval = 15 * 60
    var heartbeatInterval: TimeInterval = 5 * 60
}

struct GLMQuotaCycleCandidate: Codable, Equatable {
    let baselineID: UUID
    let first: GLMQuotaObservation
    let reason: GLMQuotaCycleEnd?
}

enum GLMQuotaOperationResult: String, Codable { case requested, confirmedUsed, unknown, rejected }
struct GLMQuotaOperationEvidence: Codable, Equatable {
    let operationHash: String
    let originalRequestedAt: Date
    let responseAt: Date?
    let isWeek: Bool
    let result: GLMQuotaOperationResult
    let baselineCycleID: UUID?
    // The proof is deliberately excluded from persisted JSON and is lost on restart.
    let attributionProven: Bool
    enum CodingKeys: String, CodingKey { case operationHash, originalRequestedAt, responseAt, isWeek, result, baselineCycleID }
    init(operationHash: String, originalRequestedAt: Date, responseAt: Date?, isWeek: Bool, result: GLMQuotaOperationResult, baselineCycleID: UUID?, attributionProven: Bool) {
        self.operationHash = operationHash; self.originalRequestedAt = originalRequestedAt
        self.responseAt = responseAt; self.isWeek = isWeek; self.result = result
        self.baselineCycleID = baselineCycleID; self.attributionProven = attributionProven
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationHash = try c.decode(String.self, forKey: .operationHash)
        originalRequestedAt = try c.decode(Date.self, forKey: .originalRequestedAt)
        responseAt = try c.decodeIfPresent(Date.self, forKey: .responseAt)
        isWeek = try c.decode(Bool.self, forKey: .isWeek)
        result = try c.decode(GLMQuotaOperationResult.self, forKey: .result)
        baselineCycleID = try c.decodeIfPresent(UUID.self, forKey: .baselineCycleID)
        attributionProven = false
    }
}

struct GLMQuotaCycleState: Codable, Equatable {
    var schemaVersion = 1
    var closed: [GLMQuotaCycleRecord] = []
    var current: GLMQuotaCycleRecord?
    var pending: GLMQuotaCycleCandidate?
    var operations: [String: GLMQuotaOperationEvidence] = [:]
    var lastRequestStartedAt: Date?
    var lastAcceptedObservedAt: Date?
}

struct GLMQuotaCycleReducer {
    let policy: GLMQuotaCyclePolicy
    func record(_ evidence: GLMQuotaOperationEvidence, into state: inout GLMQuotaCycleState) {
        guard evidence.operationHash.count == 64,
              evidence.operationHash.allSatisfy({ "0123456789abcdef".contains($0) }),
              evidence.originalRequestedAt.timeIntervalSince1970.isFinite,
              (evidence.result != .confirmedUsed || evidence.responseAt != nil),
              evidence.responseAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= evidence.originalRequestedAt }) ?? true else { return }
        let knownBaseline = evidence.baselineCycleID.flatMap { id in
            (state.closed.contains { $0.id == id } || state.current?.id == id) ? id : nil
        }
        let evidence = GLMQuotaOperationEvidence(operationHash: evidence.operationHash,
            originalRequestedAt: evidence.originalRequestedAt, responseAt: evidence.responseAt,
            isWeek: evidence.isWeek, result: evidence.result, baselineCycleID: knownBaseline,
            attributionProven: evidence.attributionProven && knownBaseline != nil)
        if let old = state.operations[evidence.operationHash] {
            guard old.result != .confirmedUsed else { return }
            if evidence.result == .requested && old.result != .requested { return }
            if old.result == .rejected && evidence.result != .confirmedUsed { return }
            guard old.originalRequestedAt == evidence.originalRequestedAt && old.isWeek == evidence.isWeek else { return }
            state.operations[evidence.operationHash] = GLMQuotaOperationEvidence(
                operationHash: old.operationHash, originalRequestedAt: old.originalRequestedAt,
                responseAt: evidence.responseAt, isWeek: old.isWeek, result: evidence.result,
                baselineCycleID: old.baselineCycleID,
                attributionProven: old.attributionProven && evidence.attributionProven)
            return
        }
        state.operations[evidence.operationHash] = evidence
    }
    func ingest(_ sample: GLMQuotaObservation, into state: inout GLMQuotaCycleState) {
        guard sample.isValid else { return }
        guard state.lastRequestStartedAt.map({ sample.requestStartedAt > $0 }) ?? true else { return }
        guard state.current.map({ sample.observedAt >= $0.lastObservation.observedAt }) ?? true,
              state.lastAcceptedObservedAt.map({ sample.observedAt >= $0 }) ?? true else { return }
        let previousAcceptedAt = state.lastAcceptedObservedAt
        state.lastRequestStartedAt = sample.requestStartedAt
        state.lastAcceptedObservedAt = sample.observedAt
        guard var current = state.current else {
            state.current = GLMQuotaCycleRecord(sample, startKind: .firstObserved)
            return
        }
        let last = current.lastObservation
        let sampleLevel = sample.planLevel.flatMap { $0.isEmpty ? nil : $0 }
        let levelChanged = current.knownPlanLevel != nil && sampleLevel != nil && current.knownPlanLevel != sampleLevel
        let specificationChanged = sample.limitCredits != last.limitCredits || levelChanged
        let resetDelta = sample.resetAt.timeIntervalSince(current.expectedResetAt)
        let resetChanged = abs(resetDelta) > policy.resetJitter
        let continuesGapCandidate = state.pending.map {
            $0.reason == .gap && abs(sample.resetAt.timeIntervalSince($0.first.resetAt)) <= policy.resetJitter
        } ?? false
        let gap = continuesGapCandidate || sample.observedAt.timeIntervalSince(previousAcceptedAt ?? last.observedAt) > policy.maximumContinuousGap
        let drop = last.usedPercent - sample.usedPercent >= policy.meaningfulDropPP
        let reason: GLMQuotaCycleEnd?
        if specificationChanged { reason = .specificationChanged }
        else if resetChanged && gap { reason = .gap }
        else if (resetChanged || drop), state.operations.values.contains(where: {
            $0.isWeek && $0.result == .confirmedUsed && $0.attributionProven &&
            $0.baselineCycleID == current.id && $0.responseAt.map { sample.requestStartedAt >= $0 } == true
        }) { reason = .redeemed }
        else if resetDelta > policy.resetJitter && sample.observedAt >= current.expectedResetAt { reason = .natural }
        else if resetDelta > policy.resetJitter && drop { reason = .unknownChange }
        else { reason = nil }

        if let reason {
            if let pending = state.pending,
               pending.baselineID == current.id, pending.reason == reason,
               abs(sample.resetAt.timeIntervalSince(pending.first.resetAt)) <= policy.resetJitter,
               sample.limitCredits == pending.first.limitCredits,
               sample.planLevel == pending.first.planLevel {
                let delay = sample.requestStartedAt.timeIntervalSince(pending.first.requestStartedAt)
                if delay >= policy.confirmationMinDelay && delay <= policy.confirmationMaxDelay {
                    current.end = reason
                    current.boundaryLower = last.observedAt
                    current.boundaryUpper = pending.first.observedAt
                    state.closed.append(current)
                    let kind: GLMQuotaCycleStart = reason == .gap ? .afterGap :
                        reason == .specificationChanged ? .specificationChanged : reason == .redeemed ? .redeemed : .observedTransition
                    var next = GLMQuotaCycleRecord(pending.first, startKind: kind)
                    next.lastObservation = sample
                    if let sampleLevel { next.knownPlanLevel = sampleLevel }
                    state.current = next
                    state.pending = nil
                } else if delay > policy.confirmationMaxDelay {
                    state.pending = GLMQuotaCycleCandidate(baselineID: current.id, first: sample, reason: reason)
                }
            } else {
                state.pending = GLMQuotaCycleCandidate(baselineID: current.id, first: sample, reason: reason)
            }
            return
        }
        if resetChanged || sample.remainingCredits > last.remainingCredits {
            if state.pending?.reason != nil || state.pending.map({ abs($0.first.resetAt.timeIntervalSince(sample.resetAt)) > policy.resetJitter }) != false {
                if let candidate = state.pending,
                   !current.rollbackEvidence.contains(where: {
                       $0.resetAt == candidate.first.resetAt && $0.remainingCredits == candidate.first.remainingCredits &&
                       $0.limitCredits == candidate.first.limitCredits && $0.planLevel == candidate.first.planLevel
                   }) {
                    current.rollbackEvidence.append(candidate.first)
                    state.current = current
                }
                state.pending = GLMQuotaCycleCandidate(baselineID: current.id, first: sample, reason: nil)
            }
            return
        }
        if !resetChanged && !specificationChanged {
            if let candidate = state.pending,
               !current.rollbackEvidence.contains(where: {
                   $0.resetAt == candidate.first.resetAt && $0.remainingCredits == candidate.first.remainingCredits &&
                   $0.limitCredits == candidate.first.limitCredits && $0.planLevel == candidate.first.planLevel
               }) {
                current.rollbackEvidence.append(candidate.first)
            }
            state.pending = nil
            if sample.remainingCredits <= last.remainingCredits {
                current.lastObservation = sample
                if let sampleLevel { current.knownPlanLevel = sampleLevel }
            }
            state.current = current
        }
    }
}

struct GLMQuotaHistoryBrowser {
    var loadedLimit = 12
    var selectedCycleID: UUID?
    var pageAnchorID: UUID? // nil means follow the latest page
    let pageSize = 6

    func visibleRange(_ records: [GLMQuotaCycleRecord]) -> Range<Int> {
        let upper = pageAnchorID.flatMap { id in records.firstIndex { $0.id == id }.map { $0 + 1 } } ?? records.count
        return max(0, upper - pageSize)..<upper
    }
    mutating func pageOlder(_ records: [GLMQuotaCycleRecord]) {
        let range = visibleRange(records)
        let loadedStart = max(0, records.count - loadedLimit)
        guard range.lowerBound > loadedStart else { return }
        pageAnchorID = records[range.lowerBound - 1].id
    }
    mutating func pageNewer(_ records: [GLMQuotaCycleRecord]) {
        let upper = visibleRange(records).upperBound
        let next = min(records.count, upper + pageSize)
        pageAnchorID = next == records.count ? nil : records[next - 1].id
    }
    mutating func loadEarlier() { loadedLimit += 12 }
    mutating func select(_ id: UUID) { selectedCycleID = id }
    mutating func move(_ direction: Int, records: [GLMQuotaCycleRecord]) {
        guard !records.isEmpty else { return }
        let current = selectedCycleID.flatMap { id in records.firstIndex { $0.id == id } } ?? records.count - 1
        let target = min(records.count - 1, max(max(0, records.count - loadedLimit), current + (direction < 0 ? -1 : 1)))
        selectedCycleID = records[target].id
        let range = visibleRange(records)
        if target < range.lowerBound { pageAnchorID = records[range.lowerBound - 1].id }
        else if target >= range.upperBound {
            let upper = min(records.count, range.upperBound + pageSize)
            pageAnchorID = upper == records.count ? nil : records[upper - 1].id
        }
    }
}

enum GLMQuotaCycleDetails {
    // 展示用 formatter 静态缓存：柱图每帧逐列取日期标签、悬停/选择重建明细行，
    // 新建 DateFormatter/NumberFormatter 开销大（与主文件 Fmt 同一口径；仅主线程使用）。
    private static let daySlash: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd"
        return f
    }()
    private static let zhDaySlash: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "MM/dd"
        return f
    }()
    private static let fullLocal: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateStyle = .medium; f.timeStyle = .medium
        return f
    }()
    private static let groupedNumber: NumberFormatter = {
        let n = NumberFormatter(); n.locale = Locale(identifier: "en_US"); n.numberStyle = .decimal; n.maximumFractionDigits = 2
        return n
    }()

    // A presentation-only estimate; the stored first observation and boundary evidence stay intact.
    static func displayedStart(_ record: GLMQuotaCycleRecord) -> Date {
        record.startKind == .firstObserved ? record.expectedResetAt.addingTimeInterval(-7 * 86400) : record.firstObservedAt
    }
    static func dateLabel(_ record: GLMQuotaCycleRecord) -> String {
        (record.startKind == .firstObserved ? "~" : "") + daySlash.string(from: displayedStart(record))
    }
    static func startExplanation(_ record: GLMQuotaCycleRecord) -> String {
        let first = "首次成功观测：" + fullLocal.string(from: record.firstObservedAt)
        return record.startKind == .firstObserved
            ? "起点按预计重置时间减7天推算，实际开始时刻未知，不代表完整记录了7天；" + first
            : "开始边界基于观测，非服务端准确时刻；" + first
    }
    static func lines(_ record: GLMQuotaCycleRecord) -> (String, String) {
        let prefix: String
        switch record.startKind {
        case .firstObserved: prefix = "推算"
        case .afterGap, .specificationChanged: prefix = "观测"
        case .observedTransition, .redeemed: prefix = "约"
        }
        let start = prefix + zhDaySlash.string(from: displayedStart(record))
        let reason: String
        switch record.end {
        case .natural: reason = "正常到期"
        case .redeemed: reason = "主动用周卡"
        case .unknownChange: reason = "额度窗口变化（原因未确认）"
        case .gap: reason = "观测缺口"
        case .specificationChanged: reason = "额度规格变化"
        case nil: reason = "进行中"
        }
        let period: String
        if record.end == nil {
            period = "\(start)–至今（预计\(zhDaySlash.string(from: record.expectedResetAt))）"
        } else {
            let end = record.end == .natural ? record.expectedResetAt : record.boundaryUpper ?? record.lastObservation.observedAt
            period = "\(start)–\(zhDaySlash.string(from: end))（约）"
        }
        let obs = record.lastObservation
        let remaining = groupedNumber.string(from: NSNumber(value: obs.remainingCredits)) ?? "—"
        let limit = groupedNumber.string(from: NSNumber(value: obs.limitCredits)) ?? "—"
        let percent = groupedNumber.string(from: NSNumber(value: obs.usedPercent)) ?? "—"
        let label = record.end == nil ? "当前剩余" : "最后观测剩余"
        let full = obs.remainingCredits == 0 ? " · 已用满（观测余额为 0）" : ""
        return ("\(period) · \(reason)", "已用 \(percent)% · \(label) \(remaining) / \(limit) 积分\(full)")
    }
}
