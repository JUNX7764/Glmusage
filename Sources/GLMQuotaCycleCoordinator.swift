import Foundation

struct GLMQuotaCycleSnapshot: Equatable {
    let state: GLMQuotaCycleState
    let isVolatile: Bool
    let isProtected: Bool
    let isUnsaved: Bool
    var isLoading: Bool = false
}

final class GLMQuotaCycleCoordinator {
    private final class Entry {
        var state = GLMQuotaCycleState()
        var isProtected = false
        var isUnsaved = false
        var lastSavedAt: Date?
        let context: GLMQuotaHistoryContext
        init(_ context: GLMQuotaHistoryContext) { self.context = context }
    }
    private let queue = DispatchQueue(label: "glm.quota-cycle-history")
    private let lock = NSLock()
    private let deliveryQueue: DispatchQueue
    private let deliver: (GLMQuotaCycleSnapshot) -> Void
    private let store: GLMQuotaCycleStore
    private let loader: ((String) throws -> GLMQuotaCycleState)?
    private let reducer = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    private var currentContext: GLMQuotaHistoryContext?
    private var activation: UInt64 = 0
    private var epoch: UInt64 = 0
    // These fields are confined to queue. Persistent partitions can be reused on A→B→A.
    private var entries: [String: Entry] = [:]
    private var activations: [UInt64: Entry] = [:]

    init(root: URL, writer: @escaping GLMQuotaCycleStore.Writer = GLMQuotaCycleStore.writePrivateJSON,
         loader: ((String) throws -> GLMQuotaCycleState)? = nil, deliveryQueue: DispatchQueue = .main, deliver: @escaping (GLMQuotaCycleSnapshot) -> Void) {
        store = GLMQuotaCycleStore(root: root, writer: writer)
        self.loader = loader
        self.deliveryQueue = deliveryQueue; self.deliver = deliver
    }
    func activate(_ context: GLMQuotaHistoryContext?) {
        lock.lock(); activation &+= 1; epoch = 0
        let generation = activation; currentContext = context; lock.unlock()
        queue.async {
            guard let context else { return }
            let key = context.partition ?? "session-\(generation)"
            let entry: Entry
            if let existing = self.entries[key] { entry = existing }
            else {
                entry = Entry(context)
                if let partition = context.partition {
                    do { entry.state = try self.loader?(partition) ?? self.store.load(partition: partition) }
                    catch { entry.isProtected = true }
                }
                self.entries[key] = entry
            }
            self.activations[generation] = entry
            self.publish(entry, generation: generation)
        }
    }
    func capture(requestStartedAt: Date) -> GLMQuotaCaptureToken? {
        lock.lock(); defer { lock.unlock() }
        guard let context = currentContext else { return nil }
        return GLMQuotaCaptureToken(context: context, activation: activation, epoch: epoch, requestStartedAt: requestStartedAt)
    }
    func advanceEpoch() {
        lock.lock(); epoch &+= 1; lock.unlock()
    }
    @discardableResult
    func advanceEpoch(ifCurrent token: GLMQuotaCaptureToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard currentContext == token.context && activation == token.activation else { return false }
        epoch &+= 1
        return true
    }
    private func isCurrent(_ token: GLMQuotaCaptureToken, includeEpoch: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return currentContext == token.context && activation == token.activation && (!includeEpoch || epoch == token.epoch)
    }
    func observe(_ sample: GLMQuotaObservation, token: GLMQuotaCaptureToken) {
        queue.async {
            guard self.isCurrent(token), sample.requestStartedAt == token.requestStartedAt,
                  let entry = self.activations[token.activation] else { return }
            let old = entry.state
            self.reducer.ingest(sample, into: &entry.state)
            guard entry.state != old else { return }
            let previousUnsaved = entry.isUnsaved, previousProtected = entry.isProtected
            self.persist(entry, previous: old, observedAt: sample.observedAt)
            if self.hasSemanticChange(previous: old, next: entry.state) ||
                previousUnsaved != entry.isUnsaved || previousProtected != entry.isProtected {
                self.publish(entry, generation: token.activation)
            }
        }
    }
    func record(_ evidence: GLMQuotaOperationEvidence, token: GLMQuotaCaptureToken) {
        queue.async {
            guard let entry = self.activations[token.activation] else { return }
            let current = self.isCurrent(token, includeEpoch: false)
            let safe = GLMQuotaOperationEvidence(operationHash: evidence.operationHash,
                originalRequestedAt: evidence.originalRequestedAt, responseAt: evidence.responseAt,
                isWeek: evidence.isWeek, result: evidence.result, baselineCycleID: evidence.baselineCycleID,
                attributionProven: evidence.attributionProven && current && token.context.mode == .oauth)
            let old = entry.state
            self.reducer.record(safe, into: &entry.state)
            guard entry.state != old else { return }
            self.persist(entry, previous: old, observedAt: evidence.responseAt ?? evidence.originalRequestedAt, force: true)
            if current { self.publish(entry, generation: token.activation) }
        }
    }
    private func semanticObservation(_ o: GLMQuotaObservation?) -> [String] {
        guard let o else { return [] }
        return [String(o.limitCredits), String(o.reportedUsedCredits), String(o.remainingCredits),
                String(o.resetAt.timeIntervalSince1970), o.planLevel ?? ""]
    }
    private func hasSemanticChange(previous: GLMQuotaCycleState, next: GLMQuotaCycleState) -> Bool {
        previous.closed != next.closed || previous.pending != next.pending ||
            previous.operations != next.operations || previous.current?.id != next.current?.id ||
            semanticObservation(previous.current?.lastObservation) != semanticObservation(next.current?.lastObservation)
    }
    private func persist(_ entry: Entry, previous: GLMQuotaCycleState, observedAt: Date, force: Bool = false) {
        guard let partition = entry.context.partition, !entry.isProtected else { return }
        guard force || hasSemanticChange(previous: previous, next: entry.state) || entry.isUnsaved || entry.lastSavedAt.map({ observedAt.timeIntervalSince($0) >= 300 }) ?? true else { return }
        do { try store.save(entry.state, partition: partition); entry.isUnsaved = false; entry.lastSavedAt = observedAt }
        catch {
            if store.isProtected(partition: partition) { entry.isProtected = true; entry.isUnsaved = false }
            else { entry.isUnsaved = true }
        }
    }
    private func publish(_ entry: Entry, generation: UInt64) {
        let snapshot = GLMQuotaCycleSnapshot(state: entry.state, isVolatile: entry.context.partition == nil,
                                              isProtected: entry.isProtected, isUnsaved: entry.isUnsaved)
        deliveryQueue.async {
            self.lock.lock(); let isCurrent = self.activation == generation; self.lock.unlock()
            if isCurrent { self.deliver(snapshot) }
        }
    }
    // Deterministic harness hooks; never call from the coordinator queue.
    func drain() { queue.sync {} }
    func testCurrentState() -> GLMQuotaCycleState? {
        lock.lock(); let generation = activation; lock.unlock()
        return queue.sync { activations[generation]?.state }
    }
}
