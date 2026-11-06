import Foundation

/// Disk I/O is isolated from UI/render queues. Each line is an independent JSON record.
actor DiagnosticsArchive {
    struct Record: Codable {
        let schemaVersion: Int
        let sessionID: UUID
        let event: DiagnosticsEventHistory.Event
        let omittedBeforeEvent: UInt64
    }

    private let sessionID = UUID()
    private var handle: FileHandle?
    private var lastSequence: UInt64 = 0

    init(url: URL) throws {
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ events: [DiagnosticsEventHistory.Event]) throws {
        guard let handle else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for event in events where event.sequence > lastSequence {
            let omitted = event.sequence > lastSequence + 1 ? event.sequence - lastSequence - 1 : 0
            let record = Record(schemaVersion: 1, sessionID: sessionID, event: event, omittedBeforeEvent: omitted)
            var data = try encoder.encode(record)
            data.append(0x0A)
            try handle.write(contentsOf: data)
            lastSequence = event.sequence
        }
        try handle.synchronize()
    }

    func close() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}
