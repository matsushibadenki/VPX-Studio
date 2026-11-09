import XCTest
@testable import VPXStudio

private final class LifecycleVideoSource: VideoSource {
    let descriptor: DeviceDescriptor
    var stops = 0
    init(_ id: UUID) {
        descriptor = DeviceDescriptor(id: id, displayName: "Test", capabilities: [.video])
    }
    func start() throws {}
    func stop() { stops += 1 }
}

final class RealtimeSourceLifecycleTests: XCTestCase {
    func testDetachReleasesOnlyTargetSourceAndReplacementIsStoppedAtShutdown() throws {
        let core = RealtimeCore()
        let id = UUID(), other = LifecycleVideoSource(UUID())
        weak var released: LifecycleVideoSource?
        do {
            let source = LifecycleVideoSource(id)
            released = source
            try core.attach(source)
        }
        try core.attach(other)
        XCTAssertNotNil(released)
        core.detach(id)
        XCTAssertNil(released)
        XCTAssertEqual(other.stops, 0)
        let replacement = LifecycleVideoSource(id)
        try core.attach(replacement)
        core.stop()
        XCTAssertEqual(other.stops, 1)
        XCTAssertEqual(replacement.stops, 1)
    }
}
