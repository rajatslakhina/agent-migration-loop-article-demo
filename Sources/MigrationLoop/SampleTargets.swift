/// Six scripted test targets covering all three outcomes. The outcomes are fixed by the
/// scripts below; they illustrate the loop, they are not measurements. The remaining exits
/// (converter outside scope, empty fix, build budget spent, test fix breaks the build) are
/// pinned by unit tests.
public struct SampleTarget: Equatable, Sendable {
    public let name: String
    public let script: ScriptedExecutor.Script
}

public enum SampleTargets {
    public static let all: [SampleTarget] = [offers, filters, search, profile, checkout, notifications]

    public static func runAll(contract: LoopContract = LoopContract()) -> [LoopReport] {
        let loop = MigrationLoop(contract: contract)
        return all.map { loop.run(target: $0.name, executor: ScriptedExecutor(script: $0.script)) }
    }

    /// Happy path: converts, builds, 100 green runs, no agent edits.
    static let offers = SampleTarget(name: "OffersTests", script: .init(
        conversion: converted("Features/Offers/OffersTests/OffersViewModelTests.swift")
    ))

    /// The converter leaves an XCTest expectation behind; the agent fixes the build.
    static let filters = SampleTarget(name: "FiltersTests", script: .init(
        conversion: converted("Features/Filters/FiltersTests/FilterSelectionTests.swift"),
        builds: [.failed(errors: [
            "FilterSelectionTests.swift:41: cannot find 'expectation' in scope",
            "FilterSelectionTests.swift:47: cannot find 'wait' in scope"
        ])],
        buildFixes: [AgentFix(
            patch: Patch(files: [FileChange(
                path: "Features/Filters/FiltersTests/FilterSelectionTests.swift",
                added: ["await confirmation { applied in", "    store.onApply = { applied() }"],
                removed: ["let applied = expectation(description: \"filters applied\")",
                          "wait(for: [applied], timeout: 1)"]
            )]),
            note: "Replaced the leftover XCTest expectation and wait with Swift Testing's confirmation."
        )]
    ))

    /// A static cache shared between tests fails 9 of 100 parallel runs; the agent moves it into init.
    static let search = SampleTarget(name: "SearchTests", script: .init(
        conversion: converted("Features/Search/SearchTests/SearchCacheTests.swift"),
        testPhases: [["SearchCacheTests/cachedResultsAreReused()": 11], [:]],
        testFixes: [AgentFix(
            patch: Patch(files: [FileChange(
                path: "Features/Search/SearchTests/SearchCacheTests.swift",
                added: ["let cache = SearchCache()", "init() { service = SearchService(cache: cache) }"],
                removed: ["static let cache = SearchCache()"]
            )]),
            note: "Moved the static SearchCache into the suite's init so each test gets its own instance."
        )]
    ))

    /// A @MainActor view model: .serialized does not help, @MainActor on the suite does.
    static let profile = SampleTarget(name: "ProfileTests", script: .init(
        conversion: converted("Features/Profile/ProfileTests/AvatarViewModelTests.swift"),
        testPhases: [["AvatarViewModelTests/loadsAvatarImage()": 4],
                     ["AvatarViewModelTests/loadsAvatarImage()": 4],
                     [:]],
        testFixes: [
            AgentFix(
                patch: Patch(files: [FileChange(
                    path: "Features/Profile/ProfileTests/AvatarViewModelTests.swift",
                    added: ["@Suite(.serialized) struct AvatarViewModelTests {"],
                    removed: ["@Suite struct AvatarViewModelTests {"]
                )]),
                note: "Serialized the suite in case its tests share state."
            ),
            AgentFix(
                patch: Patch(files: [FileChange(
                    path: "Features/Profile/ProfileTests/AvatarViewModelTests.swift",
                    added: ["@MainActor @Suite(.serialized) struct AvatarViewModelTests {"],
                    removed: ["@Suite(.serialized) struct AvatarViewModelTests {"]
                )]),
                note: "Added @MainActor to the suite: AvatarViewModel is @MainActor, and the test only passed when it happened to run on the main thread."
            )
        ]
    ))

    /// The agent's "fix" for a flaky test is to delete it. The guard rejects it.
    static let checkout = SampleTarget(name: "CheckoutTests", script: .init(
        conversion: converted("Features/Checkout/CheckoutTests/PaymentSheetTests.swift"),
        testPhases: [["PaymentSheetTests/retriesDeclinedCard()": 7]],
        testFixes: [AgentFix(
            patch: Patch(files: [FileChange(
                path: "Features/Checkout/CheckoutTests/PaymentSheetTests.swift",
                removed: ["@Test func retriesDeclinedCard() async throws {",
                          "    #expect(await sheet.retry() == .succeeded)",
                          "}"]
            )]),
            note: "Removed the flaky test retriesDeclinedCard(); the rest of the suite now passes."
        )]
    ))

    /// Two plausible fixes, neither works: the circuit breaker hands it back.
    static let notifications = SampleTarget(name: "NotificationsTests", script: .init(
        conversion: converted("Features/Notifications/NotificationsTests/BadgeCountTests.swift"),
        testPhases: [["BadgeCountTests/clearsBadgeOnOpen()": 5]],
        testFixes: [
            AgentFix(
                patch: Patch(files: [FileChange(
                    path: "Features/Notifications/NotificationsTests/BadgeCountTests.swift",
                    added: ["await store.flush()"]
                )]),
                note: "Awaited the badge store's pending writes before asserting."
            ),
            AgentFix(
                patch: Patch(files: [FileChange(
                    path: "Features/Notifications/NotificationsTests/BadgeCountTests.swift",
                    added: ["defaults.removePersistentDomain(forName: suiteName)"]
                )]),
                note: "Cleared the suite's UserDefaults domain in init."
            )
        ]
    ))

    /// A converter diff for one test file: one XCTest method becomes one @Test.
    static func converted(_ path: String) -> Patch {
        Patch(files: [FileChange(
            path: path,
            added: ["import Testing", "@Test func behaves() async throws {", "#expect(result == expected)"],
            removed: ["import XCTest", "func testBehaves() async throws {", "XCTAssertEqual(result, expected)"]
        )])
    }
}
