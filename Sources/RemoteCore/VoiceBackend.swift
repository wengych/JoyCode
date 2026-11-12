import Foundation

public enum VoiceBackend: Codable, Hashable {
    case nativeDictation
    case typeless
    /// Retain settings written by newer versions without discarding saved sessions.
    case unknown(String)

    public static let supported: [VoiceBackend] = [.nativeDictation, .typeless]

    public var rawValue: String {
        switch self {
        case .nativeDictation: return "nativeDictation"
        case .typeless: return "typeless"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "nativeDictation": self = .nativeDictation
        case "typeless": self = .typeless
        default: self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func validated() throws -> VoiceBackend {
        if case .unknown(let value) = self {
            throw VoiceBackendError.unsupportedBackend(value)
        }
        return self
    }
}

public enum VoiceBackendError: Error, Equatable, LocalizedError {
    case unsupportedBackend(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedBackend(let value):
            return "不支持语音后端“\(value)”，请重新选择语音后端。"
        }
    }
}
