import Realitizer
import RealityKit
import simd

/// Bounded LRU cache. Keys must include generator version, parameters, seed, style and quality.
@MainActor
public final class ModelResourceCache<Key: Hashable> {
    public let capacity: Int
    private var values: [Key: CompiledModelAsset] = [:]
    private var recency: [Key] = []
    private let resources: ModelRenderingResources?
    public init(capacity: Int = 32, resources: ModelRenderingResources? = nil) {
        self.capacity = max(1, capacity)
        self.resources = resources
    }
    public var count: Int { values.count }
    public func asset(for key: Key, make: () throws -> ModelAssetDefinition) throws
        -> CompiledModelAsset
    {
        if let existing = values[key] {
            touch(key)
            return existing
        }
        let compiled = try RealityKitModelCompiler.compile(make(), resources: resources)
        values[key] = compiled
        touch(key)
        if recency.count > capacity { values.removeValue(forKey: recency.removeFirst()) }
        return compiled
    }
    public func remove(_ key: Key) {
        values.removeValue(forKey: key)
        recency.removeAll { $0 == key }
    }
    public func removeAll() {
        values.removeAll()
        recency.removeAll()
    }
    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// GPU instances of static visual assets. Instance/part IDs remain addressable without one Entity per copy.
/// Animated rigs and physics use ordinary RuntimeModelInstance objects instead.
@MainActor
public final class StaticModelBatch<ID: RealitizerID> {
    public let root: Entity
    public let instanceIDs: [ID]
    private let definition: ModelAssetDefinition
    private let indexByID: [ID: Int]
    private var transforms: [ModelTransform]
    private let buffers: [AnyRealitizerID: LowLevelInstanceData]
    private var localMatrices: [AnyRealitizerID: simd_float4x4]

    public init(asset: CompiledModelAsset, instances: [(ID, ModelTransform)]) throws {
        guard !instances.isEmpty, instances.count <= 100_000,
            Set(instances.map(\.0)).count == instances.count,
            instances.allSatisfy({ $0.1.isFinite }), asset.definition.rig == nil,
            asset.definition.clips.isEmpty,
            asset.definition.collisions.isEmpty,
            asset.definition.parts.allSatisfy({
                $0.geometry.morphTargets.isEmpty && $0.levelsOfDetail.isEmpty
            })
        else {
            throw StaticBatchError.unsupportedAsset
        }
        definition = asset.definition
        instanceIDs = instances.map(\.0)
        transforms = instances.map(\.1)
        indexByID = Dictionary(
            uniqueKeysWithValues: instanceIDs.enumerated().map { ($0.element, $0.offset) })
        root = Entity()
        root.name = definition.name + " batch"
        var matrices: [AnyRealitizerID: simd_float4x4] = [:]
        for part in definition.parts {
            matrices[part.id] = try definition.globalTransform(of: .part(part.id))
        }
        localMatrices = matrices
        var created: [AnyRealitizerID: LowLevelInstanceData] = [:]
        for part in asset.parts {
            let buffer = try LowLevelInstanceData(instanceCount: instances.count)
            let local = matrices[part.definition.id]!
            buffer.withMutableTransforms { pointer in
                for i in instances.indices { pointer[i] = instances[i].1.matrix * local }
            }
            let slots = [part.definition.materialID] + part.definition.additionalMaterialIDs
            let materials = try slots.map { id -> any Material in
                guard let value = asset.materials[id] else {
                    throw RealityKitCompilationError.missingMaterial(id)
                }
                return value
            }
            let entity = ModelEntity(mesh: part.levels[0].mesh, materials: materials)
            entity.components.set(
                try MeshInstancesComponent(mesh: part.levels[0].mesh, instances: buffer))
            root.addChild(entity)
            created[part.definition.id] = buffer
        }
        buffers = created
    }

    public func setTransform(_ transform: ModelTransform, for id: ID) throws {
        guard let index = indexByID[id], transform.isFinite else {
            throw StaticBatchError.invalidInstance
        }
        transforms[index] = transform
        for (part, buffer) in buffers {
            buffer.withMutableTransforms { $0[index] = transform.matrix * localMatrices[part]! }
        }
    }

    public func transform<Part: RealitizerID>(of part: Part, in instance: ID) throws -> simd_float4x4 {
        guard let index = indexByID[instance], let local = localMatrices[part.erasedID] else {
            throw StaticBatchError.invalidInstance
        }
        return transforms[index].matrix * local
    }

    public func socketTransform<Socket: RealitizerID>(_ socket: Socket, in instance: ID) throws
        -> simd_float4x4
    {
        guard let index = indexByID[instance],
            let socket = definition.sockets.first(where: { $0.id == socket.erasedID })
        else { throw StaticBatchError.invalidInstance }
        return try transforms[index].matrix * definition.globalTransform(of: socket.parent)
            * socket.transform.matrix
    }
}

public enum StaticBatchError: Error { case unsupportedAsset, invalidInstance }
