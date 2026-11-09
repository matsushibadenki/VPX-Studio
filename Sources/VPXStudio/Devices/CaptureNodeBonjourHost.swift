import Dispatch
import Foundation
import Network
import VPXCaptureProtocol

/// Advertises the Mac Host over Bonjour and accepts one actively paired Capture
/// Node credential. Node registration and video routing are surfaced through
/// callbacks so StudioModel owns the UI and production admission policy.
/// Listener callbacks and mutable state are confined to `queue`.
final class CaptureNodeBonjourHost: @unchecked Sendable {
    static let serviceType = "_vpxcapture._tcp"

    var onHello: ((CaptureNodeHello, CaptureSecureChannel) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onTelemetry: ((UUID, UUID, CaptureTelemetryPayload) -> Void)?
    var onDisconnected: ((UUID, UUID) -> Void)?
    var onAdmissionRejected: ((CaptureNodeHello, NodeAdmissionPolicy.Rejection) -> Void)?
    var onReady: ((NWEndpoint.Port) -> Void)?
    var onMediaControlResult: ((UUID, UUID, CaptureMediaControlResult) -> Void)?

    private let credential: CapturePairingCredential
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var datagrams: CaptureDatagramListener?
    private var telemetryPort: UInt16?
    private var channels: [UUID: CaptureSecureChannel] = [:]
    private var nodes: [UUID: UUID] = [:]
    private var admission: NodeAdmissionPolicy
    private static let maximumPendingConnections = 16

    init(
        credential: CapturePairingCredential,
        queue: DispatchQueue = DispatchQueue(label: "com.vpxstudio.capture-host"),
        limits: NodeAdmissionPolicy.Limits = .standard
    ) {
        self.credential = credential
        self.queue = queue
        admission = NodeAdmissionPolicy(limits: limits)
    }

    func start(port: NWEndpoint.Port? = nil) throws {
        let datagrams = CaptureDatagramListener(credential: credential, queue: queue)
        datagrams.onReady = { [weak self] port in
            guard let self else { return }
            telemetryPort=port
            for (nodeID, id) in nodes { if let channel=channels[id] { offer(nodeID, channel: channel) } }
        }
        datagrams.onAuthenticatedDatagram = { [weak self] envelope in
            guard let self, nodes[envelope.nodeID] == envelope.connectionID else { return }
            onTelemetry?(envelope.nodeID, envelope.connectionID, envelope.payload)
        }
        datagrams.onFailure = { [weak self] error in self?.onFailure?(error) }
        self.datagrams=datagrams
        try datagrams.start()
        let listener: NWListener
        if let port {
            listener = try NWListener(using: .tcp, on: port)
        } else {
            listener = try NWListener(using: .tcp)
        }
        listener.service = NWListener.Service(type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port { self?.onReady?(port) }
            if case .failed(let error) = state {
                self?.onFailure?(error)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener=nil
            datagrams?.stop(); datagrams=nil; telemetryPort=nil
            channels.values.forEach { $0.cancel() }; channels.removeAll(); nodes.removeAll()
            admission.reset()
        }
    }

    private func accept(_ connection: NWConnection) {
        let pending = channels.count - nodes.count
        guard pending < Self.maximumPendingConnections else { connection.cancel(); return }
        let channel = CaptureSecureChannel(connection: connection, credential: credential)
        channels[channel.connectionID]=channel
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
            guard let self, let channel,
                  !nodes.values.contains(channel.connectionID) else { return }
            channel.cancel()
        }
        channel.onControlPacket = { [weak self, weak channel] envelope in
            guard let self, let channel else { return }
            if envelope.kind == .mediaControlResult,
               let nodeID = nodes.first(where: { $0.value == channel.connectionID })?.key,
               let result = try? envelope.decodePayload(CaptureMediaControlResult.self) {
                onMediaControlResult?(nodeID, channel.connectionID, result); return
            }
            if envelope.kind == .qualityEvent,
               let nodeID=nodes.first(where: { $0.value == channel.connectionID })?.key,
               let event=try? envelope.decodePayload(CaptureQualityEvent.self) {
                onTelemetry?(nodeID, channel.connectionID, .diagnostic(event)); return
            }
            guard envelope.kind == .hello,
                  let hello = try? envelope.decodePayload(CaptureNodeHello.self),
                  hello.protocolVersion == CaptureNodeHello.currentProtocolVersion else { channel.cancel(); return }
            switch admission.admit(hello, connectionID: channel.connectionID) {
            case .accepted: break
            case .duplicate: return
            case .rejected(let reason):
                onAdmissionRejected?(hello, reason); channel.cancel(); return
            }
            if let old=nodes[hello.nodeID], old != channel.connectionID { channels[old]?.cancel() }
            nodes[hello.nodeID]=channel.connectionID
            offer(hello.nodeID, channel: channel)
            onHello?(hello, channel)
        }
        channel.onStateChanged = { [weak self, weak channel] state in
            guard let self, let channel else { return }
            if case .cancelled = state { remove(channel) }
            if case .failed = state { remove(channel) }
        }
        channel.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }
        channel.start(on: queue)
    }

    private func offer(_ nodeID: UUID, channel: CaptureSecureChannel) {
        guard let telemetryPort else { return }
        datagrams?.bind(nodeID: nodeID, connectionID: channel.connectionID)
        do { try channel.sendControl(CaptureMessageEnvelope(kind: .telemetryOffer,
            payload: CaptureTelemetryOffer(connectionID: channel.connectionID, port: telemetryPort))) }
        catch { onFailure?(error) }
    }
    private func remove(_ channel: CaptureSecureChannel) {
        admission.remove(connectionID: channel.connectionID)
        channels.removeValue(forKey: channel.connectionID)
        guard let nodeID=nodes.first(where: { $0.value == channel.connectionID })?.key else { return }
        nodes.removeValue(forKey: nodeID); datagrams?.unbind(nodeID: nodeID); onDisconnected?(nodeID, channel.connectionID)
    }
}
