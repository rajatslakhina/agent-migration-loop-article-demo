import SwiftUI
import MigrationLoop

@main
struct MigrationLoopDemoApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// Launch arguments, used by Scripts/simulator-screenshots.sh:
///   -tab targets|contract    which tab to open
///   -target <name>           open one target's timeline, e.g. -target ProfileTests
struct RootView: View {
    private let contract: LoopContract
    private let reports: [LoopReport]
    @State private var tab: String
    @State private var path: [String]

    init() {
        let contract = LoopContract()
        let defaults = UserDefaults.standard
        self.contract = contract
        reports = SampleTargets.runAll(contract: contract)
        _tab = State(initialValue: defaults.string(forKey: "tab") ?? "targets")
        _path = State(initialValue: defaults.string(forKey: "target").map { [$0] } ?? [])
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                TargetsView(reports: reports, contract: contract)
                    .navigationDestination(for: String.self) { name in
                        if let report = reports.first(where: { $0.target == name }) {
                            LoopTimelineView(report: report)
                        } else {
                            Text("Unknown target \(name)")
                        }
                    }
            }
            .tabItem { Label("Targets", systemImage: "list.bullet.rectangle") }
            .tag("targets")

            NavigationStack {
                ScrollView {
                    Text(contract.renderInstructions(target: "SearchTests"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Agent contract")
            }
            .tabItem { Label("Contract", systemImage: "doc.text") }
            .tag("contract")
        }
    }
}

struct TargetsView: View {
    let reports: [LoopReport]
    let contract: LoopContract

    private func count(_ title: String) -> Int {
        reports.filter { $0.outcome.title == title }.count
    }

    var body: some View {
        List {
            Section {
                Text("\(reports.count) targets · \(count("Auto-merge")) auto-merge · \(count("Human review")) human review · \(count("Handed back")) handed back")
                    .font(.subheadline)
                Text("Scripted replay: converter, build, \(contract.repetitions) test runs, agent fixes capped at \(contract.maxFixAttempts) per phase.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Test targets") {
                ForEach(reports, id: \.target) { report in
                    NavigationLink(value: report.target) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(report.target).font(.headline)
                                Spacer()
                                OutcomeBadge(outcome: report.outcome)
                            }
                            Text(detail(for: report))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Migration loop")
    }

    private func detail(for report: LoopReport) -> String {
        let fixes = report.appliedFixes.count
        return "\(report.events.count) steps · \(fixes) agent fix\(fixes == 1 ? "" : "es") applied"
    }
}

struct OutcomeBadge: View {
    let outcome: Outcome

    private var color: Color {
        switch outcome {
        case .autoMerge: return .green
        case .humanReview: return .orange
        case .handBack: return .red
        }
    }

    var body: some View {
        Text(outcome.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct LoopTimelineView: View {
    let report: LoopReport

    var body: some View {
        List {
            Section("Outcome") {
                OutcomeBadge(outcome: report.outcome)
                switch report.outcome {
                case .autoMerge:
                    Text("Test/mock-only diff, assertion counts kept, no agent edits, every run green.")
                case .humanReview(let reasons):
                    ForEach(Array(reasons.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                case .handBack(let reason):
                    Text(reason).font(.callout)
                }
            }
            // Shown before the loop: these are the lines a reviewer should compare first.
            if !report.assertionReview.isEmpty {
                Section("Assertions to compare") {
                    ForEach(Array(report.assertionReview.enumerated()), id: \.offset) { item in
                        Text(item.element).font(.caption.monospaced())
                    }
                }
            }
            Section("Loop") {
                ForEach(report.events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Text(event.kind == .agent ? "AGENT" : "DET")
                            .font(.caption2.monospaced().weight(.bold))
                            .frame(width: 46)
                            .padding(.vertical, 2)
                            .background((event.kind == .agent ? Color.purple : Color.blue).opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(event.kind == .agent ? Color.purple : Color.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title).font(.subheadline.weight(.semibold))
                            Text(event.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !report.followUps.isEmpty {
                Section("Follow-ups") {
                    ForEach(report.followUps, id: \.self) { Text($0).font(.callout) }
                }
            }
        }
        .navigationTitle(report.target)
        .navigationBarTitleDisplayMode(.inline)
    }
}
