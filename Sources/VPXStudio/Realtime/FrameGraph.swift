import Metal

enum FrameGraphError: LocalizedError {
    case duplicatePass(String)
    case missingDependency(pass: String, dependency: String)
    case cyclicDependency

    var errorDescription: String? {
        switch self {
        case .duplicatePass(let name): "Duplicate frame pass: \(name)"
        case .missingDependency(let pass, let dependency): "Pass \(pass) requires missing pass \(dependency)"
        case .cyclicDependency: "Frame graph has a cyclic dependency"
        }
    }
}

struct FramePass {
    let name: String
    let dependsOn: [String]
}

/// Owns render-pass ordering. Device adapters never encode Metal work directly.
final class FrameGraph {
    private var passes: [String: FramePass] = [:]

    func register(_ pass: FramePass) throws {
        guard passes[pass.name] == nil else {
            throw FrameGraphError.duplicatePass(pass.name)
        }
        passes[pass.name] = pass
    }

    func orderedPasses() throws -> [FramePass] {
        var resolved = Set<String>()
        var visiting = Set<String>()
        var result: [FramePass] = []

        func visit(_ name: String) throws {
            if resolved.contains(name) { return }
            guard let pass = passes[name] else {
                throw FrameGraphError.missingDependency(pass: "FrameGraph", dependency: name)
            }
            guard !visiting.contains(name) else { throw FrameGraphError.cyclicDependency }
            visiting.insert(name)
            for dependency in pass.dependsOn {
                guard passes[dependency] != nil else {
                    throw FrameGraphError.missingDependency(pass: pass.name, dependency: dependency)
                }
                try visit(dependency)
            }
            visiting.remove(name)
            resolved.insert(name)
            result.append(pass)
        }

        for name in passes.keys.sorted() {
            try visit(name)
        }
        return result
    }
}
