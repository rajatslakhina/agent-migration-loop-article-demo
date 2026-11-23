/// Everything the loop needs from the outside world. In a real harness these call the
/// converter, `xcodebuild` and the coding agent; `ScriptedExecutor` replays fixed outcomes.
public protocol LoopExecutor: AnyObject {
    func convert(target: String) -> Patch
    func build(target: String) -> BuildResult
    /// Runs the target's tests once. Return `executedTests: 0` for a run that crashed,
    /// failed to start or ran nothing; the loop treats it as a failing run.
    func runTests(target: String, run: Int) -> TestRunResult
    func fixBuild(target: String, errors: [String], attempt: Int) -> AgentFix
    func fixFailingTests(target: String, failing: [TestFailure], attempt: Int) -> AgentFix
    /// Called only after `FixGuard` accepts a fix, before the next build. Apply the agent's
    /// diff to the migration branch here; a rejected fix never reaches this method.
    func apply(_ fix: AgentFix, target: String)
}

/// The loop from Depop's migration, with the agent as loop owner rather than converter:
/// convert (deterministic), build, fix build errors (agent), run the tests N times,
/// fix failures (agent), then route the PR. Every agent fix goes through `FixGuard`
/// first, and each fix phase stops after `contract.maxFixAttempts`.
public struct MigrationLoop: Sendable {
    public let contract: LoopContract

    public init(contract: LoopContract = LoopContract()) {
        self.contract = contract
    }

    public func run(target: String, executor: LoopExecutor) -> LoopReport {
        var recorder = Recorder(target: target)

        // 1. Converter. Deterministic, never guarded, but its scope still matters for routing.
        let conversion = executor.convert(target: target)
        recorder.log(.deterministic, "Run converter", "\(conversion.files.count) file(s) changed")
        for file in conversion.files where !contract.isInTestScope(file.path) {
            recorder.reviewReasons.append("Converter changed \(file.path), outside the test scope")
        }

        // 2-3. Build, with bounded agent fixes.
        var attempts = 0
        while case .failed(let errors) = executor.build(target: target) {
            recorder.log(.deterministic, "Build for testing", "Failed with \(errors.count) error(s)")
            guard attempts < contract.maxFixAttempts else {
                return recorder.handBack("Build still failing after \(attempts) agent fix attempt(s)")
            }
            attempts += 1
            let fix = executor.fixBuild(target: target, errors: errors, attempt: attempts)
            if let rejection = recorder.apply(fix, attempt: attempts, phase: "build errors", contract: contract) {
                return rejection
            }
            executor.apply(fix, target: target)
        }
        recorder.log(.deterministic, "Build for testing", "Succeeded")

        // 4-5. Repeated test runs, with bounded agent fixes.
        attempts = 0
        while true {
            let failures = runRepeatedly(target: target, executor: executor)
            guard let first = failures.first else {
                recorder.log(.deterministic, "Run tests \(contract.repetitions)×", "0 failures in \(contract.repetitions) runs")
                break
            }
            let summary = failures.count == 1 ? first.summary : "\(failures.count) failing tests; \(first.summary)"
            recorder.log(.deterministic, "Run tests \(contract.repetitions)×", summary)
            guard attempts < contract.maxFixAttempts else {
                return recorder.handBack("Tests still failing after \(attempts) agent fix attempt(s): \(summary)")
            }
            attempts += 1
            let fix = executor.fixFailingTests(target: target, failing: failures, attempt: attempts)
            if let rejection = recorder.apply(fix, attempt: attempts, phase: "failing tests", contract: contract) {
                return rejection
            }
            executor.apply(fix, target: target)
            if case .failed(let errors) = executor.build(target: target) {
                recorder.log(.deterministic, "Build for testing", "Failed with \(errors.count) error(s)")
                return recorder.handBack("The agent's test fix broke the build")
            }
            recorder.log(.deterministic, "Build for testing", "Succeeded")
        }

        // 6. Route the PR.
        return recorder.finish()
    }

    /// The failure recorded for a run that executed no tests (crashed, didn't start, found none).
    public static let noTestsRan = "<run executed no tests>"

    /// Runs the tests `contract.repetitions` times and counts failures per test, sorted by name.
    func runRepeatedly(target: String, executor: LoopExecutor) -> [TestFailure] {
        var counts: [String: Int] = [:]
        for run in 1...contract.repetitions {
            let result = executor.runTests(target: target, run: run)
            if result.executedTests <= 0 {
                counts[Self.noTestsRan, default: 0] += 1
            }
            for name in result.failedTests {
                counts[name, default: 0] += 1
            }
        }
        return counts.keys.sorted().compactMap { name in
            guard let failed = counts[name] else { return nil }
            return TestFailure(name: name, failedRuns: failed, totalRuns: contract.repetitions)
        }
    }
}

/// Collects events and routing state for one run of the loop.
private struct Recorder {
    let target: String
    var events: [LoopEvent] = []
    var reviewReasons: [String] = []
    var appliedFixes: [AgentFix] = []
    var followUps: [String] = []

    init(target: String) {
        self.target = target
    }

    mutating func log(_ kind: StepKind, _ title: String, _ detail: String) {
        events.append(LoopEvent(id: events.count, kind: kind, title: title, detail: detail))
    }

    /// Returns a hand-back report if the guard rejects the fix, otherwise records it and returns nil.
    mutating func apply(_ fix: AgentFix, attempt: Int, phase: String, contract: LoopContract) -> LoopReport? {
        let title = "Agent fixes \(phase) (attempt \(attempt) of \(contract.maxFixAttempts))"
        guard fix.patch.files.contains(where: { $0.added != $0.removed }) else {
            // Rerunning unchanged code would only test luck: a flaky test can pass 100 runs by chance.
            log(.agent, title, "No change proposed")
            return handBack("The agent proposed no change for the \(phase)")
        }
        let check = FixGuard.check(fix.patch, contract: contract)
        guard check.isClean else {
            let reasons = check.violations.map(\.description).joined(separator: "; ")
            log(.agent, title, fix.note)
            log(.deterministic, "Fix guard", "Rejected: \(reasons)")
            return handBack("Agent fix rejected by the guard: \(reasons)")
        }
        log(.agent, title, fix.note)
        appliedFixes.append(fix)
        for followUp in check.followUps where !followUps.contains(followUp) {
            followUps.append(followUp)
        }
        reviewReasons.append("Agent fixed \(phase): \(fix.note)")
        return nil
    }

    mutating func handBack(_ reason: String) -> LoopReport {
        log(.deterministic, "Stop and hand back", reason)
        return report(.handBack(reason: reason))
    }

    mutating func finish() -> LoopReport {
        if reviewReasons.isEmpty {
            log(.deterministic, "Open PR", "Auto-merge: test/mock-only diff, no agent edits, every run green")
            return report(.autoMerge)
        }
        log(.deterministic, "Open PR", "Tagged for human review with \(reviewReasons.count) reason(s)")
        return report(.humanReview(reasons: reviewReasons))
    }

    private func report(_ outcome: Outcome) -> LoopReport {
        LoopReport(target: target, events: events, outcome: outcome,
                   appliedFixes: appliedFixes, followUps: followUps)
    }
}
