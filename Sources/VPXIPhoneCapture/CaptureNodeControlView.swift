#if os(iOS)
import Observation
import SwiftUI
import UIKit
import VisionKit
import VPXCaptureProtocol

public enum CaptureNodeLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"
    case chineseSimplified = "zh-Hans"

    public var id: String { rawValue }

    var name: String {
        switch self {
        case .english: "English"
        case .japanese: "日本語"
        case .chineseSimplified: "简体中文"
        }
    }
}

public enum CaptureNodeConnectionStatus: Equatable {
    case idle
    case discovering
    case pairingReady
    case connecting
    case connected
    case capturing
    case failed(String)
}

@MainActor @Observable
public final class CaptureNodeSessionModel {
    public var language: CaptureNodeLanguage = .english
    public var hosts: [CaptureNodeDiscoveredHost] = []
    public var selectedHostID: String?
    public var pairingPayload = ""
    public private(set) var verificationCode: String?
    public private(set) var status: CaptureNodeConnectionStatus = .idle
    public private(set) var isCapturing = false
    public private(set) var errorMessage: String?

    private let nodeID: UUID
    private let displayName: String
    private let coordinator = IPhoneCaptureCoordinator()
    private let discovery = CaptureNodeHostDiscovery()
    private let networkQueue = DispatchQueue(label: "com.vpxstudio.capture-node")
    private var credential: CapturePairingCredential?
    private var channel: CaptureSecureChannel?

    public init(nodeID: UUID = UUID(), displayName: String = UIDevice.current.name) {
        self.nodeID = nodeID
        self.displayName = displayName
        discovery.onHostsChanged = { [weak self] hosts in
            Task { @MainActor [weak self] in
                self?.hosts = hosts
                if self?.selectedHostID == nil {
                    self?.selectedHostID = hosts.first?.id
                }
            }
        }
        discovery.onFailure = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.fail(error)
            }
        }
        coordinator.onEncodedVideoFrame = { [weak self] frame in
            do {
                try self?.channel?.sendVideo(frame)
            } catch {
                self?.failFromAnyQueue(error)
            }
        }
        coordinator.onEncodingError = { [weak self] error in
            self?.failFromAnyQueue(error)
        }
    }

    public func startDiscovery() {
        status = .discovering
        errorMessage = nil
        discovery.start(on: networkQueue)
    }

    public func applyPairingPayload(_ payload: String) {
        do {
            let credential = try CapturePairingCredential(qrPayload: payload)
            try CapturePairingCredentialStore.save(credential)
            self.credential = credential
            pairingPayload = payload
            verificationCode = credential.verificationCode
            status = .pairingReady
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    public func connectSelectedHost() {
        guard let credential else {
            fail(CapturePairingError.invalidCredential)
            return
        }
        guard let host = hosts.first(where: { $0.id == selectedHostID }) else {
            fail(CaptureNodeSessionError.hostNotSelected)
            return
        }

        channel?.cancel()
        let channel = CaptureSecureChannel(endpoint: host.endpoint, credential: credential)
        channel.onStateChanged = { [weak self, weak channel] state in
            Task { @MainActor [weak self] in
                self?.handleChannelState(state, channel: channel)
            }
        }
        channel.onFailure = { [weak self] error in
            self?.failFromAnyQueue(error)
        }
        self.channel = channel
        status = .connecting
        channel.start(on: networkQueue)
    }

    public func startCapture() {
        guard channel != nil else {
            fail(CaptureNodeSessionError.notConnected)
            return
        }
        do {
            try coordinator.startHEVCEncoding()
            coordinator.start(enableDepth: true)
            isCapturing = true
            status = .capturing
        } catch {
            fail(error)
        }
    }

    public func stopCapture() {
        coordinator.stop()
        coordinator.stopHEVCEncoding()
        isCapturing = false
        status = channel == nil ? .idle : .connected
    }

    public func stop() {
        stopCapture()
        channel?.cancel()
        channel = nil
        discovery.stop()
        status = .idle
    }

    private func handleChannelState(
        _ state: CaptureSecureChannelState,
        channel: CaptureSecureChannel?
    ) {
        switch state {
        case .ready:
            do {
                let hello = CaptureNodeHello(
                    nodeID: nodeID,
                    displayName: displayName,
                    capabilities: [.video, .pose, .imu, .depth, .timeSync]
                )
                try channel?.sendControl(CaptureMessageEnvelope(kind: .hello, payload: hello))
                status = .connected
            } catch {
                fail(error)
            }
        case .failed(let message), .waiting(let message):
            fail(CaptureNodeSessionError.connection(message))
        case .cancelled:
            if !isCapturing { status = .idle }
        case .setup, .preparing:
            status = .connecting
        }
    }

    private func failFromAnyQueue(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.fail(error)
        }
    }

    private func fail(_ error: Error) {
        isCapturing = false
        errorMessage = error.localizedDescription
        status = .failed(error.localizedDescription)
    }
}

private enum CaptureNodeSessionError: LocalizedError {
    case hostNotSelected
    case notConnected
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .hostNotSelected: "Select a VPX Studio Host before connecting."
        case .notConnected: "Connect to a VPX Studio Host before starting capture."
        case .connection(let message): message
        }
    }
}

public struct CaptureNodeControlView: View {
    @Bindable private var model: CaptureNodeSessionModel
    @State private var showsScanner = false

    public init(model: CaptureNodeSessionModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                hostCard
                pairingCard
                captureCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .sheet(isPresented: $showsScanner) {
            QRCodeScanner { payload in
                showsScanner = false
                model.applyPairingPayload(payload)
            }
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text(.title)).font(.title2.weight(.semibold))
                Text(text(.subtitle)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Picker(text(.language), selection: $model.language) {
                ForEach(CaptureNodeLanguage.allCases) { language in
                    Text(language.name).tag(language)
                }
            }
            .labelsHidden()
        }
    }

    private var statusCard: some View {
        card(title: text(.connection)) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusText).font(.body.weight(.medium))
                Spacer()
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var hostCard: some View {
        card(title: text(.host)) {
            Button(text(.findHosts)) { model.startDiscovery() }
                .buttonStyle(.bordered)
            if model.hosts.isEmpty {
                Text(text(.noHosts)).font(.footnote).foregroundStyle(.secondary)
            } else {
                Picker(text(.host), selection: $model.selectedHostID) {
                    ForEach(model.hosts) { host in
                        Text(host.name).tag(Optional(host.id))
                    }
                }
                Button(text(.connect)) { model.connectSelectedHost() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedHostID == nil || model.verificationCode == nil)
            }
        }
    }

    private var pairingCard: some View {
        card(title: text(.pairing)) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                Button(text(.scanQR)) { showsScanner = true }
                    .buttonStyle(.bordered)
            }
            TextField(text(.pairingPayload), text: $model.pairingPayload, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button(text(.applyPairing)) { model.applyPairingPayload(model.pairingPayload) }
                .buttonStyle(.bordered)
                .disabled(model.pairingPayload.isEmpty)
            if let verificationCode = model.verificationCode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text(.confirmCode)).font(.caption).foregroundStyle(.secondary)
                    Text(verificationCode).font(.title3.monospacedDigit().weight(.semibold))
                }
            }
        }
    }

    private var captureCard: some View {
        card(title: text(.capture)) {
            Button(model.isCapturing ? text(.stopCapture) : text(.startCapture)) {
                model.isCapturing ? model.stopCapture() : model.startCapture()
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isCapturing ? .red : .accentColor)
            .disabled(!isConnected)
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var isConnected: Bool {
        switch model.status {
        case .connected, .capturing: true
        default: false
        }
    }

    private var statusIcon: String {
        switch model.status {
        case .capturing: "record.circle.fill"
        case .connected: "checkmark.circle.fill"
        case .discovering, .connecting, .pairingReady: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "circle"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .capturing: .red
        case .connected: .green
        case .discovering, .connecting, .pairingReady: .orange
        case .failed: .red
        case .idle: .secondary
        }
    }

    private var statusText: String {
        switch model.status {
        case .idle: text(.idle)
        case .discovering: text(.discovering)
        case .pairingReady: text(.pairingReady)
        case .connecting: text(.connecting)
        case .connected: text(.connected)
        case .capturing: text(.capturing)
        case .failed: text(.failed)
        }
    }

    private enum Key {
        case title, subtitle, language, connection, host, findHosts, noHosts, connect
        case pairing, scanQR, pairingPayload, applyPairing, confirmCode
        case capture, startCapture, stopCapture
        case idle, discovering, pairingReady, connecting, connected, capturing, failed
    }

    private func text(_ key: Key) -> String {
        let english: [Key: String] = [
            .title: "Capture Node", .subtitle: "Secure iPhone input for VPX Studio", .language: "Language",
            .connection: "Connection", .host: "Mac Host", .findHosts: "Find Hosts", .noHosts: "No VPX Studio Hosts found.", .connect: "Connect",
            .pairing: "Pairing", .scanQR: "Scan QR Code", .pairingPayload: "Pairing QR payload", .applyPairing: "Apply Pairing", .confirmCode: "Verify this code on the Mac",
            .capture: "Capture", .startCapture: "Start Capture", .stopCapture: "Stop Capture",
            .idle: "Idle", .discovering: "Discovering Hosts", .pairingReady: "Pairing ready", .connecting: "Connecting", .connected: "Connected", .capturing: "Capturing", .failed: "Connection failed"
        ]
        let japanese: [Key: String] = [
            .title: "Capture Node", .subtitle: "VPX Studio用の安全なiPhone入力", .language: "言語",
            .connection: "接続", .host: "Mac Host", .findHosts: "Hostを検索", .noHosts: "VPX Studio Hostが見つかりません。", .connect: "接続",
            .pairing: "ペアリング", .scanQR: "QRコードをスキャン", .pairingPayload: "ペアリングQRペイロード", .applyPairing: "ペアリングを適用", .confirmCode: "Macに表示されたコードと照合してください",
            .capture: "キャプチャ", .startCapture: "キャプチャ開始", .stopCapture: "キャプチャ停止",
            .idle: "待機中", .discovering: "Hostを検索中", .pairingReady: "ペアリング準備完了", .connecting: "接続中", .connected: "接続済み", .capturing: "キャプチャ中", .failed: "接続に失敗しました"
        ]
        let chinese: [Key: String] = [
            .title: "采集节点", .subtitle: "为VPX Studio提供安全的iPhone输入", .language: "语言",
            .connection: "连接", .host: "Mac主机", .findHosts: "查找主机", .noHosts: "未找到VPX Studio主机。", .connect: "连接",
            .pairing: "配对", .scanQR: "扫描二维码", .pairingPayload: "配对二维码内容", .applyPairing: "应用配对", .confirmCode: "请与Mac上显示的代码核对",
            .capture: "采集", .startCapture: "开始采集", .stopCapture: "停止采集",
            .idle: "空闲", .discovering: "正在查找主机", .pairingReady: "配对已就绪", .connecting: "正在连接", .connected: "已连接", .capturing: "采集中", .failed: "连接失败"
        ]
        return switch model.language {
        case .english: english[key]!
        case .japanese: japanese[key]!
        case .chineseSimplified: chinese[key]!
        }
    }
}

@available(iOS 16.0, *)
private struct QRCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue else { continue }
                dataScanner.stopScanning()
                onCode(payload)
                return
            }
        }
    }
}

struct CaptureNodeControlView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CaptureNodeControlView(model: CaptureNodeSessionModel())
                .previewDevice("iPhone SE (3rd generation)")
            CaptureNodeControlView(model: CaptureNodeSessionModel())
                .previewDevice("iPhone 16 Pro Max")
        }
    }
}
#endif
