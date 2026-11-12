/// Allows a rebuilt Codex editor after an owned stop/cancel request, or for explicit
/// read-only recovery of an owned operation already confirmed idle. Window, process,
/// conversation and original scope identity must first be independently verified.
public enum CodexDictationEditorPolicy {
    public enum Decision: Equatable {
        /// The original unique recognized editor is still present.
        case original
        /// A unique recognized completion editor may be pinned/read while idle.
        /// This never replaces the original operation token or action target.
        case completedReplacement
        /// Preserve ownership without reading or adopting a completion editor.
        case waiting
        /// Stop observation; do not retarget or clear the uncertainty lock.
        case reject
    }

    public static func resolve(owned: Bool, endingRequested: Bool, idle: Bool,
                               editorCount: Int, originalEditor: Bool,
                               recognizedEditor: Bool, settledEditorMatches: Bool?,
                               readOnlyRecovery: Bool = false) -> Decision {
        guard editorCount >= 0, editorCount <= 1 else { return .reject }
        if editorCount == 0 { return owned ? .waiting : .reject }
        guard recognizedEditor, settledEditorMatches != false else { return .reject }
        if originalEditor { return .original }
        guard owned else { return .reject }
        if endingRequested { return idle ? .completedReplacement : .waiting }
        // A user/system may have ended dictation without our stop/cancel request.
        // This exception proves idle for a read only; it never retargets an action
        // or treats a replacement during active recording as the owned editor.
        return readOnlyRecovery && idle ? .completedReplacement : .reject
    }
}
