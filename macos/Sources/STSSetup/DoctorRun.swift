import STSSetupCore
import SwiftUI

/// One run of `sts doctor --fix`, revealed a section at a time.
///
/// The script prints its whole report in well under a second, which reads
/// as a flash of text. Sections are shown one after another instead, each
/// only once it is complete, at a pace the eye can follow. The checks
/// themselves are real and already finished; only the reveal is paced.
@MainActor
final class DoctorRun: ObservableObject {
    @Published private(set) var report = DoctorReport()
    @Published private(set) var shown = 0
    @Published private(set) var running = false
    @Published private(set) var passed: Bool?

    private var processDone = false
    private var exitStatus: Int32 = 0
    private var generation = 0

    static let pace: UInt64 = 350_000_000

    var visibleSections: ArraySlice<DoctorSection> { report.sections.prefix(shown) }

    /// The section being checked right now, for the spinner row.
    var upcoming: DoctorSection? {
        running && shown < report.sections.count ? report.sections[shown] : nil
    }

    func start(script: String) {
        generation += 1
        let gen = generation
        report = DoctorReport()
        shown = 0
        passed = nil
        processDone = false
        running = true

        Task.detached {
            let status = Shell.stream("/bin/bash", [script, "doctor", "--fix"]) { line in
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.report.add(line)
                }
            }
            await MainActor.run {
                guard self.generation == gen else { return }
                self.exitStatus = status
                self.processDone = true
            }
        }

        Task { @MainActor in
            while generation == gen {
                // A section is complete once the next one has started, or
                // the run is over.
                let complete = processDone ? report.sections.count : max(0, report.sections.count - 1)
                if shown < complete {
                    try? await Task.sleep(nanoseconds: Self.pace)
                    guard generation == gen else { return }
                    withAnimation(.easeOut(duration: 0.25)) { shown += 1 }
                } else if processDone {
                    try? await Task.sleep(nanoseconds: Self.pace / 2)
                    guard generation == gen else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        passed = exitStatus == 0
                        running = false
                    }
                    return
                } else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
    }
}

struct DoctorProgressView: View {
    @ObservedObject var run: DoctorRun

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(run.visibleSections) { section in
                DoctorSectionRow(section: section)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if run.running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).frame(width: 18)
                    Text(run.upcoming.map { "Checking \($0.displayTitle.lowercased())…" } ?? "Checking…")
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            if let passed = run.passed {
                resultBanner(passed)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder func resultBanner(_ passed: Bool) -> some View {
        let problems = run.report.sections.filter { $0.outcome == .fail }.count
        let warnings = run.report.sections.filter { $0.outcome == .warn }.count
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: passed ? (warnings == 0 ? "checkmark.seal.fill" : "checkmark.circle") : "xmark.octagon.fill")
                .foregroundStyle(passed ? .green : .red)
            if passed {
                Text(warnings == 0 ? "Everything checks out." : "Works, with \(warnings) thing\(warnings == 1 ? "" : "s") worth a look above.")
                    .fontWeight(.semibold)
            } else {
                Text("\(problems) thing\(problems == 1 ? "" : "s") to fix. Each one above says how.")
                    .fontWeight(.semibold)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill((passed ? Color.green : Color.red).opacity(0.10)))
    }
}

struct DoctorSectionRow: View {
    let section: DoctorSection
    @State private var expanded: Bool

    init(section: DoctorSection) {
        self.section = section
        // Problems open by themselves; a passing section stays one line.
        _expanded = State(initialValue: [.fail, .warn].contains(section.outcome))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon.frame(width: 18)
                    Text(section.displayTitle).fontWeight(.medium).foregroundStyle(.primary)
                        .layoutPriority(1)
                    Spacer(minLength: 12)
                    Text(section.summary).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(section.lines) { line in
                        detail(line)
                    }
                }
                .padding(.leading, 28)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder var icon: some View {
        switch section.outcome {
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .fixed:   Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.green)
        case .warn:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail:    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func detail(_ line: DoctorLine) -> some View {
        switch line.kind {
        case .plain:
            // The script's how-to-fix lines: commands, keep them exact.
            Text(line.message)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.leading, 18)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol(line.kind)).font(.caption).foregroundStyle(tint(line.kind)).frame(width: 12)
                Text(line.message).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func symbol(_ k: DoctorLine.Kind) -> String {
        switch k {
        case .ok:    return "checkmark"
        case .fixed: return "wrench.fill"
        case .warn:  return "exclamationmark.triangle"
        case .fail:  return "xmark"
        case .skip:  return "minus"
        default:     return "info.circle"
        }
    }

    func tint(_ k: DoctorLine.Kind) -> Color {
        switch k {
        case .ok, .fixed: return .green
        case .warn:       return .orange
        case .fail:       return .red
        default:          return .secondary
        }
    }
}
