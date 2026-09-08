import SwiftUI

struct StudioView: View {
    @Bindable var studio: StudioModel
    @Bindable var localization: LocalizationStore
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sourcePanel
                    .frame(width: 220)
                Divider()
                viewport
                Divider()
                inspector
                    .frame(width: 270)
            }
            Divider()
            statusBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear { studio.startPreview() }
        .onDisappear { studio.stopPreview() }
        .task {
            while !Task.isCancelled {
                studio.refreshMetrics()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("VPX Studio")
                .font(.title2.weight(.semibold))
            Picker(localization.text(.mode), selection: $studio.mode) {
                ForEach(StudioMode.allCases) { mode in
                    Text(localization.text(mode.localizationKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Spacer(minLength: 16)
            Menu {
                Picker(localization.text(.language), selection: $localization.selectedLanguageID) {
                    ForEach(localization.languages, id: \.id) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                Divider()
                Picker(localization.text(.appearance), selection: $settings.appearance) {
                    Text(localization.text(.system)).tag(AppearanceOption.system)
                    Text(localization.text(.light)).tag(AppearanceOption.light)
                    Text(localization.text(.dark)).tag(AppearanceOption.dark)
                }
            } label: {
                Image(systemName: "globe")
                    .accessibilityLabel(localization.text(.language))
            }
            Button(studio.isRecording ? localization.text(.stop) : localization.text(.record)) {
                studio.isRecording.toggle()
            }
            .tint(studio.isRecording ? .red : .accentColor)
        }
        .padding(.bottom, 12)
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localization.text(.sources)).font(.headline)
            Label(localization.text(.iphoneCaptureNode), systemImage: "iphone")
            Label(localization.text(.professionalVideoInput), systemImage: "video")
            Label(localization.text(.externalTracking), systemImage: "scope")
            Button(localization.text(.connectLocalCamera)) {
                studio.connectLocalCamera()
            }
            .buttonStyle(.bordered)
            Divider()
            if studio.deviceRegistry.devices.isEmpty {
                Text(localization.text(.noConnectedDevices))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(studio.deviceRegistry.devices) { device in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: device.descriptor.capabilities.contains(.video) ? "video.fill" : "dot.radiowaves.left.and.right")
                            .foregroundStyle(deviceStateColor(device.state))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.descriptor.displayName)
                                .lineLimit(1)
                            Text(deviceStateText(device.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Text(studio.selectedSourceName.isEmpty ? localization.text(.noInput) : studio.selectedSourceName)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var viewport: some View {
        ZStack(alignment: .topLeading) {
            MetalPreviewView(
                latestVideoFrame: studio.realtimeCore.latestVideoFrame,
                metrics: studio.realtimeCore.metrics,
                chromaKeyEnabled: studio.chromaKeyEnabled,
                chromaGreenThreshold: studio.chromaGreenThreshold,
                chromaGreenSoftness: studio.chromaGreenSoftness,
                focalLengthMillimeters: studio.focalLengthMillimeters,
                radialDistortionK1: studio.radialDistortionK1
            )
                .clipShape(.rect(cornerRadius: 10))
                .padding(12)
            Text(studio.rendererStatus.text(localization))
                .font(.caption.monospaced())
                .padding(8)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.text(.monitor)).font(.headline)
            metric(localization.text(.renderer), studio.rendererStatus.text(localization))
            metric(localization.text(.tracking), studio.trackingQuality.rawValue)
            metric(localization.text(.frameRate), String(format: "%.1f fps", studio.frameRate))
            metric(localization.text(.latency), String(format: "%.1f ms", studio.latencyMilliseconds))
            metric(localization.text(.gpuFrameTime), String(format: "%.2f ms", studio.gpuFrameMilliseconds))
            metric(localization.text(.droppedFrames), String(studio.droppedFrameEstimate))
            metric(
                localization.text(.inputColor),
                studio.inputColorMetadata.isEmpty ? "—" : studio.inputColorMetadata
            )
            metric(
                localization.text(.videoProfile),
                studio.projectConfiguration.liveVideoProfile.name
            )
            metric(
                localization.text(.stageSpace),
                "+X / +Y / -Z · m"
            )
            Divider()
            Toggle(localization.text(.chromaKey), isOn: $studio.chromaKeyEnabled)
            chromaControl(
                localization.text(.greenThreshold),
                value: $studio.chromaGreenThreshold,
                range: 0.02...0.45
            )
            chromaControl(
                localization.text(.edgeSoftness),
                value: $studio.chromaGreenSoftness,
                range: 0.01...0.45
            )
            .disabled(!studio.chromaKeyEnabled)
            focalLengthControl
            radialDistortionControl
            Spacer()
        }
        .padding(12)
    }

    private var statusBar: some View {
        HStack {
            Label(studio.isRecording ? localization.text(.recording) : localization.text(.ready),
                  systemImage: studio.isRecording ? "record.circle.fill" : "checkmark.circle")
            Spacer()
            Text(localization.text(.metalFrameGraph))
                .foregroundStyle(.secondary)
        }
        .font(.footnote)
        .padding(.top, 10)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospaced())
        }
    }

    private func chromaControl(
        _ title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }

    private var focalLengthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localization.text(.focalLength))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(studio.focalLengthMillimeters, format: .number.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                Text("mm").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $studio.focalLengthMillimeters, in: 14...120, step: 1)
        }
    }

    private var radialDistortionControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localization.text(.radialDistortion))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(studio.radialDistortionK1, format: .number.precision(.fractionLength(3)))
                    .font(.caption.monospacedDigit())
            }
            Slider(value: $studio.radialDistortionK1, in: -0.5...0.5, step: 0.005)
        }
    }

    private func deviceStateText(_ state: DeviceConnectionState) -> String {
        switch state {
        case .connecting: localization.text(.connecting)
        case .connected: localization.text(.connected)
        case .disconnected: localization.text(.disconnected)
        case .failed(let message): message
        }
    }

    private func deviceStateColor(_ state: DeviceConnectionState) -> Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected, .failed: .red
        }
    }
}
