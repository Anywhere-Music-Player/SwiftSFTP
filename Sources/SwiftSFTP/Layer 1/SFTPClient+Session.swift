import Foundation

// MARK: SFTPClientProtocol + Session

public extension SFTPClient {
    var banner: String {
        get async throws {
            try withSessionIO {
                try checkClosed()

                guard let banner = SessionBannerGet(session: session) else {
                    throw NotLoggedIn()
                }

                return banner
            }
        }
    }

    var latency: TimeInterval {
        get async throws {
            try checkClosed()

            let start = Date()
            _ = try await currentWorkingDirectory
            return Date().timeIntervalSince(start)
        }
    }

    var timeout: TimeInterval {
        get {
            withSessionIO {
                guard !closed else {
                    return .zero
                }

                let value = SessionGetTimeout(session: session)

                if value == 0 {
                    return .infinity
                }
                else {
                    return TimeInterval(value) / 1000.0
                }
            }
        }
        set {
            withSessionIO {
                guard !closed else {
                    return
                }

                guard newValue != .infinity else {
                    SessionSetTimeout(session: session, timeoutMilliseconds: 0)
                    return
                }

                guard newValue.isFinite, newValue > 0 else {
                    return
                }

                SessionSetTimeout(session: session, timeOut: newValue)
            }
        }
    }
}
