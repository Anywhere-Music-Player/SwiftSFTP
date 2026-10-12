import Foundation

// MARK: SFTPClientProtocol + Compression

public extension SFTPClient {
    /// Returns the compression negotiated for both directions of the connection.
    var compression: (clientToServer: CompressionAlgorithm, serverToClient: CompressionAlgorithm) {
        withSessionIO {
            guard !closed else {
                return (.none, .none)
            }

            return (
                clientToServer: CompressionAlgorithm(
                    negotiatedMethod: SessionMethods(session: session, methodType: .compressClientToServer)
                ),
                serverToClient: CompressionAlgorithm(
                    negotiatedMethod: SessionMethods(session: session, methodType: .compressServerToClient)
                )
            )
        }
    }
}

// MARK: Compression configuration

extension SFTPClient {
    /// Applies compression preferences before handshake, falling back to no compression in both directions on failure.
    static func configureCompression(
        session: borrowing LibSSH2Session,
        clientToServerPreferences: String,
        serverToClientPreferences: String
    ) {
        do {
            try SessionFlag(
                session: session,
                flag: .compress,
                value: clientToServerPreferences != "none" || serverToClientPreferences != "none"
            )
            try SessionMethodPreference(
                session: session,
                methodType: .compressClientToServer,
                preferences: clientToServerPreferences
            )
            try SessionMethodPreference(
                session: session,
                methodType: .compressServerToClient,
                preferences: serverToClientPreferences
            )
        }
        catch {
            try? SessionFlag(session: session, flag: .compress, value: false)
            // Replace any preferences applied before the failure so handshake advertises only `none`.
            try? SessionMethodPreference(session: session, methodType: .compressClientToServer, preferences: "none")
            try? SessionMethodPreference(session: session, methodType: .compressServerToClient, preferences: "none")
        }
    }
}
