import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ value: Bool, _ message: String) throws {
    if !value { throw CheckFailure(description: message) }
}

@main
struct SyncSchedulingChecks {
    static func main() throws {
        var schedule = PrivateSyncSchedule()
        var remoteTimes: [Int] = []
        var localChecks = 0
        for second in 0...180 {
            let now = Double(second)
            guard schedule.shouldInspect(at: now, force: false) else { continue }
            localChecks += 1
            schedule.inspected(at: now)
            if schedule.shouldContactRemote(at: now, pendingChanges: false, force: false) {
                remoteTimes.append(second)
                schedule.succeeded(at: now)
            }
        }
        try require(remoteTimes == [0, 60, 120, 180], "idle network requests were not limited to startup and minute heartbeats")
        try require(localChecks == 91, "idle local checks did not respect the two-second interval")
        print("PASS idle simulation: 4 remote contacts / 181 one-second pump opportunities, 91 inspection opportunities")

        // Place new work at every phase between maintenance ticks. A successful
        // empty run must not delay newly pending work until the remote heartbeat.
        for tenth in 1...100 {
            let changedAt = Double(tenth) / 10
            var candidate = PrivateSyncSchedule()
            candidate.succeeded(at: 0)
            var contactedAt: Double?
            for tick in 1...14 {
                let now = Double(tick)
                guard candidate.shouldInspect(at: now, force: false) else { continue }
                candidate.inspected(at: now)
                if candidate.shouldContactRemote(at: now, pendingChanges: now >= changedAt, force: false) {
                    contactedAt = now; break
                }
            }
            try require(contactedAt != nil && contactedAt! >= changedAt && contactedAt! - changedAt <= 3,
                        "new journal work missed the three-second scheduling budget at \(changedAt)")
        }
        print("PASS 100 changed-data phases schedule within 3 seconds under a one-second pump")

        schedule = PrivateSyncSchedule()
        schedule.succeeded(at: 0)
        for now in [2.0, 4.0, 6.0] {
            try require(schedule.shouldInspect(at: now, force: false), "bounded catch-up was blocked")
            schedule.inspected(at: now)
            try require(schedule.shouldContactRemote(at: now, pendingChanges: true, force: false), "remaining journal pages waited for heartbeat")
            schedule.succeeded(at: now)
        }
        try require(!schedule.shouldContactRemote(at: 65, pendingChanges: false, force: false) && schedule.shouldContactRemote(at: 66, pendingChanges: false, force: false), "successful transfer failed to restart the idle heartbeat")
        print("PASS remaining catch-up pages run promptly; successful traffic restarts heartbeat")

        schedule = PrivateSyncSchedule()
        schedule.succeeded(at: 0)
        var failedAt = 10.0
        for delay in [2.0, 4.0, 8.0, 16.0, 32.0, 60.0, 60.0] {
            schedule.inspected(at: failedAt)
            schedule.failed(at: failedAt)
            try require(!schedule.shouldInspect(at: failedAt + delay - 0.001, force: false), "retry escaped exponential backoff")
            try require(schedule.shouldInspect(at: failedAt + 0.001, force: true), "force did not bypass backoff/local throttle")
            try require(schedule.shouldContactRemote(at: failedAt + 0.001, pendingChanges: false, force: true), "forced empty sync skipped remote status")
            failedAt += delay
            try require(schedule.shouldInspect(at: failedAt, force: false), "retry deadline missed")
            try require(schedule.shouldContactRemote(at: failedAt, pendingChanges: false, force: false), "failed request with now-empty journal was never retried")
        }
        schedule.succeeded(at: failedAt)
        try require(!schedule.shouldContactRemote(at: failedAt + 2, pendingChanges: false, force: false), "success failed to clear retry state")
        schedule.failed(at: failedAt + 2)
        try require(schedule.shouldInspect(at: failedAt + 4, force: false), "success failed to reset exponential backoff")
        print("PASS exponential backoff 2/4/8/16/32/60/60, force bypass and success recovery")

        schedule = PrivateSyncSchedule()
        try require(schedule.shouldInspect(at: 0, force: false) && schedule.shouldContactRemote(at: 0, pendingChanges: false, force: false), "configuration reset did not allow immediate replica check")
        print("PASS reset allows immediate startup/replica check")
        print("Passed 5 deterministic sync scheduling groups; no filesystem, network, Keychain or real input")
    }
}
