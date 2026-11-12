import Foundation
import Darwin

enum GLMQuotaCycleStoreError: Error { case invalidPartition, unsafePath, invalidData, protectedFile }

final class GLMQuotaCycleStore {
    typealias Writer = (Data, URL) throws -> Void
    private let root: URL
    private let writer: Writer
    private var protectedPartitions: Set<String> = []

    init(root: URL, writer: @escaping Writer = GLMQuotaCycleStore.writePrivateJSON) {
        self.root = root; self.writer = writer
    }
    private func location(_ partition: String) throws -> URL {
        guard partition.count == 64 && partition.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw GLMQuotaCycleStoreError.invalidPartition
        }
        let directory = root.appendingPathComponent(partition, isDirectory: true)
        let file = directory.appendingPathComponent("history-v1.json")
        for path in [root.path, directory.path, file.path] {
            var info = stat()
            if lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK {
                throw GLMQuotaCycleStoreError.unsafePath
            }
        }
        return file
    }
    func isProtected(partition: String) -> Bool { protectedPartitions.contains(partition) }
    func load(partition: String) throws -> GLMQuotaCycleState {
        let file = try location(partition)
        guard FileManager.default.fileExists(atPath: file.path) else { return GLMQuotaCycleState() }
        do {
            let data = try Data(contentsOf: file)
            let state = try JSONDecoder().decode(GLMQuotaCycleState.self, from: data)
            guard Self.validate(state) else { throw GLMQuotaCycleStoreError.invalidData }
            return state
        } catch {
            protectedPartitions.insert(partition)
            throw error
        }
    }
    func save(_ state: GLMQuotaCycleState, partition: String) throws {
        let file = try location(partition)
        guard !protectedPartitions.contains(partition) else { throw GLMQuotaCycleStoreError.protectedFile }
        guard Self.validate(state) else { throw GLMQuotaCycleStoreError.invalidData }
        if FileManager.default.fileExists(atPath: file.path) { _ = try load(partition: partition) }
        try writer(JSONEncoder().encode(state), file)
    }
    static func validate(_ state: GLMQuotaCycleState) -> Bool {
        guard state.schemaVersion == 1 else { return false }
        let records = state.closed + (state.current.map { [$0] } ?? [])
        guard Set(records.map(\.id)).count == records.count else { return false }
        for record in records {
            guard record.lastObservation.isValid, record.rollbackEvidence.allSatisfy({ $0.isValid }),
                  record.firstObservedAt.timeIntervalSince1970.isFinite,
                  record.expectedResetAt.timeIntervalSince1970.isFinite,
                  record.firstObservedAt <= record.lastObservation.observedAt,
                  record.expectedResetAt.timeIntervalSince1970 > 0,
                  record.boundaryLower.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  record.boundaryUpper.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { return false }
            if (record.boundaryLower == nil) != (record.boundaryUpper == nil) { return false }
            if let lower = record.boundaryLower, let upper = record.boundaryUpper,
               (lower != record.lastObservation.observedAt || lower > upper || record.end == nil) { return false }
            if !record.rollbackEvidence.allSatisfy({ $0.observedAt >= record.firstObservedAt && $0.observedAt <= record.lastObservation.observedAt }) { return false }
        }
        guard state.closed.allSatisfy({ $0.end != nil }), state.current?.end == nil else { return false }
        for (previous, next) in zip(records, records.dropFirst()) {
            guard previous.lastObservation.observedAt <= next.firstObservedAt else { return false }
        }
        if let pending = state.pending {
            guard pending.baselineID == state.current?.id && pending.first.isValid,
                  state.current.map({ pending.first.observedAt >= $0.lastObservation.observedAt }) ?? false,
                  state.lastRequestStartedAt.map({ pending.first.requestStartedAt <= $0 }) ?? true,
                  state.lastAcceptedObservedAt.map({ pending.first.observedAt <= $0 }) ?? true else { return false }
        }
        if let time = state.lastRequestStartedAt, !time.timeIntervalSince1970.isFinite { return false }
        if let time = state.lastAcceptedObservedAt, !time.timeIntervalSince1970.isFinite { return false }
        if let request = state.lastRequestStartedAt, let observed = state.lastAcceptedObservedAt, request > observed { return false }
        for (key, operation) in state.operations {
            guard key == operation.operationHash && key.count == 64 && key.allSatisfy({ "0123456789abcdef".contains($0) }),
                  operation.originalRequestedAt.timeIntervalSince1970.isFinite,
                  (operation.result != .confirmedUsed || operation.responseAt != nil),
                  operation.baselineCycleID.map({ id in records.contains { $0.id == id } }) ?? true,
                  operation.responseAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= operation.originalRequestedAt }) ?? true else { return false }
        }
        return true
    }
    static func writePrivateJSON(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent(), root = dir.deletingLastPathComponent()
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let tmp = dir.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: tmp) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard Darwin.rename(tmp.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
