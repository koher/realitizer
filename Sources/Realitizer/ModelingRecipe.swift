import Foundation

/// Closed operations accepted by the runtime recipe evaluator. No files, network or executable code.
public indirect enum ModelingOperation: Sendable, Codable {
    case box(size: SIMD3<Float>)
    case sphere(radius: Float)
    case cylinder(radius: Float, height: Float)
    case cone(radius: Float, height: Float)
    case extrude(profile: Profile2D, depth: Float)
    case revolve(profile: [SIMD2<Float>])
    case sweep(profile: Profile2D, path: [SIMD3<Float>], twist: Float)
    case loft(sections: [LoftSection], capped: Bool)
    case transformed(ModelingOperation, ModelTransform)
    case mirrored(ModelingOperation, ModelingAxis)
    case array(ModelingOperation, transforms: [ModelTransform])
    case group([ModelingOperation])
    case normals(ModelingOperation, smoothingAngle: Float)
    case uv(ModelingOperation, UVProjection)
    case twist(ModelingOperation, axis: ModelingAxis, radiansPerMeter: Float)
    case bend(ModelingOperation, curvature: Float)
    case taper(ModelingOperation, axis: ModelingAxis, start: Float, end: Float)
    case noise(ModelingOperation, amplitude: Float, frequency: Float)
    case material(ModelingOperation, slot: UInt32)
    case reference(String)
}

public struct ModelingRecipe: Sendable, Codable {
    public var version: Int
    public var seed: UInt64
    public var definitions: [String: ModelingOperation]
    public var root: ModelingOperation
    public init(
        version: Int = 1, seed: UInt64 = 0, definitions: [String: ModelingOperation] = [:], root: ModelingOperation
    ) {
        self.version = version
        self.seed = seed
        self.definitions = definitions
        self.root = root
    }

    /// Limits encoded input before JSON decoding. Evaluation separately limits graph depth and geometry.
    public static func decode(_ data: Data, maximumBytes: Int = 1_000_000) throws -> Self {
        guard data.count <= maximumBytes else {
            throw modelingError("recipe.byteBudget", "Encoded recipe exceeds its byte budget.")
        }
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    quoted = false
                }
            } else if byte == 34 {
                quoted = true
            } else if byte == 123 || byte == 91 {
                depth += 1
                guard depth <= 128 else {
                    throw modelingError("recipe.decodeDepth", "Encoded JSON exceeds its nesting budget.")
                }
            } else if byte == 125 || byte == 93 {
                depth -= 1
            }
        }
        // JSONSerialization enforces JSON validity before the strongly typed decoder runs.
        _ = try JSONSerialization.jsonObject(with: data)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func evaluate(quality: ModelQualityProfile = ModelQualityProfile()) throws -> RecipeEvaluation {
        guard version == 1 else {
            throw modelingError("recipe.version", "Unsupported recipe version.", path: "version")
        }
        guard (3...256).contains(quality.curveSegments), (2...256).contains(quality.surfaceSegments),
            quality.budget.maximumVertices > 0, quality.budget.maximumTriangles > 0,
            (1...128).contains(quality.budget.maximumDepth), quality.budget.maximumOperations > 0
        else {
            throw modelingError("recipe.quality", "Quality resolution and evaluation budgets are invalid.")
        }
        var evaluator = RecipeEvaluator(recipe: self, quality: quality)
        let clock = ContinuousClock()
        let start = clock.now
        let mesh = try evaluator.evaluate(root, path: "root", depth: 0)
        return RecipeEvaluation(
            mesh: mesh, evaluatedOperations: evaluator.operations, cachedReferences: evaluator.cache.count,
            elapsed: start.duration(to: clock.now))
    }
}

public struct RecipeEvaluation: Sendable {
    public let mesh: MeshData
    public let evaluatedOperations: Int
    public let cachedReferences: Int
    /// Telemetry only; elapsed time never affects generated geometry.
    public let elapsed: Duration
}

private struct RecipeEvaluator {
    let recipe: ModelingRecipe
    let quality: ModelQualityProfile
    var operations = 0
    var cache: [String: MeshData] = [:]
    var cachedVertices = 0
    var activeReferences: Set<String> = []

    mutating func evaluate(_ operation: ModelingOperation, path: String, depth: Int) throws -> MeshData {
        operations += 1
        guard operations <= quality.budget.maximumOperations, depth <= quality.budget.maximumDepth else {
            throw modelingError("recipe.complexity", "Recipe exceeds the operation or nesting budget.", path: path)
        }
        func checkAllocation(vertices: Int, triangles: Int) throws {
            guard vertices <= quality.budget.maximumVertices, triangles <= quality.budget.maximumTriangles else {
                throw modelingError("recipe.allocation", "Operation would exceed the geometry budget.", path: path)
            }
        }
        do {
            let mesh: MeshData
            switch operation {
            case .box(let size): mesh = try MeshBuilder.box(size: size)
            case .sphere(let radius):
                try checkAllocation(
                    vertices: (quality.surfaceSegments + 1) * (quality.curveSegments + 1),
                    triangles: 2 * quality.surfaceSegments * quality.curveSegments)
                mesh = try MeshBuilder.sphere(
                    radius: radius, latitudeSegments: quality.surfaceSegments, longitudeSegments: quality.curveSegments)
            case .cylinder(let radius, let height):
                mesh = try MeshBuilder.cylinder(radius: radius, height: height, segments: quality.curveSegments)
            case .cone(let radius, let height):
                mesh = try MeshBuilder.cone(radius: radius, height: height, segments: quality.curveSegments)
            case .extrude(let profile, let depth):
                let points = profile.outer.count + profile.holes.reduce(0) { $0 + $1.count + 2 }
                guard points <= 1024 else {
                    throw modelingError(
                        "recipe.profileBudget", "Runtime profiles are limited to 1024 points including hole bridges.")
                }
                try checkAllocation(vertices: points * 8, triangles: points * 4)
                mesh = try MeshBuilder.extrude(profile, depth: depth)
            case .revolve(let profile):
                try checkAllocation(
                    vertices: profile.count * (quality.curveSegments + 1) * 2,
                    triangles: profile.count * quality.curveSegments * 2)
                mesh = try MeshBuilder.revolve(profile: profile, segments: quality.curveSegments)
            case .sweep(let profile, let points, let twist):
                guard profile.outer.count <= 1024, points.count <= 1024 else {
                    throw modelingError(
                        "recipe.sweepBudget", "Runtime sweep profiles and paths are limited to 1024 points each.")
                }
                try checkAllocation(
                    vertices: (profile.outer.count + 1) * points.count * 8,
                    triangles: profile.outer.count * points.count * 4)
                mesh = try MeshBuilder.sweep(profile, along: points, twist: twist)
            case .loft(let sections, let capped):
                let count = sections.first?.profile.count ?? 0
                guard sections.count <= 1024, sections.allSatisfy({ $0.profile.count <= 1024 }) else {
                    throw modelingError(
                        "recipe.loftBudget", "Runtime loft sections and profiles are limited to 1024 entries each.")
                }
                try checkAllocation(vertices: (count + 1) * sections.count * 8, triangles: count * sections.count * 4)
                mesh = try MeshBuilder.loft(sections, capped: capped)
            case .reference(let name):
                if let cached = cache[name] { return cached }
                guard let definition = recipe.definitions[name], activeReferences.insert(name).inserted else {
                    throw modelingError("recipe.reference", "Reference is missing or cyclic.", path: name)
                }
                mesh = try evaluate(definition, path: "definitions.\(name)", depth: depth + 1)
                guard cachedVertices <= quality.budget.maximumVertices - mesh.vertices.count else {
                    throw modelingError(
                        "recipe.cacheBudget", "Named reference geometry exceeds the aggregate cache budget.")
                }
                cachedVertices += mesh.vertices.count
                activeReferences.remove(name)
                cache[name] = mesh
            case .group(let children):
                var builder = MeshBuilder()
                for (i, child) in children.enumerated() {
                    let result = try evaluate(child, path: "\(path).group[\(i)]", depth: depth + 1)
                    try checkAllocation(
                        vertices: builder.vertices.count + result.vertices.count,
                        triangles: builder.indices.count / 3 + result.triangleCount)
                    builder.append(result)
                }
                mesh = try builder.build()
            case .array(let child, let transforms):
                let source = try evaluate(child, path: "\(path).input", depth: depth + 1)
                guard transforms.count <= quality.budget.maximumVertices / max(source.vertices.count, 1),
                    transforms.count <= quality.budget.maximumTriangles / max(source.triangleCount, 1)
                else { throw modelingError("recipe.arrayBudget", "Array would exceed the geometry budget.") }
                mesh = try source.repeated(at: transforms)
            case .transformed(let child, let transform):
                guard transform.isFinite, abs(transform.scale.x * transform.scale.y * transform.scale.z) > 1e-12 else {
                    throw modelingError("recipe.transform", "Transforms must be finite and invertible.")
                }
                mesh = try evaluate(child, path: "\(path).input", depth: depth + 1).transformed(by: transform)
            case .mirrored(let child, let axis):
                mesh = try evaluate(child, path: "\(path).input", depth: depth + 1).mirrored(across: axis)
            case .normals(let child, let angle):
                let source = try evaluate(child, path: "\(path).input", depth: depth + 1)
                try checkAllocation(vertices: source.indices.count, triangles: source.triangleCount)
                mesh = try source.recalculatingNormals(smoothingAngle: angle).generatingTangents()
            case .uv(let child, let projection):
                let source = try evaluate(child, path: "\(path).input", depth: depth + 1)
                try checkAllocation(vertices: source.indices.count, triangles: source.triangleCount)
                mesh = try source.projectingUV(projection)
            case .twist(let child, let axis, let radians):
                mesh = try evaluate(child, path: "\(path).input", depth: depth + 1).twisted(
                    around: axis, radiansPerMeter: radians)
            case .bend(let child, let curvature):
                mesh = try evaluate(child, path: "\(path).input", depth: depth + 1).bent(curvature: curvature)
            case .taper(let child, let axis, let start, let end):
                mesh = try evaluate(child, path: "\(path).input", depth: depth + 1).tapered(
                    along: axis, from: start, to: end)
            case .noise(let child, let amplitude, let frequency):
                mesh = try evaluate(child, path: "\(path).input", depth: depth + 1).noiseDisplaced(
                    amplitude: amplitude, frequency: frequency, seed: recipe.seed)
            case .material(let child, let slot):
                var result = try evaluate(child, path: "\(path).input", depth: depth + 1)
                result.materialIndices = Array(repeating: slot, count: result.triangleCount)
                mesh = result
            }
            try quality.budget.validate(mesh)
            return try mesh.validated(path: path)
        } catch let error as ModelValidationError {
            throw ModelValidationError(
                diagnostics: error.diagnostics.map {
                    ModelDiagnostic(
                        severity: $0.severity, code: $0.code, path: "\(path).\($0.path)", message: $0.message)
                })
        }
    }
}
