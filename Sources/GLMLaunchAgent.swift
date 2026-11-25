import Foundation

// MARK: - 开机自启（LaunchAgent）开关：决策矩阵、受控重启 helper 与失败回执
//
// 口径（2026-11-21）：
// - 偏好记录 = ~/Library/LaunchAgents/com.local.glm-usage.plist 是否存在。
//   写入/删除在所有决策分支都无条件执行（磁盘定义始终与当前可执行路径同步），
//   因此 plistExists 不参与动作分流，仅用于探测结果完整性与提示文案。
// - 「立即生效」= 受控重启：App 绝不直接 bootstrap/bootout 自己（bootout 会终止
//   自己，bootstrap 未加载 job 会拉起第二实例造成同坐标 NSStatusItem 叠死）。
//   流程固定为：写/删 plist → 派生 detach helper 子进程 → App 正常 exit(0)
//   （KeepAlive=SuccessfulExit:false 对成功退出不复活）→ helper 等本进程消失
//   （超时即放弃动作写回执）且 pgrep -x 确认无其他实例后，执行 launchctl 动作
//   → 失败写结果回执，下次启动提示一次，不静默。
// - 探测阶段只做只读操作（launchctl print 与查看 plist），绝不写生产 LaunchAgent；
//   身份比对用 launchctl print 的 program 路径与可执行文件路径精确比对，
//   已加载任务指向其他副本时绝不动作（绝不碰别人的 job）。
// - decide / parsePrintedProgram / plistContent / helperScript / consumeResultLog
//   为纯函数或可离线驱动，--self-test 全矩阵覆盖，不碰真实 plist、不联网。

enum GLMLaunchAgent {

    static let label = "com.local.glm-usage"

    /// 偏好记录路径（生产 LaunchAgent plist；本模块自身绝不写它，写入由 App 开关路径执行）
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    /// 「用户做过显式选择」标记（UserDefaults，Bool=true）。plist 不存在有歧义
    /// （从未开启 vs 显式关闭），默认开启逻辑必须靠它区分：存在标记后启动不再自动写。
    static let explicitChoiceDefaultsKey = "login.explicitChoiceRecorded"

    /// 启动默认开启判定（纯函数，--self-test 覆盖）：仅当非 preview、用户从未显式
    /// 选择且当前无 plist 时自动写入偏好。显式关闭过的用户永远不被静默重新开启。
    static func shouldAutoEnableOnLaunch(preview: Bool, explicitChoiceRecorded: Bool, plistExists: Bool) -> Bool {
        !preview && !explicitChoiceRecorded && !plistExists
    }

    // MARK: 决策矩阵

    enum Action: Equatable {
        /// ON + 未加载：写 plist + 受控重启（bootstrap 方向）
        case writeAndBootstrap
        /// ON + 已加载且身份匹配：写 plist 同步磁盘定义，不动 launchctl（已托管）
        case writeSynced
        /// ON + 已加载但身份不匹配：写 plist + 报错不动作，绝不碰别人的 job
        case writeForeignConflict
        /// OFF + 已加载且身份匹配：删 plist + 受控重启（bootout 后 open 回来）
        case removeAndRelaunch
        /// OFF + 未加载：删 plist，无重启
        case removeOnly
        /// OFF + 已加载但身份不匹配：删 plist + 报错不动作，绝不碰别人的 job
        case removeForeignConflict

        /// 仅这两个方向需要用户确认「立即重启并生效 / 仅保存偏好」
        var needsRestart: Bool { self == .writeAndBootstrap || self == .removeAndRelaunch }
        /// 已加载任务身份不匹配：不执行任何 launchctl 动作
        var conflictsForeignJob: Bool { self == .writeForeignConflict || self == .removeForeignConflict }
    }

    /// 本机只读探测结果
    struct MachineState: Equatable {
        var plistExists = false
        var jobLoaded = false
        var jobMatches = false
    }

    static func decide(wantEnabled: Bool, state: MachineState) -> Action {
        switch (wantEnabled, state.jobLoaded) {
        case (true, false): return .writeAndBootstrap
        case (true, true): return state.jobMatches ? .writeSynced : .writeForeignConflict
        case (false, false): return .removeOnly
        case (false, true): return state.jobMatches ? .removeAndRelaunch : .removeForeignConflict
        }
    }

    // MARK: 只读探测

    /// 解析 launchctl print 输出中的 `program = <path>` 行（与 scripts/update.sh 同判据）
    static func parsePrintedProgram(_ output: String) -> String? {
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("program = ") {
                let value = line.dropFirst("program = ".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// 只读探测：launchctl print（只读）+ plist 存在性。print 失败或解析不出
    /// program 都归为未加载；身份用可执行文件路径精确比对，不按名称模糊匹配。
    static func probe(binaryPath: String) -> MachineState {
        var state = MachineState(plistExists: FileManager.default.fileExists(atPath: plistPath))
        guard !binaryPath.isEmpty else { return state }
        let output = Pipe()
        let errors = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/\(label)"]
        task.standardOutput = output
        task.standardError = errors
        guard (try? task.run()) != nil else { return state }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let program = parsePrintedProgram(text) else { return state }
        state.jobLoaded = true
        state.jobMatches = (program == binaryPath)
        return state
    }

    // MARK: plist 定义与 helper 脚本

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// 与历史版本及 scripts/update.sh 恢复分支同款定义：
    /// RunAtLoad 登录/加载即拉起；KeepAlive 仅非正常退出复活（菜单「退出」exit 0 不再被拉回）。
    /// 使用 PropertyListSerialization 生成规范 XML，避免路径含 XML 特殊字符破坏 plist 结构。
    static func plistContent(executablePath: String) -> String {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
           let xml = String(data: data, encoding: .utf8) {
            return xml
        }
        let escapedPath = xmlEscape(executablePath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(escapedPath)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict><key>SuccessfulExit</key><false/></dict>
        </dict>
        </plist>
        """
    }

    enum Direction: String {
        /// ON 方向：App 退出后 bootstrap，RunAtLoad 拉起受管实例；失败兜底 open -n
        case bootstrap
        /// OFF 方向：App 退出后 bootout 解除接管，再 open -n 普通拉回（关自启 ≠ 关应用）
        case bootoutThenOpen
    }

    /// helper 参数布局（两个方向统一）：$1=等待退出的 PID $2=plist 路径 $3=App 路径
    /// $4=失败回执路径 $5=job label $6=进程名（pgrep -x 精确守卫用）$7=轮询上限。
    /// 等待上限 50×0.2s≈10s（App 卡在收尾时不无限等待）；超时或动作前发现仍有
    /// GlmUsage 实例（pgrep -x 精确匹配进程名，绝不按路径模糊匹配）一律放弃
    /// launchctl 动作并写回执——宁可本次不接管，也不冒双实例叠死图标的风险
    /// （对抗审查 P1：等待超时后照常 bootstrap / 窗口期用户手动开 App 都会双实例）。
    /// 余量 0.5s 等进程完全消失后再动作。
    static func helperScript(_ direction: Direction) -> String {
        let waitAndGuard = """
        pid="$1"; plist="$2"; app="$3"; log="$4"; label="$5"; procname="$6"; maxpolls="$7"
        stamp() { date '+%Y-%m-%d %H:%M:%S'; }
        n=0
        while kill -0 "$pid" 2>/dev/null; do
          n=$((n+1))
          [ "$n" -ge "$maxpolls" ] && break
          sleep 0.2
        done
        if kill -0 "$pid" 2>/dev/null; then
          printf 'wait-timeout\\t%s\\n' "$(stamp)" > "$log" 2>/dev/null
          exit 0
        fi
        sleep 0.5
        if pgrep -x "$procname" >/dev/null 2>&1; then
          printf 'instance-exists\\t%s\\n' "$(stamp)" > "$log" 2>/dev/null
          exit 0
        fi
        """
        switch direction {
        case .bootstrap:
            return waitAndGuard + """

            if launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1; then
              exit 0
            fi
            if pgrep -x "$procname" >/dev/null 2>&1; then
              printf 'instance-exists\\t%s\\n' "$(stamp)" > "$log" 2>/dev/null
              exit 0
            fi
            printf 'bootstrap-failed\\t%s\\n' "$(stamp)" > "$log" 2>/dev/null
            if ! open -n "$app" >/dev/null 2>&1; then
              printf 'open-failed\\t%s\\n' "$(stamp)" >> "$log" 2>/dev/null
            fi
            """
        case .bootoutThenOpen:
            return waitAndGuard + """

            launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || {
              printf 'bootout-failed\\t%s\\n' "$(stamp)" > "$log" 2>/dev/null
            }
            if pgrep -x "$procname" >/dev/null 2>&1; then
              exit 0
            fi
            if ! open -n "$app" >/dev/null 2>&1; then
              printf 'open-failed\\t%s\\n' "$(stamp)" >> "$log" 2>/dev/null
            fi
            """
        }
    }

    // MARK: 失败回执

    /// 失败回执固定路径（临时目录 + uid 隔离，仅失败时写入；下次启动消费一次后删除）
    static var resultLogPath: String {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("GlmUsage-launchctl-helper-\(getuid()).result").path
    }

    static func resultMessage(for tag: String) -> String? {
        switch tag {
        case "bootstrap-failed":
            return "开机自启已保存，但 launchd 接管失败；应用已用普通方式重新打开（可再次切换重试）"
        case "bootout-failed":
            return "开机自启已关闭，但解除 launchd 接管未成功；可再次切换确认或注销后检查"
        case "open-failed":
            return "开机自启设置已保存，但应用未能自动重新打开，请手动启动"
        case "wait-timeout":
            return "应用退出超时，本次「立即生效」已取消；偏好已保存，下次登录或更新时生效"
        case "instance-exists":
            return "检测到另一个正在运行的实例，已跳过接管动作以避免重复；偏好已保存，下次登录或更新时生效"
        default: return nil
        }
    }

    /// 读取并删除 helper 回执（提示一次）。回试行 = `标签\t时间戳`，按首个字段匹配；
    /// 只识别已知失败标签，未知或空内容静默清除。
    /// path 参数供 --self-test 在临时根驱动，生产走固定回执路径。
    static func consumeResultLog(path: String? = nil) -> String? {
        let target = path ?? resultLogPath
        let raw = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(atPath: target)
        guard !raw.isEmpty else { return nil }
        for line in raw.split(separator: "\n") {
            let tag = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) ?? ""
            if let message = resultMessage(for: tag) { return message }
        }
        return nil
    }

    // MARK: 派生 helper

    /// 从 App 路径或可执行路径解析 pgrep -x 使用的真实进程名（若末段为 .app 则去除后缀）。
    static func processName(forAppPath appPath: String) -> String {
        let last = (appPath as NSString).lastPathComponent
        return last.hasSuffix(".app") ? (last as NSString).deletingPathExtension : last
    }

    /// 构造 /bin/sh 所需的 helper 完整参数列表（纯函数，--self-test 直接覆盖 $1..$7 绑定）。
    static func helperArguments(
        direction: Direction,
        waitingPID: Int32,
        appPath: String,
        processName: String? = nil,
        plistPath: String = plistPath,
        resultLogPath: String = resultLogPath,
        maxPolls: Int = 50
    ) -> [String] {
        let resolvedProcessName: String
        if let processName, !processName.isEmpty {
            resolvedProcessName = processName
        } else {
            resolvedProcessName = Self.processName(forAppPath: appPath)
        }
        return [
            "-c", helperScript(direction), "glm-launchctl-helper",
            "\(waitingPID)", plistPath, appPath, resultLogPath, label,
            resolvedProcessName, "\(maxPolls)"
        ]
    }

    /// 派生 detach helper（/bin/sh -c，独立于本进程存活）。调用方随后自行正常退出；
    /// 返回 false 表示派生失败，调用方不得退出，改走「仅保存偏好」并提示。
    /// 进程名优先取调用方传入的可执行文件名（缺失时自动去除 .app 后缀），轮询上限 50×0.2s≈10s。
    static func spawnExitHelper(direction: Direction, waitingPID: Int32, appPath: String,
                                processName: String? = nil) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = helperArguments(
            direction: direction,
            waitingPID: waitingPID,
            appPath: appPath,
            processName: processName
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return true
    }
}
