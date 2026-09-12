#if os(iOS)
import Dispatch
import Foundation
import Network

public struct CaptureNodeDiscoveredHost: Identifiable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
}

/// Finds Mac Hosts advertised by `CaptureNodeBonjourHost`. Discovery is kept
/// separate from pairing: seeing a Host never grants permission to stream.
public final class CaptureNodeHostDiscovery: @unchecked Sendable {
    public var onHostsChanged: (([CaptureNodeDiscoveredHost]) -> Void)?
    public var onFailure: ((Error) -> Void)?

    private var browser: NWBrowser?

    public init() {}

    public func start(on queue: DispatchQueue) {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_vpxcapture._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.map { result in
                CaptureNodeDiscoveredHost(
                    id: result.endpoint.debugDescription,
                    name: Self.displayName(for: result.endpoint),
                    endpoint: result.endpoint
                )
            }
            self?.onHostsChanged?(hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onFailure?(error)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private static func displayName(for endpoint: NWEndpoint) -> String {
        if case .service(let name, _, _, _) = endpoint {
            return name
        }
        return endpoint.debugDescription
    }
}
#endif
