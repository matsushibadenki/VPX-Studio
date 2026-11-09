import SwiftUI
import VPXCaptureProtocol

struct NodeMonitorView: View {
    @Bindable var studio: StudioModel
    @Bindable var localization: LocalizationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(localization.text(.nodeMonitor), systemImage: "network").font(.headline)
                Spacer()
                Button(localization.text(.close)) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Image(systemName: "person.3.sequence")
                Text(localization.text(.admissionLimits))
                Text("\(studio.admissionLimits.nodes) / \(studio.admissionLimits.videoStreams)").monospacedDigit()
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
            ScrollView {
                ForEach(studio.admissionEvents.reversed()) { event in
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(event.name).lineLimit(1).help(event.nodeID.uuidString)
                        Text(localization.text(rejectionKey(event.reason))).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(event.occurredAt, style: .time).monospacedDigit()
                    }.font(.caption).padding(.vertical, 4)
                }
                if studio.nodeMonitoring.isEmpty {
                    ContentUnavailableView(localization.text(.noConnectedDevices), systemImage: "iphone.slash")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12)], spacing: 12) {
                    ForEach(studio.nodeMonitoring) { node in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: node.selected ? "iphone.radiowaves.left.and.right" : "iphone")
                                Text(node.name).font(.headline).lineLimit(1).help(node.name)
                                Spacer(minLength: 8)
                                Button {
                                    studio.setNodeMediaSuspended(node.mediaControl?.suspended != true, nodeID: node.id)
                                } label: {
                                    Image(systemName: node.mediaControl?.suspended == true ? "play.fill" : "pause.fill")
                                }
                                .disabled(!node.connected || node.mediaControl?.pending != nil)
                                .help(localization.text(node.mediaControl?.suspended == true ? .resumeNodeMedia : .pauseNodeMedia))
                                .accessibilityLabel(localization.text(node.mediaControl?.suspended == true ? .resumeNodeMedia : .pauseNodeMedia))
                                Image(systemName: node.connected ? "circle.fill" : "circle")
                                    .foregroundStyle(node.connected ? .green : .secondary)
                                    .help(localization.text(node.connected ? .connected : .disconnected))
                            }
                            if node.mediaControl?.pending != nil {
                                Label(localization.text(.nodeMediaPending), systemImage: "clock").font(.caption)
                            } else if node.mediaControl?.failed == true {
                                Label(localization.text(.nodeMediaFailed), systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            } else if node.mediaControl?.suspended == true {
                                Label(localization.text(.nodeMediaPaused), systemImage: "pause.circle").font(.caption)
                            }
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                metric(.nodeFrameAge, milliseconds(node.frameAgeMilliseconds), warning: (node.frameAgeMilliseconds ?? .infinity) > 500)
                                metric(.decodeDuration, milliseconds(node.decodeMilliseconds))
                                metric(.tracking, localization.text(qualityKey(node.poseQuality)))
                                if let raw = node.trackingReason, let reason = CaptureQualityEvent.Reason(rawValue: raw) {
                                    metric(.trackingReason, localization.trackingReason(reason))
                                }
                                metric(.poseCaptureAge, milliseconds(node.poseAgeMilliseconds))
                                metric(.clock, localization.text(node.clock == .current ? .stateCurrent : node.clock == .stale ? .stateStale : .stateUnmeasured))
                                metric(.networkRTT, milliseconds(node.roundTripMilliseconds))
                                metric(.networkJitter, milliseconds(node.jitterMilliseconds))
                                metric(.nodeBattery, node.status?.batteryFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                                metric(.nodeThermal, thermal(node.status?.thermalState), warning: node.status?.thermalState == .serious || node.status?.thermalState == .critical)
                                metric(.nodeCapture, node.status.map { localization.text($0.isCapturing ? .nodeSending : .nodeIdle) } ?? localization.text(.stateUnmeasured))
                            }
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 760, height: 540)
    }

    private func metric(_ key: LocalizationKey, _ value: String, warning: Bool = false) -> some View {
        GridRow {
            Text(localization.text(key)).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(warning ? Color.orange : Color.primary)
        }
    }
    private func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
    private func rejectionKey(_ reason: NodeAdmissionPolicy.Rejection) -> LocalizationKey {
        switch reason {
        case .nodeLimit: .admissionNodeLimit
        case .videoLimit: .admissionVideoLimit
        case .identityChanged: .admissionIdentityChanged
        case .capabilitiesChanged: .admissionCapabilitiesChanged
        }
    }
    private func qualityKey(_ quality: StreamQuality) -> LocalizationKey {
        switch quality {
        case .nominal: .stateCurrent
        case .degraded: .stateDegraded
        case .estimated: .stateEstimated
        case .lost: .stateLost
        }
    }
    private func thermal(_ state: CaptureNodeStatus.ThermalState?) -> String {
        let key: LocalizationKey = switch state {
        case .nominal: .nodeThermalNominal
        case .fair: .nodeThermalFair
        case .serious: .nodeThermalSerious
        case .critical: .nodeThermalCritical
        default: .stateUnmeasured
        }
        return localization.text(key)
    }
}
