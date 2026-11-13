import Foundation

enum GLMPanelCardID: String, CaseIterable, Codable {
    case quota, peak, resetCards, usage, daily, mcp

    var title: String {
        switch self {
        case .quota: return "用量进度"
        case .peak: return "峰谷状态"
        case .resetCards: return "重置卡"
        case .usage: return "用量情况"
        case .daily: return "每日用量"
        case .mcp: return "MCP 工具"
        }
    }
}

enum GLMPanelMoveDirection {
    case up, down
    var offset: Int { self == .up ? -1 : 1 }
}

struct GLMPanelLayout: Equatable {
    private struct Stored: Codable {
        let order: [String]
        let hidden: [String]
    }

    static let defaultsKey = "panelCardLayout.v1"
    static let `default` = GLMPanelLayout(order: GLMPanelCardID.allCases, hidden: [])

    private(set) var order: [GLMPanelCardID]
    private(set) var hidden: Set<GLMPanelCardID>

    var visibleOrder: [GLMPanelCardID] { order.filter { !hidden.contains($0) } }

    func isVisible(_ id: GLMPanelCardID) -> Bool { !hidden.contains(id) }

    mutating func setVisible(_ visible: Bool, for id: GLMPanelCardID) {
        if visible { hidden.remove(id) } else { hidden.insert(id) }
    }

    mutating func move(_ id: GLMPanelCardID, direction: GLMPanelMoveDirection) {
        guard let index = order.firstIndex(of: id) else { return }
        move(id, to: index + direction.offset)
    }

    mutating func move(_ id: GLMPanelCardID, to destination: Int) {
        guard let source = order.firstIndex(of: id), !order.isEmpty else { return }
        let target = max(0, min(destination, order.count - 1))
        guard source != target else { return }
        let item = order.remove(at: source)
        order.insert(item, at: target)
    }

    static func normalized(order savedOrder: [GLMPanelCardID], hidden savedHidden: Set<GLMPanelCardID>) -> Self {
        var result: [GLMPanelCardID] = []
        for id in savedOrder where !result.contains(id) { result.append(id) }

        // 旧配置没有的新卡片按当前默认顺序的相对位置插入，而不是静默丢弃或一律追加末尾。
        for id in GLMPanelCardID.allCases where !result.contains(id) {
            guard let defaultIndex = GLMPanelCardID.allCases.firstIndex(of: id) else { continue }
            let successors = GLMPanelCardID.allCases[GLMPanelCardID.allCases.index(after: defaultIndex)...]
            if let next = successors.first(where: { result.contains($0) }), let index = result.firstIndex(of: next) {
                result.insert(id, at: index)
            } else {
                result.append(id)
            }
        }
        let known = Set(GLMPanelCardID.allCases)
        return Self(order: result, hidden: savedHidden.intersection(known))
    }

    static func decode(_ data: Data?) -> Self {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return .default }
        return normalized(order: stored.order.compactMap(GLMPanelCardID.init),
                          hidden: Set(stored.hidden.compactMap(GLMPanelCardID.init)))
    }

    func encoded() throws -> Data {
        let stored = Stored(order: order.map(\.rawValue),
                            hidden: GLMPanelCardID.allCases.filter { hidden.contains($0) }.map(\.rawValue))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(stored)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        decode(defaults.data(forKey: defaultsKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? encoded() else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
