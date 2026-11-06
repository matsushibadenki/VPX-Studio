import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticsHistoryView: View {
    @Bindable var studio: StudioModel
    @Bindable var localization: LocalizationStore
    @Environment(\.dismiss) private var dismiss
    @State private var nodeFilter = ""
    @State private var showsMeasurements = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localization.text(.diagnosticsHistory)).font(.headline)
                Spacer()
                Button {
                    if studio.isArchivingDiagnostics {
                        Task { await studio.stopDiagnosticsArchive() }
                    } else {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "VPX-events.jsonl"
                        panel.begin { response in
                            guard response == .OK, let url = panel.url else { return }
                            Task { await studio.startDiagnosticsArchive(to: url) }
                        }
                    }
                } label: {
                    Image(systemName: studio.isArchivingDiagnostics ? "stop.circle.fill" : "externaldrive.badge.plus")
                }
                .help(localization.text(studio.isArchivingDiagnostics ? .stopArchive : .archiveDiagnostics))
                .accessibilityLabel(localization.text(studio.isArchivingDiagnostics ? .stopArchive : .archiveDiagnostics))
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help(localization.text(.close))
                    .accessibilityLabel(localization.text(.close))
            }
            DisclosureGroup(localization.text(.pipelineMeasurements), isExpanded: $showsMeasurements) {
                PipelineMeasurementsView(values: studio.pipelineMeasurements, poseAge: studio.poseCaptureAgeMilliseconds,
                                         localization: localization)
            }
            Picker(localization.text(.sources), selection: $nodeFilter) {
                Text(localization.text(.sources)).tag("")
                ForEach(Array(Set(studio.diagnosticHistory.compactMap(\.nodeID))).sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                    Text(id.uuidString).tag(id.uuidString)
                }
            }
            if studio.diagnosticHistory.isEmpty {
                ContentUnavailableView(localization.text(.noEvents), systemImage: "waveform.path.ecg")
            } else {
                List(studio.diagnosticHistory.reversed().filter { nodeFilter.isEmpty || $0.nodeID?.uuidString == nodeFilter }, id: \.sequence) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(event.timestamp, format: .dateTime.hour().minute().second())
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text(streamText(event.stream)).fontWeight(.medium)
                            Spacer()
                            Text("#\(event.sequence)").foregroundStyle(.secondary)
                        }
                        HStack {
                            if let previous = event.previousState {
                                Text(stateText(previous)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            }
                            Text(stateText(event.state))
                        }
                        if let node = event.nodeID {
                            Text(node.uuidString).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
            HStack {
                Text(localization.text(.discardedEvents))
                Text(studio.discardedDiagnosticEventCount, format: .number).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(minWidth: 600, idealWidth: 700, minHeight: 600, idealHeight: 680)
        .alert(localization.text(.diagnosticsExportFailed), isPresented: Binding(
            get: { studio.diagnosticsArchiveError != nil },
            set: { if !$0 { studio.diagnosticsArchiveError = nil } }
        )) {
            Button("OK") { studio.diagnosticsArchiveError = nil }
        } message: { Text(studio.diagnosticsArchiveError ?? "") }
    }

    private func streamText(_ stream: DiagnosticsEventHistory.Stream) -> String {
        localization.text(stream == .videoInput ? .sources : stream == .clock ? .clock : .tracking)
    }

    private func stateText(_ state: String) -> String {
        let key: LocalizationKey? = switch state {
        case "active", "nominal": .stateCurrent
        case "stale": .stateStale
        case "missing": .noInput
        case "unmeasured": .stateUnmeasured
        case "current": .stateCurrent
        case "lost": .stateLost
        case "degraded": .stateDegraded
        case "estimated": .stateEstimated
        default: nil
        }
        return key.map { localization.text($0) } ?? state
    }
}
