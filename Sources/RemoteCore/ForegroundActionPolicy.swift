import Foundation

/// Ordinary controls never activate an application. LB/RB activation is separate.
public enum ForegroundAction: String, CaseIterable, Equatable {
    case voice
    case send
    case cancel
    case session
    case scroll
}

public enum ForegroundActionPolicyError: Error, Equatable, LocalizedError {
    case unsupportedForeground
    case unsupportedAction(ForegroundAction, AgentID)
    case voiceTargetMismatch
    case targetUnavailable
    case targetChanged

    public var errorDescription: String? {
        switch self {
        case .unsupportedForeground:
            return "当前前台应用不支持此操作；不会切换到其他应用。"
        case .unsupportedAction(_, .chatGPT):
            return "ChatGPT / Codex 尚未适配此操作；当前窗口保持不变。"
        case .unsupportedAction(_, .claude):
            return "Claude 尚未适配此操作；当前窗口保持不变。"
        case .voiceTargetMismatch:
            return "本段语音的原窗口不在前台；请先手动返回原窗口。"
        case .targetUnavailable:
            return "无法确认当前激活窗口，已停止操作。"
        case .targetChanged:
            return "当前激活应用或窗口已变化，已停止操作。"
        }
    }
}

/// A value identity for routing/tests. Production must also compare the original
/// AX window object with CFEqual immediately before each mutating operation.
public struct ForegroundTargetIdentity: Equatable {
    public let bundleID: String
    public let pid: Int32
    public let windowID: String

    public init(bundleID: String, pid: Int32, windowID: String) {
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
    }

    fileprivate var isUsable: Bool {
        !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pid > 0
            && !windowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum ForegroundActionPolicy {
    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let codexBundleID = "com.openai.codex"

    /// Resolve only this invocation's foreground application. There is deliberately
    /// no selected-agent, remembered-window, or application-activation fallback.
    /// Voice ownership additionally requires the original window identity at use.
    public static func resolve(action: ForegroundAction, foregroundBundleID: String?,
                               voicePhase: VoicePhase, ownedBundleID: String?) throws -> AgentID {
        if voicePhase != .idle {
            if action == .send || action == .session { throw RemoteCoreError.targetLocked }
            guard let agent = supportedAgent(for: foregroundBundleID),
                  ownedBundleID == foregroundBundleID else {
                throw ForegroundActionPolicyError.voiceTargetMismatch
            }
            return agent
        }

        guard let agent = supportedAgent(for: foregroundBundleID) else {
            throw ForegroundActionPolicyError.unsupportedForeground
        }
        return agent
    }

    private static func supportedAgent(for bundleID: String?) -> AgentID? {
        switch bundleID {
        case claudeBundleID:
            return .claude
        case codexBundleID:
            return .chatGPT
        default:
            return nil
        }
    }

    public static func validate(expected: ForegroundTargetIdentity,
                                current: ForegroundTargetIdentity?) throws {
        guard expected.isUsable, let current, current.isUsable else {
            throw ForegroundActionPolicyError.targetUnavailable
        }
        guard expected == current else { throw ForegroundActionPolicyError.targetChanged }
    }

    /// Fetch the current target at the mutation boundary; do not cache this closure's
    /// result across awaits or retry a failed operation. The platform adapter still
    /// performs its own live AX object identity check at the actual write.
    @discardableResult
    public static func withVerifiedTarget<T>(expected: ForegroundTargetIdentity,
                                             current: () throws -> ForegroundTargetIdentity?,
                                             operation: () throws -> T) throws -> T {
        try validate(expected: expected, current: current())
        return try operation()
    }
}
