import XCTest
@testable import VPXStudio

final class FrameGraphTests: XCTestCase {
    func testOrdersDependenciesBeforeDependents() throws {
        let graph = FrameGraph()
        try graph.register(FramePass(name: "output", dependsOn: ["composite"]))
        try graph.register(FramePass(name: "scene", dependsOn: []))
        try graph.register(FramePass(name: "composite", dependsOn: ["scene"]))

        XCTAssertEqual(
            try graph.orderedPasses().map { $0.name },
            ["scene", "composite", "output"]
        )
    }

    func testRejectsDuplicatePasses() throws {
        let graph = FrameGraph()
        try graph.register(FramePass(name: "scene", dependsOn: []))

        XCTAssertThrowsError(
            try graph.register(FramePass(name: "scene", dependsOn: []))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Duplicate frame pass: scene")
        }
    }

    func testRejectsMissingDependencies() throws {
        let graph = FrameGraph()
        try graph.register(FramePass(name: "composite", dependsOn: ["missing"]))

        XCTAssertThrowsError(try graph.orderedPasses()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Pass composite requires missing pass missing"
            )
        }
    }

    func testRejectsCyclicDependencies() throws {
        let graph = FrameGraph()
        try graph.register(FramePass(name: "scene", dependsOn: ["composite"]))
        try graph.register(FramePass(name: "composite", dependsOn: ["scene"]))

        XCTAssertThrowsError(try graph.orderedPasses()) { error in
            XCTAssertEqual(error.localizedDescription, "Frame graph has a cyclic dependency")
        }
    }
}
