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
    /// Test/mock-only diff, no agent edits, every repeated run green.
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
}
