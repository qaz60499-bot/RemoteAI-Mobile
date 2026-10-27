import Foundation

/// Presentation-only summary of already synchronized state. This does not query providers,
/// start a polling loop, infer delivery from relay connectivity, or retry commands.
struct RuntimeIssue: Identifiable, Equatable {
    enum Level: Equatable { case failure, uncertain }
    let id: String
    let level: Level
    let title: String
    let detail: String
    let suggestion: String
}

enum RuntimeIssueSummary {
    static func build(
        paired: Bool,
        machineState: MachineConnectionState,
        connectionPhase: ConnectionDiagnosticPhase,
        transientPresentation: Bool,
        browserConnected: Bool?,
        relayConnected: Bool?,
        agentConnected: Bool?,
        errors: [String: String],
        runtimes: [RuntimeDescriptor],
        instances: [InstanceDescriptor],
        sessions: [SessionDescriptor],
        commands: [UUID: CommandState]
    ) -> [RuntimeIssue] {
        guard paired else { return [] }
        var items: [RuntimeIssue] = []
        func append(_ id: String, _ level: RuntimeIssue.Level, _ title: String,
                    _ detail: String, _ suggestion: String) {
            items.append(RuntimeIssue(id: id, level: level, title: title, detail: detail, suggestion: suggestion))
        }
        let offline = machineState == .offline
        if !transientPresentation && (offline || [.relayError, .timedOut, .pairingExpired, .windowsOffline].contains(connectionPhase)) {
            append("connection", .failure, "电脑或 Relay 连接异常",
                   "连接状态：\(connectionPhase.displayName)。当前不能验证远程任务是否仍在运行。",
                   "检查电脑 Agent 与网络。不要在投递结果未知时重复发送。")
        } else if !transientPresentation && [.reconnecting, .windowsReconnecting].contains(connectionPhase) {
            append("reconnecting", .uncertain, connectionPhase == .windowsReconnecting ? "正在重连 Windows Agent" : "正在重连 Relay",
                   "连接暂时不稳定，尚未证明命令失败。",
                   "先查看原任务是否恢复，不要立即重发。")
        }
        if machineState == .online && !transientPresentation {
            if relayConnected == false {
                append("relay", .failure, "Relay 连接异常", "最近一次电脑状态显示 Relay 未连接。",
                       "检查代理和 Relay；当前不能确认断线期间的消息是否已送达。")
            }
            if agentConnected == false {
                append("agent", .failure, "Windows Agent 不在线", "最近一次状态未确认 Agent 在线。",
                       "检查电脑 Agent；不要强制结束正在运行的 Codex 任务。")
            }
            if browserConnected == false {
                append("bridge", .failure, "浏览器控制连接异常", "Browser Bridge 未连接，ChatGPT 网页状态不能确认。",
                       "检查现有 Chrome/Bridge，保留原标签，不要重复发送。")
            }
        }
        if let syncError = errors["sync"], !syncError.isEmpty {
            append("sync", .failure, "数据同步失败", String(syncError.prefix(180)),
                   "保留已缓存内容，恢复连接后再刷新；不要清空历史。")
        }
        for runtime in runtimes {
            if let error = errors["runtime.\(runtime.id)"], !error.isEmpty {
                append("runtime.\(runtime.id)", .uncertain, "\(runtime.kind.displayName) 实例状态读取失败",
                       String(error.prefix(180)),
                       "本次未能确认应用能力，不等于任务失败。检查连接后手动刷新实例状态，不要重发原任务。")
            }
        }
        if machineState == .online {
            for instance in instances where instance.status == "unavailable" || instance.status == "limited" {
                let isUnavailable = instance.status == "unavailable"
                append("instance.\(instance.id)", isUnavailable ? .failure : .uncertain,
                       "\(instance.name) 服务\(isUnavailable ? "不可用" : "受限")",
                       "上次同步时状态为 \(instance.status ?? "未知")；并不代表历史会话已经丢失。",
                       "检查该应用和账号/代理状态，再查看原会话；不要自动重发。")
            }
        }

        let namesByInstance = Dictionary(instances.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let kindsByRuntime = Dictionary(runtimes.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        let runtimeByInstance = Dictionary(instances.map { ($0.id, $0.runtimeId) }, uniquingKeysWith: { first, _ in first })
        let recent = sessions.filter {
            $0.state == .error || $0.state == .unknown ||
            ($0.backgroundTaskStatus?.state == .available && $0.backgroundTaskStatus?.tasks.contains { $0.status == .failed } == true)
        }.sorted {
            $0.orderingDate == $1.orderingDate ? $0.id < $1.id : $0.orderingDate > $1.orderingDate
        }
        var errorCount = 0
        var unknownCount = 0
        var taskFailureCount = 0
        for session in recent {
            // Antigravity's sidebar tasks may fail independently of the main
            // conversation, which can already report Idle. Use only the last
            // synchronized task snapshot; never infer completion from Idle.
            if taskFailureCount < 4, let snapshot = session.backgroundTaskStatus,
               snapshot.state == .available {
                for task in snapshot.tasks where task.status == .failed && taskFailureCount < 4 {
                    taskFailureCount += 1
                    append("task.\(session.id).\(task.id)", .failure,
                           "上次记录后台任务失败：\(String(task.title.prefix(64)))",
                           "上次观测时间：\(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))。会话主状态不能证明该任务已完成。",
                           "打开 Antigravity 原侧边栏核对失败原因和已生成内容，不要直接重发原任务。")
                }
            }
            guard session.state == .error || session.state == .unknown else { continue }
            let isError = session.state == .error
            if isError && errorCount >= 5 { continue }
            if !isError && unknownCount >= 3 { continue }
            if isError { errorCount += 1 } else { unknownCount += 1 }
            let runtimeName = runtimeByInstance[session.instanceId].flatMap { kindsByRuntime[$0]?.displayName } ?? "运行环境"
            let source = namesByInstance[session.instanceId] ?? runtimeName
            let name = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = name.isEmpty ? source : String(name.prefix(72))
            append("session.\(session.id)", isError ? .failure : .uncertain,
                   "\(source)：\(title)",
                   "会话记录时间：\(session.orderingDate.formatted(date: .abbreviated, time: .shortened))。" +
                   (isError ? "上次同步显示会话错误，可能为历史状态；不能据此判定消息未送达。" : "上次同步的会话状态未知，不能据此判定任务失败。"),
                   "查看原会话及消息收据；投递未知时不要点击 Retry。")
        }

        let unknownCommands = commands.values.filter { $0 == .unknown }.count
        if unknownCommands > 0 {
            append("commands.unknown", .uncertain, "有 \(unknownCommands) 条命令结果未确认",
                   "命令可能包括发送或停止；无法确认电脑是否已执行。",
                   "先检查对应会话的进度或最终回复，不要重复发送。")
        }
        let failedCommands = commands.values.filter { $0 == .failed }.count
        if failedCommands > 0 {
            append("commands.failed", .failure, "有 \(failedCommands) 条命令报告失败",
                   "这是已记录的命令失败，不能单凭该状态判定整项任务失败或从未执行。",
                   "查看原会话、错误详情和消息收据；不要自动重发或停止。")
        }
        return items
    }
}
