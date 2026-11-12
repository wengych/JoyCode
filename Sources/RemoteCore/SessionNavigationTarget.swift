import Foundation

/// Session navigation follows the current foreground app independently of voice support.
public enum SessionNavigationTarget: Equatable {
    case claude
    case codex

    public var bundleID: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.codex"
        }
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT · Codex"
        }
    }

    /// Never fall back to the selected voice agent or a previously foreground app.
    public static func resolve(foregroundBundleID: String?, voicePhase: VoicePhase) throws -> Self? {
        guard voicePhase == .idle else { throw RemoteCoreError.targetLocked }
        switch foregroundBundleID {
        case Self.claude.bundleID: return .claude
        case Self.codex.bundleID: return .codex
        default: return nil
        }
    }
}
