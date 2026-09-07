/// Caller-owned, typed authoring inputs. Parameters are usually a dedicated struct.
public struct AssetGenerationInput<Parameters: Sendable>: Sendable {
    public var parameters: Parameters
    public var seed: UInt64
    public var quality: ModelQualityProfile
    public init(
        parameters: Parameters, seed: UInt64 = 0, quality: ModelQualityProfile = ModelQualityProfile()
    ) {
        self.parameters = parameters
        self.seed = seed
        self.quality = quality
    }
}
extension AssetGenerationInput: Equatable where Parameters: Equatable {}

public struct NoAssetParameters: Equatable, Sendable {
    public init() {}
}

/// Lazy, deterministic authoring with domain-specific validation, independent of editor controls.
public struct ModelAssetGenerator<Parameters: Sendable>: Sendable {
    public let name: String
    public let version: Int
    public let parameters: Parameters
    public let seed: UInt64
    private let validateParameters: @Sendable (Parameters) throws -> Void
    private let make: @Sendable (AssetGenerationInput<Parameters>) throws -> ModelAssetDefinition

    public init(
        name: String, version: Int = 1, parameters: Parameters, seed: UInt64 = 0,
        validate: @escaping @Sendable (Parameters) throws -> Void = { _ in },
        make: @escaping @Sendable (AssetGenerationInput<Parameters>) throws -> ModelAssetDefinition
    ) {
        self.name = name
        self.version = version
        self.parameters = parameters
        self.seed = seed
        validateParameters = validate
        self.make = make
    }

    public func generate(_ input: AssetGenerationInput<Parameters>) throws -> ModelAssetDefinition {
        guard version > 0 else {
            throw modelingError("generator.version", "Generator version must be positive.")
        }
        try validateParameters(input.parameters)
        let asset = try make(input).validated()
        for part in asset.parts { try input.quality.budget.validate(part.geometry.mesh) }
        let geometry = asset.parts.flatMap {
            [$0.geometry.mesh] + $0.levelsOfDetail.map(\.geometry.mesh)
        }
        guard geometry.reduce(0, { $0 + $1.vertices.count }) <= input.quality.budget.maximumVertices,
            geometry.reduce(0, { $0 + $1.triangleCount }) <= input.quality.budget.maximumTriangles
        else {
            throw modelingError(
                "generator.assetBudget", "Asset and LOD geometry exceeds the aggregate generation budget.")
        }
        return asset
    }

    public var defaultInput: AssetGenerationInput<Parameters> {
        AssetGenerationInput(parameters: parameters, seed: seed)
    }
    public func generate() throws -> ModelAssetDefinition { try generate(defaultInput) }
}

extension ModelAssetGenerator where Parameters == NoAssetParameters {
    public init(
        name: String, version: Int = 1, seed: UInt64 = 0,
        make:
            @escaping @Sendable (AssetGenerationInput<NoAssetParameters>) throws -> ModelAssetDefinition
    ) {
        self.init(name: name, version: version, parameters: NoAssetParameters(), seed: seed, make: make)
    }
}

extension ModelingRecipe {
    public func geometryLevels(qualities: [ModelQualityProfile], distances: [Float]) throws
        -> [ModelGeometryLevel]
    {
        guard qualities.count == distances.count else {
            throw modelingError("lod.recipeCounts", "Each LOD quality requires a distance.")
        }
        return try zip(qualities, distances).map { quality, distance in
            ModelGeometryLevel(minimumDistance: distance, mesh: try evaluate(quality: quality).mesh)
        }
    }
}
