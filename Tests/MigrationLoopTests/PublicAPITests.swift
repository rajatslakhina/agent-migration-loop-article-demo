import Testing
import MigrationLoop  // deliberately not @testable: this file only sees the public API

@Suite struct PublicAPITests {
    @Test func assertionDiffCanBeBuiltOutsideTheModule() {
        let path = "Features/Search/SearchTests/SearchCacheTests.swift"
        let patch = Patch(files: [FileChange(path: path, removed: ["#expect(a)"])])
        let report = FixGuard.check(patch, contract: LoopContract())
        #expect(report.violations == [.removesAssertions(count: 1)])
        #expect(report.assertionChanges
                == AssertionDiff(removed: [AssertionLine(path: path, code: "#expect(a)")], added: []))
        // The report's structured views can be built for comparison too.
        #expect(ConverterAssertionCount(path: path, before: 2, after: 1).after == 1)
        #expect(FixAssertionChange(attempt: 1, phase: .failingTests, rejected: true,
                                   diff: report.assertionChanges).diff.lines == ["\(path): - #expect(a)"])
    }
}
