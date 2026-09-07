#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

constexpr sampler colorSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);

// RealityKit supplies color textures/tints in linear Display P3. Authored vertex values use
// linear sRGB. Do the documented multiplication in sRGB primaries, then return working-space RGB.
static float3 to_srgb(float3 p3) {
    return float3x3(float3(1.225003, -0.0420922, -0.0196249),
                   float3(-0.224976, 1.042071, -0.0786100),
                   float3(-0.00002723, 0.00002146, 1.098235)) * p3;
}
static half3 to_working(float3 srgb) {
    return half3(float3x3(float3(0.8224261, 0.0332198, 0.0170742),
                         float3(0.1775570, 0.9667982, 0.0723748),
                         float3(0.00001689, -0.00001807, 0.9105511)) * srgb);
}

// custom.x: texture presence bits; custom.y: emission intensity; custom.z: alpha enabled;
// custom.w: explicit cutout threshold, or -1 when cutout is disabled.
static half4 vertex_base(realitykit::surface_parameters p) {
    uint flags = uint(p.uniforms().custom_parameter().x);
    half4 texel = (flags & 1) ? p.textures().base_color().sample(colorSampler, p.geometry().uv0()) : half4(1);
    half4 vertexColor = half4(p.geometry().color());
    half3 rgb = to_working(max(to_srgb(p.material_constants().base_color_tint()), float3(0))
                          * max(to_srgb(float3(texel.rgb)), float3(0)) * float3(vertexColor.rgb));
    half alpha = p.uniforms().custom_parameter().z > 0
        ? texel.a * vertexColor.a * half(p.material_constants().opacity_scale()) : half(1);
    if (p.uniforms().custom_parameter().w >= 0 && alpha < p.uniforms().custom_parameter().w) discard_fragment();
    return half4(rgb, alpha);
}

[[visible]] void realitizer_vertex_color_lit(realitykit::surface_parameters p) {
    half4 base = vertex_base(p);
    auto surface = p.surface();
    auto textures = p.textures();
    auto constants = p.material_constants();
    float4 custom = p.uniforms().custom_parameter();
    uint flags = uint(custom.x);
    float2 uv = p.geometry().uv0();
    surface.set_base_color(base.rgb);
    surface.set_opacity(base.a);
    surface.set_roughness(half(constants.roughness_scale()) *
        ((flags & 4) ? textures.roughness().sample(colorSampler, uv).r : half(1)));
    surface.set_metallic(half(constants.metallic_scale()) *
        ((flags & 8) ? textures.metallic().sample(colorSampler, uv).r : half(1)));
    if (flags & 2) surface.set_normal(float3(realitykit::unpack_normal(textures.normal().sample(colorSampler, uv).rgb)));
    float3 emission = max(to_srgb(constants.emissive_color()), float3(0)) * custom.y;
    if (flags & 16) emission *= max(to_srgb(float3(textures.emissive_color().sample(colorSampler, uv).rgb)), float3(0));
    surface.set_emissive_color(to_working(emission));
}

[[visible]] void realitizer_vertex_color_unlit(realitykit::surface_parameters p) {
    half4 base = vertex_base(p);
    p.surface().set_emissive_color(base.rgb);
    p.surface().set_opacity(base.a);
}
