/// The one place a lead writes down how a migration loop works.
///
/// `renderInstructions(target:)` is what the agent is told, and `MigrationLoop`
/// enforces the same run count, fix budget and test scope. Change one of those here and
/// the prompt and the enforcement change together, so they cannot drift apart. The
/// commands are only rendered into the prompt; a real `LoopExecutor` should read them
/// from the same contract.
public struct LoopContract: Equatable, Sendable {
    /// The deterministic converter. The agent runs it; it never rewrites tests itself.
    public let converterCommand: String
    public let buildCommand: String
    public let testCommand: String
    /// How many times the whole test target is run to expose flakiness. At least 1.
    public let repetitions: Int
    /// Agent fix attempts allowed in the build phase, and again in the test phase. At least 0.
    public let maxFixAttempts: Int
    /// A changed file is in test scope when one of its directories ends with one of these.
    /// At least one: an empty list falls back to the default `["Tests", "Mocks"]`.
    public let testScopeSuffixes: [String]

    public init(
        converterCommand: String = "swift-testing-revolutionary <test-target-dir>",
        buildCommand: String = "xcodebuild build-for-testing -scheme <scheme>",
        testCommand: String = "xcodebuild test-without-building -scheme <scheme>",
        repetitions: Int = 100,
        maxFixAttempts: Int = 2,
        testScopeSuffixes: [String] = ["Tests", "Mocks"]
    ) {
        self.converterCommand = converterCommand
        self.buildCommand = buildCommand
        self.testCommand = testCommand
        self.repetitions = max(1, repetitions)
        self.maxFixAttempts = max(0, maxFixAttempts)
        let suffixes = testScopeSuffixes.filter { !$0.isEmpty }
        self.testScopeSuffixes = suffixes.isEmpty ? ["Tests", "Mocks"] : suffixes
    }

    /// True when `path` is a relative path whose directories include one ending in a
    /// test-scope suffix, for example `Features/Search/SearchTests/SearchCacheTests.swift`.
    /// Absolute paths and paths with `.`, `..` or empty components are never in scope,
    /// so `SearchTests/../Search/Cache.swift` cannot pass as a test file.
    public func isInTestScope(_ path: String) -> Bool {
        guard !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return components.dropLast().contains { directory in
            testScopeSuffixes.contains { directory.hasSuffix($0) }
        }
    }
}
