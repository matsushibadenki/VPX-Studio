#if canImport(Network)
import Foundation
import Network

/// One authenticated UDP session. A fresh token is negotiated over the reliable
/// channel on every connection; replay windows never cross connection lifetimes.
public final class CaptureDatagramChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let protector: CaptureControlMessageProtector
    private let nodeID: UUID
    private let connectionID: UUID
    private let queue: DispatchQueue
    private var sequence: UInt64 = 0
    private var replay = CaptureReplayWindow()
    public var onPayload: ((CaptureTelemetryPayload) -> Void)?
    public var onFailure: ((Error) -> Void)?

    public init(connection: NWConnection, credential: CapturePairingCredential, nodeID: UUID,
                connectionID: UUID, queue: DispatchQueue) {
        self.connection=connection; self.protector=CaptureControlMessageProtector(credential: credential)
        self.nodeID=nodeID; self.connectionID=connectionID; self.queue=queue
    }
    public convenience init(host: NWEndpoint.Host, port: UInt16, credential: CapturePairingCredential,
                            nodeID: UUID, connectionID: UUID, queue: DispatchQueue) {
        self.init(connection: NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .udp),
                  credential: credential, nodeID: nodeID, connectionID: connectionID, queue: queue)
    }
    public func start() {
        connection.start(queue: queue)
        queue.async { [weak self] in self?.receive() }
    }
    public func send(_ payload: CaptureTelemetryPayload) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let envelope = CaptureDatagramEnvelope(nodeID: nodeID, connectionID: connectionID, sequence: sequence, payload: payload)
                sequence &+= 1
                let bytes = try envelope.seal(using: protector)
                connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    if let error { self?.onFailure?(error) }
                })
            } catch { onFailure?(error) }
        }
    }
    public func cancel() { connection.cancel() }
    private func receive() {
        connection.receiveMessage { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error { onFailure?(error); return }
            if let data, complete,
               let envelope = try? CaptureDatagramEnvelope.open(data, using: protector),
               envelope.nodeID == nodeID, envelope.connectionID == connectionID,
               replay.accept(envelope.sequence) { onPayload?(envelope.payload) }
            receive()
        }
    }
}
#endif
