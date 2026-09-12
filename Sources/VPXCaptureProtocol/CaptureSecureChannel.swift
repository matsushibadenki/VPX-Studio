#if canImport(Network)
import Dispatch
import Foundation
import Network

public enum CaptureSecureChannelState: Sendable, Equatable {
    case setup
    case preparing
    case ready
    case waiting(String)
    case failed(String)
    case cancelled
}

/// A bidirectional, encrypted byte-stream channel for control and HEVC access
/// units. It may wrap TCP directly or a connection accepted by a Bonjour Host.
/// TLS/QUIC can replace the underlying `NWParameters` without changing packet
/// framing or authenticated encryption.
/// All mutable receive state is confined to the queue passed to `start(on:)`.
/// Callbacks must configure the channel before start, or dispatch their own UI
/// work to the appropriate actor.
public final class CaptureSecureChannel: @unchecked Sendable {
    public var onControlPacket: ((CaptureMessageEnvelope) -> Void)?
    public var onVideoFrame: ((CaptureEncodedVideoFrame) -> Void)?
    public var onStateChanged: ((CaptureSecureChannelState) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private let connection: NWConnection
    private let protector: CaptureControlMessageProtector
    private var streamDecoder = CaptureTransportStreamDecoder()
    private var isReceiving = false

    public init(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        credential: CapturePairingCredential,
        parameters: NWParameters = .tcp
    ) {
        connection = NWConnection(host: host, port: port, using: parameters)
        protector = CaptureControlMessageProtector(credential: credential)
    }

    public init(
        endpoint: NWEndpoint,
        credential: CapturePairingCredential,
        parameters: NWParameters = .tcp
    ) {
        connection = NWConnection(to: endpoint, using: parameters)
        protector = CaptureControlMessageProtector(credential: credential)
    }

    public init(connection: NWConnection, credential: CapturePairingCredential) {
        self.connection = connection
        protector = CaptureControlMessageProtector(credential: credential)
    }

    public func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChanged?(Self.map(state))
        }
        connection.start(queue: queue)
        receiveNext()
    }

    public func sendControl(_ envelope: CaptureMessageEnvelope) throws {
        try send(.control(envelope))
    }

    public func sendVideo(_ frame: CaptureEncodedVideoFrame) throws {
        try send(.video(frame))
    }

    public func cancel() {
        connection.cancel()
    }

    private func send(_ packet: CaptureTransportPacket) throws {
        let clearPacket = try CaptureTransportPacketCodec.encode(packet)
        let encryptedPacket = try protector.sealPayload(clearPacket)
        let streamFrame = try CaptureTransportStreamCodec.encode(encryptedPacket)
        connection.send(content: streamFrame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.onFailure?(error)
            }
        })
    }

    private func receiveNext() {
        guard !isReceiving else { return }
        isReceiving = true
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1_048_576
        ) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            self.isReceiving = false
            if let error {
                self.onFailure?(error)
                return
            }
            if let content {
                do {
                    try self.process(content)
                } catch {
                    self.onFailure?(error)
                    self.cancel()
                    return
                }
            }
            if !isComplete {
                self.receiveNext()
            }
        }
    }

    private func process(_ content: Data) throws {
        for encryptedPacket in try streamDecoder.append(content) {
            let clearPacket = try protector.openPayload(encryptedPacket)
            switch try CaptureTransportPacketCodec.decode(clearPacket) {
            case .control(let envelope): onControlPacket?(envelope)
            case .video(let frame): onVideoFrame?(frame)
            }
        }
    }

    private static func map(_ state: NWConnection.State) -> CaptureSecureChannelState {
        switch state {
        case .setup: .setup
        case .preparing: .preparing
        case .ready: .ready
        case .waiting(let error): .waiting(error.debugDescription)
        case .failed(let error): .failed(error.debugDescription)
        case .cancelled: .cancelled
        @unknown default: .failed("Unknown Network.framework connection state.")
        }
    }
}
#endif
