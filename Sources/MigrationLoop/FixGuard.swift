import Foundation

public enum GuardViolation: Equatable, Sendable, CustomStringConvertible {
    case outsideTestScope(path: String)
    case removesTests(count: Int)
    case dropsTest(name: String)
    case disablesTest(path: String, marker: String)
    case editsTestConfiguration(path: String)

    public var description: String {
        switch self {
        case .outsideTestScope(let path):
            return "edits \(path), outside the test scope"
        case .removesTests(let count):
            return count == 1 ? "removes 1 test" : "removes \(count) tests"
        case .dropsTest(let name):
            return "drops the test \(name)()"
        case .disablesTest(let path, let marker):
            return "adds \(marker) in \(path)"
        case .editsTestConfiguration(let path):
            return "edits \(path), which can skip tests"
        }
    }
}

public struct GuardReport: Equatable, Sendable {
    public let violations: [GuardViolation]
    public let followUps: [String]

    public var isClean: Bool { violations.isEmpty }
}

/// Deterministic checks run on every agent fix before it is applied.
///
/// This is a lexical check, not a Swift parser. It counts `@Test` lines across the patch
/// and disabling markers per file (ignoring whitespace), so it catches the obvious
/// shortcuts (delete the flaky test, comment it out, disable or condition it, wrap it in
/// `#if false` or a block comment, cancel it, empty its arguments on one line, skip it in
/// a test plan, edit production code, swap it for a differently named test, or move it
/// into a file that isn't Swift) and nothing subtler, such as emptying a test's body,
/// returning early, deleting assertions, moving an existing marker from one test to
/// another in the same file, moving a test into a Swift file the target doesn't compile,
/// skipping it through a trait defined elsewhere, or cancelling its task directly with
/// `withUnsafeCurrentTask`.
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
            removedTests += file.removed.filter(declaresTest).count
            removedNames.formUnion(file.removed.compactMap(testName))
            // Only Swift files compile, so a test "moved" into `X.swift.disabled` is a removal.
            if file.path.hasSuffix(".swift") {
                addedTests += file.added.filter(declaresTest).count
                addedNames.formUnion(file.added.compactMap(testName))
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
        if removedTests > addedTests {
            violations.append(.removesTests(count: removedTests - addedTests))
        } else {
            // Names must survive too, so deleting a test and adding a placeholder isn't net zero.
            for name in removedNames.subtracting(addedNames).sorted() {
                violations.append(.dropsTest(name: name))
            }
        }
        return GuardReport(violations: violations, followUps: followUps)
    }

    /// A line that declares a test. Anything after `//` is ignored, so turning
    /// `@Test func a()` into `// @Test func a()` or `func a() { // was @Test` is still a removal.
    static func declaresTest(_ line: String) -> Bool {
        let code = line.components(separatedBy: "//").first ?? ""
        return code.contains("@Test")
    }

    /// The function name on a line that declares a test, when `@Test` and `func` share the line.
    static func testName(_ line: String) -> String? {
        guard declaresTest(line), let range = line.range(of: "func ") else { return nil }
        let name = line[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
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
