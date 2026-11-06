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

    private let credential: CapturePairingCredential
    private let queue: DispatchQueue
    private var listener: NWListener?
    private var datagrams: CaptureDatagramListener?
    private var telemetryPort: UInt16?
    private var channels: [UUID: CaptureSecureChannel] = [:]
    private var nodes: [UUID: UUID] = [:]

    init(
        credential: CapturePairingCredential,
        queue: DispatchQueue = DispatchQueue(label: "com.vpxstudio.capture-host")
    ) {
        self.credential = credential
        self.queue = queue
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
        }
    }

    private func accept(_ connection: NWConnection) {
        let channel = CaptureSecureChannel(connection: connection, credential: credential)
        channels[channel.connectionID]=channel
        channel.onControlPacket = { [weak self, weak channel] envelope in
            guard let self, let channel else { return }
            if envelope.kind == .qualityEvent,
               let nodeID=nodes.first(where: { $0.value == channel.connectionID })?.key,
               let event=try? envelope.decodePayload(CaptureQualityEvent.self) {
                onTelemetry?(nodeID, channel.connectionID, .diagnostic(event)); return
            }
            guard envelope.kind == .hello,
                  let hello = try? envelope.decodePayload(CaptureNodeHello.self),
                  hello.protocolVersion == CaptureNodeHello.currentProtocolVersion else { channel.cancel(); return }
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
        channels.removeValue(forKey: channel.connectionID)
        guard let nodeID=nodes.first(where: { $0.value == channel.connectionID })?.key else { return }
        nodes.removeValue(forKey: nodeID); datagrams?.unbind(nodeID: nodeID); onDisconnected?(nodeID, channel.connectionID)
    }
}
