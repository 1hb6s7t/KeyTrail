import Foundation

/// Monotonic scheduling only: no credentials, journals, network or user data.
/// The resident maintenance timer supplies opportunities to inspect local work.
struct PrivateSyncSchedule {
    static let localCheckInterval: TimeInterval = 2
    static let heartbeatInterval: TimeInterval = 60
    private var nextLocalCheck: TimeInterval = -.infinity
    private var nextHeartbeat: TimeInterval = -.infinity
    private var nextAttempt: TimeInterval = -.infinity
    private var failureCount = 0

    func shouldInspect(at now: TimeInterval, force: Bool) -> Bool {
        force || (now >= nextLocalCheck && now >= nextAttempt)
    }

    mutating func inspected(at now: TimeInterval) {
        nextLocalCheck = now + Self.localCheckInterval
    }

    func shouldContactRemote(at now: TimeInterval, pendingChanges: Bool, force: Bool) -> Bool {
        force || pendingChanges || failureCount > 0 || now >= nextHeartbeat
    }

    mutating func succeeded(at now: TimeInterval) {
        failureCount = 0
        nextAttempt = -.infinity
        nextLocalCheck = now + Self.localCheckInterval
        nextHeartbeat = now + Self.heartbeatInterval
    }

    mutating func failed(at now: TimeInterval) {
        failureCount = min(6, failureCount + 1)
        nextAttempt = now + min(60, pow(2, Double(failureCount)))
    }
}
