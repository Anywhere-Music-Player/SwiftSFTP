/// Carries a non-`Sendable` value across an isolation boundary after its sole owner has given it up.
///
/// Use only where a manual handoff (e.g. state cleared under a lock immediately after capture) already rules out
/// concurrent access; this type does nothing to enforce that itself.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
