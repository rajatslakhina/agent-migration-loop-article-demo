import Foundation

public enum GuardViolation: Equatable, Sendable, CustomStringConvertible {
    case outsideTestScope(path: String)
    case removesTests(count: Int)
    case removesAssertions(count: Int)
    case dropsTest(name: String)
    case disablesTest(path: String, marker: String)
    case editsTestConfiguration(path: String)

    public var description: String {
        switch self {
        case .outsideTestScope(let path):
            return "edits \(path), outside the test scope"
        case .removesTests(let count):
            return count == 1 ? "removes 1 test" : "removes \(count) tests"
        case .removesAssertions(let count):
            return count == 1 ? "removes 1 assertion line" : "removes \(count) assertion lines"
        case .dropsTest(let name):
            return "drops the test \(name)()"
        case .disablesTest(let path, let marker):
            return "adds \(marker) in \(path)"
        case .editsTestConfiguration(let path):
            return "edits \(path), which can skip tests"
        }
    }
}

/// One assertion line and the file it is in.
public struct AssertionLine: Equatable, Sendable {
    public let path: String
    /// The line's code: everything before a `//` comment, without leading or trailing spaces.
    /// A line containing `"""`, `#"`, `#/` or `\(` is kept whole, comment included.
    public let code: String

    public init(path: String, code: String) {
        self.path = path
        self.code = code
    }
}

/// The assertion lines a patch removes and adds. Within each file, lines that appear on
/// both sides (same code, ignoring a `//` comment and leading or trailing spaces; a line
/// containing `"""`, `#"`, `#/` or `\(` is compared whole, comment included) cancel out,
/// so reindenting or reordering inside a file is not listed; an assertion moved to another
/// file is listed as removed from one path and added to the other.
public struct AssertionDiff: Equatable, Sendable {
    public let removed: [AssertionLine]
    public let added: [AssertionLine]

    public init(removed: [AssertionLine], added: [AssertionLine]) {
        self.removed = removed
        self.added = added
    }

    public var isEmpty: Bool { removed.isEmpty && added.isEmpty }

    /// One line per change, `path: - old` then `path: + new`, for a reviewer to compare.
    public var lines: [String] {
        removed.map { "\($0.path): - \($0.code)" } + added.map { "\($0.path): + \($0.code)" }
    }
}

public struct GuardReport: Equatable, Sendable {
    public let violations: [GuardViolation]
    public let followUps: [String]
    /// Assertion lines the patch removes and adds, after per-file cancellation. A net loss is
    /// also reported as `removesAssertions` (unless the patch loses `@Test` lines, which is
    /// reported as `removesTests`); everything here is listed for the reviewer.
    public let assertionChanges: AssertionDiff

    public var isClean: Bool { violations.isEmpty }
}

/// Deterministic checks run on every agent fix before it is applied.
///
/// This is a lexical check, not a Swift parser. It counts `@Test` lines and assertion lines
/// (lines containing one of `contract.assertionMarkers`) across the patch, and disabling
/// markers per file (ignoring whitespace). It catches the obvious shortcuts: delete the flaky
/// test, comment it out, disable or condition it, wrap it in `#if false` or a block comment,
/// cancel it, empty its arguments on one line, skip it in a test plan, edit production code,
/// swap it for a differently named test, move it into a file that isn't Swift, or end up with
/// fewer assertion lines. Reworded assertion lines are listed for the reviewer, not rejected.
///
/// It misses subtler shortcuts, such as emptying a test's body of non-assertion code,
/// returning early, wrapping the body or an assertion in a runtime `if` (`if false {`,
/// `if !isCI {`; the assertion lines are unchanged, so neither counted nor listed), an assertion that can't fail (`#expect(true)`), editing the argument
/// lines of a multi-line assertion or the variable an assertion checks, deleting one
/// assertion while adding another (the count is net; both are listed), moving an assertion
/// within a file (for example above the code it checks), calling a helper that isn't in
/// `assertionMarkers`, moving an existing disabling marker from one test to another in the
/// same file, moving a test into a Swift file the target doesn't compile, skipping it
/// through a trait defined elsewhere, cancelling its task with `withUnsafeCurrentTask`, or
/// swapping an assertion for marker text in a string (`print("#expect(x)")`), which still
/// counts as an assertion line (both lines are listed), or wrapping existing lines in a new
/// multi-line string literal, which leaves the wrapped lines out of the diff.
///
/// Matching is textual, so it also has false positives: deleting a non-assertion line whose
/// marker text sits in a string, an existing block comment or a multi-line string body reads
/// as removing an assertion (README → Honest limits lists the others).
///
/// It checks the patch it is given: a real harness should build that patch in a fresh
/// worktree per attempt with `git add -A && git diff --cached --no-renames <base>`
/// (`<base>` = the commit the worktree started from), not from the agent's own description.
public enum FixGuard {
    /// Text that disables, conditions, cancels or hides a test, matched with whitespace
    /// removed from both sides. A file may not end up with more of any marker than it had:
    /// a marker that was already on a removed line can be re-added (editing an existing
    /// `.enabled(if: Flags.x)` trait is fine), a new one can't. `.enabled(` and `.enabled {`
    /// cover both forms of the condition trait. Any new `/*` counts, including a `/**` doc
    /// comment or a string such as `"image/*"`, and any new `.disabled` counts, including
    /// SwiftUI's `.disabled()` modifier. Any new `@available(` counts, because Swift Testing
    /// reports a test that availability makes unavailable as skipped.
    public static let disablingMarkers = [
        ".disabled", "withKnownIssue", ".enabled(", ".enabled {", "Test.cancel",
        "arguments: []", "#if false", "#if 0", "/*", "@available("
    ]
    /// The default text that marks an assertion line (matched with whitespace removed,
    /// before any `//`). `LoopContract.assertionMarkers` replaces it; pass
    /// `defaultAssertionMarkers + ["assertEvent("]` to add a helper.
    public static let defaultAssertionMarkers = [
        "#expect", "#require", "XCTAssert", "XCTFail", "XCTUnwrap", "Issue.record"
    ]
    /// Config files that commonly skip or exclude tests without touching Swift: test plans,
    /// schemes and build settings (for example `EXCLUDED_SOURCE_FILE_NAMES`).
    public static let testConfigurationExtensions = [".xctestplan", ".xcscheme", ".xcconfig"]

    public static func check(_ patch: Patch, contract: LoopContract) -> GuardReport {
        var violations: [GuardViolation] = []
        var followUps: [String] = []
        var removedTests = 0
        var addedTests = 0
        var removedNames: Set<String> = []
        var addedNames: Set<String> = []

        for file in patch.files {
            if !contract.isInTestScope(file.path) {
                violations.append(.outsideTestScope(path: file.path))
            }
            if testConfigurationExtensions.contains(where: { file.path.hasSuffix($0) }) {
                violations.append(.editsTestConfiguration(path: file.path))
            }
            removedTests += file.removed.filter { declaresTest($0) }.count
            removedNames.formUnion(file.removed.compactMap { testName($0) })
            // Only Swift files compile, so a test "moved" into `X.swift.disabled` is a removal.
            if file.path.hasSuffix(".swift") {
                addedTests += file.added.filter { declaresTest($0, added: true) }.count
                addedNames.formUnion(file.added.compactMap { testName($0, added: true) })
            }
            for marker in disablingMarkers
            where occurrences(of: marker, in: file.added) > occurrences(of: marker, in: file.removed) {
                violations.append(.disablesTest(path: file.path, marker: marker))
            }
            if occurrences(of: ".serialized", in: file.added) > occurrences(of: ".serialized", in: file.removed) {
                followUps.append("Remove .serialized from \(file.path) once the suite no longer needs it")
            }
        }
        // Counted across the whole patch, so moving a test between files is not a removal.
        let assertions = assertionDiff(patch, markers: contract.assertionMarkers)
        if removedTests > addedTests {
            violations.append(.removesTests(count: removedTests - addedTests))
        } else {
            // Names must survive too, so deleting a test and adding a placeholder isn't net zero.
            for name in removedNames.subtracting(addedNames).sorted() {
                violations.append(.dropsTest(name: name))
            }
            // A fix may reword an assertion line (listed for review) but not end up with fewer.
            // Not reported when tests were removed: removesTests already covers their asserts.
            if assertions.removed.count > assertions.added.count {
                violations.append(.removesAssertions(count: assertions.removed.count - assertions.added.count))
            }
        }
        return GuardReport(violations: violations, followUps: followUps, assertionChanges: assertions)
    }

    /// A line that declares a test. Anything after `//` is ignored, so turning
    /// `@Test func a()` into `// @Test func a()` or `func a() { // was @Test` is still a removal.
    /// Added lines are cut at the first `//` even inside a string (see `beforeAnySlashes`).
    static func declaresTest(_ line: String, added: Bool = false) -> Bool {
        (added ? beforeAnySlashes(line) : stripComment(line)).contains("@Test")
    }

    /// The line cut at its first `//`, string or not. Used to count added lines, so the count
    /// can only err low: a comment hidden behind a raw string or regex literal that
    /// `stripComment` can't follow (`#"\"# // @Test func a()`) never counts as an added test
    /// or assertion. The cost: a real added line with `//` in a string before its marker
    /// doesn't count, which reads as a removal, and a `//` between `@Test` and `func` (a
    /// display name with a URL, say) hides the test's name, so editing that line reads as
    /// dropping the test.
    static func beforeAnySlashes(_ line: String) -> String {
        line.components(separatedBy: "//").first ?? line
    }

    /// The line without a trailing `//` comment. A `//` inside a string literal (a URL, say)
    /// is kept: quotes are tracked, honouring `\"` escapes. A line containing `\"\"\"`, a raw
    /// string (`#"`), an extended regex literal (`#/`) or an interpolation (`\(`, which can nest
    /// a string) is returned whole, comment included,
    /// since the quote tracking can't follow those: for a removed line that errs toward
    /// counting a marker, never toward hiding one. A bare `/…/` regex literal isn't recognised.
    static func stripComment(_ line: String) -> String {
        if line.contains("\"\"\"") || line.contains("#\"") || line.contains("#/") || line.contains("\\(") { return line }
        var inString = false
        var escaped = false
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == "/", previous == "/" {
                return String(line[..<line.index(before: index)])
            }
            previous = inString ? nil : char
            index = line.index(after: index)
        }
        return line
    }

    /// The code part of a line: no `//` comment, no leading or trailing spaces.
    static func code(_ line: String) -> String {
        stripComment(line).trimmingCharacters(in: .whitespaces)
    }

    /// A line with an assertion. Anything after `//` is ignored, so commenting one out removes it.
    /// Added lines are cut at the first `//` even inside a string (see `beforeAnySlashes`).
    static func declaresAssertion(_ line: String, markers: [String], added: Bool = false) -> Bool {
        let compact = withoutWhitespace(added ? beforeAnySlashes(line) : code(line))
        return markers.contains { compact.contains(withoutWhitespace($0)) }
    }

    /// Assertion lines removed and added (added ones only in `.swift` files, since only those
    /// compile), with lines that appear on both sides of the same file cancelled out.
    public static func assertionDiff(_ patch: Patch, markers: [String] = defaultAssertionMarkers) -> AssertionDiff {
        var removed: [AssertionLine] = []
        var added: [AssertionLine] = []
        for file in patch.files {
            var remaining: [String: Int] = [:]
            let gone = file.removed.filter { declaresAssertion($0, markers: markers) }.map(code)
            for line in gone { remaining[line, default: 0] += 1 }
            var new: [String] = []
            if file.path.hasSuffix(".swift") {
                for line in file.added.filter({ declaresAssertion($0, markers: markers, added: true) }).map(code) {
                    if let count = remaining[line], count > 0 {
                        remaining[line] = count - 1
                    } else {
                        new.append(line)
                    }
                }
            }
            for line in gone where (remaining[line] ?? 0) > 0 {
                removed.append(AssertionLine(path: file.path, code: line))
                remaining[line, default: 0] -= 1
            }
            added.append(contentsOf: new.map { AssertionLine(path: file.path, code: $0) })
        }
        return AssertionDiff(removed: removed, added: added)
    }

    /// The function name on a line that declares a test, when `@Test` and `func` share the line.
    static func testName(_ line: String, added: Bool = false) -> String? {
        let text = added ? beforeAnySlashes(line) : stripComment(line)
        guard text.contains("@Test"), let range = text.range(of: "func ") else { return nil }
        let name = text[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    /// Counts `marker` in `lines`, ignoring all whitespace, so `arguments:[ ]` and
    /// `#if  false` match `arguments: []` and `#if false`.
    static func occurrences(of marker: String, in lines: [String]) -> Int {
        let needle = withoutWhitespace(marker)
        return lines.reduce(0) { $0 + withoutWhitespace($1).components(separatedBy: needle).count - 1 }
    }

    static func withoutWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
