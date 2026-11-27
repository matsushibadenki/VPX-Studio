import CoreMedia

struct TakeOcclusionSummary: Sendable {
    enum Category: CaseIterable, Hashable, Sendable {
        case applied, missingDepth, mismatch, lowConfidence

        var localizationKey: LocalizationKey {
            switch self {
            case .applied: .takeOcclusionApplied
            case .missingDepth: .takeOcclusionMissing
            case .mismatch: .takeOcclusionMismatch
            case .lowConfidence: .takeOcclusionLowConfidence
            }
        }
    }

    struct Segment: Sendable {
        let start: CMTime
        var frames: ClosedRange<Int>
    }

    struct Group: Sendable {
        var frameCount = 0
        var segments: [Segment] = []

        func next(after time: CMTime) -> Segment? {
            segments.first { time.isNumeric && $0.start > time } ?? segments.first
        }

        mutating func append(_ row: TakeAuxiliaryTracks.Row) {
            frameCount += 1
            if let last = segments.last, last.frames.upperBound == row.frameIndex - 1 {
                segments[segments.count - 1].frames = last.frames.lowerBound...row.frameIndex
            } else {
                segments.append(.init(start: CMTime(value: row.ptsValue, timescale: row.ptsTimescale),
                                      frames: row.frameIndex...row.frameIndex))
            }
        }
    }

    let enabledFrameCount: Int
    let groups: [Category: Group]

    var appliedRate: Double {
        Double(groups[.applied]?.frameCount ?? 0) / Double(enabledFrameCount)
    }

    init?(rows: [TakeAuxiliaryTracks.Row]) throws {
        var count = 0
        var groups: [Category: Group] = [:]
        for row in rows {
            try Task.checkCancellation()
            guard let result = row.depthOcclusion, result.state != .disabled else { continue }
            count += 1
            if result.state == .mismatchedDepth { groups[.mismatch, default: Group()].append(row) }
            if result.state == .missingDepth || (result.state == .evaluated && result.missingSamples) {
                groups[.missingDepth, default: Group()].append(row)
            }
            if result.state == .evaluated && result.lowConfidence { groups[.lowConfidence, default: Group()].append(row) }
            if result.state == .evaluated && result.applied { groups[.applied, default: Group()].append(row) }
        }
        guard count > 0 else { return nil }
        enabledFrameCount = count
        self.groups = groups
    }
}
