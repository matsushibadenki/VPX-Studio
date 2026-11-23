import AppKit
import SwiftUI
import AVKit

private struct TakeReviewRow: Identifiable {
    let asset: TakeManifest.Asset
    let status: TakeManifest.IntegrityStatus
    var id: String { asset.relativePath }
}

struct TakeReviewView: View {
    @Bindable var studio: StudioModel
    @Bindable var localization: LocalizationStore
    var initialDirectory: URL? = nil
    @State private var review = TakeReviewModel()
    @State private var playback = TakePlaybackModel()
    @State private var assetRestoreTask: Task<Void, Never>?
    @State private var assetRestoreError: String?
    @State private var selectedPlaybackPath: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localization.text(.takeIntegrity), systemImage: "checkmark.shield").font(.headline)
                Spacer()
                Button {
                    guard let directory = review.directory, let snapshot = review.snapshot, let path = selectedPlaybackPath else { return }
                    playback.play(directory: directory, snapshot: snapshot, relativePath: path)
                } label: { Image(systemName: "play.fill") }
                .disabled(!canPlaySelection || review.isLoading || playback.isPreparing)
                .help(localization.text(.playTakeAsset)).accessibilityLabel(localization.text(.playTakeAsset))
                Button { restoreSelectedAsset() } label: { Image(systemName: "cube.transparent") }
                    .disabled(!canRestoreSelection || assetRestoreTask != nil)
                    .help(localization.text(.restoreTakeScene))
                    .accessibilityLabel(localization.text(.restoreTakeScene))
                Button { restoreSelectedAsset(role: .calibration) } label: { Image(systemName: "camera.aperture") }
                    .disabled(!canRestoreCalibration || assetRestoreTask != nil)
                    .help(localization.text(.restoreTakeCalibration))
                    .accessibilityLabel(localization.text(.restoreTakeCalibration))
                Button { restoreSelectedAsset(role: .lut) } label: { Image(systemName: "circle.lefthalf.filled") }
                    .disabled(!canRestoreLUT || assetRestoreTask != nil)
                    .help(localization.text(.restoreTakeLUT))
                    .accessibilityLabel(localization.text(.restoreTakeLUT))
                Button { saveSnapshot() } label: { Image(systemName: "square.and.arrow.down") }
                    .disabled(review.isLoading)
                    .help(localization.text(.saveTakeSnapshot)).accessibilityLabel(localization.text(.saveTakeSnapshot))
                Button { chooseDirectory() } label: { Image(systemName: "folder") }
                    .help(localization.text(.openTake)).accessibilityLabel(localization.text(.openTake))
                Button { playback.stop(); if let directory = review.directory { review.open(directory) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(review.directory == nil || review.isLoading)
                .help(localization.text(.recheckTake)).accessibilityLabel(localization.text(.recheckTake))
                if review.isLoading || playback.isPreparing || playback.player != nil {
                    Button { playback.stop(); review.cancel() } label: { Image(systemName: "stop.fill") }
                        .help(localization.text(.stop)).accessibilityLabel(localization.text(.stop))
                }
                Button(localization.text(.close)) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let assetRestoreError {
                Label(localization.text(.takeAssetRestoreFailed), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).help(assetRestoreError)
            }
            if review.isLoading {
                HStack { ProgressView().controlSize(.small); Text(localization.text(.takeChecking)) }
            } else if let error = review.error {
                Label(localization.text(.takeReadFailed), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).help(error)
            } else if let snapshot = review.snapshot {
                HStack {
                    Text(snapshot.manifest.name).font(.title3).lineLimit(1).help(snapshot.manifest.name)
                    Spacer()
                    Label(localization.text(snapshot.hasFailures ? .takeIntegrityFailed : snapshot.allVerified ? .takeVerified : .takeUnverified),
                          systemImage: snapshot.hasFailures ? "exclamationmark.triangle" : snapshot.allVerified ? "checkmark.shield.fill" : "questionmark.circle")
                        .foregroundStyle(snapshot.hasFailures ? .orange : snapshot.allVerified ? .green : .secondary)
                }
                HStack {
                    Text(snapshot.manifest.createdAt, style: .date)
                    Text(snapshot.manifest.configuration.liveVideoProfile.name)
                    Spacer()
                    Text(snapshot.inspectedAt, style: .time)
                }.font(.caption).foregroundStyle(.secondary)
                if let provenance = snapshot.manifest.provenance {
                    HStack {
                        Label(localization.text(provenance.kind == .configurationSnapshot ? .takeConfigurationSnapshot : .recording),
                              systemImage: provenance.kind == .configurationSnapshot ? "doc.text" : "record.circle")
                        Text("\(provenance.software.name) \(provenance.software.version) (\(provenance.software.build))")
                            .lineLimit(1).help(provenance.software.build)
                        Spacer()
                        Text("\(localization.text(.takeDevices)): \(provenance.devices.count)")
                        if let calibration = provenance.calibration {
                            Image(systemName: "camera.aperture").help("\(calibration.id.uuidString) · r\(calibration.revision)")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    if provenance.kind == .recording {
                        if let plugins = provenance.plugins, !plugins.isEmpty {
                            let names = plugins.map { "\($0.name) \($0.version)" }.joined(separator: " · ")
                            Label(names, systemImage: "puzzlepiece.extension")
                                .lineLimit(1).help(names)
                                .accessibilityLabel("\(localization.text(.takePlugins)): \(names)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(localization.text(provenance.plugins == nil ? .takePluginsUnknown : .takePluginsNone),
                                  systemImage: "puzzlepiece.extension")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let recording = provenance.recording {
                        HStack {
                            Label("\(recording.width) × \(recording.height)", systemImage: "film")
                            Text("\(localization.text(.takeWrittenFrames)): \(recording.writtenFrames)")
                            Text("\(localization.text(.takeRecorderDrops)): \(recording.recorderDrops)")
                                .help(localization.text(.recordingDrops))
                            if let gaps = recording.inputSequenceGaps {
                                Text("\(localization.text(.takeInputSequenceGaps)): \(gaps)")
                                    .help(localization.text(.takeInputSequenceGapsHelp))
                            }
                            if let pose = recording.pose {
                                Text("\(localization.text(.poseAlignment)): \(recording.writtenFrames - pose.missing)/\(recording.writtenFrames)")
                            }
                        }
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if let usages = recording.lutUsage {
                            DisclosureGroup("LUT") {
                                ForEach(usages, id: \.self) { usage in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(usage.reference?.name ?? "LUT") · \(localization.text(usage.applied ? .takeLUTApplied : .takeLUTNotApplied))")
                                        if let hash = usage.reference?.sha256 {
                                            Text("SHA-256 \(hash)").monospaced().textSelection(.enabled)
                                        }
                                    }
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        if let color = recording.colorConversion {
                            let policy = color.requested.map { $0.displayName(localization) }.joined(separator: " / ")
                            let applied = color.applied.map { $0.displayName(localization) }.joined(separator: " / ")
                            Label("\(localization.text(.takeColorPolicy)) \(policy) · \(localization.text(.takeColorApplied)) \(applied.isEmpty ? "—" : applied)",
                                  systemImage: "circle.lefthalf.filled")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let loss = recording.localInputLoss {
                            HStack {
                                Label("\(localization.text(.takeLocalInputDrops)) \(loss.droppedFrames)", systemImage: "video.slash")
                                Text("\(localization.text(.takeLocalDiscontinuities)) \(loss.discontinuities)")
                                if loss.unknownReasonEvents > 0 {
                                    Text("\(localization.text(.takeLocalUnknownLoss)) \(loss.unknownReasonEvents)")
                                }
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if let clock = recording.clock {
                            HStack {
                                Label(localization.text(.takeClockSamples), systemImage: "clock")
                                Text("\(localization.text(.takeClockCurrent)) \(clock.current)")
                                Text("\(localization.text(.takeClockStale)) \(clock.stale)")
                                Text("\(localization.text(.takeClockUnmeasured)) \(clock.unmeasured)")
                                if let peak = clock.peakUncertaintyMilliseconds {
                                    Text("\(localization.text(.takeClockPeak)) \(peak, specifier: "%.2f") ms")
                                }
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(localization.text(.takeProvenanceUnknown)).font(.caption).foregroundStyle(.secondary)
                }
                Table(zip(snapshot.manifest.assets, snapshot.results).map { TakeReviewRow(asset: $0.0, status: $0.1.status) }, selection: $selectedPlaybackPath) {
                    TableColumn(localization.text(.takeAssetRole)) { entry in
                        Text(localization.text(roleKey(entry.asset.role)))
                    }.width(90)
                    TableColumn(localization.text(.takeAssetPath)) { entry in
                        Text(entry.asset.relativePath).lineLimit(1).help(entry.asset.relativePath)
                    }
                    TableColumn(localization.text(.takeAssetStatus)) { entry in
                        let status = entry.status
                        Label(localization.text(statusKey(status)), systemImage: status == .verified ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(status == .verified ? Color.green : .orange)
                    }.width(130)
                }
                if playback.isPreparing {
                    HStack { ProgressView().controlSize(.small); Text(localization.text(.takePreparingPlayback)) }
                }
                if let error = playback.error {
                    Label(localization.text(.takePlaybackFailed), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(error)
                }
                if let player = playback.player {
                    VideoPlayer(player: player).frame(height: 240)
                    if let row = playback.currentAuxiliaryFrame {
                        HStack(spacing: 16) {
                            Label(String(row.frameIndex + 1), systemImage: "film")
                                .help(localization.text(.takeIndexedFrame))
                            Label(auxiliaryDimensions(row.matteWidth, row.matteHeight), systemImage: "circle.lefthalf.filled")
                                .help(localization.text(.mattePass))
                            Label(auxiliaryDimensions(row.depth.map { Int($0.width) }, row.depth.map { Int($0.height) }),
                                  systemImage: "square.3.layers.3d")
                                .help(localization.text(.depthPass))
                            Label(localization.text(PoseAlignmentTelemetry.Mode(rawValue: row.pose?.mode ?? "")?.localizationKey
                                ?? .poseAlignmentUnavailable), systemImage: "move.3d")
                                .help(localization.text(.poseAlignment))
                        }.font(.caption).monospacedDigit()
                    } else if playback.auxiliaryIndexFailed {
                        Label(localization.text(.takeFrameIndexError), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            } else {
                ContentUnavailableView(localization.text(.openTake), systemImage: "folder")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 820, height: playback.player == nil ? 520 : 720)
        .onAppear { if let initialDirectory, review.directory == nil { review.open(initialDirectory) } }
        .onDisappear { assetRestoreTask?.cancel(); playback.stop(); review.cancel() }
        .onChange(of: review.snapshot?.manifest.id) { _, _ in
            assetRestoreTask?.cancel()
            assetRestoreTask = nil
            assetRestoreError = nil
            playback.stop()
            selectedPlaybackPath = nil
        }
    }

    private func auxiliaryDimensions(_ width: Int?, _ height: Int?) -> String {
        guard let width, let height else { return "—" }
        return "\(width) × \(height)"
    }

    private var canRestoreSelection: Bool {
        guard studio.canRestoreTakeScene, !review.isLoading, let snapshot = review.snapshot,
              selectedPlaybackPath == "scene.vpx.json" else { return false }
        return snapshot.manifest.assets.contains { $0.role == .scene && $0.relativePath == selectedPlaybackPath }
            && snapshot.results.contains { $0.relativePath == selectedPlaybackPath && $0.status == .verified }
    }

    private var canRestoreCalibration: Bool {
        guard studio.canRestoreTakeScene, !review.isLoading, let snapshot = review.snapshot,
              let reference = snapshot.manifest.provenance?.calibration,
              reference.cameraID == studio.selectedSourceID,
              reference.relativePath == selectedPlaybackPath else { return false }
        return snapshot.results.contains { $0.relativePath == reference.relativePath && $0.status == .verified }
    }

    private var canRestoreLUT: Bool {
        guard studio.canRestoreTakeScene, !studio.isLoadingCompositeLUT, !review.isLoading,
              let snapshot = review.snapshot, let path = selectedPlaybackPath else { return false }
        return snapshot.manifest.assets.contains { $0.role == .lut && $0.relativePath == path }
            && snapshot.results.contains { $0.relativePath == path && $0.status == .verified }
    }

    private func restoreSelectedAsset(role: TakeManifest.Asset.Role = .scene) {
        let allowed = switch role {
        case .scene: canRestoreSelection
        case .calibration: canRestoreCalibration
        case .lut: canRestoreLUT
        default: false
        }
        guard allowed, let directory = review.directory, let snapshot = review.snapshot,
              let path = selectedPlaybackPath else { return }
        assetRestoreError = nil
        assetRestoreTask = Task {
            defer { if !Task.isCancelled { assetRestoreTask = nil } }
            do {
                let service = TakeReviewService()
                switch role {
                case .calibration:
                    let profile = try await service.restoreCalibration(directory: directory,
                        manifest: snapshot.manifest, relativePath: path)
                    try Task.checkCancellation()
                    guard review.snapshot?.manifest == snapshot.manifest, review.directory == directory else { return }
                    try studio.restoreTakeCalibration(profile)
                    dismiss()
                case .lut:
                    let lut = try await service.restoreLUT(directory: directory, manifest: snapshot.manifest, relativePath: path)
                    try Task.checkCancellation()
                    guard review.snapshot?.manifest == snapshot.manifest, review.directory == directory else { return }
                    if studio.restoreTakeLUT(lut) { dismiss() }
                case .scene:
                    let scene = try await service.restoreScene(directory: directory,
                        manifest: snapshot.manifest, relativePath: path)
                    try Task.checkCancellation()
                    guard review.snapshot?.manifest == snapshot.manifest, review.directory == directory else { return }
                    if studio.restoreTakeScene(scene) { dismiss() }
                default: break
                }
            } catch {
                if !Task.isCancelled { assetRestoreError = String(describing: error) }
            }
        }
    }

    private var canPlaySelection: Bool {
        guard let snapshot = review.snapshot, let path = selectedPlaybackPath else { return false }
        return snapshot.manifest.assets.contains { $0.relativePath == path && ($0.role == .camera || $0.role == .composite) }
            && snapshot.results.contains { $0.relativePath == path && $0.status == .verified }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = localization.text(.openTake)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            playback.stop()
            review.open(url)
        }
    }
    private func saveSnapshot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = localization.text(.saveTakeSnapshot)
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            do {
                let request = try studio.takeSnapshotRequest()
                let destination = parent.appendingPathComponent("VPX-Snapshot-\(request.manifest.id.uuidString)", isDirectory: true)
                playback.stop(); review.saveSnapshot(request, to: destination)
            } catch { review.showError(error) }
        }
    }
    private func statusKey(_ status: TakeManifest.IntegrityStatus) -> LocalizationKey {
        switch status {
        case .verified: .takeVerified
        case .unverified: .takeUnverified
        case .missing: .takeMissing
        case .modified: .takeModified
        case .unreadable: .takeUnreadable
        }
    }
    private func roleKey(_ role: TakeManifest.Asset.Role) -> LocalizationKey {
        switch role {
        case .camera: .takeCamera
        case .composite: .compositePass
        case .audio: .takeAudio
        case .matte: .mattePass
        case .depth: .depthPass
        case .pose: .tracking
        case .calibration: .calibrate
        case .scene: .scenePass
        case .color: .inputColor
        case .lut: .takeLUTAsset
        case .diagnostics: .diagnosticsHistory
        }
    }
}
