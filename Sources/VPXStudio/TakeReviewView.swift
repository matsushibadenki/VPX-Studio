import AppKit
import SwiftUI
import AVKit
import UniformTypeIdentifiers

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
    @State private var selectedAudioPath: String?
    @State private var audioOffsetMilliseconds = 0
    @State private var audioEditTask: Task<Void, Never>?
    @State private var audioExportTask: Task<Void, Never>?
    @State private var exportedAudioMovie: URL?
    @State private var audioExportFailed = false
    @State private var mattePreviewTask: Task<Void, Never>?
    @State private var mattePreviewImage: CGImage?
    @State private var mattePreviewFailed = false
    @State private var auxiliaryPreviewFrame: Int?
    @State private var recompositionTask: Task<Void, Never>?
    @State private var recomposedImage: CGImage?
    @State private var recompositionError = false
    @State private var depthPreview: TakeReviewService.DepthPreview?
    @State private var depthPreviewFailed = false
    @State private var previewHasMatte = false
    @State private var previewDepthRow: TakeAuxiliaryTracks.Row?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localization.text(.takeIntegrity), systemImage: "checkmark.shield").font(.headline)
                Spacer()
                Button {
                    guard let directory = review.directory, let snapshot = review.snapshot, let path = selectedPlaybackPath else { return }
                    playback.play(directory: directory, snapshot: snapshot, relativePath: path,
                                  audioPath: path == "composite.mov" ? selectedAudioPath : nil,
                                  audioOffsetMilliseconds: audioOffsetMilliseconds)
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
                Button { restoreSelectedAsset(role: .diagnostics) } label: { Image(systemName: "slider.horizontal.3") }
                    .disabled(!canRestoreCompositeSettings || assetRestoreTask != nil)
                    .help(localization.text(.restoreTakeCompositeSettings))
                    .accessibilityLabel(localization.text(.restoreTakeCompositeSettings))
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
                DisclosureGroup(localization.text(.takeRecompositionAssets)) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), alignment: .leading)], alignment: .leading) {
                        ForEach(snapshot.recompositionAssets) { item in
                            Label("\(localization.text(roleKey(item.role))) · \(localization.text(statusKey(item.status)))",
                                  systemImage: item.status == .verified ? "checkmark.circle" : "circle.dashed")
                                .foregroundStyle(item.status == .verified ? Color.green : .secondary)
                        }
                    }.font(.caption)
                }.help(localization.text(.takeRecompositionAssetsHelp))
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
                if selectedPlaybackPath == "composite.mov" {
                    let audioAssets = zip(snapshot.manifest.assets, snapshot.results).filter {
                        $0.0.role == .audio && $0.1.status == .verified
                    }.map { $0.0 }
                    HStack {
                        Button(action: chooseIndependentAudio) {
                            Image(systemName: "waveform.badge.plus")
                        }
                        .disabled(audioEditTask != nil || !canPlaySelection)
                        .help(localization.text(.takeImportAudio))
                        .accessibilityLabel(localization.text(.takeImportAudio))
                        if !audioAssets.isEmpty {
                            Picker(localization.text(.takeAuditionAudio), selection: $selectedAudioPath) {
                                Text(localization.text(.takeOriginalAudio)).tag(nil as String?)
                                ForEach(audioAssets, id: \.relativePath) { asset in
                                    Text(asset.displayName ?? asset.relativePath).tag(Optional(asset.relativePath))
                                }
                            }
                            if selectedAudioPath != nil {
                                Stepper(value: $audioOffsetMilliseconds, in: -10_000...10_000, step: 10) {
                                    Text("\(localization.text(.takeAuditionOffset)) \(audioOffsetMilliseconds) ms")
                                }
                                .fixedSize()
                            }
                            let sync = selectedAudioPath.map {
                                TakeManifest.AudioSync(relativePath: $0, offsetMilliseconds: audioOffsetMilliseconds)
                            }
                            Button { saveAudioSync(sync) } label: { Image(systemName: "square.and.arrow.down") }
                                .disabled(audioEditTask != nil || sync == snapshot.manifest.audioSync)
                                .help(localization.text(.takeSaveAudioSync))
                                .accessibilityLabel(localization.text(.takeSaveAudioSync))
                            Button { if let sync { chooseAudioExport(sync) } } label: {
                                Image(systemName: "film.stack")
                            }
                            .disabled(audioExportTask != nil || audioEditTask != nil || sync == nil || !canPlaySelection)
                            .help(localization.text(.takeExportSyncedMovie))
                            .accessibilityLabel(localization.text(.takeExportSyncedMovie))
                        }
                        if audioEditTask != nil { ProgressView().controlSize(.small) }
                    }.font(.caption)
                }
                if audioExportTask != nil {
                    HStack { ProgressView().controlSize(.small); Text(localization.text(.takeExportSyncedMovie)) }
                } else if let exportedAudioMovie {
                    Label(exportedAudioMovie.lastPathComponent, systemImage: "checkmark.circle")
                        .font(.caption).help(exportedAudioMovie.path)
                } else if audioExportFailed {
                    Label(localization.text(.takeExportSyncedMovieFailed), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if playback.isPreparing {
                    HStack { ProgressView().controlSize(.small); Text(localization.text(.takePreparingPlayback)) }
                }
                if let error = playback.error {
                    Label(localization.text(.takePlaybackFailed), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(error)
                }
                if let player = playback.player {
                    HStack(alignment: .top, spacing: 12) {
                        VideoPlayer(player: player).frame(height: 240)
                        if let recomposedImage {
                            Image(decorative: recomposedImage, scale: 1).resizable().scaledToFit()
                                .frame(width: 320, height: 240)
                                .accessibilityLabel(localization.text(.takePreviewRecomposition))
                        } else if recompositionTask != nil {
                            ProgressView().frame(width: 120)
                        }
                        if auxiliaryPreviewFrame != nil { auxiliaryPreviewPanel }
                    }
                    if recompositionError {
                        Label(localization.text(.takeRecompositionFailed), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let timing = playback.audioTiming {
                        HStack(spacing: 12) {
                            Label(localization.text(.takeAudioTiming), systemImage: "waveform")
                            Text("\(localization.text(.takeAudioStartOffset)) \(String(format: "%+.1f ms", timing.startOffsetMilliseconds))")
                            Text("\(localization.text(.takeAudioEndOffset)) \(String(format: "%+.1f ms", timing.endOffsetMilliseconds))")
                            Text(timing.overlapFraction, format: .percent.precision(.fractionLength(1)))
                                .help(localization.text(.takeAudioOverlap))
                                .accessibilityLabel(localization.text(.takeAudioOverlap))
                        }.font(.caption.monospacedDigit())
                    }
                    if let summary = playback.occlusionSummary {
                        occlusionSummaryView(summary)
                    }
                    if let row = playback.currentAuxiliaryFrame {
                        HStack(spacing: 16) {
                            Label(String(row.frameIndex + 1), systemImage: "film")
                                .help(localization.text(.takeIndexedFrame))
                            Button {
                                showAuxiliaryPreview(row)
                            } label: {
                                Label(localization.text(.takePreviewAuxiliary), systemImage: "rectangle.split.2x1")
                            }
                            .disabled(row.matte == nil && row.depth == nil)
                            Button { playRecomposition(row) } label: {
                                Label(localization.text(.takePreviewRecomposition), systemImage: "play.rectangle")
                            }
                            .disabled(row.originalVideo == nil || row.matte == nil || recompositionTask != nil)
                            .help(localization.text(.takePreviewRecompositionHelp))
                            Label(localization.text(PoseAlignmentTelemetry.Mode(rawValue: row.pose?.mode ?? "")?.localizationKey
                                ?? .poseAlignmentUnavailable), systemImage: "move.3d")
                                .help(localization.text(.poseAlignment))
                            if let occlusion = row.depthOcclusion {
                                Label(depthOcclusionDescription(occlusion), systemImage: "square.3.layers.3d.down.right")
                                    .lineLimit(1).help(depthOcclusionDescription(occlusion))
                            }
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
        .onDisappear { recompositionTask?.cancel(); audioExportTask?.cancel(); audioEditTask?.cancel(); resetAuxiliaryPreview(); assetRestoreTask?.cancel(); playback.stop(); review.cancel() }
        .onChange(of: playback.currentAuxiliaryFrame?.frameIndex) { _, index in
            recompositionTask?.cancel()
            recompositionTask = nil
            recomposedImage = nil
            recompositionError = false
            if let auxiliaryPreviewFrame, index != auxiliaryPreviewFrame { resetAuxiliaryPreview() }
        }
        .onChange(of: review.snapshot?.manifest.id) { _, _ in
            audioExportTask?.cancel()
            exportedAudioMovie = nil
            audioExportFailed = false
            resetAuxiliaryPreview()
            assetRestoreTask?.cancel()
            assetRestoreTask = nil
            assetRestoreError = nil
            playback.stop()
            selectedPlaybackPath = nil
            let sync = review.snapshot?.manifest.audioSync
            if let sync, review.snapshot?.results.contains(where: { $0.relativePath == sync.relativePath && $0.status == .verified }) == true {
                selectedAudioPath = sync.relativePath
                audioOffsetMilliseconds = sync.offsetMilliseconds
            } else {
                selectedAudioPath = nil
                audioOffsetMilliseconds = 0
            }
        }
    }

    private func playRecomposition(_ row: TakeAuxiliaryTracks.Row) {
        guard let directory = review.directory, let snapshot = review.snapshot else { return }
        playback.player?.pause()
        resetAuxiliaryPreview()
        recomposedImage = nil
        recompositionError = false
        recompositionTask = Task {
            defer { if !Task.isCancelled { recompositionTask = nil } }
            do {
                let preview = try await TakeReviewService().recomposePreview(directory: directory, manifest: snapshot.manifest,
                                                                             startingAt: row.frameIndex)
                let clock = ContinuousClock()
                let start = clock.now
                for frame in preview.frames {
                    try await clock.sleep(until: start.advanced(by: .seconds(frame.seconds)))
                    try Task.checkCancellation()
                    recomposedImage = frame.image
                }
            } catch {
                if !Task.isCancelled { recompositionError = true }
            }
        }
    }

    private var auxiliaryPreviewPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button(action: resetAuxiliaryPreview) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(localization.text(.takeCloseAuxiliary))
            HStack(alignment: .top, spacing: 8) {
                if previewHasMatte {
                    auxiliaryImage(mattePreviewImage, title: .mattePass, failed: mattePreviewFailed)
                }
                if previewDepthRow?.depth != nil {
                    auxiliaryImage(depthPreview?.depth, title: .takeDepthScale, failed: depthPreviewFailed)
                    auxiliaryImage(depthPreview?.confidence, title: .depthConfidencePass, failed: depthPreviewFailed)
                        .help(localization.text(.depthPreviewHelp))
                }
            }
            if depthPreview != nil, let row = previewDepthRow, let depth = row.depth {
                HStack(spacing: 8) {
                    Text("\(localization.text(.takeDepthSourceFrame)) \(depth.sequence)")
                    if let offset = row.depthOffsetMilliseconds {
                        Text(String(format: "%+.1f ms", offset))
                            .help(localization.text(.takeDepthOffset))
                    }
                    let status: LocalizationKey = switch row.depthSameARKitFrame {
                    case true?: .depthSameARKitFrame
                    case false?: .takeDepthNearbyFrame
                    case nil: .takeDepthFrameMatchUnknown
                    }
                    Image(systemName: row.depthSameARKitFrame == true ? "link" : "clock")
                        .help(localization.text(status))
                        .accessibilityLabel(localization.text(status))
                }.font(.caption.monospacedDigit())
            }
        }
    }

    private func auxiliaryImage(_ image: CGImage?, title: LocalizationKey, failed: Bool) -> some View {
        VStack(spacing: 4) {
            Text(localization.text(title)).lineLimit(2)
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .accessibilityLabel(localization.text(title))
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .help(localization.text(.takePreviewAuxiliaryFailed))
                        .accessibilityLabel(localization.text(.takePreviewAuxiliaryFailed))
                } else {
                    ProgressView().controlSize(.small)
                }
            }.frame(height: 108)
        }.frame(width: 104).font(.caption)
    }

    private func resetAuxiliaryPreview() {
        mattePreviewTask?.cancel()
        mattePreviewTask = nil
        mattePreviewImage = nil
        mattePreviewFailed = false
        auxiliaryPreviewFrame = nil
        depthPreview = nil
        depthPreviewFailed = false
        previewHasMatte = false
        previewDepthRow = nil
    }

    private func showAuxiliaryPreview(_ row: TakeAuxiliaryTracks.Row) {
        guard let directory = review.directory, let snapshot = review.snapshot else { return }
        resetAuxiliaryPreview()
        playback.player?.pause()
        playback.player?.seek(to: CMTime(value: row.ptsValue, timescale: row.ptsTimescale),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        auxiliaryPreviewFrame = row.frameIndex
        previewHasMatte = row.matte != nil
        previewDepthRow = row.depth == nil ? nil : row
        mattePreviewTask = Task {
            let service = TakeReviewService()
            if row.matte != nil {
                let image = try? await service.previewMatte(directory: directory, manifest: snapshot.manifest, row: row)
                guard !Task.isCancelled else { return }
                mattePreviewImage = image
                mattePreviewFailed = image == nil
            }
            if row.depth != nil {
                let preview = try? await service.previewDepth(directory: directory, manifest: snapshot.manifest, row: row)
                guard !Task.isCancelled else { return }
                depthPreview = preview
                depthPreviewFailed = preview == nil
            }
        }
    }

    private func occlusionSummaryView(_ summary: TakeOcclusionSummary) -> some View {
        HStack {
            Label {
                Text(summary.appliedRate, format: .percent.precision(.fractionLength(1)))
            } icon: {
                Image(systemName: "square.3.layers.3d")
            }
            .help("\(localization.text(.takeOcclusionRateHelp)) · \(summary.enabledFrameCount)")
            .accessibilityLabel(localization.text(.takeOcclusionRateHelp))
            Menu(localization.text(.takeOcclusionJump)) {
                ForEach(TakeOcclusionSummary.Category.allCases, id: \.self) { category in
                    let group = summary.groups[category]
                    Button("\(localization.text(category.localizationKey)) · \(group?.frameCount ?? 0)") {
                        playback.jumpToNextOcclusionSegment(category)
                    }.disabled(group == nil)
                }
            }
            .fixedSize()
            .help(localization.text(.takeOcclusionJumpHelp))
            Spacer(minLength: 0)
        }.font(.caption.monospacedDigit())
    }

    private func depthOcclusionDescription(_ occlusion: TakeDepthOcclusion) -> String {
        let reasons: [LocalizationKey] = switch occlusion.state {
        case .disabled: [.takeOcclusionDisabled]
        case .missingDepth: [.takeOcclusionMissing]
        case .mismatchedDepth: [.takeOcclusionMismatch]
        case .unavailable: [.takeOcclusionUnavailable]
        case .evaluated:
            [occlusion.applied ? .takeOcclusionApplied : nil,
             occlusion.missingSamples ? .takeOcclusionMissing : nil,
             occlusion.lowConfidence ? .takeOcclusionLowConfidence : nil].compactMap { $0 }
        }
        let text = (reasons.isEmpty ? [.takeOcclusionNoChange] : reasons).map { localization.text($0) }
        return text.joined(separator: " · ")
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

    private var canRestoreCompositeSettings: Bool {
        guard studio.canRestoreTakeScene, !review.isLoading, let snapshot = review.snapshot,
              selectedPlaybackPath == "diagnostics.json" else { return false }
        return snapshot.manifest.assets.contains { $0.role == .diagnostics && $0.relativePath == selectedPlaybackPath }
            && snapshot.results.contains { $0.relativePath == selectedPlaybackPath && $0.status == .verified }
    }

    private func restoreSelectedAsset(role: TakeManifest.Asset.Role = .scene) {
        let allowed = switch role {
        case .scene: canRestoreSelection
        case .calibration: canRestoreCalibration
        case .lut: canRestoreLUT
        case .diagnostics: canRestoreCompositeSettings
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
                case .diagnostics:
                    let settings = try await service.restoreCompositeSettings(directory: directory, manifest: snapshot.manifest)
                    try Task.checkCancellation()
                    guard review.snapshot?.manifest == snapshot.manifest, review.directory == directory else { return }
                    if studio.restoreTakeCompositeSettings(settings) { dismiss() }
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

    private func chooseAudioExport(_ sync: TakeManifest.AudioSync) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = localization.text(.takeExportSyncedMovie)
        panel.begin { response in
            guard response == .OK, let parent = panel.url, let directory = review.directory,
                  let snapshot = review.snapshot, audioExportTask == nil else { return }
            let exportRoot = parent.resolvingSymlinksInPath().standardizedFileURL.path
            let takeRoot = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard exportRoot != takeRoot, !exportRoot.hasPrefix(takeRoot + "/") else {
                exportedAudioMovie = nil
                audioExportFailed = true
                return
            }
            exportedAudioMovie = nil
            audioExportFailed = false
            audioExportTask = Task {
                let scopedTake = directory.startAccessingSecurityScopedResource()
                let scopedParent = parent.startAccessingSecurityScopedResource()
                defer {
                    if scopedTake { directory.stopAccessingSecurityScopedResource() }
                    if scopedParent { parent.stopAccessingSecurityScopedResource() }
                    audioExportTask = nil
                }
                do {
                    let service = TakeReviewService()
                    let video = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest,
                                                                  relativePath: "composite.mov")
                    let audio = try await service.preparePlayback(directory: directory, manifest: snapshot.manifest,
                                                                  relativePath: sync.relativePath, audioOnly: true)
                    let audition = try await TakeAudioAudition.build(video: AVURLAsset(url: video), audio: AVURLAsset(url: audio),
                                                                    offsetMilliseconds: sync.offsetMilliseconds)
                    let destination = parent.appendingPathComponent("VPX-AudioSync-\(UUID().uuidString).mov")
                    try await TakeAudioAudition.export(composition: audition.composition, to: destination)
                    if !Task.isCancelled { exportedAudioMovie = destination }
                } catch {
                    if !Task.isCancelled { audioExportFailed = true }
                }
            }
        }
    }

    private func chooseIndependentAudio() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = localization.text(.takeImportAudio)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editAudio { directory, snapshot in
                try await TakeReviewService.audioEditor.importAudio(from: url, directory: directory, snapshot: snapshot)
            }
        }
    }

    private func saveAudioSync(_ sync: TakeManifest.AudioSync?) {
        editAudio { directory, snapshot in
            try await TakeReviewService.audioEditor.saveAudioSync(sync, directory: directory, snapshot: snapshot)
        }
    }

    private func editAudio(_ operation: @escaping (URL, TakeReviewSnapshot) async throws -> TakeReviewSnapshot) {
        guard audioEditTask == nil, let directory = review.directory, let snapshot = review.snapshot else { return }
        assetRestoreError = nil
        audioEditTask = Task {
            defer { audioEditTask = nil }
            do {
                let updated = try await operation(directory, snapshot)
                guard !Task.isCancelled, review.acceptAudioEdit(updated, previous: snapshot, directory: directory) else { return }
                playback.stop()
                if updated.manifest.assets.count > snapshot.manifest.assets.count {
                    selectedAudioPath = updated.manifest.assets.last?.relativePath
                    audioOffsetMilliseconds = 0
                }
            } catch {
                if !Task.isCancelled { assetRestoreError = String(describing: error) }
            }
        }
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
        case .sourceFrames: .takeOriginalFrames
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
