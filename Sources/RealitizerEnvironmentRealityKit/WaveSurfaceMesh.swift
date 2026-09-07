import RealitizerEnvironment
import RealitizerRealityKit
import Metal
import Realitizer
import RealityKit
import simd

/// GPU deformation of a horizontal mesh using an immutable, portable WaveField.
/// Keeps topology, UVs and resources stable. Bounds include every possible wave;
/// no vertex readback or CPU mesh validation occurs during a frame.
@MainActor
public final class WaveSurfaceMesh {
    public let resource: MeshResource
    public let lowLevelMesh: LowLevelMesh
    public let field: WaveField
    private let engine: EnvironmentResources
    private let restBuffer: any MTLBuffer
    private let waveBuffer: any MTLBuffer
    private let vertexCount: Int
    private let radialFade: ClosedRange<Float>?
    private var inFlight: (any MTLCommandBuffer)?

    /// Optional radialFade smoothly flattens waves between two XZ radii around
    /// the local origin. Rest vertices must lie on one horizontal plane.
    public init(mesh: MeshData, field: WaveField, radialFade: ClosedRange<Float>? = nil, resources: EnvironmentResources? = nil) throws {
        _ = try mesh.validated()
        guard let first = mesh.vertices.first,
            mesh.vertices.allSatisfy({ v in
                abs(v.position.y - first.position.y) < 0.0001
                    && simd_length(v.position) <= 1_000_000 && abs(v.normal.y) > 0.9999
            }), field.waves.allSatisfy({ abs($0.phase) <= 1_000_000 })
        else { throw WaveSurfaceError.invalidSurface }
        let horizontal = field.waves.reduce(Float(0)) { $0 + $1.steepness * $1.amplitude }
        if let fade = radialFade {
            let slope = field.waves.reduce(Float(0)) { $0 + $1.steepness * $1.amplitude * 2 * .pi / $1.wavelength }
            guard fade.lowerBound.isFinite, fade.upperBound.isFinite, fade.lowerBound >= 0,
                fade.upperBound > fade.lowerBound,
                slope + 1.5 * horizontal / (fade.upperBound - fade.lowerBound) < 0.95
            else { throw WaveSurfaceError.invalidFade }
        }
        engine = try resources ?? EnvironmentResources.shared()
        self.field = field
        self.radialFade = radialFade
        vertexCount = mesh.vertices.count
        let rest = mesh.vertices.map { v in
            let t = SIMD3(v.tangent.x, v.tangent.y, v.tangent.z)
            return DynamicVertex(position: v.position, normal: v.normal, uv: v.textureCoordinate,
                tangent: t, bitangent: simd_cross(v.normal, t) * v.tangent.w, color: v.color.linearRGBA)
        }
        restBuffer = try Self.buffer(rest, device: engine.device)
        var waves = field.waves.flatMap { wave in
            [SIMD4(wave.direction.x, wave.direction.y, wave.amplitude, 2 * Float.pi / wave.wavelength),
             SIMD4(wave.speed, wave.steepness, wave.phase, 0)]
        }
        if waves.isEmpty { waves = [.zero, .zero] }
        waveBuffer = try Self.buffer(waves, device: engine.device)
        let dynamic = try DynamicModelMesh(mesh: mesh)
        resource = dynamic.resource
        lowLevelMesh = dynamic.lowLevelMesh
        let expansion = SIMD3(horizontal, field.maximumVerticalDisplacement, horizontal)
        lowLevelMesh.parts.replaceAll(lowLevelMesh.parts.map { part in
            var expanded = part
            expanded.bounds = BoundingBox(min: part.bounds.min - expansion, max: part.bounds.max + expansion)
            return expanded
        })
    }

    /// Enqueues a complete vertex-buffer replacement and returns without waiting.
    /// If the preceding update is still running, reuses it (bounded backpressure).
    /// The returned buffer is already committed; do not commit it again. Waiting
    /// is useful in tests, but should not be done on the main actor in a game.
    @discardableResult
    public func update(time: Float) throws -> any MTLCommandBuffer {
        guard time.isFinite, abs(time) <= 1_000_000 else { throw WaveSurfaceError.invalidTime }
        if let inFlight {
            if inFlight.status == .error { throw WaveSurfaceError.gpuFailure(inFlight.error?.localizedDescription ?? "Wave compute failed.") }
            if inFlight.status != .completed { return inFlight }
        }
        guard let command = engine.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw WaveSurfaceError.metalUnavailable }
        command.label = "Realitizer wave surface"
        var parameters = WaveParameters(
            timing: SIMD4(time, radialFade?.lowerBound ?? 0, radialFade?.upperBound ?? 0, 0),
            counts: SIMD4(UInt32(vertexCount), UInt32(field.waves.count), 0, 0))
        encoder.setComputePipelineState(engine.pipeline)
        encoder.setBuffer(restBuffer, offset: 0, index: 0)
        encoder.setBuffer(waveBuffer, offset: 0, index: 1)
        encoder.setBuffer(lowLevelMesh.replace(bufferIndex: 0, using: command), offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<WaveParameters>.stride, index: 3)
        encoder.dispatchThreads(MTLSize(width: vertexCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: engine.pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        inFlight = command
        return command
    }

    private static func buffer<T>(_ values: [T], device: any MTLDevice) throws -> any MTLBuffer {
        guard let buffer = values.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }) else { throw WaveSurfaceError.metalUnavailable }
        return buffer
    }
}

public enum WaveSurfaceError: Error {
    case invalidSurface, invalidFade, invalidTime, metalUnavailable
    case gpuFailure(String)
}

private struct WaveParameters {
    var timing: SIMD4<Float>
    var counts: SIMD4<UInt32>
}
