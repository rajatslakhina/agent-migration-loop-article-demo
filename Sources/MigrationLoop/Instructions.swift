extension LoopContract {
    /// Renders the contract as the instructions handed to the coding agent.
    ///
    /// Every number in the text comes from the contract, and the rules are split into the
    /// ones `FixGuard` checks on every fix, the ones it records on every fix (the
    /// `.serialized` follow-up), and guidance that nothing checks.
    public func renderInstructions(target: String = "<target>") -> String {
        let scope = testScopeSuffixes.map { "*\($0)" }.joined(separator: " or ")
        let markers = FixGuard.disablingMarkers.joined(separator: ", ")
        let configs = FixGuard.testConfigurationExtensions.joined(separator: " or ")
        let budget: String
        switch maxFixAttempts {
        case 0: budget = "Do not attempt fixes; stop and hand back."
        case 1: budget = "You get 1 fix attempt, then stop and hand back."
        default: budget = "You get \(maxFixAttempts) fix attempts, then stop and hand back."
        }
        return """
        You own the migration loop for \(target). You do not convert code yourself.

        1. (Deterministic) Run \(converterCommand). Do not edit its output before the build.
        2. (Deterministic) Run \(buildCommand).
        3. (Agent) If the build fails, fix only the reported errors. \(budget)
        4. (Deterministic) Run \(testCommand) \(repetitions) times. A test that fails in any run counts as failing.
        5. (Agent) Fix the failing tests, rebuild, and repeat all \(repetitions) runs. If that rebuild fails, the loop stops and hands back. \(budget)
        6. (Deterministic) Open the PR. It auto-merges only if you made no edits and every changed file is in a \(scope) directory. Otherwise it goes to human review with your notes.

        Checked on every fix (a violation stops the loop and hands back):
        - Edit only files inside \(scope) directories.
        - Never delete or disable a test: no net loss of @Test lines across the patch (moving a test between Swift files is fine), no removed test name that doesn't reappear, no commented-out @Test lines, no new \(markers) in any file, and no \(configs) edits.

        Recorded on every fix:
        - Adding .serialized is allowed as a temporary measure; the loop files a follow-up for it.

        Guidance (not machine-checked; the first rule is from Depop's migration guide):
        - Anything that touches UI or a @MainActor-isolated type gets @MainActor on its suite.
        - In every note, say what you changed and why.
        """
    }
}
