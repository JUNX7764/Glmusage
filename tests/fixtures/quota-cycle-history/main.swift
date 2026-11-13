import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let t = Date(timeIntervalSince1970: 1_800_000_000)
func sample(_ seconds: Double, _ remaining: Double, _ reset: Double = 604800,
            _ limit: Double = 10000) -> GLMQuotaObservation {
    GLMQuotaObservation(requestStartedAt: t.addingTimeInterval(seconds - 1),
        observedAt: t.addingTimeInterval(seconds), limitCredits: limit,
        reportedUsedCredits: limit - remaining, remainingCredits: remaining,
        resetAt: t.addingTimeInterval(reset), planLevel: "PRO")
}
switch CommandLine.arguments.dropFirst().first {
case "firstObservation":
    var state = GLMQuotaCycleState()
    let reducer = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    reducer.ingest(sample(0, 5700), into: &state)
    check(state.closed.isEmpty, "must not fabricate old rounds")
    check(state.current?.startKind == .firstObserved, "start is unknown")
    check(state.current?.lastObservation.remainingCredits == 5700, "keep credits")
    check(state.current?.lastObservation.usedPercent == 43, "derive percentage")
    print("PASS: firstObservation")
case "sameWindow":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 5700), into: &state)
    let id = state.current!.id
    r.ingest(sample(10, 5600, 604802), into: &state)
    check(state.current?.id == id && state.current?.lastObservation.remainingCredits == 5600, "jitter updates same window")
    r.ingest(sample(10, 5500), into: &state)
    r.ingest(sample(20, -1), into: &state)
    r.ingest(sample(30, .nan), into: &state)
    check(state.current?.lastObservation.remainingCredits == 5600, "reject invalid and replay")
    let over = GLMQuotaObservation(requestStartedAt: t, observedAt: t, limitCredits: 10000, reportedUsedCredits: 12000, remainingCredits: 0, resetAt: t, planLevel: nil)
    check(over.isValid, "reported usage may exceed limit")
    check(sample(0, 40).usedPercent == 99.6, "rounding does not mean full")
    let nearlyFull = GLMQuotaCycleRecord(sample(0, 40), startKind: .firstObserved)
    let full = GLMQuotaCycleRecord(sample(0, 0), startKind: .firstObserved)
    check(!GLMQuotaCycleDetails.lines(nearlyFull).1.contains("已用满") && GLMQuotaCycleDetails.lines(full).1.contains("已用满"), "only zero balance is called full")
    print("PASS: sameWindow")
case "unknownChange":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &state)
    r.ingest(sample(100, 9800, 605800), into: &state)
    check(state.closed.isEmpty && state.pending != nil, "first observation is pending")
    r.ingest(sample(120, 9700, 605800), into: &state)
    check(state.closed.count == 1 && state.closed[0].end == .unknownChange, "confirmed unknown")
    check(state.closed[0].lastObservation.remainingCredits == 2800, "preserve prior observation")
    print("PASS: unknownChange")
case "naturalAndGap":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var a = GLMQuotaCycleState()
    r.ingest(sample(604790, 10000), into: &a)
    r.ingest(sample(604810, 10000, 1209600), into: &a)
    r.ingest(sample(604830, 10000, 1209600), into: &a)
    check(a.closed.count == 1 && a.closed[0].end == .natural, "natural zero to zero")
    var b = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &b)
    r.ingest(sample(604800*3, 9700, 604800*4), into: &b)
    r.ingest(sample(604800*3+20, 9600, 604800*4), into: &b)
    check(b.closed.count == 1 && b.closed[0].end == .gap, "gap must not fabricate weeks")
    print("PASS: naturalAndGap")
case "specificationChange":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &state)
    r.ingest(sample(100, 19000, 604800, 20000), into: &state)
    check(state.closed.isEmpty, "specification first sample pending")
    r.ingest(sample(120, 18900, 604800, 20000), into: &state)
    check(state.closed.count == 1 && state.closed[0].end == .specificationChanged, "confirmed specification change")
    print("PASS: specificationChange")
case "candidateTimeout":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &state)
    r.ingest(sample(100, 9800, 605800), into: &state)
    r.ingest(sample(100, 9800, 605800), into: &state)
    check(state.closed.isEmpty, "replay cannot confirm")
    r.ingest(sample(400, 9700, 605800), into: &state)
    check(state.closed.isEmpty, "expired candidate cannot confirm")
    r.ingest(sample(420, 9600, 605800), into: &state)
    check(state.closed.count == 1, "new candidate confirmed")
    print("PASS: candidateTimeout")
case "partitionAndAttribution":
    let a = GLMQuotaHistoryContext.apiKey("fixture-plan-a")
    let b = GLMQuotaHistoryContext.apiKey("fixture-plan-b")
    check(a.partition != b.partition && a.partition?.count == 64, "separate hashes")
    check(a.partition == GLMQuotaHistoryContext.apiKey("fixture-plan-a").partition, "stable hash")
    check(GLMQuotaHistoryContext.oauth.partition == nil, "oauth memory only")
    check(!a.mayAttributeReset(planCredential: "x", resetCredential: "x"), "API key never proof")
    check(GLMQuotaHistoryContext.oauth.mayAttributeReset(planCredential: "x", resetCredential: "x"), "same OAuth")
    check(!GLMQuotaHistoryContext.oauth.mayAttributeReset(planCredential: "x", resetCredential: "y"), "different token")
    print("PASS: partitionAndAttribution")
case "captureGate":
    let context = GLMQuotaHistoryContext.apiKey("fixture-plan-a")
    let a = GLMQuotaCaptureToken(context: context, activation: 1, epoch: 0, requestStartedAt: t)
    check(a.matches(context: context, activation: 1, epoch: 0), "matching token")
    check(!a.matches(context: context, activation: 3, epoch: 0), "A-B-A rejected")
    check(!a.matches(context: context, activation: 1, epoch: 1), "old epoch rejected")
    print("PASS: captureGate")
case "weekCardEvidence":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &state)
    let id = state.current!.id
    let op = GLMQuotaOperationEvidence(operationHash: String(repeating: "a", count: 64), originalRequestedAt: t.addingTimeInterval(50), responseAt: t.addingTimeInterval(60), isWeek: true, result: .confirmedUsed, baselineCycleID: id, attributionProven: true)
    r.record(op, into: &state)
    r.record(op, into: &state)
    check(state.operations.count == 1, "deduplicate")
    r.ingest(sample(70, 10000), into: &state)
    check(state.closed.isEmpty, "first sample not enough")
    r.ingest(sample(90, 9900), into: &state)
    check(state.closed.count == 1 && state.closed[0].end == .redeemed, "verified same-reset redemption")
    var unbound = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &unbound)
    let other = GLMQuotaOperationEvidence(operationHash: String(repeating: "b", count: 64), originalRequestedAt: t, responseAt: t, isWeek: true, result: .confirmedUsed, baselineCycleID: unbound.current!.id, attributionProven: false)
    r.record(other, into: &unbound)
    r.ingest(sample(70, 10000), into: &unbound)
    r.ingest(sample(90, 9900), into: &unbound)
    check(unbound.closed.isEmpty, "unbound operation cannot split same reset")
    print("PASS: weekCardEvidence")
case "restoredOperation":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &state)
    let event = GLMQuotaOperationEvidence(operationHash: String(repeating: "a", count: 64), originalRequestedAt: t, responseAt: t.addingTimeInterval(2), isWeek: true, result: .confirmedUsed, baselineCycleID: state.current!.id, attributionProven: true)
    r.record(event, into: &state)
    state = try! JSONDecoder().decode(GLMQuotaCycleState.self, from: JSONEncoder().encode(state))
    check(state.operations[event.operationHash]?.attributionProven == false, "proof not restored")
    r.ingest(sample(20, 10000), into: &state)
    r.ingest(sample(40, 9900), into: &state)
    check(state.closed.isEmpty, "restored proof cannot split")
    var five = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &five)
    let fiveHour = GLMQuotaOperationEvidence(operationHash: String(repeating: "c", count: 64), originalRequestedAt: t, responseAt: t.addingTimeInterval(2), isWeek: false, result: .confirmedUsed, baselineCycleID: five.current!.id, attributionProven: true)
    r.record(fiveHour, into: &five)
    r.ingest(sample(20, 10000), into: &five)
    r.ingest(sample(40, 9900), into: &five)
    check(five.closed.isEmpty, "five hour cannot split")
    print("PASS: restoredOperation")
case "storeSafety":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GLMQuotaCycleStore(root: root)
    let partition = String(repeating: "a", count: 64)
    var state = GLMQuotaCycleState()
    GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy()).ingest(sample(0, 2800), into: &state)
    try! store.save(state, partition: partition)
    let loaded = try! store.load(partition: partition)
    check(loaded == state, "round trip")
    let url = root.appendingPathComponent(partition).appendingPathComponent("history-v1.json")
    let attrs = try! FileManager.default.attributesOfItem(atPath: url.path)
    check((attrs[.posixPermissions] as! NSNumber).intValue == 0o600, "private file")
    let original = try! Data(contentsOf: url)
    let failing = GLMQuotaCycleStore(root: root, writer: { _, _ in throw NSError(domain: "fixture", code: 1) })
    do { try failing.save(state, partition: partition); check(false, "writer must fail") } catch { }
    check(try! Data(contentsOf: url) == original, "write failure preserves file")
    do { _ = try store.load(partition: "../escape"); check(false, "partition must reject traversal") } catch { }
    try! Data("{\"schemaVersion\":999}".utf8).write(to: url)
    do { _ = try store.load(partition: partition); check(false, "future version must fail") } catch { }
    do { try store.save(state, partition: partition); check(false, "protected file must not be overwritten") } catch { }
    check(try! Data(contentsOf: url) == Data("{\"schemaVersion\":999}".utf8), "future preserved")
    print("PASS: storeSafety")
case "storeNestedAndSymlink":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let p = String(repeating: "e", count: 64)
    let store = GLMQuotaCycleStore(root: root)
    var state = GLMQuotaCycleState()
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    r.ingest(sample(0, 2800), into: &state)
    state.closed = [state.current!, state.current!]
    check(!GLMQuotaCycleStore.validate(state), "duplicate id invalid")
    state.closed = []
    state.pending = GLMQuotaCycleCandidate(baselineID: UUID(), first: sample(10, 10000), reason: .natural)
    check(!GLMQuotaCycleStore.validate(state), "dangling candidate invalid")
    state.pending = nil
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try! FileManager.default.createSymbolicLink(at: root.appendingPathComponent(p), withDestinationURL: FileManager.default.temporaryDirectory)
    do { try store.save(state, partition: p); check(false, "symlink rejected") } catch { }
    print("PASS: storeNestedAndSymlink")
case "coordinatorIsolation":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = DispatchQueue(label: "fixture-callback")
    let coordinator = GLMQuotaCycleCoordinator(root: root, deliveryQueue: queue, deliver: { _ in })
    let a = GLMQuotaHistoryContext.apiKey("fixture-plan-a")
    let b = GLMQuotaHistoryContext.apiKey("fixture-plan-b")
    coordinator.activate(a)
    let old = coordinator.capture(requestStartedAt: t.addingTimeInterval(-1))!
    coordinator.observe(sample(0, 2800), token: old)
    coordinator.drain()
    coordinator.activate(b)
    coordinator.activate(a)
    coordinator.observe(sample(10, 2000), token: old)
    coordinator.drain()
    let state = coordinator.testCurrentState()!
    check(state.current?.lastObservation.remainingCredits == 2800, "A-B-A old request refused")
    let token = coordinator.capture(requestStartedAt: t.addingTimeInterval(19))!
    coordinator.advanceEpoch()
    coordinator.observe(sample(20, 1000), token: token)
    coordinator.drain()
    check(coordinator.testCurrentState()?.current?.lastObservation.remainingCredits == 2800, "old epoch refused")
    print("PASS: coordinatorIsolation")
case "ambiguousPending":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var a = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &a)
    r.ingest(sample(20, 9800), into: &a)
    r.ingest(sample(40, 9700), into: &a)
    check(a.pending != nil && a.closed.isEmpty && a.current?.lastObservation.remainingCredits == 2800, "same reset recovery remains pending")
    r.ingest(sample(60, 2700), into: &a)
    check(a.pending == nil && a.current?.lastObservation.remainingCredits == 2700, "candidate rollback")
    var b = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &b)
    r.ingest(sample(20, 2700, 605800), into: &b)
    r.ingest(sample(40, 2600, 605800), into: &b)
    check(b.pending != nil && b.closed.isEmpty, "clock shift without decrease remains pending")
    print("PASS: ambiguousPending")
case "historyPaging":
    let records = (0..<25).map { GLMQuotaCycleRecord(sample(Double($0)*100, Double(10000-$0)), startKind: .firstObserved) }
    var browser = GLMQuotaHistoryBrowser()
    check(browser.visibleRange(records) == 19..<25, "latest page")
    browser.pageOlder(records)
    check(browser.visibleRange(records) == 13..<19, "previous page")
    let anchor = records[18].id
    var appended = records
    appended.append(GLMQuotaCycleRecord(sample(3000, 8000), startKind: .firstObserved))
    check(browser.visibleRange(appended).contains(appended.firstIndex { $0.id == anchor }!), "history remains anchored")
    browser.loadEarlier()
    browser.pageOlder(appended)
    check(browser.visibleRange(appended).lowerBound < 13, "older content accessible")
    var small = GLMQuotaHistoryBrowser()
    let thirteen = Array(records.prefix(13))
    small.pageOlder(thirteen)
    small.loadEarlier()
    small.pageOlder(thirteen)
    check(small.visibleRange(thirteen).lowerBound == 0, "13th cycle accessible")
    for count in [0, 1, 5, 6, 7, 12, 13, 25, 1000] {
        let many = (0..<count).map { GLMQuotaCycleRecord(sample(Double($0)*100, 9000), startKind: .firstObserved) }
        let range = GLMQuotaHistoryBrowser().visibleRange(many)
        check(range.count <= 6 && range.upperBound == count, "page bounds")
    }
    var keyboard = GLMQuotaHistoryBrowser()
    keyboard.select(thirteen[7].id)
    keyboard.move(-1, records: thirteen)
    check(keyboard.visibleRange(thirteen) == 1..<7 && keyboard.selectedCycleID == thirteen[6].id, "keyboard left advances a whole page")
    keyboard.move(1, records: thirteen)
    check(keyboard.visibleRange(thirteen) == 7..<13 && keyboard.selectedCycleID == thirteen[7].id, "keyboard right advances a whole page")
    let details = GLMQuotaCycleDetails.lines(records[0])
    check(details.0.contains("推算") && GLMQuotaCycleDetails.startExplanation(records[0]).contains("未知") && details.1.contains("10,000"), "estimated presentation preserves uncertainty and credits")
    var closed = records[0]; closed.end = .gap
    check(GLMQuotaCycleDetails.lines(closed).1.contains("最后观测") && !GLMQuotaCycleDetails.lines(closed).1.contains("到期未用"), "honest closure")
    print("PASS: historyPaging")
case "chartGeometry":
    for width in [220.0, 280.0] {
        let frames = GLMQuotaHistoryGeometry.columns(width: width, height: 80, count: 6)
        check(frames.count == 6, "six columns")
        check(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= width && $0.width > 12 }, "columns in bounds")
        check(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "no overlap")
    }
    print("PASS: chartGeometry")
case "clockRollbackPending":
    var state = GLMQuotaCycleState()
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    r.ingest(sample(0, 2800), into: &state)
    let a = GLMQuotaObservation(requestStartedAt: t.addingTimeInterval(100), observedAt: t.addingTimeInterval(200), limitCredits: 10000, reportedUsedCredits: 200, remainingCredits: 9800, resetAt: t.addingTimeInterval(605800), planLevel: "PRO")
    let b = GLMQuotaObservation(requestStartedAt: t.addingTimeInterval(115), observedAt: t.addingTimeInterval(116), limitCredits: 10000, reportedUsedCredits: 300, remainingCredits: 9700, resetAt: t.addingTimeInterval(605800), planLevel: "PRO")
    r.ingest(a, into: &state); r.ingest(b, into: &state)
    check(state.closed.isEmpty, "clock went backwards, cannot confirm")
    print("PASS: clockRollbackPending")
case "thousandRecords":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GLMQuotaCycleStore(root: root); let p = String(repeating: "a", count: 64)
    var state = GLMQuotaCycleState()
    for i in 0..<1000 {
        var record = GLMQuotaCycleRecord(sample(Double(i)*100, 5700), startKind: .observedTransition)
        record.end = .natural; state.closed.append(record)
    }
    try! store.save(state, partition: p)
    check(try! store.load(partition: p) == state, "1000 round trip")
    check(GLMQuotaHistoryBrowser().visibleRange(state.closed) == 994..<1000, "1000 paging")
    print("PASS: thousandRecords")
case "coordinatorHeartbeat":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var writes = 0; var failNext = false
    let c = GLMQuotaCycleCoordinator(root: root, writer: { _, _ in writes += 1; if failNext { throw NSError(domain: "fake", code: 1) } }, deliveryQueue: DispatchQueue(label: "test-delivery"), deliver: { _ in })
    c.activate(.apiKey("fixture"))
    func observe(_ n: Double, _ remaining: Double) {
        let value = sample(n, remaining)
        let token = c.capture(requestStartedAt: value.requestStartedAt)!
        c.observe(value, token: token); c.drain()
    }
    observe(0, 5700); check(writes == 1, "first write")
    for i in 1...29 { observe(Double(i * 10), 5700) }
    check(writes == 1, "same values do not write each 10 seconds")
    observe(300, 5700); check(writes == 2, "heartbeat 5 minutes")
    failNext = true; observe(310, 5600); check(writes == 3, "changed values saved immediately")
    failNext = false; observe(320, 5600); check(writes == 4, "failed write retries")
    print("PASS: coordinatorHeartbeat")
case "pendingContinuity":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &state)
    // Same-reset rebounds cannot be trusted as a new round, but are real evidence of connectivity.
    for i in 1...100 { r.ingest(sample(Double(i)*10, 9800), into: &state) }
    r.ingest(sample(1010, 9800, 605800), into: &state)
    r.ingest(sample(1030, 9700, 605800), into: &state)
    check(state.closed.count == 1 && state.closed[0].end == .unknownChange, "continuous pending traffic is not an observation gap")
    print("PASS: pendingContinuity")
case "rollbackEvidence":
    let reducer = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var state = GLMQuotaCycleState()
    reducer.ingest(sample(0, 2800), into: &state)
    reducer.ingest(sample(10, 9800, 605800), into: &state)
    reducer.ingest(sample(20, 2700), into: &state)
    check(state.pending == nil && state.closed.isEmpty, "rollback does not split")
    check(state.current?.rollbackEvidence.count == 1 && state.current?.rollbackEvidence[0].remainingCredits == 9800, "rollback keeps candidate")
    print("PASS: rollbackEvidence")
case "operationMonotonic":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var s = GLMQuotaCycleState(); r.ingest(sample(0, 2800), into: &s)
    let id = s.current!.id, hash = String(repeating: "a", count: 64)
    func event(_ result: GLMQuotaOperationResult, _ response: Date?) -> GLMQuotaOperationEvidence {
        .init(operationHash: hash, originalRequestedAt: t, responseAt: response, isWeek: true, result: result, baselineCycleID: id, attributionProven: true)
    }
    r.record(event(.requested, nil), into: &s)
    r.record(event(.unknown, t.addingTimeInterval(5)), into: &s)
    r.record(event(.requested, nil), into: &s)
    check(s.operations[hash]?.result == .unknown && s.operations[hash]?.responseAt != nil, "retry does not erase unknown")
    r.record(event(.confirmedUsed, t.addingTimeInterval(15)), into: &s)
    r.record(event(.unknown, t.addingTimeInterval(20)), into: &s)
    check(s.operations[hash]?.result == .confirmedUsed && s.operations.count == 1, "late unknown does not downgrade confirmed")
    print("PASS: operationMonotonic")
case "planLevelEnrichment":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    func levelSample(_ secs: Double, _ level: String?) -> GLMQuotaObservation {
        let x = sample(secs, 5700 - secs)
        return .init(requestStartedAt: x.requestStartedAt, observedAt: x.observedAt,
                     limitCredits: x.limitCredits, reportedUsedCredits: x.reportedUsedCredits,
                     remainingCredits: x.remainingCredits, resetAt: x.resetAt, planLevel: level)
    }
    var s = GLMQuotaCycleState()
    r.ingest(levelSample(0, nil), into: &s)
    r.ingest(levelSample(10, "PRO"), into: &s)
    check(s.closed.isEmpty && s.pending == nil, "nil to known is enrichment")
    r.ingest(levelSample(20, nil), into: &s)
    r.ingest(levelSample(30, "MAX"), into: &s)
    check(s.pending?.reason == .specificationChanged, "missing level does not erase known level")
    r.ingest(levelSample(50, "MAX"), into: &s)
    check(s.closed.last?.end == .specificationChanged, "level change confirmed")
    print("PASS: planLevelEnrichment")
case "invalidStoreSequence":
    var s = GLMQuotaCycleState()
    var earlier = GLMQuotaCycleRecord(sample(0, 5000), startKind: .firstObserved); earlier.end = .natural
    var later = GLMQuotaCycleRecord(sample(100, 5000), startKind: .observedTransition); later.end = .natural
    s.closed = [later, earlier]
    check(!GLMQuotaCycleStore.validate(s), "reversed cycle sequence must be rejected")
    s.closed = [earlier, later]
    s.operations[String(repeating: "a", count: 64)] = .init(operationHash: String(repeating: "a", count: 64), originalRequestedAt: t, responseAt: nil, isWeek: true, result: .confirmedUsed, baselineCycleID: nil, attributionProven: false)
    check(!GLMQuotaCycleStore.validate(s), "confirmed outcome requires response time")
    print("PASS: invalidStoreSequence")
case "orderedLoad":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var disk = GLMQuotaCycleState(); GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy()).ingest(sample(0, 5700), into: &disk)
    let deliverQueue = DispatchQueue(label: "fixture-deliver")
    var snapshots: [GLMQuotaCycleSnapshot] = []
    let a = GLMQuotaHistoryContext.apiKey("fixture-a"), b = GLMQuotaHistoryContext.apiKey("fixture-b")
    let c = GLMQuotaCycleCoordinator(root: root, writer: { _, _ in }, loader: { partition in
        if partition == a.partition { started.signal(); _ = release.wait(timeout: .now() + 3); return disk }
        return GLMQuotaCycleState()
    }, deliveryQueue: deliverQueue, deliver: { snapshots.append($0) })
    c.activate(a); check(started.wait(timeout: .now() + 3) == .success, "load entered")
    let token = c.capture(requestStartedAt: sample(10, 5600).requestStartedAt)!
    c.observe(sample(10, 5600), token: token)
    release.signal(); c.drain(); deliverQueue.sync { }
    check(c.testCurrentState()?.current?.id == disk.current?.id && c.testCurrentState()?.current?.lastObservation.remainingCredits == 5600, "load precedes queued sample")
    check(snapshots.last?.state.current?.lastObservation.remainingCredits == 5600, "latest UI not overwritten")
    c.activate(b); c.observe(sample(20, 5500), token: token); c.drain(); deliverQueue.sync { }
    check(c.testCurrentState()?.current == nil, "old A callback not applied to B")
    print("PASS: orderedLoad")
case "apiKeyAttributionDefence":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let c = GLMQuotaCycleCoordinator(root: root, writer: { _, _ in }, deliveryQueue: DispatchQueue(label: "delivery"), deliver: { _ in })
    c.activate(.apiKey("fixture"))
    let first = sample(0, 2800); let quota = c.capture(requestStartedAt: first.requestStartedAt)!
    c.observe(first, token: quota); c.drain()
    let token = c.capture(requestStartedAt: t)!, id = c.testCurrentState()!.current!.id
    let event = GLMQuotaOperationEvidence(operationHash: String(repeating: "a", count: 64), originalRequestedAt: t, responseAt: t.addingTimeInterval(2), isWeek: true, result: .confirmedUsed, baselineCycleID: id, attributionProven: true)
    c.record(event, token: token); c.drain()
    check(c.testCurrentState()!.operations[event.operationHash]?.attributionProven == false, "API Key cannot claim OAuth proof")
    print("PASS: apiKeyAttributionDefence")
case "oldConnectionOperation":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let c = GLMQuotaCycleCoordinator(root: root, writer: { _, _ in }, deliveryQueue: DispatchQueue(label: "test-delivery"), deliver: { _ in })
    let a = GLMQuotaHistoryContext.apiKey("a"), b = GLMQuotaHistoryContext.apiKey("b")
    c.activate(a)
    let sampleA = sample(0, 2800), token = c.capture(requestStartedAt: sampleA.requestStartedAt)!
    c.observe(sampleA, token: token); c.drain()
    let baseline = c.testCurrentState()!.current!.id, hash = String(repeating: "f", count: 64)
    func op(_ result: GLMQuotaOperationResult, _ response: Date?) -> GLMQuotaOperationEvidence {
        .init(operationHash: hash, originalRequestedAt: t, responseAt: response, isWeek: true, result: result, baselineCycleID: baseline, attributionProven: false)
    }
    c.record(op(.requested, nil), token: token); c.drain()
    c.activate(b)
    c.record(op(.confirmedUsed, t.addingTimeInterval(10)), token: token); c.drain()
    check(c.testCurrentState()?.operations.isEmpty == true, "late A operation does not leak to B")
    c.activate(a); c.drain()
    check(c.testCurrentState()?.operations[hash]?.result == .confirmedUsed, "old partition keeps operation fact")
    check(c.testCurrentState()?.operations[hash]?.attributionProven == false, "old partition does not gain proof")
    print("PASS: oldConnectionOperation")
case "smallReboundPending":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var s = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &s)
    r.ingest(sample(10, 2850), into: &s)
    check(s.current?.lastObservation.remainingCredits == 2800, "small rebound does not overwrite trusted reading")
    check(s.pending?.first.remainingCredits == 2850, "small rebound is retained as pending evidence")
    r.ingest(sample(20, 2700), into: &s)
    check(s.pending == nil && s.current?.rollbackEvidence.first?.remainingCredits == 2850, "small rebound rollback retains evidence")
    print("PASS: smallReboundPending")
case "rollbackThenSmallReboundStore":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy()), store = GLMQuotaCycleStore(root: root)
    let p = String(repeating: "a", count: 64)
    var s = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &s)
    r.ingest(sample(10, 9800, 605800), into: &s)
    r.ingest(sample(20, 2850), into: &s)
    check(s.current?.rollbackEvidence.count == 1, "earlier candidate retained")
    check(GLMQuotaCycleStore.validate(s), "rollback evidence after last trusted observation must remain saveable")
    do { try store.save(s, partition: p); let loaded = try store.load(partition: p); check(loaded == s, "rollback state roundtrip") }
    catch { check(false, "rollback state save failed: \(error)") }
    r.ingest(sample(30, 2700), into: &s)
    r.ingest(sample(40, 9800, 605800), into: &s)
    r.ingest(sample(60, 9700, 605800), into: &s)
    check(s.closed.count == 1 && s.closed[0].rollbackEvidence.count == 2, "both rolled-back candidates survive closure")
    do { try store.save(s, partition: p); let loaded = try store.load(partition: p); check(loaded == s, "closed rollback evidence roundtrip") }
    catch { check(false, "closed rollback state save failed: \(error)") }
    print("PASS: rollbackThenSmallReboundStore")
case "operationInvalidState":
    let r = GLMQuotaCycleReducer(policy: GLMQuotaCyclePolicy())
    var s = GLMQuotaCycleState()
    r.ingest(sample(0, 2800), into: &s)
    let hash = String(repeating: "a", count: 64)
    r.record(.init(operationHash: hash, originalRequestedAt: t, responseAt: nil, isWeek: true, result: .confirmedUsed, baselineCycleID: s.current!.id, attributionProven: true), into: &s)
    check(s.operations.isEmpty && GLMQuotaCycleStore.validate(s), "invalid confirmed result cannot poison state")
    let hash2 = String(repeating: "b", count: 64)
    r.record(.init(operationHash: hash2, originalRequestedAt: t, responseAt: t, isWeek: true, result: .confirmedUsed, baselineCycleID: UUID(), attributionProven: true), into: &s)
    check(s.operations[hash2]?.baselineCycleID == nil && s.operations[hash2]?.attributionProven == false, "missing baseline stays unbound")
    check(GLMQuotaCycleStore.validate(s), "unbound operation remains saveable")
    print("PASS: operationInvalidState")
case "chartPercentageLabels":
    for (value, expected) in [(0.0, "0%"), (100, "100%"), (81.2, "81%"), (72, "72%"), (0.4, "<1%"), (99.6, ">99%")] {
        check(GLMQuotaHistoryGeometry.usedPercentLabel(value) == expected, "compact per-cycle percentage preserves endpoints")
    }
    check(GLMQuotaHistoryGeometry.usedPercentLabel(.nan) == "—", "nonfinite label is unknown")
    for width in [220.0, 280.0] {
        let columns = GLMQuotaHistoryGeometry.columns(width: width, height: GLMQuotaHistoryGeometry.canvasHeight, count: 6)
        for column in columns {
            let percentage = GLMQuotaHistoryGeometry.percentageFrame(in: column)
            let date = GLMQuotaHistoryGeometry.dateFrame(in: column)
            check(percentage.minY >= 0 && percentage.maxY <= date.minY, "percentage belongs below its date")
            check(date.maxY < GLMQuotaHistoryGeometry.plotBaseline, "date does not overlap bars")
            check(percentage.midX == date.midX && percentage.width == column.width, "labels align with their cycle column")
        }
    }
    print("PASS: chartPercentageLabels")
case "shortHistoryRightAligned":
    for width in [220.0, 280.0] {
        for count in 1...6 {
            let frames = GLMQuotaHistoryGeometry.columns(width: width, height: 92, count: count)
            check(frames.count == count && frames.last?.maxX == CGFloat(width), "short history must finish at the right edge")
            check(frames[0].minX >= 20 && zip(frames, frames.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "right-aligned groups stay ordered")
        }
        check(GLMQuotaHistoryGeometry.columns(width: width, height: 92, count: 0).isEmpty, "no placeholder cycles")
    }
    print("PASS: shortHistoryRightAligned")
case "compactCycleWording":
    let calendar = Calendar(identifier: .gregorian)
    let observed = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
    let reset = calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
    let observation = GLMQuotaObservation(requestStartedAt: observed, observedAt: observed,
        limitCredits: 10000, reportedUsedCredits: 6000, remainingCredits: 4000, resetAt: reset, planLevel: "LITE")
    var record = GLMQuotaCycleRecord(observation, startKind: .firstObserved)
    check(GLMQuotaCycleDetails.lines(record).0 == "推算11/06–至今（预计11/13） · 进行中", "current cycle uses compact estimated range and expected end")
    check(record.firstObservedAt == observed && record.startKind == .firstObserved, "display estimate does not rewrite observed history")
    check(GLMQuotaCycleDetails.dateLabel(record) == "~11/06", "estimated date is visibly marked")
    check(GLMQuotaCycleDetails.startExplanation(record).contains("实际开始时刻未知"), "tooltip preserves uncertainty")
    record.end = .natural
    check(GLMQuotaCycleDetails.lines(record).0.contains("推算11/06–11/13") && GLMQuotaCycleDetails.lines(record).0.contains("正常到期"), "closed range is not shown as ongoing")
    let yearReset = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 12))!
    let crossYear = GLMQuotaObservation(requestStartedAt: observed, observedAt: observed,
        limitCredits: 10000, reportedUsedCredits: 0, remainingCredits: 10000, resetAt: yearReset, planLevel: "LITE")
    check(GLMQuotaCycleDetails.lines(GLMQuotaCycleRecord(crossYear, startKind: .firstObserved)).0 == "推算12/27–至今（预计01/03） · 进行中", "estimated label handles year boundary")
    print("PASS: compactCycleWording")
default:
    fputs("FAIL: unknown test case\n", stderr); exit(1)
}
