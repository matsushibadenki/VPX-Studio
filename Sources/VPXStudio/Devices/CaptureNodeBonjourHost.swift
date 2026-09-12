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

    private let credential: CapturePairingCredential
    private let queue: DispatchQueue
    private var listener: NWListener?

    init(
        credential: CapturePairingCredential,
        queue: DispatchQueue = DispatchQueue(label: "com.vpxstudio.capture-host")
    ) {
        self.credential = credential
        self.queue = queue
    }

    func start(port: NWEndpoint.Port? = nil) throws {
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
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let channel = CaptureSecureChannel(connection: connection, credential: credential)
        channel.onControlPacket = { [weak self, weak channel] envelope in
            guard envelope.kind == .hello,
                  let hello = try? envelope.decodePayload(CaptureNodeHello.self),
                  let channel else { return }
            self?.onHello?(hello, channel)
        }
        channel.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }
        channel.start(on: queue)
    }
}
