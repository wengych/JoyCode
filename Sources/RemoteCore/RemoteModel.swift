import Foundation

public enum AgentID: String, Codable, CaseIterable {
    case chatGPT
    case claude
}

public struct SavedSession: Identifiable, Codable, Equatable {
    public var id: UUID
    public var agent: AgentID
    public var title: String
    public var deepLink: String

    public init(id: UUID = UUID(), agent: AgentID, title: String, deepLink: String) {
        self.id = id
        self.agent = agent
        self.title = title
        self.deepLink = deepLink
    }
}

public enum RemoteCoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case targetLocked
    case sessionNotFound
    case invalidDeepLink
    case focusNotConfirmed
    case targetMismatch
    case invalidVoiceTransition
    case draftNotReady

    public var errorDescription: String? {
        switch self {
        case .targetLocked: return "请先结束、取消或确认当前语音已停止，再切换目标。"
        case .sessionNotFound: return "未找到保存的聊天记录，请重新选择。"
        case .invalidDeepLink: return "仅接受已有聊天的 codex://threads/… 或 claude://claude.ai/chat/… 链接。"
        case .focusNotConfirmed: return "尚未确认目标输入框，请重新定位并等待文字稳定后再试。"
        case .targetMismatch: return "当前输入框与本段语音绑定的聊天不一致。"
        case .invalidVoiceTransition: return "当前语音状态不支持此操作，请先确认录音状态。"
        case .draftNotReady: return "草稿尚未完成或已改变，请等待文字稳定并确认目标后再发送。"
        }
    }

    public var description: String { errorDescription ?? "无法完成当前操作。" }
}

/// Validate persisted or pasted links immediately before opening them.
/// Validation establishes the link's destination shape, not that the chat exists.
public enum SessionDeepLink {
    public static func validatedURL(for session: SavedSession) throws -> URL {
        try validatedURL(session.deepLink, agent: session.agent)
    }

    public static func validatedURL(_ rawValue: String, agent: AgentID) throws -> URL {
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              rawValue.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
              let components = URLComponents(string: rawValue),
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == components.path else {
            throw RemoteCoreError.invalidDeepLink
        }

        let segments = components.path.split(separator: "/", omittingEmptySubsequences: false)
        let identifier: Substring
        switch agent {
        case .chatGPT:
            guard components.scheme == "codex", components.host == "threads",
                  segments.count == 2, segments[0].isEmpty else {
                throw RemoteCoreError.invalidDeepLink
            }
            identifier = segments[1]
        case .claude:
            guard components.scheme == "claude", components.host == "claude.ai",
                  segments.count == 3, segments[0].isEmpty, segments[1] == "chat" else {
                throw RemoteCoreError.invalidDeepLink
            }
            identifier = segments[2]
        }

        // Session IDs are opaque, but never paths, commands, or URL-encoded payloads.
        guard !identifier.isEmpty, identifier.count <= 128,
              identifier.lowercased() != "new",
              identifier.unicodeScalars.allSatisfy({ scalar in
                  (48...57).contains(scalar.value) || (65...90).contains(scalar.value) ||
                  (97...122).contains(scalar.value) || scalar.value == 45 || scalar.value == 95
              }),
              let url = components.url,
              url.absoluteString == rawValue else {
            throw RemoteCoreError.invalidDeepLink
        }
        return url
    }
}

public struct RemoteConfiguration: Codable {
    public var sessions: [SavedSession]
    public var lastSessionIDs: [String: UUID]
    public var defaultVoiceShortcut: VoiceShortcut
    public var defaultVoiceBackend: VoiceBackend
    /// Keys are exact bundle IDs. Keeping a profile does not authorize app activation.
    public var applicationProfiles: [String: ApplicationProfile]

    public init(
        sessions: [SavedSession] = [],
        lastSessionIDs: [String: UUID] = [:],
        defaultVoiceShortcut: VoiceShortcut = .defaultVoice,
        defaultVoiceBackend: VoiceBackend = .nativeDictation,
        applicationProfiles: [String: ApplicationProfile] = [:]
    ) {
        self.sessions = sessions
        self.lastSessionIDs = lastSessionIDs
        self.defaultVoiceShortcut = defaultVoiceShortcut
        self.defaultVoiceBackend = defaultVoiceBackend
        self.applicationProfiles = applicationProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, lastSessionIDs, defaultVoiceShortcut, defaultVoiceBackend, applicationProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([SavedSession].self, forKey: .sessions) ?? []
        lastSessionIDs = try container.decodeIfPresent([String: UUID].self, forKey: .lastSessionIDs) ?? [:]
        // Migrate missing fields without validating or rewriting the user's old sessions.
        // Invalid explicit shortcuts remain visible for repair and fail when resolved.
        defaultVoiceShortcut = try container.decodeIfPresent(VoiceShortcut.self, forKey: .defaultVoiceShortcut) ?? .defaultVoice
        // Previously every recording used Typeless. Keep existing installations on
        // that backend until explicitly changed, while fresh configurations use native.
        defaultVoiceBackend = try container.decodeIfPresent(VoiceBackend.self, forKey: .defaultVoiceBackend) ?? .typeless
        applicationProfiles = try container.decodeIfPresent([String: ApplicationProfile].self, forKey: .applicationProfiles) ?? [:]
    }

    public static var defaults: RemoteConfiguration { RemoteConfiguration() }

    public func resolveVoiceBackend(forBundleID bundleID: String) throws -> VoiceBackend {
        // Exact bundle IDs only, matching shortcut resolution. A valid app override
        // can operate even when an unrelated global or application setting is invalid.
        let backend = applicationProfiles[bundleID]?.voiceBackend ?? defaultVoiceBackend
        return try backend.validated()
    }

    public func resolveVoiceShortcut(forBundleID bundleID: String) throws -> VoiceShortcut {
        // Do not fold case, match prefixes, or silently replace an invalid override.
        let shortcut = applicationProfiles[bundleID]?.voiceShortcut ?? defaultVoiceShortcut
        return try shortcut.validated()
    }

    public func sessions(for agent: AgentID) -> [SavedSession] {
        sessions.filter { $0.agent == agent }
    }

    /// Nil means use the current chat; it does not mean silently choose the first saved chat.
    public func lastSession(for agent: AgentID) -> SavedSession? {
        guard let id = lastSessionIDs[agent.rawValue] else { return nil }
        return sessions.first { $0.id == id && $0.agent == agent }
    }

    /// Order is the user's stored order, scoped to the agent. Navigation never wraps.
    public func session(before id: UUID, for agent: AgentID) -> SavedSession? {
        let ordered = sessions(for: agent)
        guard let index = ordered.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return ordered[index - 1]
    }

    public func session(after id: UUID, for agent: AgentID) -> SavedSession? {
        let ordered = sessions(for: agent)
        guard let index = ordered.firstIndex(where: { $0.id == id }), index + 1 < ordered.count else {
            return nil
        }
        return ordered[index + 1]
    }
}

public enum VoicePhase: Equatable {
    case idle
    case recording
    case transcribing
    case uncertain
}

/// Tokens must identify the actual app, window, chat/composer instance observed by the adapter.
/// A nil sessionID is an unregistered current chat, not a wildcard when comparing targets.
public struct ComposerTarget: Equatable {
    public var sessionID: UUID?
    public var applicationBundleID: String
    public var windowID: String
    public var composerID: String

    public init(sessionID: UUID? = nil, applicationBundleID: String, windowID: String, composerID: String) {
        self.sessionID = sessionID
        self.applicationBundleID = applicationBundleID
        self.windowID = windowID
        self.composerID = composerID
    }

    fileprivate var hasIdentity: Bool {
        !applicationBundleID.isEmpty && !windowID.isEmpty && !composerID.isEmpty
    }
}

public struct ComposerSnapshot: Equatable {
    public var target: ComposerTarget
    public var text: String
    public var isFocused: Bool
    /// Supplied by the observation adapter after repeated matching text observations.
    public var isStable: Bool

    public init(target: ComposerTarget, text: String, isFocused: Bool, isStable: Bool) {
        self.target = target
        self.text = text
        self.isFocused = isFocused
        self.isStable = isStable
    }
}

public struct ReadyDraft: Equatable {
    public var target: ComposerTarget
    public var text: String

    public init(target: ComposerTarget, text: String) {
        self.target = target
        self.text = text
    }
}

/// Pure semantic state. It does not activate apps, emit keys, infer Typeless state,
/// or queue send actions. Callers must confirm side effects and observe the real UI.
public struct RemoteState {
    public private(set) var voicePhase: VoicePhase = .idle
    public private(set) var selectedSessionID: UUID?
    public private(set) var lockedTarget: ComposerTarget?
    public private(set) var readyDraft: ReadyDraft?

    private var baselineText: String?
    private var previousReadyDraft: ReadyDraft?
    private var latestSnapshot: ComposerSnapshot?

    public init(selectedSessionID: UUID? = nil) {
        self.selectedSessionID = selectedSessionID
    }

    public var isTargetLocked: Bool { voicePhase != .idle }

    /// This is only as recent as observe(_:). Sending also requires a fresh snapshot.
    public var canSend: Bool {
        guard let snapshot = latestSnapshot else { return false }
        return (try? validatedReadyDraft(for: snapshot)) != nil
    }

    public mutating func selectSession(_ id: UUID, configuration: inout RemoteConfiguration) throws {
        guard !isTargetLocked else { throw RemoteCoreError.targetLocked }
        guard let session = configuration.sessions.first(where: { $0.id == id }) else {
            throw RemoteCoreError.sessionNotFound
        }
        _ = try SessionDeepLink.validatedURL(for: session)
        selectedSessionID = id
        configuration.lastSessionIDs[session.agent.rawValue] = id
        clearDraftReadiness()
    }

    public mutating func selectCurrentSession(for agent: AgentID, configuration: inout RemoteConfiguration) throws {
        guard !isTargetLocked else { throw RemoteCoreError.targetLocked }
        selectedSessionID = nil
        configuration.lastSessionIDs.removeValue(forKey: agent.rawValue)
        clearDraftReadiness()
    }

    public mutating func begin(with snapshot: ComposerSnapshot) throws {
        guard voicePhase == .idle else { throw RemoteCoreError.invalidVoiceTransition }
        guard snapshot.isFocused, snapshot.target.hasIdentity else {
            throw RemoteCoreError.focusNotConfirmed
        }
        // The frontmost confirmed current chat may differ from the last saved selection.
        selectedSessionID = snapshot.target.sessionID
        // Cancelling this recording may restore readiness only for its own exact
        // baseline. A draft from an earlier foreground chat or an earlier edit is
        // not part of the operation being cancelled.
        if let readyDraft, readyDraft.target == snapshot.target, readyDraft.text == snapshot.text {
            previousReadyDraft = readyDraft
        } else {
            previousReadyDraft = nil
        }
        readyDraft = nil
        latestSnapshot = snapshot
        baselineText = snapshot.text
        lockedTarget = snapshot.target
        voicePhase = .recording
    }

    public mutating func stop() throws {
        guard voicePhase == .recording else { throw RemoteCoreError.invalidVoiceTransition }
        voicePhase = .transcribing
    }

    /// The caller must independently prove that the native dictation control is idle.
    /// A stable composer alone is not proof; Typeless must continue using observe(_:).
    /// Confirmed native completion also unlocks an empty or unchanged recording.
    public mutating func completeConfirmedDictation(with snapshot: ComposerSnapshot) throws {
        guard voicePhase == .transcribing else { throw RemoteCoreError.invalidVoiceTransition }
        guard snapshot.isFocused, snapshot.isStable else { throw RemoteCoreError.focusNotConfirmed }
        guard snapshot.target == lockedTarget else { throw RemoteCoreError.targetMismatch }

        let newText = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = (baselineText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !newText.isEmpty, newText != originalText {
            readyDraft = ReadyDraft(target: snapshot.target, text: snapshot.text)
        } else if !newText.isEmpty,
                  previousReadyDraft?.target == snapshot.target,
                  previousReadyDraft?.text == snapshot.text {
            readyDraft = previousReadyDraft
        } else {
            readyDraft = nil
        }
        latestSnapshot = snapshot
        voicePhase = .idle
        lockedTarget = nil
        baselineText = nil
        previousReadyDraft = nil
    }

    /// The caller must independently prove that the owned native dictation is idle.
    /// A stable observation of the original target can clear uncertainty without
    /// keyboard focus, but never makes its text ready to send.
    public mutating func reconcileConfirmedNativeIdle(with snapshot: ComposerSnapshot) throws {
        guard voicePhase == .uncertain else { throw RemoteCoreError.invalidVoiceTransition }
        guard snapshot.isStable else { throw RemoteCoreError.focusNotConfirmed }
        guard snapshot.target == lockedTarget else { throw RemoteCoreError.targetMismatch }

        confirmVoiceStopped()
    }

    /// An attempted cancel without a confirmed outcome must keep the target locked.
    public mutating func cancelRecording(confirmed: Bool) throws {
        guard voicePhase == .recording else { throw RemoteCoreError.invalidVoiceTransition }
        guard confirmed else { markUncertain(); return }
        voicePhase = .idle
        lockedTarget = nil
        baselineText = nil
        readyDraft = previousReadyDraft
        previousReadyDraft = nil
        latestSnapshot = nil
    }

    public mutating func markUncertain() {
        lockedTarget = lockedTarget ?? latestSnapshot?.target
        voicePhase = .uncertain
        readyDraft = nil
        previousReadyDraft = nil
        latestSnapshot = nil
    }

    /// Explicit human confirmation that voice capture/processing has stopped.
    /// It unlocks navigation, but does not treat arbitrary text as a ready transcript.
    public mutating func confirmVoiceStopped() {
        guard voicePhase != .idle else { return }
        voicePhase = .idle
        lockedTarget = nil
        baselineText = nil
        previousReadyDraft = nil
        clearDraftReadiness()
    }

    public mutating func observe(_ snapshot: ComposerSnapshot) {
        latestSnapshot = snapshot
        switch voicePhase {
        case .uncertain:
            // A matching snapshot cannot prove that Typeless has stopped.
            return
        case .recording, .transcribing:
            guard snapshot.isFocused, snapshot.target == lockedTarget else {
                markUncertain()
                return
            }
            guard voicePhase == .transcribing, snapshot.isStable else { return }
            let newText = snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalText = (baselineText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newText.isEmpty, newText != originalText else { return }
            readyDraft = ReadyDraft(target: snapshot.target, text: snapshot.text)
            voicePhase = .idle
            lockedTarget = nil
            baselineText = nil
            previousReadyDraft = nil
        case .idle:
            // Edits to an already verified draft are permitted after a new stable observation.
            guard let draft = readyDraft, draft.target == snapshot.target,
                  snapshot.isFocused, snapshot.isStable else { return }
            if snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readyDraft = nil
            } else {
                readyDraft = ReadyDraft(target: snapshot.target, text: snapshot.text)
            }
        }
    }

    public func validatedReadyDraft(for snapshot: ComposerSnapshot) throws -> ReadyDraft {
        guard voicePhase == .idle, let draft = readyDraft else { throw RemoteCoreError.draftNotReady }
        guard snapshot.isFocused, snapshot.isStable else { throw RemoteCoreError.focusNotConfirmed }
        guard snapshot.target == draft.target, snapshot.target.sessionID == selectedSessionID else {
            throw RemoteCoreError.targetMismatch
        }
        guard snapshot.text == draft.text,
              !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteCoreError.draftNotReady
        }
        return draft
    }

    /// A physical send command may also submit a manually typed draft after fresh stable observations.
    public mutating func acceptManualDraft(_ snapshot: ComposerSnapshot) throws {
        guard voicePhase == .idle else { throw RemoteCoreError.targetLocked }
        guard snapshot.isFocused, snapshot.isStable, snapshot.target.hasIdentity else {
            throw RemoteCoreError.focusNotConfirmed
        }
        guard snapshot.target.sessionID == selectedSessionID else { throw RemoteCoreError.targetMismatch }
        guard !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RemoteCoreError.draftNotReady
        }
        readyDraft = ReadyDraft(target: snapshot.target, text: snapshot.text)
        latestSnapshot = snapshot
    }

    /// Consume once when the caller chooses to send. A rejected attempt is never queued.
    @discardableResult
    public mutating func consumeReadyDraft(for snapshot: ComposerSnapshot) throws -> ReadyDraft {
        let draft = try validatedReadyDraft(for: snapshot)
        readyDraft = nil
        latestSnapshot = snapshot
        return draft
    }

    private mutating func clearDraftReadiness() {
        readyDraft = nil
        latestSnapshot = nil
    }
}
