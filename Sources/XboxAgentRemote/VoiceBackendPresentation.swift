import RemoteCore

extension VoiceBackend {
    var displayName: String {
        switch self {
        case .nativeDictation: return "Agent 原生听写"
        case .typeless: return "Typeless"
        case .unknown: return "不支持的语音来源"
        }
    }
}
