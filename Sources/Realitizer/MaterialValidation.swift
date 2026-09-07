extension MaterialDefinition {
    /// The same contract is used by assets and direct renderer compilation.
    public func validationReport() -> ModelValidationReport {
        var diagnostics: [ModelDiagnostic] = []
        func require(_ condition: Bool, _ code: String, _ message: String) {
            if !condition { diagnostics.append(.error(code, path: "materials.\(id.rawValue)", message)) }
        }
        func validColor(_ c: RGBAColor) -> Bool {
            c.isFinite && [c.red, c.green, c.blue, c.alpha].allSatisfy { (0...1).contains($0) }
        }
        require(
            validColor(baseColor), "material.invalidColor",
            "sRGB color channels and alpha must be in [0, 1].")
        require(
            roughness.isFinite && (0...1).contains(roughness), "material.invalidRoughness",
            "Roughness must be in [0, 1].")
        require(
            metallic.isFinite && (0...1).contains(metallic), "material.invalidMetallic",
            "Metallic must be in [0, 1].")
        if case .mask(let cutoff) = alphaMode {
            require(
                cutoff.isFinite && (0...1).contains(cutoff), "material.alphaCutoff",
                "Alpha cutoff must be finite and in [0, 1].")
        }
        require(
            validColor(emissiveColor) && emissiveIntensity.isFinite && emissiveIntensity >= 0,
            "material.emission", "Emission requires a valid color and nonnegative finite intensity.")
        if shading == .unlit {
            require(
                normalTexture == nil && roughnessTexture == nil && metallicTexture == nil
                    && emissiveTexture == nil && emissiveIntensity == 0,
                "material.unlitChannels", "Unlit materials support base color and opacity only.")
        }
        for (texture, encoding) in [
            (baseColorTexture, TextureEncoding.sRGB), (emissiveTexture, .sRGB),
            (normalTexture, .raw), (roughnessTexture, .raw), (metallicTexture, .raw),
        ] {
            guard let texture else { continue }
            do { try texture.validate() } catch let error as ModelValidationError {
                diagnostics += error.diagnostics
            } catch {
                diagnostics.append(
                    .error("material.texture", path: "materials.\(id.rawValue)", String(describing: error)))
            }
            require(
                texture.encoding == encoding, "material.textureEncoding",
                "Color textures require sRGB encoding; normal, roughness and metallic textures require raw encoding."
            )
        }
        return ModelValidationReport(diagnostics: diagnostics)
    }

    public func validate() throws { try validationReport().throwingIfNeeded() }
}
