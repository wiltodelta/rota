import RotaCore
import SwiftUI

/// A selection sheet. Source apps are read only; imported routines start paused.
struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scans: [ImportScan]?
    @State private var chosen: Set<String> = []
    @State private var search = ""
    @State private var showImported = false
    /// nil preserves the agent and model from each source.
    @State private var harness: Harness?

    init(scans: [ImportScan]? = nil) {
        _scans = State(initialValue: scans)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 640, height: 500)
        .task {
            guard scans == nil else { return }
            scans = await Task.detached(priority: .userInitiated) { RoutineImport.scanAll() }.value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Import Routines").font(.title2.bold())
                Text("Choose routines to copy into Rota. They start paused.")
                    .foregroundStyle(Color.secondaryText)
            }
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryText)
                    TextField("Search routines", text: $search)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("importSearch")
                }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.5)))
                if importedCount > 0 {
                    Toggle("Show imported (\(importedCount))", isOn: $showImported)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .accessibilityIdentifier("showImported")
                }
            }
            .disabled(scans == nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var results: some View {
        if let scans {
            if scans.allSatisfy({ visible($0).isEmpty && $0.problem == nil }) {
                VStack(spacing: 8) {
                    Text(search.isEmpty ? "No routines to import" : "No matching routines").font(.headline)
                    Text(search.isEmpty
                         ? (importedCount > 0 ? "Already imported routines can be shown above."
                            : "No routines found in Claude Desktop or Codex.")
                         : "Try another name, project folder, or source app.")
                        .foregroundStyle(Color.secondaryText)
                }
                .accessibilityIdentifier("importEmpty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(scans, id: \.source) { scan in
                            let rows = visible(scan)
                            if !rows.isEmpty || scan.problem != nil {
                                sourceSection(scan, rows: rows)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .accessibilityIdentifier("importResults")
            }
        } else {
            ProgressView("Looking for routines…")
        }
    }

    private func sourceSection(_ scan: ImportScan, rows: [ImportCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(scan.source.title).font(.headline)
                Text("\(rows.count)").foregroundStyle(Color.secondaryText)
                Spacer()
                let ids = rows.filter(canImport).map(\.id)
                let all = !ids.isEmpty && Set(ids).isSubset(of: chosen)
                if !ids.isEmpty {
                    Button(all ? "Deselect All" : "Select All") {
                        if all { chosen.subtract(ids) } else { chosen.formUnion(ids) }
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("importSelect-\(scan.source.rawValue)")
                }
            }
            if let problem = scan.problem {
                Text(problem).foregroundStyle(Color.secondaryText)
                    .padding(.vertical, 12)
            }
            VStack(spacing: 0) {
                ForEach(rows) { candidate in
                    ImportRow(candidate: candidate, inRota: isImported(candidate), chosen: $chosen)
                    if candidate.id != rows.last?.id {
                        Divider().padding(.leading, 21)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent").foregroundStyle(Color.secondaryText)
                Picker("Agent", selection: $harness) {
                    Text("Original agent").tag(Harness?.none)
                    Divider()
                    ForEach(Harness.agents) { Text($0.title).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("importAgent")
                Spacer()
                Text("\(chosen.count) selected").foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("importSelectionCount")
            }
            HStack(spacing: 12) {
                // A fixed notice area keeps the action row stable in both states.
                Text(stillOn > 0
                     ? "Still active in source: \(stillOn). Pause there before enabling in Rota."
                     : "Source apps stay unchanged. Enable imported routines when you’re ready.")
                    .font(.caption)
                    .foregroundStyle(stillOn > 0 ? Color.warningText : Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32, alignment: .leading)
                    .accessibilityIdentifier("importNotice")
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? "Import" : "Import \(chosen.count)", action: importChosen)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
                    .accessibilityIdentifier("confirmImport")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var candidates: [ImportCandidate] { scans?.flatMap(\.candidates) ?? [] }
    private var importedCount: Int { candidates.filter(isImported).count }
    private var stillOn: Int { candidates.filter { chosen.contains($0.id) && $0.onInSource }.count }

    private func isImported(_ candidate: ImportCandidate) -> Bool {
        model.scheduler.routine(candidate.routine.id) != nil
    }

    private func canImport(_ candidate: ImportCandidate) -> Bool {
        candidate.unsupported == nil && !isImported(candidate)
    }

    private func visible(_ scan: ImportScan) -> [ImportCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return scan.candidates.filter { candidate in
            (showImported || !isImported(candidate)) && (query.isEmpty
                || [candidate.routine.name, candidate.routine.workingDirectory, scan.source.title]
                    .contains { $0.localizedStandardContains(query) })
        }
    }

    private func importChosen() {
        var first: String?
        for candidate in candidates where chosen.contains(candidate.id) && canImport(candidate) {
            var routine = candidate.routine
            if let harness, harness != candidate.source.harness {
                routine.harness = harness
                routine.model = nil
                routine.effort = nil
            }
            routine.enabled = false
            model.scheduler.save(routine)
            first = first ?? routine.id
        }
        model.selection = first.map { .routine($0) }
        dismiss()
    }
}

private struct ImportRow: View {
    let candidate: ImportCandidate
    let inRota: Bool
    @Binding var chosen: Set<String>

    var body: some View {
        Toggle(isOn: Binding(
            get: { inRota || chosen.contains(candidate.id) },
            set: { if $0 { chosen.insert(candidate.id) } else { chosen.remove(candidate.id) } }
        )) {
            content
        }
        .toggleStyle(.checkbox)
        .disabled(inRota || candidate.unsupported != nil)
        .accessibilityIdentifier(inRota ? "imported-\(candidate.id)" : "importChoice-\(candidate.id)")
        .padding(.vertical, 12)
        .help("\(candidate.routine.name)\n\(detail)")
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.routine.name)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(inRota ? Color.secondaryText : .primary)
                Text(detail).font(.caption).foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                if let reason = candidate.unsupported {
                    Text(reason).font(.caption).foregroundStyle(Color.errorText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(inRota ? "Already imported" : (candidate.onInSource ? "Active in source" : ""))
                .font(.caption)
                .foregroundStyle(Color.secondaryText)
                .frame(width: 100, alignment: .trailing)
                .accessibilityHidden(!inRota && !candidate.onInSource)
        }
    }

    private var detail: String {
        let routine = candidate.routine
        let schedule = ScheduleText.describe(routine.schedule) ?? routine.schedule
        var parts = [URL(fileURLWithPath: routine.workingDirectory).lastPathComponent, schedule]
        if let modelID = routine.model { parts.append(modelID) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
