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
                }
            } else {
                ContentUnavailableView(localization.text(.openTake), systemImage: "folder")
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 820, height: playback.player == nil ? 520 : 720)
        .onAppear { if let initialDirectory, review.directory == nil { review.open(initialDirectory) } }
        .onDisappear { playback.stop(); review.cancel() }
        .onChange(of: review.snapshot?.manifest.id) { _, _ in playback.stop(); selectedPlaybackPath = nil }
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
        case .diagnostics: .diagnosticsHistory
        }
    }
}
