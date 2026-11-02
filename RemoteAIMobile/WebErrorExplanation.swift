import Foundation

/// Explains only structured errors captured by the adapter. It never reads or
/// translates conversation bodies and never changes the provider page.
struct WebErrorExplanation: Equatable {
    let summary: String
    let impact: String
    let safeAction: String
    let deliveryUnknown: Bool

    static func resolve(code: String, state: String = "", original: String? = nil) -> Self {
        let raw = (original ?? "").lowercased()
        let unknown = code == "WEB_SEND_DELIVERY_UNKNOWN" || state == "delivery-unknown"
            || raw.contains("message delivery timed out")
        if unknown {
            return Self(summary: "消息送达结果尚未确认", impact: "网页可能已经收到消息；尚未确认不代表发送失败。", safeAction: "先核查原命令和当前 Chat 的消息；不会自动创建新命令重发。", deliveryUnknown: true)
        }
        switch code {
        case "PAGE_TRANSLATION_ACTIVE":
            return Self(summary: "Chrome 网页翻译改变了页面结构", impact: "当前页面身份和消息位置可能无法安全核对。", safeAction: "请在电脑还原网页原文，再检测状态。手机只解释错误短文本。", deliveryUnknown: false)
        case "SESSION_UNAVAILABLE", "CONVERSATION_IDENTITY_UNVERIFIED":
            return Self(summary: "当前 Chat 页面尚未安全就绪", impact: "页面身份未确认；本地历史和草稿已保留，未导入其他 Chat 的消息。", safeAction: "重新检查当前页；已有核验历史时可只读查看缓存。", deliveryUnknown: false)
        case "BROWSER_BINDING_MISSING":
            return Self(summary: "原网页标签的绑定已失效", impact: "电脑可能已切换、导航或关闭该标签。", safeAction: "更新实际网页标签列表，再核验原 Chat；不按旧标签编号操作。", deliveryUnknown: false)
        case "PROVIDER_RATE_LIMITED":
            return Self(summary: "ChatGPT 网页请求受限", impact: "回复可能延迟或未完成，已有内容保留。", safeAction: "按网页提示等待，再检查状态；不要连续重试发送。", deliveryUnknown: false)
        default: break
        }
        if state == "response-incomplete" || raw.contains("connection interrupted") {
            return Self(summary: "网页连接中断，回复尚未完成", impact: "已收到的部分回复保留；当前不能报告回复完成。", safeAction: "等待网页恢复，再检测状态或重新同步消息。", deliveryUnknown: false)
        }
        if raw.contains("this response couldn't load") || state == "response-unavailable" {
            return Self(summary: "网页最新回复加载失败", impact: "已有消息保留；加载失败不能证明用户消息未送达。", safeAction: "检测同一 Chat 的网页状态，再重新同步；不会自动点击 Retry。", deliveryUnknown: false)
        }
        if raw.contains("network error") || raw.contains("failed to fetch") || state == "connection-lost" || state == "response-network-error" {
            return Self(summary: "ChatGPT 网页网络请求异常", impact: "网页回复或同步可能暂停；手机到 Agent 的连接状态需单独核对。", safeAction: "等待网络恢复，检测网页状态并补同步；不要盲目重发。", deliveryUnknown: false)
        }
        return Self(summary: "ChatGPT 网页当前异常", impact: "回复或网页操作可能受影响；本地历史、草稿和已收到内容保留。", safeAction: "先检测网页状态；恢复后重新同步。刷新仍需确认且不能打断生成。", deliveryUnknown: false)
    }
}

extension RemoteProviderSurfaceIssue {
    var explanation: WebErrorExplanation {
        WebErrorExplanation.resolve(code: code, state: state, original: originalMessage)
    }
}
