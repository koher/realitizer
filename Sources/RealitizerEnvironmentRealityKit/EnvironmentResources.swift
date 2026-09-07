import Foundation
import Metal

public enum EnvironmentResourceError: Error, Sendable {
    case metalUnavailable
    case libraryUnavailable(String)
    case missingFunction(String)
    case pipelineUnavailable(String)
}

/// Shared shader preparation for optional grass and waves.
/// Call shared() during loading to prepare the bundled library and wave pipeline.
/// Xcode compiles Shaders/*.metal; other build systems supply their own compiled library.
@MainActor
public final class EnvironmentResources {
    public let library: any MTLLibrary
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLComputePipelineState
    private static var cached: EnvironmentResources?

    public static func shared() throws -> EnvironmentResources {
        if let cached { return cached }
        guard let device = MTLCreateSystemDefaultDevice() else { throw EnvironmentResourceError.metalUnavailable }
        let library: any MTLLibrary
        do { library = try device.makeDefaultLibrary(bundle: .module) }
        catch { throw EnvironmentResourceError.libraryUnavailable(String(describing: error)) }
        let prepared = try EnvironmentResources(library: library)
        cached = prepared
        return prepared
    }

    /// Injection supports explicit device ownership and non-Xcode build systems.
    public init(library: any MTLLibrary) throws {
        self.library = library
        device = library.device
        guard let queue = device.makeCommandQueue() else { throw EnvironmentResourceError.metalUnavailable }
        self.queue = queue
        guard let function = library.makeFunction(name: "realitizerWaves") else {
            throw EnvironmentResourceError.missingFunction("realitizerWaves")
        }
        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw EnvironmentResourceError.pipelineUnavailable(String(describing: error)) }
    }
}
