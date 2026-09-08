import Foundation
import Observation

enum DeviceRole: String, CaseIterable, Identifiable {
    case primaryCamera
    case secondaryCamera
    case trackerOnly
    case monitorOnly

    var id: String { rawValue }
}

enum DeviceConnectionState: Equatable {
    case connecting
    case connected
    case disconnected
    case failed(String)
}

struct RegisteredDevice: Identifiable {
    let descriptor: DeviceDescriptor
    var role: DeviceRole
    var state: DeviceConnectionState

    var id: UUID { descriptor.id }
}

/// Main-actor registry for all local, iPhone, and professional-device adapters.
/// Frame delivery remains in RealtimeCore; this type only owns control-plane state.
@MainActor @Observable
final class DeviceRegistry {
    private(set) var devices: [RegisteredDevice] = []

    func register(_ descriptor: DeviceDescriptor, role: DeviceRole) {
        guard !devices.contains(where: { $0.id == descriptor.id }) else { return }
        devices.append(
            RegisteredDevice(
                descriptor: descriptor,
                role: role,
                state: .connecting
            )
        )
    }

    func updateState(for id: UUID, to state: DeviceConnectionState) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].state = state
    }

    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
    }

    func containsConnectedVideoDevice(named name: String) -> Bool {
        devices.contains {
            $0.descriptor.displayName == name
                && $0.descriptor.capabilities.contains(.video)
                && $0.state == .connected
        }
    }
}
