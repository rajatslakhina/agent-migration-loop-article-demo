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
        let rules = FixGuard.disablingMarkers + FixGuard.testConfigurationExtensions + FixGuard.defaultAssertionMarkers
        #expect(text.contains("no net loss of assertion lines"))
        #expect(text.contains("as many assertion lines as the XCTest code it replaced"))
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

    @Test func rejectsDeletingAnAssertion() {
        let patch = Patch(files: [FileChange(path: testFile, removed: ["    #expect(cache.count == 1)"])])
        let report = FixGuard.check(patch, contract: contract)
        #expect(report.violations == [.removesAssertions(count: 1)])
        #expect(report.assertionChanges.removed == [AssertionLine(path: testFile, code: "#expect(cache.count == 1)")])
        #expect(report.assertionChanges.lines == ["\(testFile): - #expect(cache.count == 1)"])
    }

    @Test func commentingOutAnAssertionIsARemoval() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["// #expect(cache.count == 1)"],
                                             removed: ["#expect(cache.count == 1)"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func rewordedAssertionIsAllowedButListed() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["#expect(cache.count >= 1)"],
                                             removed: ["#expect(cache.count == 1)"])])
        let report = FixGuard.check(patch, contract: contract)
        #expect(report.isClean)
        #expect(report.assertionChanges.lines == ["\(testFile): - #expect(cache.count == 1)",
                                                 "\(testFile): + #expect(cache.count >= 1)"])
    }

    @Test func reindentedAssertionInTheSameFileIsNotAChange() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["        #expect(a == b)"],
                                             removed: ["    #expect(a == b)  // was flaky"])])
        let report = FixGuard.check(patch, contract: contract)
        #expect(report.isClean)
        #expect(report.assertionChanges.isEmpty)
    }

    @Test func assertionMovedToAnotherFileIsListedNotRejected() {
        let other = "Features/Search/SearchTests/SearchRankingTests.swift"
        let patch = Patch(files: [FileChange(path: testFile, removed: ["#expect(a == b)"]),
                                  FileChange(path: other, added: ["#expect(a == b)"])])
        let report = FixGuard.check(patch, contract: contract)
        #expect(report.isClean)
        #expect(report.assertionChanges.lines == ["\(testFile): - #expect(a == b)", "\(other): + #expect(a == b)"])
    }

    @Test func assertionsAreCountedAsAMultiset() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["#expect(a)"],
                                             removed: ["#expect(a)", "#expect(a)"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func assertionMovedIntoANonSwiftFileIsARemoval() {
        let patch = Patch(files: [FileChange(path: testFile, removed: ["#expect(a)"]),
                                  FileChange(path: testFile + ".disabled", added: ["#expect(a)"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func addedAssertionIsCleanAndListed() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["#expect(cache.isEmpty) // reset check"])])
        let report = FixGuard.check(patch, contract: contract)
        #expect(report.isClean)
        #expect(report.assertionChanges.lines == ["\(testFile): + #expect(cache.isEmpty)"])
    }

    @Test func droppedTestNameAndAssertionAreBothReported() {
        let patch = Patch(files: [FileChange(path: testFile, added: ["@Test func placeholder() {}"],
                                             removed: ["@Test func real() {", "#expect(x)"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.dropsTest(name: "real"), .removesAssertions(count: 1)])
    }

    @Test func customAssertionHelpersCount() {
        let helpers = LoopContract(assertionMarkers: FixGuard.defaultAssertionMarkers + ["assertEvent("])
        let patch = Patch(files: [FileChange(path: testFile, removed: ["assertEvent(.tap, in: events)"])])
        #expect(FixGuard.check(patch, contract: helpers).violations == [.removesAssertions(count: 1)])
        #expect(FixGuard.check(patch, contract: contract).isClean)
        #expect(LoopContract(assertionMarkers: [""]).assertionMarkers == FixGuard.defaultAssertionMarkers)
        #expect(LoopContract(assertionMarkers: [" ", "\t"]).assertionMarkers == FixGuard.defaultAssertionMarkers)
        #expect(LoopContract(assertionMarkers: ["", "assertEvent("]).assertionMarkers == ["assertEvent("])
        #expect(helpers.renderInstructions().contains("assertEvent("))
    }

    @Test func aDoubleSlashInsideAStringIsNotAComment() {
        let line = "#expect(url.absoluteString == \"https://example.com/a\") // host check"
        #expect(FixGuard.code(line) == "#expect(url.absoluteString == \"https://example.com/a\")")
        let patch = Patch(files: [FileChange(path: testFile, removed: [line])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func anEscapedQuoteDoesNotEndTheString() {
        #expect(FixGuard.code("#expect(s == \"a\\\"//b\") // c") == "#expect(s == \"a\\\"//b\")")
    }

    @Test func aMultiLineStringLineIsKeptWhole() {
        // Without the rule, the quote count would put this `//` outside a string.
        let line = ##"#expect(s == """a"b // c"##
        #expect(FixGuard.stripComment(line) == line)
    }

    @Test func deletingAnInterpolatedLineWithAnAssertionIsCounted() {
        // Without the `\(` rule, the nested quotes would cut this line before the marker.
        let line = #"let s = "\(a ?? "//")"; #expect(ok)"#
        #expect(FixGuard.code(line) == line)
        let patch = Patch(files: [FileChange(path: testFile, removed: [line])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func deletingAnExtendedRegexLineWithAnAssertionIsCounted() {
        // Without the `#/` rule, the quote count would cut this line before the marker.
        let line = ##"let r = #/a"/#; let s = "x//"; #expect(ok)"##
        #expect(FixGuard.code(line) == line)
        let patch = Patch(files: [FileChange(path: testFile, removed: [line])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func aCommentHiddenBehindARawStringDoesNotAddATest() {
        let patch = Patch(files: [FileChange(path: testFile,
                                             added: [##"let s = #"\"# // @Test func flaky() {"##],
                                             removed: ["@Test func flaky() {"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesTests(count: 1)])
    }

    @Test func aCommentHiddenBehindARegexLiteralDoesNotAddAnAssertion() {
        let patch = Patch(files: [FileChange(path: testFile,
                                             added: [##"let r = #/"/# // #expect(x == 1)"##],
                                             removed: ["#expect(x == 1)"])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
    }

    @Test func deletingARawStringLineWithAnAssertionIsCounted() {
        let line = ##"let s = #"a"b//c"#; #expect(ok)"##
        #expect(FixGuard.code(line) == line)
        let patch = Patch(files: [FileChange(path: testFile, removed: [line])])
        #expect(FixGuard.check(patch, contract: contract).violations == [.removesAssertions(count: 1)])
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

    @Test func converterThatDropsAnAssertionNeedsAHuman() {
        let conversion = Patch(files: [FileChange(path: testFile,
                                                  added: ["@Test func a() {", "#expect(x == 1)"],
                                                  removed: ["func testA() {", "XCTAssertEqual(x, 1)", "XCTAssertNotNil(y)"])])
        let report = MigrationLoop().run(target: "T", executor: ScriptedExecutor(script: .init(conversion: conversion)))
        #expect(report.outcome == .humanReview(reasons: [
            "Converter changed the assertion count in \(testFile): 2 XCTest assertion line(s) became 1"]))
        #expect(report.assertionReview == ["Converter, \(testFile): 2 assertion line(s) became 1"])
        #expect(report.converterAssertionCounts == [ConverterAssertionCount(path: testFile, before: 2, after: 1)])
    }

    @Test func converterCountIsCheckedPerFile() {
        let other = "Features/Search/SearchTests/SearchRankingTests.swift"
        let conversion = Patch(files: [
            FileChange(path: testFile, added: [], removed: ["XCTAssertTrue(a)"]),
            FileChange(path: other, added: ["#expect(b)", "#expect(c)"], removed: ["XCTAssertTrue(b)"])
        ])
        let report = MigrationLoop().run(target: "T", executor: ScriptedExecutor(script: .init(conversion: conversion)))
        #expect(report.outcome == .humanReview(reasons: [
            "Converter changed the assertion count in \(testFile): 1 XCTest assertion line(s) became 0",
            "Converter changed the assertion count in \(other): 1 XCTest assertion line(s) became 2"]))
        #expect(report.assertionReview == ["Converter, \(testFile): 1 assertion line(s) became 0",
                                           "Converter, \(other): 1 assertion line(s) became 2"])
    }

    @Test func agentFixThatRewordsAnAssertionIsFlaggedForReview() throws {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["#expect(n >= 1)"],
                                                           removed: ["#expect(n == 1)"])]), note: "Relaxed the count check.")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 3], [:]], testFixes: [fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        guard case .humanReview(let reasons) = report.outcome else { Issue.record("expected human review"); return }
        #expect(reasons.contains("Fix 1 (failing tests) changed assertion lines; compare them before merging"))
        #expect(report.assertionReview == ["Fix 1 (failing tests), \(testFile): - #expect(n == 1)",
                                           "Fix 1 (failing tests), \(testFile): + #expect(n >= 1)"])
        #expect(report.fixAssertionChanges.map(\.rejected) == [false])
        #expect(report.fixAssertionChanges.first?.diff.lines.count == 2)
    }

    @Test func converterCheckUsesTheContractsMarkers() {
        let conversion = Patch(files: [FileChange(path: testFile, added: ["#expect(a)"],
                                                  removed: ["XCTAssertTrue(a)", "assertEvent(.tap, in: events)"])])
        let helpers = LoopContract(assertionMarkers: FixGuard.defaultAssertionMarkers + ["assertEvent("])
        let custom = MigrationLoop(contract: helpers).run(target: "T", executor: ScriptedExecutor(script: .init(conversion: conversion)))
        #expect(custom.assertionReview == ["Converter, \(testFile): 2 assertion line(s) became 1"])
        let plain = MigrationLoop().run(target: "T", executor: ScriptedExecutor(script: .init(conversion: conversion)))
        #expect(plain.outcome == .autoMerge)
    }

    @Test func converterAddsInANonSwiftFileDoNotCount() {
        let path = testFile + ".orig"
        let conversion = Patch(files: [FileChange(path: path, added: ["#expect(a)"], removed: ["XCTAssertTrue(a)"])])
        let report = MigrationLoop().run(target: "T", executor: ScriptedExecutor(script: .init(conversion: conversion)))
        #expect(report.assertionReview == ["Converter, \(path): 1 assertion line(s) became 0"])
    }

    @Test func buildFixThatChangesAnAssertionIsLabelledWithItsPhase() throws {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["#expect(try value() == 1)"],
                                                           removed: ["#expect(value() == 1)"])]), note: "Added try.")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, builds: [.failed(errors: ["e"])], buildFixes: [fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        guard case .humanReview(let reasons) = report.outcome else { Issue.record("expected human review"); return }
        #expect(reasons.contains("Fix 1 (build errors) changed assertion lines; compare them before merging"))
        #expect(report.assertionReview == ["Fix 1 (build errors), \(testFile): - #expect(value() == 1)",
                                           "Fix 1 (build errors), \(testFile): + #expect(try value() == 1)"])
    }

    @Test func rejectedFixListsTheAssertionsItRemoved() {
        let fix = AgentFix(patch: Patch(files: [FileChange(path: testFile, added: ["// flaky"],
                                                           removed: ["#expect(n == 1)"])]), note: "Dropped the check.")
        let executor = ScriptedExecutor(script: .init(conversion: .empty, testPhases: [["A/b()": 3]], testFixes: [fix]))
        let report = MigrationLoop().run(target: "T", executor: executor)
        #expect(report.outcome == .handBack(reason: "Agent fix rejected by the guard: removes 1 assertion line"))
        #expect(report.assertionReview == ["Rejected fix 1 (failing tests), \(testFile): - #expect(n == 1)"])
        #expect(report.fixAssertionChanges == [FixAssertionChange(
            attempt: 1, phase: .failingTests, rejected: true,
            diff: AssertionDiff(removed: [AssertionLine(path: testFile, code: "#expect(n == 1)")], added: []))])
        #expect(executor.applyCalls == 0)
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

    @Test func onlyCheckoutHasAssertionsToCompare() throws {
        let checkout = try #require(reports.first { $0.target == "CheckoutTests" })
        #expect(checkout.assertionReview == [
            "Rejected fix 1 (failing tests), Features/Checkout/CheckoutTests/PaymentSheetTests.swift: - #expect(await sheet.retry() == .succeeded)"])
        for report in reports where report.target != "CheckoutTests" {
            #expect(report.assertionReview.isEmpty, "\(report.target)")
        }
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
