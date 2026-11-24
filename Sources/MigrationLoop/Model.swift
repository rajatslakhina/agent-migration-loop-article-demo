/// One file in a diff, reduced to the lines it adds and removes.
public struct FileChange: Equatable, Sendable {
    public let path: String
    public let added: [String]
    public let removed: [String]

    public init(path: String, added: [String] = [], removed: [String] = []) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

public struct Patch: Equatable, Sendable {
    public let files: [FileChange]

    public init(files: [FileChange]) {
        self.files = files
    }

    public static let empty = Patch(files: [])
}

/// What the agent proposes when it is asked to fix something.
public struct AgentFix: Equatable, Sendable {
    public let patch: Patch
    public let note: String

    public init(patch: Patch, note: String) {
        self.patch = patch
        self.note = note
    }
}

public enum BuildResult: Equatable, Sendable {
    case succeeded
    case failed(errors: [String])
}

/// One run of a target's tests.
public struct TestRunResult: Equatable, Sendable {
    /// How many tests actually ran. Report 0 when the run crashed, failed to start or found
    /// no tests: the loop counts such a run as failing, so it can never look green.
    public let executedTests: Int
    /// Names of the tests that failed in this run.
    public let failedTests: Set<String>

    public init(executedTests: Int, failedTests: Set<String> = []) {
        self.executedTests = executedTests
        self.failedTests = failedTests
    }
}

/// A test that failed in at least one of the repeated runs.
public struct TestFailure: Equatable, Sendable {
    public let name: String
    public let failedRuns: Int
    public let totalRuns: Int

    /// Failed in some runs but not all of them.
    public var isFlaky: Bool { failedRuns < totalRuns }

    public var summary: String {
        "\(name) failed in \(failedRuns) of \(totalRuns) runs" + (isFlaky ? " (flaky)" : "")
    }
}

public enum StepKind: String, Equatable, Sendable {
    case deterministic
    case agent
}

public struct LoopEvent: Equatable, Sendable, Identifiable {
    public let id: Int
    public let kind: StepKind
    public let title: String
    public let detail: String
}

public enum Outcome: Equatable, Sendable {
    /// Test/mock-only diff, each converted file's assertion-line count kept, no agent edits,
    /// every repeated run green.
    case autoMerge
    /// The PR is opened but tagged for a human, with the reasons.
    case humanReview(reasons: [String])
    /// The loop stopped and gave the target back to a developer.
    case handBack(reason: String)

    public var title: String {
        switch self {
        case .autoMerge: return "Auto-merge"
        case .humanReview: return "Human review"
        case .handBack: return "Handed back"
        }
    }
}

public struct LoopReport: Equatable, Sendable {
    public let target: String
    public let events: [LoopEvent]
    public let outcome: Outcome
    /// Agent fixes that passed `FixGuard` and were handed to `LoopExecutor.apply(_:target:)`.
    public let appliedFixes: [AgentFix]
    public let followUps: [String]
    /// What a reviewer should compare: each agent fix's changed assertion lines, as
    /// `Fix N (phase), path: - old` / `path: + new` (`Rejected fix N …` for a fix the guard
    /// rejected), and each converted file whose assertion-line count changed, as
    /// `Converter, path: X assertion line(s) became Y`.
    public let assertionReview: [String]
    /// The same converter entries as data, for a harness that posts its own review comments.
    public let converterAssertionCounts: [ConverterAssertionCount]
    /// The same agent-fix entries as data, rejected fixes included.
    public let fixAssertionChanges: [FixAssertionChange]
}

/// A converted file whose assertion-line count changed, which sends the target to review.
public struct ConverterAssertionCount: Equatable, Sendable {
    public let path: String
    /// Assertion lines the converter removed from the file (the XCTest side).
    public let before: Int
    /// Assertion lines it added (counted only in `.swift` files).
    public let after: Int

    public init(path: String, before: Int, after: Int) {
        self.path = path
        self.before = before
        self.after = after
    }
}

/// The phase an agent fix belongs to. The raw value is the text used in reports.
public enum FixPhase: String, Equatable, Sendable {
    case buildErrors = "build errors"
    case failingTests = "failing tests"
}

/// The assertion lines one agent fix changed, whether or not the guard accepted it.
public struct FixAssertionChange: Equatable, Sendable {
    /// The attempt number within its phase, starting at 1.
    public let attempt: Int
    public let phase: FixPhase
    /// True when `FixGuard` rejected the fix and the target was handed back.
    public let rejected: Bool
    public let diff: AssertionDiff

    public init(attempt: Int, phase: FixPhase, rejected: Bool, diff: AssertionDiff) {
        self.attempt = attempt
        self.phase = phase
        self.rejected = rejected
        self.diff = diff
    }
}
