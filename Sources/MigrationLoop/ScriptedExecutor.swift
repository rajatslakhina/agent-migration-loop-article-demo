/// Replays a fixed script instead of calling a converter, `xcodebuild` or a model.
/// Used by the tests and the demo app, so both show the same outcomes.
public final class ScriptedExecutor: LoopExecutor {
    public struct Script: Equatable, Sendable {
        public var conversion: Patch
        /// Build results in call order. Once exhausted, every build succeeds.
        public var builds: [BuildResult]
        /// One entry per test phase: test name -> failure period. A test with period `p`
        /// fails on every run where `run % p == 0`, so period 11 fails 9 of 100 runs.
        /// The phase advances after each test fix; the last phase repeats.
        public var testPhases: [[String: Int]]
        public var buildFixes: [AgentFix]
        public var testFixes: [AgentFix]
        /// How many tests each run executes. 0 simulates a run that crashed or found no tests.
        public var executedTests: Int

        public init(conversion: Patch, builds: [BuildResult] = [], testPhases: [[String: Int]] = [],
                    buildFixes: [AgentFix] = [], testFixes: [AgentFix] = [], executedTests: Int = 12) {
            self.executedTests = executedTests
            self.conversion = conversion
            self.builds = builds
            self.testPhases = testPhases
            self.buildFixes = buildFixes
            self.testFixes = testFixes
        }
    }

    public let script: Script
    public private(set) var buildCalls = 0
    public private(set) var testRunCalls = 0
    public private(set) var fixCalls = 0
    public private(set) var applyCalls = 0
    private var phase = 0
    private var buildFixIndex = 0
    private var testFixIndex = 0

    public init(script: Script) {
        self.script = script
    }

    public func convert(target: String) -> Patch {
        script.conversion
    }

    public func build(target: String) -> BuildResult {
        defer { buildCalls += 1 }
        return script.builds.indices.contains(buildCalls) ? script.builds[buildCalls] : .succeeded
    }

    public func runTests(target: String, run: Int) -> TestRunResult {
        testRunCalls += 1
        guard let lastPhase = script.testPhases.indices.last else {
            return TestRunResult(executedTests: script.executedTests)
        }
        let periods = script.testPhases[min(phase, lastPhase)]
        let failed = Set(periods.compactMap { name, period in
            period > 0 && run % period == 0 ? name : nil
        })
        return TestRunResult(executedTests: script.executedTests, failedTests: failed)
    }

    public func fixBuild(target: String, errors: [String], attempt: Int) -> AgentFix {
        fixCalls += 1
        defer { buildFixIndex += 1 }
        return Self.element(script.buildFixes, at: buildFixIndex)
    }

    public func fixFailingTests(target: String, failing: [TestFailure], attempt: Int) -> AgentFix {
        fixCalls += 1
        phase += 1
        defer { testFixIndex += 1 }
        return Self.element(script.testFixes, at: testFixIndex)
    }

    public func apply(_ fix: AgentFix, target: String) {
        applyCalls += 1
    }

    private static func element(_ fixes: [AgentFix], at index: Int) -> AgentFix {
        fixes.indices.contains(index) ? fixes[index] : AgentFix(patch: .empty, note: "No change proposed")
    }
}
