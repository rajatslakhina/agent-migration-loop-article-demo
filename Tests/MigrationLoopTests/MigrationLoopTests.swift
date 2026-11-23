import Testing
@testable import MigrationLoop

private let testFile = "Features/Search/SearchTests/SearchCacheTests.swift"

private func outcomes(_ reports: [LoopReport]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: reports.map { ($0.target, $0.outcome.title) })
}

@Suite struct ContractTests {
    @Test func emptyScopeFallsBackToTheDefault() {
        #expect(LoopContract(testScopeSuffixes: [""]).testScopeSuffixes == ["Tests", "Mocks"])
        #expect(LoopContract(testScopeSuffixes: []).renderInstructions().contains("*Tests or *Mocks"))
    }

    @Test func clampsBudgets() {
        let contract = LoopContract(repetitions: 0, maxFixAttempts: -3)
        #expect(contract.repetitions == 1)
        #expect(contract.maxFixAttempts == 0)
    }

    @Test(arguments: [
        ("Features/Offers/OffersTests/OffersViewModelTests.swift", true),
        ("Features/Offers/OffersMocks/MockOffersService.swift", true),
        ("Features/Offers/Sources/OffersViewModel.swift", false),
        ("Features/Offers/OffersTests/../Sources/OffersViewModel.swift", false),
        ("Features/Offers/OffersTests/./OffersViewModelTests.swift", false),
        ("/Users/ci/OffersTests/OffersViewModelTests.swift", false),
        ("Features//OffersTests/OffersViewModelTests.swift", false),
        ("OffersTests.swift", false),
        ("TestingTools/Assertions.swift", false)
    ])
    func testScope(path: String, expected: Bool) {
        #expect(LoopContract().isInTestScope(path) == expected)
    }

    @Test func instructionsCarryTheContractsNumbers() {
        let text = LoopContract(repetitions: 25, maxFixAttempts: 3).renderInstructions(target: "SearchTests")
        #expect(text.contains("for SearchTests"))
        #expect(text.contains("25 times"))
        #expect(text.contains("repeat all 25 runs"))
        #expect(text.contains("You get 3 fix attempts"))
        #expect(text.contains("If that rebuild fails, the loop stops and hands back."))
        #expect(!text.contains("100"))
    }

    @Test func customScopeIsEnforced() {
        let contract = LoopContract(testScopeSuffixes: ["Specs"])
        #expect(contract.isInTestScope("Features/Search/SearchSpecs/CacheSpec.swift"))
        #expect(!contract.isInTestScope("Features/Search/SearchTests/CacheTests.swift"))
    }

    @Test func instructionsDescribeTheNetTestCount() {
        let text = LoopContract().renderInstructions()
        #expect(text.contains("no net loss of @Test lines across the patch"))
    }

    @Test func instructionsUseTheCustomScope() {
        let text = LoopContract(testScopeSuffixes: ["Specs"]).renderInstructions()
        #expect(text.contains("*Specs"))
        #expect(!text.contains("*Mocks"))
        #expect(!text.contains("*Tests"))
    }

    @Test func instructionsListEveryRuleTheGuardChecks() {
        let text = LoopContract().renderInstructions()
        let rules = FixGuard.disablingMarkers + FixGuard.testConfigurationExtensions
        for rule in rules {
            #expect(text.contains(rule), "missing \(rule)")
        }
    }

    @Test func instructionsForAZeroBudget() {
        let text = LoopContract(maxFixAttempts: 0).renderInstructions()
        #expect(text.contains("Do not attempt fixes"))
        #expect(text.contains("100 times"))
    }

    @Test func instructionsSeparateCheckedRulesFromGuidance() throws {
        let text = LoopContract().renderInstructions()
        let checked = try #require(text.range(of: "Checked on every fix"))
        let guidance = try #require(text.range(of: "Guidance (not machine-checked"))
        let mainActor = try #require(text.range(of: "@MainActor on its suite"))
        #expect(checked.lowerBound < guidance.lowerBound)
        #expect(mainActor.lowerBound > guidance.lowerBound)
    }
}

@Suite struct FixGuardTests {
    let contract = LoopContract()

    @Test func rejectsDeletingATest() {
        let patch = Patch(files: [FileChange(path: testFile, removed: ["@Test func flaky() {", "}"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesTests(count: 1)])
    }

    @Test func commentingOutATestIsARemoval() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["// @Test func flaky() {"],
                                             removed: ["@Test func flaky() {"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesTests(count: 1)])
    }

    @Test func allowsEditingATestDeclaration() {
        let patch = Patch(files: [FileChange(path: testFile,
                                             added: ["@Test(.timeLimit(.minutes(1))) func slow() {"],
                                             removed: ["@Test func slow() {"])])
        #expect(FixGuard.check(patch, contract: contract).isClean)
    }

    @Test func allowsMovingATestBetweenFiles() {
        let patch = Patch(files: [
            FileChange(path: testFile, removed: ["@Test func moved() {"]),
            FileChange(path: "Features/Search/SearchTests/SearchRankingTests.swift", added: ["@Test func moved() {"])
        ])
        #expect(FixGuard.check(patch, contract: contract).isClean)
    }

    @Test(arguments: [
        ("@Test(.disabled(\"flaky\")) func a() {", ".disabled"),
        ("withKnownIssue { try check() }", "withKnownIssue"),
        ("@Test(.enabled(if: false)) func a() {", ".enabled("),
        ("@Test(.enabled(if: !isCI)) func a() {", ".enabled("),
        ("@Test(.enabled(\"flaky\") { false }) func a() {", ".enabled("),
        ("@Test(.enabled { false }) func a() {", ".enabled {"),
        ("try Test.cancel(\"flaky on CI\")", "Test.cancel"),
        ("@Test(arguments: []) func a(value: Int) {", "arguments: []"),
        ("@Test(arguments:[ ]) func a(value: Int) {", "arguments: []"),
        ("#if false", "#if false"),
        ("#if  false", "#if false"),
        ("#if 0", "#if 0"),
        ("} /* hide the next test", "/*"),
        ("@available(*, unavailable) @Test func a() {", "@available(")
    ])
    func rejectsNewDisablingMarkers(line: String, marker: String) {
        let patch = Patch(files: [FileChange(path: testFile, added: ["    " + line])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.disablesTest(path: testFile, marker: marker)])
    }

    @Test func swappingATestForAPlaceholderIsCaught() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["@Test func placeholder() {}"],
                                             removed: ["@Test func retriesDeclinedCard() async throws {"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.dropsTest(name: "retriesDeclinedCard")])
    }

    @Test func movingATestIntoANonSwiftFileIsARemoval() {
        let patch = Patch(files: [
            FileChange(path: testFile, removed: ["@Test func flaky() {"]),
            FileChange(path: testFile + ".disabled", added: ["@Test func flaky() {"])
        ])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesTests(count: 1)])
    }

    @Test func markersAreCountedPerFile() {
        let other = "Features/Search/SearchTests/SearchRankingTests.swift"
        let line = "@Test(.disabled(\"x\")) func a() {"
        let patch = Patch(files: [FileChange(path: testFile, removed: [line]),
                                  FileChange(path: other, added: [line])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.disablesTest(path: other, marker: ".disabled")])
    }

    @Test func aTrailingCommentDoesNotDeclareATest() {
        let patch = Patch(files: [FileChange(path: testFile,
                                             added: ["func retries() async throws { // was @Test"],
                                             removed: ["@Test func retries() async throws {"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesTests(count: 1)])
    }

    @Test func guardUsesTheContractsScope() {
        let specs = LoopContract(testScopeSuffixes: ["Specs"])
        let inScope = "Features/Search/SearchSpecs/CacheSpec.swift"
        let outOfScope = "Features/Search/SearchTests/CacheTests.swift"
        #expect(FixGuard.check(Patch(files: [FileChange(path: inScope, added: ["x"])]), contract: specs).isClean)
        #expect(FixGuard.check(Patch(files: [FileChange(path: outOfScope, added: ["x"])]), contract: specs).violations
                == [.outsideTestScope(path: outOfScope)])
    }

    @Test func allowsKeepingAnExistingFeatureFlagTrait() {
        let patch = Patch(files: [FileChange(path: testFile,
                                             added: ["@Test(.enabled(if: Flags.search), .timeLimit(.minutes(1))) func a() {"],
                                             removed: ["@Test(.enabled(if: Flags.search)) func a() {"])])
        #expect(FixGuard.check(patch, contract: contract).isClean)
    }

    @Test(arguments: ["Features/Search/SearchTests/SearchTests.xctestplan",
                      "Features/Search/SearchTests/SearchTests.xcscheme",
                      "Features/Search/SearchTests/SearchTests.xcconfig"])
    func rejectsTestConfigurationEdits(path: String) {
        let patch = Patch(files: [FileChange(path: path, added: ["\"skippedTests\" : [\"SearchCacheTests\"]"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.editsTestConfiguration(path: path)])
    }

    @Test func rejectsEditsOutsideTestScope() {
        let path = "Features/Search/Sources/SearchCache.swift"
        let patch = Patch(files: [FileChange(path: path, added: ["nonisolated(unsafe) static var shared"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.outsideTestScope(path: path)])
    }

    @Test func serializedIsAllowedButFiled() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["@Suite(.serialized) struct SearchCacheTests {"],
                                             removed: ["@Suite struct SearchCacheTests {"])])
        let report = FixGuard.check(patch, contract: contract)
        #expect(report.isClean)
        #expect(report.followUps.count == 1)
    }
}

@Suite struct LoopTests {
    @Test func happyPathAutoMergesWithoutAgentSteps() {
        let executor = ScriptedExecutor(script: .init(conversion: SampleTargets.converted(testFile)))
        let report = MigrationLoop().run(target: "SearchTests", executor: executor)
        #expect(report.outcome == .autoMerge)
        #expect(report.events.allSatisfy { $0.kind == .deterministic })
        #expect(executor.fixCalls == 0)
        #expect(executor.testRunCalls == 100)
    }

    @Test func runsTheTestsExactlyRepetitionsTimes() {
        let executor = ScriptedExecutor(script: .init(conversion: SampleTargets.converted(testFile)))
        _ = MigrationLoop(contract: LoopContract(repetitions: 37)).run(target: "SearchTests", executor: executor)
        #expect(executor.testRunCalls == 37)
    }

    @Test func eachPhaseGetsItsOwnFixBudget() {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["x"])]), note: "n")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, builds: [.failed(errors: ["e"])],
                                                      testPhases: [["A/b()": 2], ["A/b()": 2], [:]],
                                                      buildFixes: [fix], testFixes: [fix, fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(executor.fixCalls == 3)
        #expect(report.appliedFixes.count == 3)
        #expect(executor.applyCalls == 3)
        #expect(report.outcome.title == "Human review")
    }

    @Test func aTestFixRebuildsAndRerunsAllRuns() {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["x"])]), note: "n")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 11], [:]], testFixes: [fix]))
        _ = MigrationLoop().run(target: "T", executor: executor)
        #expect(executor.testRunCalls == 200)
        #expect(executor.buildCalls == 2)
    }

    @Test func converterOutsideTestScopeNeedsAHuman() {
        let path = "Features/Search/Sources/SearchService.swift"
        let executor = ScriptedExecutor(script: .init(conversion: Patch(files: [FileChange(path: path, added: ["x"])])))
        let report = MigrationLoop().run(target: "SearchTests", executor: executor)
        #expect(report.outcome == .humanReview(reasons: ["Converter changed \(path), outside the test scope"]))
    }

    @Test func converterRoutingUsesTheContractsScope() {
        let path = "Features/Search/SearchTests/CacheTests.swift"
        let executor = ScriptedExecutor(script: .init(conversion: Patch(files: [FileChange(path: path, added: ["x"])])))
        let report = MigrationLoop(contract: LoopContract(testScopeSuffixes: ["Specs"])).run(target: "T", executor: executor)
        #expect(report.outcome == .humanReview(reasons: ["Converter changed \(path), outside the test scope"]))
    }

    @Test func zeroBudgetHandsBackWithoutCallingTheAgent() {
        let executor = ScriptedExecutor(script: .init(conversion: .empty, builds: [.failed(errors: ["e"])]))
        let report = MigrationLoop(contract: LoopContract(maxFixAttempts: 0)).run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "Build still failing after 0 agent fix attempt(s)"))
        #expect(executor.fixCalls == 0)
    }

    @Test func buildThatNeverRecoversStopsAtTheBudget() {
        let failing = BuildResult.failed(errors: ["e"])
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["x"])]), note: "n")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, builds: [failing, failing, failing, failing],
                                                      buildFixes: [fix, fix, fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "Build still failing after 2 agent fix attempt(s)"))
        #expect(executor.fixCalls == 2)
        #expect(executor.buildCalls == 3)
    }

    @Test func buildFixThatDeletesATestHandsBack() {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, removed: ["@Test func a() {"])]), note: "n")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, builds: [.failed(errors: ["e"])],
                                                      buildFixes: [fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "Agent fix rejected by the guard: removes 1 test"))
        #expect(report.appliedFixes.isEmpty)
        #expect(executor.buildCalls == 1)
        #expect(executor.applyCalls == 0)
    }

    @Test func aRunThatExecutesNoTestsIsNeverGreen() {
        let executor = ScriptedExecutor(script: .init(conversion: SampleTargets.converted(testFile), executedTests: 0))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome != .autoMerge)
        #expect(report.events.contains { $0.detail == "\(MigrationLoop.noTestsRan) failed in 100 of 100 runs" })
    }

    @Test func countsFlakyFailuresAcrossRuns() {
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 11]]))
        let failures = MigrationLoop().runRepeatedly(target: "T", executor: executor)
        #expect(failures == [TestFailure(name: "A/b()", failedRuns: 9, totalRuns: 100)])
        #expect(failures.first?.isFlaky == true)
    }

    @Test func aTestFailingEveryRunIsNotFlaky() {
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 1]]))
        let failures = MigrationLoop().runRepeatedly(target: "T", executor: executor)
        #expect(failures.first?.failedRuns == 100)
        #expect(failures.first?.isFlaky == false)
    }

    @Test func testFixThatDeletesATestIsNeverApplied() {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, removed: ["@Test func a() {"])]), note: "n")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 2]], testFixes: [fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "Agent fix rejected by the guard: removes 1 test"))
        #expect(executor.applyCalls == 0)
        #expect(executor.buildCalls == 1)
    }

    @Test func emptyFixHandsBackInsteadOfRerunningUnchangedCode() {
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 3], [:]]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(executor.fixCalls == 1)
        #expect(executor.testRunCalls == 100)
        #expect(report.appliedFixes.isEmpty)
        #expect(report.outcome == .handBack(reason: "The agent proposed no change for the failing tests"))
        #expect(executor.applyCalls == 0)
        #expect(report.events.contains { $0.kind == .agent && $0.detail == "No change proposed" })
    }

    @Test func noOpPatchHandsBackLikeAnEmptyOne() {
        let noOp = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["a"], removed: ["a"])]), note: "n")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 3], [:]], testFixes: [noOp]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "The agent proposed no change for the failing tests"))
    }

    @Test func testFixThatBreaksTheBuildHandsBack() {
        let executor = ScriptedExecutor(script: .init(
            conversion: .empty,
            builds: [.succeeded, .failed(errors: ["e"])],
            testPhases: [["A/b()": 2], [:]],
            testFixes: [AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["x"])]), note: "n")]
        ))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "The agent's test fix broke the build"))
    }
}

@Suite struct SampleTargetTests {
    let reports = SampleTargets.runAll()

    @Test func outcomesMatchTheArticle() {
        #expect(outcomes(reports) == [
            "OffersTests": "Auto-merge",
            "FiltersTests": "Human review",
            "SearchTests": "Human review",
            "ProfileTests": "Human review",
            "CheckoutTests": "Handed back",
            "NotificationsTests": "Handed back"
        ])
    }

    @Test func checkoutIsRejectedForDeletingItsFlakyTest() throws {
        let checkout = try #require(reports.first { $0.target == "CheckoutTests" })
        #expect(checkout.outcome == .handBack(reason: "Agent fix rejected by the guard: removes 1 test"))
        #expect(checkout.appliedFixes.isEmpty)
        #expect(checkout.events.contains { $0.detail == "PaymentSheetTests/retriesDeclinedCard() failed in 14 of 100 runs (flaky)" })
    }

    @Test func notificationsTripsTheCircuitBreakerAfterTwoFixes() throws {
        let notifications = try #require(reports.first { $0.target == "NotificationsTests" })
        #expect(notifications.appliedFixes.count == 2)
        #expect(notifications.outcome == .handBack(reason:
            "Tests still failing after 2 agent fix attempt(s): BadgeCountTests/clearsBadgeOnOpen() failed in 20 of 100 runs (flaky)"))
    }

    @Test func profileNeedsMainActorAndFilesOneFollowUp() throws {
        let profile = try #require(reports.first { $0.target == "ProfileTests" })
        #expect(profile.appliedFixes.count == 2)
        #expect(profile.followUps.count == 1)
        #expect(profile.events.contains { $0.detail == "AvatarViewModelTests/loadsAvatarImage() failed in 25 of 100 runs (flaky)" })
        #expect(profile.appliedFixes.last?.note.contains("@MainActor") == true)
    }

    @Test func searchFailsNineOfAHundredBeforeTheFix() throws {
        let search = try #require(reports.first { $0.target == "SearchTests" })
        #expect(search.events.contains { $0.detail == "SearchCacheTests/cachedResultsAreReused() failed in 9 of 100 runs (flaky)" })
        #expect(search.events.last?.title == "Open PR")
    }
}
