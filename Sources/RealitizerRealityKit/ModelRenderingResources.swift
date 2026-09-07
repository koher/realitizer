import Foundation
import Metal

public enum ModelRenderingResourceError: Error, Sendable {
    case metalUnavailable
    case libraryUnavailable(String)
    case missingFunction(String)
    case vertexColorSemanticUnavailable
}

/// Optional shader resources for vertex-colored materials. Ordinary materials do not load them.
/// Xcode compiles the bundled Metal source; other build systems inject a compiled library.
@MainActor
public final class ModelRenderingResources {
    public let library: any MTLLibrary
    private static var cached: ModelRenderingResources?

    public static func shared() throws -> ModelRenderingResources {
        if let cached { return cached }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ModelRenderingResourceError.metalUnavailable
        }
        let library: any MTLLibrary
        do { library = try device.makeDefaultLibrary(bundle: .module) } catch {
            throw ModelRenderingResourceError.libraryUnavailable(String(describing: error))
        }
        let result = try ModelRenderingResources(library: library)
        cached = result
        return result
    }

    public init(library: any MTLLibrary) throws {
        for name in ["realitizer_vertex_color_lit", "realitizer_vertex_color_unlit"] {
            guard library.makeFunction(name: name) != nil else {
                throw ModelRenderingResourceError.missingFunction(name)
            }
        }
        self.library = library
    }
}
