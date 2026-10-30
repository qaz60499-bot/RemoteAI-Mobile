import Foundation

/// A read-only snapshot of state already synchronized by WorkspaceStore. Building
/// the summary never queries the provider, retries a command, or infers delivery.
struct RuntimeIssueSnapshot {
    let machineState: MachineConnectionState
    let connectionPhase: ConnectionDiagnosticPhase
    let transientPresentation: Bool
    let browserConnected: Bool?
    let relayConnected: Bool?
    let agentConnected: Bool?
    let statusUpdatedAt: Date?
    let errors: [String: String]
    let runtimes: [RuntimeDescriptor]
    let instances: [InstanceDescriptor]
    let sessions: [SessionDescriptor]
    let commands: [UUID: CommandState]
    let providerIssues: [String: RemoteProviderSurfaceIssue]
    let providerStates: [String: String]
    let providerObservedAt: [String: Date]

    @MainActor
    init(store: WorkspaceStore) {
        machineState = store.machine.state
        connectionPhase = store.connectionPhase
        transientPresentation = store.deferringTransientConnectionPresentation
        browserConnected = store.desktopBrowserConnected
        relayConnected = store.desktopRelayConnected
        agentConnected = store.desktopAgentConnected
        statusUpdatedAt = store.desktopStatusUpdatedAt
        errors = store.errors
        runtimes = store.runtimes
        instances = store.instances
        sessions = store.sessions
        commands = store.commandStates
        providerIssues = store.webProviderIssuesBySession
        providerStates = store.webProviderSurfaceStateBySession
        providerObservedAt = store.webProviderSurfaceObservedAtBySession
    }

    init(
        machineState: MachineConnectionState = .online,
        connectionPhase: ConnectionDiagnosticPhase = .online,
        transientPresentation: Bool = false,
        browserConnected: Bool? = nil,
        relayConnected: Bool? = nil,
        agentConnected: Bool? = nil,
        statusUpdatedAt: Date? = nil,
        errors: [String: String] = [:],
        runtimes: [RuntimeDescriptor] = [],
        instances: [InstanceDescriptor] = [],
        sessions: [SessionDescriptor] = [],
        commands: [UUID: CommandState] = [:],
        providerIssues: [String: RemoteProviderSurfaceIssue] = [:],
        providerStates: [String: String] = [:],
        providerObservedAt: [String: Date] = [:]
    ) {
        self.machineState = machineState
        self.connectionPhase = connectionPhase
        self.transientPresentation = transientPresentation
        self.browserConnected = browserConnected
        self.relayConnected = relayConnected
        self.agentConnected = agentConnected
        self.statusUpdatedAt = statusUpdatedAt
        self.errors = errors
        self.runtimes = runtimes
        self.instances = instances
        self.sessions = sessions
        self.commands = commands
        self.providerIssues = providerIssues
        self.providerStates = providerStates
        self.providerObservedAt = providerObservedAt
    }
}

struct RuntimeIssue: Identifiable, Equatable {
    enum Level: Equatable { case failure, uncertain }

    let id: String
    let level: Level
    let title: String
    let source: String
    let detail: String
    let suggestion: String
    let observedAt: Date?
}

enum RuntimeIssueSummary {
    @MainActor
    static func build(store: WorkspaceStore) -> [RuntimeIssue] {
        build(RuntimeIssueSnapshot(store: store))
    }

    static func build(_ snapshot: RuntimeIssueSnapshot) -> [RuntimeIssue] {
        var items: [RuntimeIssue] = []
        func append(
            _ id: String,
            _ level: RuntimeIssue.Level,
            _ title: String,
            _ source: String,
            _ detail: String,
            _ suggestion: String,
            _ observedAt: Date? = nil
        ) {
            items.append(RuntimeIssue(
                id: id,
                level: level,
                title: title,
                source: source,
                detail: detail,
                suggestion: suggestion,
                observedAt: observedAt
            ))
        }

        let connectionError = snapshot.errors["connection"]
        let offline = snapshot.machineState == .offline
        let failedPhases: [ConnectionDiagnosticPhase] = [.relayError, .timedOut, .pairingExpired, .windowsOffline]
        let reconnectingPhases: [ConnectionDiagnosticPhase] = [.reconnecting, .windowsReconnecting]
        if !snapshot.transientPresentation,
           offline || failedPhases.contains(snapshot.connectionPhase) || connectionError?.isEmpty == false {
            let detail = connectionError?.isEmpty == false
                ? connectionError!
                : "连接状态：\(snapshot.connectionPhase.displayName)。当前不能验证远程任务是否仍在运行。"
            append(
                "connection",
                .failure,
                "电脑或 Relay 连接异常",
                "连接状态",
                detail,
                "检查电脑 Agent 与网络。不要在投递结果未知时重复发送。",
                snapshot.statusUpdatedAt
            )
        } else if !snapshot.transientPresentation, reconnectingPhases.contains(snapshot.connectionPhase) {
            append(
                "reconnecting",
                .uncertain,
                snapshot.connectionPhase == .windowsReconnecting ? "正在重连 Windows Agent" : "正在重连 Relay",
                "连接状态",
                "连接暂时不稳定，尚未证明命令失败。",
                "先查看原任务是否恢复，不要立即重发。",
                snapshot.statusUpdatedAt
            )
        }

        if snapshot.machineState == .online && !snapshot.transientPresentation {
            if snapshot.relayConnected == false {
                append("relay", .failure, "Relay 连接异常", "手机到 Cloudflare Relay",
                       "最近一次电脑状态显示 Relay 未连接。",
                       "检查 Relay；当前不能确认断线期间的消息是否已送达。", snapshot.statusUpdatedAt)
            }
            if snapshot.agentConnected == false {
                append("agent", .failure, "Windows Agent 不在线", "Windows Agent",
                       "最近一次状态未确认 Agent 在线。",
                       "检查电脑 Agent；不要强制结束正在运行的任务。", snapshot.statusUpdatedAt)
            }
            if snapshot.browserConnected == false {
                append("bridge", .failure, "浏览器控制连接异常", "Windows Browser Bridge",
                       "Browser Bridge 未连接，ChatGPT 网页状态不能确认。",
                       "检查现有 Chrome 和 Bridge，保留原标签，不要重复发送。", snapshot.statusUpdatedAt)
            }
        }

        for key in snapshot.errors.keys.sorted() where key != "connection" {
            guard let error = snapshot.errors[key], !error.isEmpty else { continue }
            let source = sourceName(for: key, runtimes: snapshot.runtimes,
                                   instances: snapshot.instances, sessions: snapshot.sessions)
            let session = snapshot.sessions.first(where: { $0.id == key })
            append(
                "error.\(key)",
                session?.state == .unknown || key.hasPrefix("runtime.") ? .uncertain : .failure,
                errorTitle(for: key, source: source),
                source,
                error,
                key.hasPrefix("runtime.") || key.hasPrefix("instance.")
                    ? "本次未能确认应用能力，不等于任务失败。恢复连接后手动刷新状态；不要重发原任务。"
                    : "保留已缓存内容，先查看对应原会话和投递状态；不要自动重发。",
                nil
            )
        }

        if snapshot.machineState == .online {
            for instance in snapshot.instances where instance.status == "unavailable" || instance.status == "limited" {
                let isUnavailable = instance.status == "unavailable"
                append(
                    "instance.\(instance.id)",
                    isUnavailable ? .failure : .uncertain,
                    "\(instance.name) 服务\(isUnavailable ? "不可用" : "受限")",
                    instance.name,
                    "上次同步时状态为 \(instance.status ?? "未知")；并不代表历史会话已经丢失。",
                    "检查该应用和账号/代理状态，再查看原会话；不要自动重发。",
                    nil
                )
            }
        }

        let sessionByID = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sortedProviderIDs = Set(snapshot.providerIssues.keys).union(snapshot.providerStates.keys).sorted()
        for sessionID in sortedProviderIDs {
            let state = snapshot.providerStates[sessionID]?.lowercased()
            guard let issue = snapshot.providerIssues[sessionID] else {
                guard state == "unknown" || state == "degraded" else { continue }
                let session = sessionByID[sessionID]
                let source = session.map { sourceName(for: $0, runtimes: snapshot.runtimes, instances: snapshot.instances) } ?? "Web"
                append(
                    "provider-state.\(sessionID)",
                    .uncertain,
                    state == "unknown" ? "ChatGPT 网页状态无法确认" : "ChatGPT 网页状态异常",
                    source,
                    "最近同步的网页状态为 \(state ?? "unknown")；这不证明消息未送达或会话丢失。",
                    "打开原会话核对页面和消息收据；投递未知时不要重发。",
                    snapshot.providerObservedAt[sessionID]
                )
                continue
            }
            let session = sessionByID[sessionID]
            let source = session.map { sourceName(for: $0, runtimes: snapshot.runtimes, instances: snapshot.instances) } ?? "Web"
            let original = issue.originalMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = original?.isEmpty == false
                ? "\(issue.message)\n原始网页错误：\(original!)"
                : issue.message
            append(
                "provider-issue.\(sessionID)",
                .failure,
                issue.chineseStateName,
                source,
                detail,
                issue.retryable
                    ? "先在同一网页会话核对回复和投递状态；只有确认未执行后再决定是否重试。"
                    : "查看同一网页会话中的实际回复和错误；不要自动重发。",
                issue.at ?? snapshot.providerObservedAt[sessionID]
            )
        }

        let recentSessions = snapshot.sessions.filter { session in
            session.state == .error || session.state == .unknown
                || (session.backgroundTaskStatus?.state == .available
                    && session.backgroundTaskStatus?.tasks.contains(where: { $0.status == .failed }) == true)
        }.sorted {
            $0.orderingDate == $1.orderingDate ? $0.id < $1.id : $0.orderingDate > $1.orderingDate
        }
        var errorCount = 0
        var unknownCount = 0
        var taskFailureCount = 0
        for session in recentSessions {
            if taskFailureCount < 4, let taskSnapshot = session.backgroundTaskStatus,
               taskSnapshot.state == .available {
                for task in taskSnapshot.tasks where task.status == .failed && taskFailureCount < 4 {
                    taskFailureCount += 1
                    append(
                        "task.\(session.id).\(task.id)",
                        .failure,
                        "上次记录后台任务失败：\(String(task.title.prefix(64)))",
                        sourceName(for: session, runtimes: snapshot.runtimes, instances: snapshot.instances),
                        "上次观测时间：\(taskSnapshot.observedAt.formatted(date: .abbreviated, time: .shortened))。会话主状态不能证明该任务已完成。",
                        "打开 Antigravity 原侧边栏核对失败原因和已生成内容，不要直接重发原任务。",
                        taskSnapshot.observedAt
                    )
                }
            }
            guard session.state == .error || session.state == .unknown else { continue }
            let isError = session.state == .error
            if isError && errorCount >= 5 { continue }
            if !isError && unknownCount >= 3 { continue }
            if isError { errorCount += 1 } else { unknownCount += 1 }
            let source = sourceName(for: session, runtimes: snapshot.runtimes, instances: snapshot.instances)
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            append(
                "session.\(session.id)",
                isError ? .failure : .uncertain,
                "\(source)：\(title.isEmpty ? session.id : String(title.prefix(72)))",
                source,
                "会话记录时间：\(session.orderingDate.formatted(date: .abbreviated, time: .shortened))。"
                    + (isError
                       ? "上次同步显示会话错误，可能为历史状态；不能据此判定消息未送达。"
                       : "上次同步的会话状态未知，不能据此判定任务失败。"),
                "查看原会话及消息收据；投递未知时不要点击 Retry。",
                nil
            )
        }

        let unknownCommands = snapshot.commands.values.filter { $0 == .unknown }.count
        if unknownCommands > 0 {
            append("commands.unknown", .uncertain, "有 \(unknownCommands) 条命令结果未确认", "命令投递",
                   "命令可能包括发送或停止；无法确认电脑是否已执行。",
                   "先检查对应会话的进度或最终回复，不要重复发送。")
        }
        let failedCommands = snapshot.commands.values.filter { $0 == .failed }.count
        if failedCommands > 0 {
            append("commands.failed", .failure, "有 \(failedCommands) 条命令报告失败", "命令投递",
                   "这是已记录的命令失败，不能单凭该状态判定整项任务失败或从未执行。",
                   "查看原会话、错误详情和消息收据；不要自动重发或停止。")
        }
        return items
    }

    private static func errorTitle(for key: String, source: String) -> String {
        if key == "sync" { return "数据同步失败" }
        if key.hasPrefix("runtime.") { return "\(source) 实例状态读取失败" }
        if key.hasPrefix("instance.") { return "\(source) 操作状态异常" }
        if key.hasPrefix("web.") { return "\(source) 状态异常" }
        return "\(source) 错误"
    }

    private static func sourceName(
        for key: String,
        runtimes: [RuntimeDescriptor],
        instances: [InstanceDescriptor],
        sessions: [SessionDescriptor]
    ) -> String {
        if let session = sessions.first(where: { $0.id == key }) {
            return sourceName(for: session, runtimes: runtimes, instances: instances)
        }
        if key == "sync" { return "数据同步" }
        if key == "web.tabs" { return "Web · Chrome 标签" }
        if key == "web.projects" { return "Web · Projects" }
        if key == "web.root" { return "Web · 对话目录" }
        if key.hasPrefix("web.project.") { return "Web · Project \(key.dropFirst("web.project.".count))" }
        if let instance = instances.first(where: { $0.id == key }) { return instance.name }
        if key.hasPrefix("runtime."), let runtime = runtimes.first(where: { $0.id == String(key.dropFirst("runtime.".count)) }) {
            return runtime.name
        }
        if key.hasPrefix("instance."), let instance = instances.first(where: { $0.id == String(key.dropFirst("instance.".count)) }) {
            return instance.name
        }
        return key
    }

    private static func sourceName(
        for session: SessionDescriptor,
        runtimes: [RuntimeDescriptor],
        instances: [InstanceDescriptor]
    ) -> String {
        let instanceName = instances.first(where: { $0.id == session.instanceId })?.name
        let runtimeName = instances.first(where: { $0.id == session.instanceId })
            .flatMap { instance in runtimes.first(where: { $0.id == instance.runtimeId })?.name }
        return instanceName ?? runtimeName ?? "会话"
    }
}
