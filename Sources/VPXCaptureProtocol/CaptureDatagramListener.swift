#if canImport(Network)
import Foundation
import Network

/// UDP ingress binds node identities only after an authenticated TCP Hello.
/// Invalid/oversized/replayed datagrams are discarded without affecting TCP.
public final class CaptureDatagramListener: @unchecked Sendable {
    public var onReady: ((UInt16) -> Void)?
    public var onPayload: ((UUID, CaptureTelemetryPayload) -> Void)?
    public var onAuthenticatedDatagram: ((CaptureDatagramEnvelope) -> Void)?
    public var onFailure: ((Error) -> Void)?
    private let queue: DispatchQueue
    private let protector: CaptureControlMessageProtector
    private var listener: NWListener?
    private var bindings: [UUID: UUID] = [:]
    private var replay: [UUID: CaptureReplayWindow] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var nodeConnections: [UUID: UUID] = [:]
    public init(credential: CapturePairingCredential, queue: DispatchQueue) {
        self.queue=queue; protector=CaptureControlMessageProtector(credential: credential)
    }
    public func bind(nodeID: UUID, connectionID: UUID) {
        queue.async { [weak self] in
            guard let self, bindings[nodeID] != connectionID else { return }
            bindings[nodeID]=connectionID; replay[nodeID]=CaptureReplayWindow()
        }
    }
    public func unbind(nodeID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            bindings.removeValue(forKey: nodeID); replay.removeValue(forKey: nodeID)
            if let id=nodeConnections.removeValue(forKey: nodeID) { connections.removeValue(forKey: id)?.cancel() }
        }
    }
    public func start() throws {
        let listener = try NWListener(using: .udp)
        self.listener=listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port { self?.onReady?(port.rawValue) }
            if case .failed(let error) = state { self?.onFailure?(error) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, connections.count < 32 else { connection.cancel(); return }
            let id = UUID()
            connections[id]=connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.connections.removeValue(forKey: id) }
                if case .failed = state { self?.connections.removeValue(forKey: id) }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now()+5) { [weak self, weak connection] in
                guard let self, !nodeConnections.values.contains(id) else { return }
                connection?.cancel(); connections.removeValue(forKey: id)
            }
            receive(connection, id: id)
        }
        listener.start(queue: queue)
    }
    public func stop() {
        queue.async { [self] in
            listener?.cancel(); listener=nil
            connections.values.forEach { $0.cancel() }; connections.removeAll()
            bindings.removeAll(); replay.removeAll()
            nodeConnections.removeAll()
        }
    }
    private func receive(_ connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            guard error == nil else { connection.cancel(); connections.removeValue(forKey: id); return }
            if let data, complete,
               let envelope = try? CaptureDatagramEnvelope.open(data, using: protector),
               bindings[envelope.nodeID] == envelope.connectionID {
                if replay[envelope.nodeID]?.accept(envelope.sequence) == true {
                    if let old=nodeConnections[envelope.nodeID], old != id { connections.removeValue(forKey: old)?.cancel() }
                    nodeConnections[envelope.nodeID]=id
                    onAuthenticatedDatagram?(envelope)
                    onPayload?(envelope.nodeID, envelope.payload)
                }
            } else {
                connection.cancel(); connections.removeValue(forKey: id); return
            }
            receive(connection, id: id)
        }
    }
}
#endif
