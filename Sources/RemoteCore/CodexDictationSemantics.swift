import Foundation

/// Codex dictation has separate start/stop/cancel buttons which may be rebuilt.
/// The platform adapter owns window/composer/container identity and AX actions;
/// these rules classify only the controls observed inside that verified scope.
public enum CodexDictationSemantics {
    public enum Control: String, CaseIterable, Hashable {
        case dictate
        case stop
        case cancel
        case transcribeAndSend
        case processing
        case retry
    }

    public struct ControlEvidence: Equatable {
        public let kind: Control
        public let enabled: Bool

        public init(kind: Control, enabled: Bool) {
            self.kind = kind
            self.enabled = enabled
        }
    }

    public enum State: Equatable {
        case idle
        case recording
        case processing
        case unavailable
    }

    private static let labels: [String: Control] = [
        "dictate": .dictate,
        "听写": .dictate,
        "聽寫": .dictate,
        "stop dictation": .stop,
        "停止听写": .stop,
        "停止聽寫": .stop,
        "停止口述": .stop,
        "cancel dictation": .cancel,
        "取消听写": .cancel,
        "取消聽寫": .cancel,
        "cancel transcription": .cancel,
        "取消转录": .cancel,
        "取消轉錄": .cancel,
        "transcribe and send": .transcribeAndSend,
        "转录并发送": .transcribeAndSend,
        "轉錄並傳送": .transcribeAndSend,
        "transcribing": .processing,
        "正在转写": .processing,
        "轉錄中": .processing,
        "正在轉錄": .processing,
        "starting dictation; click to cancel": .processing,
        "正在启动听写；点击可取消": .processing,
        "正在開始聽寫；按一下即可取消": .processing,
        "正在啟動聽寫，按一下即可取消": .processing,
        "finishing dictation": .processing,
        "正在完成听写": .processing,
        "正在完成聽寫": .processing,
        "preparing dictation": .processing,
        "正在准备听写": .processing,
        "正在準備聽寫": .processing,
        "retry dictation": .retry,
        "重试听写": .retry,
        "重新嘗試聽寫轉錄": .retry,
        "重試聽寫": .retry
    ]

    /// Names may come from title/description/label attributes. Match whole known
    /// labels; contradictory recognized names never choose an arbitrary action.
    /// Labels include only English and Chinese strings evidenced in installed app assets.
    public static func match(role: String, names: [String], hidden: Bool?) -> Control? {
        guard ["AXButton", "AXCheckBox"].contains(role), hidden != true else { return nil }
        let matches = Set(names.compactMap {
            labels[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        })
        return matches.count == 1 ? matches.first : nil
    }

    /// AXPress support is an action precondition, not an input to state inference.
    /// A visible Stop+Cancel pair confirms recording even if the editor stays editable.
    public static func classify(controls: [ControlEvidence], composerEditable: Bool,
                                owned: Bool, endingRequested: Bool) -> State {
        let kinds = Set(controls.map(\.kind))
        guard kinds.count == controls.count else { return .unavailable }
        // Retry is a failure/recovery surface, never an implicit start/stop request.
        guard !kinds.contains(.retry) else { return .unavailable }
        let evidence = Dictionary(uniqueKeysWithValues: controls.map { ($0.kind, $0.enabled) })

        if let dictateEnabled = evidence[.dictate] {
            // Start and any live/ending control together do not establish idle.
            guard controls.count == 1 else { return .unavailable }
            if dictateEnabled && composerEditable { return .idle }
            return owned ? .processing : .unavailable
        }

        if kinds.contains(.processing) {
            // A marker does not grant ownership of a manually started recording.
            // An enabled Stop conflicts with an explicit processing marker.
            guard owned, evidence[.stop] != true else { return .unavailable }
            return .processing
        }

        if let stopEnabled = evidence[.stop], let cancelEnabled = evidence[.cancel] {
            // Transcribe-and-send may coexist, but is never the stop action.
            if stopEnabled && cancelEnabled { return .recording }
            return owned ? .processing : .unavailable
        }

        let ordinaryControls = controls.filter { $0.kind != .transcribeAndSend }
        // Control disappearance during an owned ending is only a processing transition.
        // It can never confirm completion, clear ownership, or authorize a send.
        if ordinaryControls.isEmpty, owned && endingRequested { return .processing }
        return .unavailable
    }
}
