import Foundation

/// status.json 写盘器（运行状态自诊断文件；内容只有渲染行/剩余比例/错误文案/时间戳，无凭据）。
///
/// 2026-11-21 写盘加固（原实现：updateUI 每 10s 主线程同步写盘，仅 1s 限频、`data.write` 无 .atomic）：
/// - 主线程只构造不可变快照并提交；序列化、去重判定与落盘全部在专用串行队列。
///   上一轮写盘进行中到来的新快照合并为「待写最新快照」（pending 单槽覆盖 + 单排空块），不排队多次。
/// - 原子写（.atomic），读侧不会看到半截 JSON；写失败保留旧文件与旧时间戳（与旧 `try?` 行为
///   一致，不崩溃），下一次提交按原内容重试。
/// - 内容去重 + 60s 心跳：比对「规范化 payload」——剔除 updatedAt/lastAttemptAt 两个逐周期
///   时间戳字段（实测 lastAttemptAt 在 performQuotaRefresh 每 10s 额度刷新都会更新，见
///   GlmUsage.swift），按 sortedKeys 稳定序列化后与上次成功写盘内容逐字节比对；相同且距
///   上次成功写盘 <60s → 跳过。距上次成功写盘 ≥60s 强制心跳写一次（以最新快照刷新时间戳
///   字段与文件 mtime）。活性信号保留：部署验收靠 status.json 的 updatedAt/文件 mtime 确认
///   进程存活；稳态写盘从 ~8640 次/天降到 ~1440 次/天 + 变化驱动。
final class GLMStatusWriter {
    /// 一次待写快照：payload 已含 updatedAt/lastAttemptAt，由调用方（主线程）构造，提交后不可变。
    struct Snapshot {
        let payload: [String: Any]
    }

    /// 去重比对剔除的「逐周期时间戳」字段：每轮刷新必变，不代表诊断内容变化；
    /// 真实写盘（变化驱动/心跳）时以最新快照值刷新到文件。
    static let writeMomentKeys: Set<String> = ["updatedAt", "lastAttemptAt"]

    private let directory: String
    private let fileName: String
    private let heartbeatInterval: TimeInterval
    private let clock: () -> Date
    private let performWrite: (Data, URL, Data.WritingOptions) throws -> Void
    private let serialQueue: DispatchQueue

    // 以下状态仅在 serialQueue 上访问
    private var pending: Snapshot?
    private var flushScheduled = false
    private var lastWrittenNormalized: Data?
    private var lastWriteAt: Date?

    /// - Parameters:
    ///   - directory: status.json 所在目录（不存在时写盘前自动创建）。
    ///   - heartbeatInterval: 距上次成功写盘超过该秒数后，即使内容未变也强制心跳写一次。
    ///   - clock: 队列内取「当前时刻」；self-test 注入固定时钟做确定性验证。
    ///   - performWrite: 实际落盘；self-test 注入记录/抛错实现验证 .atomic 与异常路径。
    init(directory: String,
         fileName: String = "status.json",
         heartbeatInterval: TimeInterval = 60,
         queue: DispatchQueue = DispatchQueue(label: "GlmUsage.status-writer"),
         clock: @escaping () -> Date = { Date() },
         performWrite: @escaping (Data, URL, Data.WritingOptions) throws -> Void = { data, url, options in
             try data.write(to: url, options: options)
         }) {
        self.directory = directory
        self.fileName = fileName
        self.heartbeatInterval = heartbeatInterval
        self.serialQueue = queue
        self.clock = clock
        self.performWrite = performWrite
    }

    /// 主线程入口：只登记最新快照并确保有一个排空块在队列上；不序列化、不触盘、不阻塞。
    func submit(_ snapshot: Snapshot) {
        serialQueue.async { [weak self] in
            guard let self else { return }
            self.pending = snapshot
            guard !self.flushScheduled else { return }   // 已有排空块会带走 pending，不重复排块
            self.flushScheduled = true
            self.serialQueue.async { [weak self] in self?.flush() }
        }
    }

    /// 等待队列排空（无 pending 且无已排期的排空块）。生产路径仅退出前调用一次；
    /// self-test 用它在提交后做确定性等待——注意不能直接 `queue.sync`：排空块是在
    /// 提交块内异步排期的，sync 屏障可能排在它之前。
    func waitForIdle(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if serialQueue.sync(execute: { self.pending == nil && !self.flushScheduled }) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// 排空 pending（仅 serialQueue）：写盘中新提交的快照在下一轮循环带走，队列上永远不积压多次写盘。
    private func flush() {
        flushScheduled = false
        while let snapshot = pending {
            pending = nil
            writeOnce(snapshot)
        }
    }

    private func writeOnce(_ snapshot: Snapshot) {
        let now = clock()
        guard let normalized = Self.normalizedData(of: snapshot.payload) else { return }   // 序列化失败不写（与旧 try? 一致）
        if let last = lastWrittenNormalized, normalized == last,
           let lastWrite = lastWriteAt, now.timeIntervalSince(lastWrite) < heartbeatInterval {
            return   // 内容未变且心跳窗口内：跳过（文件保持上次成功写盘的时间戳/mtime）
        }
        do {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: snapshot.payload,
                                                  options: [.prettyPrinted, .sortedKeys])
            try performWrite(data, URL(fileURLWithPath: directory + "/" + fileName), [.atomic])
            lastWrittenNormalized = normalized
            lastWriteAt = now
        } catch {
            // 写失败静默保留旧文件（不崩，与旧 try? 行为一致）；指纹/心跳时刻不更新，下次提交重试
        }
    }

    /// 规范化 payload：剔除逐周期时间戳字段后按 sortedKeys 稳定序列化，作为去重指纹。
    static func normalizedData(of payload: [String: Any]) -> Data? {
        var normalized = payload
        for key in writeMomentKeys { normalized.removeValue(forKey: key) }
        return try? JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
    }
}
