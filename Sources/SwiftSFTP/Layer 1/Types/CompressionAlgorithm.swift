/// An SSH compression algorithm family requested or negotiated for one direction of a connection.
public enum CompressionAlgorithm: Int, Codable, Sendable, CaseIterable {
    /// No SSH transport compression.
    case none = 0
    /// Zlib compression, preferring its OpenSSH variant that starts after authentication.
    case zlib = 1

    var openSSHStrings: [String] {
        switch self {
        case .none:
            ["none"]
        case .zlib:
            ["zlib@openssh.com", "zlib"]
        }
    }

    static func sanitizePreferencesArray(_ array: [Self]) -> [Self] {
        (array + [.none]).uniqued()
    }

    init(negotiatedMethod: String?) {
        guard let negotiatedMethod else {
            self = .none
            return
        }

        self = Self.allCases.first { $0.openSSHStrings.contains(negotiatedMethod) } ?? .none
    }
}
