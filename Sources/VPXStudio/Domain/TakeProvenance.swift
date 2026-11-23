import Foundation

struct TakeProvenance: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case configurationSnapshot, recording }
    struct Software: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let build: String
        static var current: Self {
            let bundle = Bundle.main
            return Self(name: "VPX Studio",
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local-build")
        }
    }
    struct Device: Codable, Equatable, Sendable {
        let id: UUID
        let name: String
        let capabilities: [String]
        let role: String
        let connection: String
    }
    struct Plugin: Codable, Equatable, Hashable, Sendable {
        let name: String
        let version: String

        var isValid: Bool {
            [name, version].allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    $0.count <= 256 && $0.rangeOfCharacter(from: .controlCharacters) == nil
            }
        }
    }

    struct CalibrationReference: Codable, Equatable, Sendable {
        let id: UUID
        let revision: Int
        let cameraID: UUID
        let relativePath: String
    }
    struct Recording: Codable, Equatable, Sendable {
        struct PoseCoverage: Codable, Equatable, Sendable {
            var measured = 0
            var interpolated = 0
            var predicted = 0
            var missing = 0

            mutating func record(_ mode: String?) {
                switch mode.flatMap(PoseTimeline.Mode.init(rawValue:)) {
                case .measured: measured += 1
                case .interpolated: interpolated += 1
                case .predicted: predicted += 1
                case nil: missing += 1
                }
            }

            func matches(frameCount: Int) -> Bool {
                var remaining = frameCount
                for count in [measured, interpolated, predicted, missing] {
                    guard count >= 0, count <= remaining else { return false }
                    remaining -= count
                }
                return remaining == 0
            }
        }

        struct ClockCoverage: Codable, Equatable, Sendable {
            var current = 0
            var stale = 0
            var unmeasured = 0
            var peakUncertaintyMilliseconds: Double?

            mutating func record(_ freshness: ClockFreshness, uncertaintyMilliseconds: Double?) {
                switch freshness {
                case .current:
                    current += 1
                    if let uncertaintyMilliseconds, uncertaintyMilliseconds.isFinite, uncertaintyMilliseconds >= 0 {
                        peakUncertaintyMilliseconds = max(peakUncertaintyMilliseconds ?? 0, uncertaintyMilliseconds)
                    }
                case .stale: stale += 1
                case .unmeasured: unmeasured += 1
                }
            }

            var isValid: Bool {
                current >= 0 && stale >= 0 && unmeasured >= 0 &&
                    (current > 0 || stale > 0 || unmeasured > 0) &&
                    (peakUncertaintyMilliseconds.map { current > 0 && $0.isFinite && $0 >= 0 } ?? true)
            }
        }

        struct LocalInputLoss: Codable, Equatable, Sendable {
            enum Event { case droppedFrame, discontinuity, unknownReason }

            var droppedFrames: UInt64 = 0
            var discontinuities: UInt64 = 0
            var unknownReasonEvents: UInt64 = 0

            mutating func record(_ event: Event) {
                switch event {
                case .droppedFrame: droppedFrames += 1
                case .discontinuity: discontinuities += 1
                case .unknownReason: unknownReasonEvents += 1
                }
            }
        }

        struct ColorConversion: Codable, Equatable, Sendable {
            let requested: [SDRInputEncoding]
            let applied: [SDRInputEncoding]
        }

        let sourceID: UUID
        let width: Int
        let height: Int
        let writerPixelFormat: UInt32
        let encodedBitDepth: Int?
        let writtenFrames: Int
        let recorderDrops: Int
        let pose: PoseCoverage?
        var inputSequenceGaps: UInt64?
        var clock: ClockCoverage?
        var localInputLoss: LocalInputLoss?
        var colorConversion: ColorConversion?
        var lutUsage: [CompositeLUT.Usage]?
    }

    let kind: Kind
    let software: Software
    let devices: [Device]
    let calibration: CalibrationReference?
    var recording: Recording?
    var plugins: [Plugin]?

    func validate(assets: [TakeManifest.Asset]) throws {
        guard !software.name.isEmpty, !software.version.isEmpty, !software.build.isEmpty,
              Set(devices.map(\.id)).count == devices.count,
              devices.allSatisfy({ !$0.name.isEmpty && !$0.role.isEmpty && !$0.connection.isEmpty &&
                  Set($0.capabilities).count == $0.capabilities.count && $0.capabilities.allSatisfy { !$0.isEmpty } }) else {
            throw TakeManifest.ValidationError.invalidProvenance
        }
        if let plugins {
            guard plugins.count <= 256, Set(plugins).count == plugins.count,
                  plugins.allSatisfy(\.isValid) else { throw TakeManifest.ValidationError.invalidProvenance }
        }
        if let recording {
            let hasComposite = assets.contains { $0.role == .composite }
            guard kind == .recording,
                  hasComposite || assets.contains(where: { $0.role == .camera }),
                  recording.width > 0, recording.height > 0, recording.writerPixelFormat != 0,
                  recording.writtenFrames > 0, recording.recorderDrops >= 0,
                  recording.encodedBitDepth.map({ $0 == 8 || $0 == 10 }) ?? true,
                  recording.clock?.isValid ?? true,
                  recording.colorConversion.map({ color in
                      hasComposite && !color.requested.isEmpty && Set(color.requested).count == color.requested.count &&
                          !color.applied.contains(.automatic) && Set(color.applied).count == color.applied.count
                  }) ?? true,
                  recording.lutUsage.map({ usage in
                      hasComposite && !usage.isEmpty && Set(usage).count == usage.count && usage.allSatisfy(\.isValid)
                  }) ?? true,
                  recording.pose.map({ hasComposite && $0.matches(frameCount: recording.writtenFrames) }) ?? true else {
                throw TakeManifest.ValidationError.invalidProvenance
            }
        }
        if let calibration {
            guard calibration.revision > 0,
                  assets.contains(where: { $0.role == .calibration && $0.relativePath == calibration.relativePath }) else {
                throw TakeManifest.ValidationError.invalidProvenance
            }
        }
    }
}
