/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)` so the
/// package needs no `.metal` build step or shader resource bundle.
///
/// Two pipelines share one unit-quad (drawn as a 4-vertex triangle strip, expanded per
/// instance): a solid-fill background pass and a texture-sampled glyph pass. Positions
/// are supplied in pixels and mapped to NDC in the vertex stage (y-down screen space).
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct BgInstance {
        float2 origin;
        float2 size;
        float4 color;
    };

    struct GlyphInstance {
        float2 origin;
        float2 size;
        float2 uvOrigin;
        float2 uvSize;
        float4 color;
    };

    struct VOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
    };

    constant float2 quadVerts[4] = {
        float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0)
    };

    static float2 pixelToNDC(float2 px, float2 viewport) {
        return float2(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0);
    }

    vertex VOut bg_vertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant BgInstance *instances [[buffer(0)]],
                          constant float2 &viewport [[buffer(1)]]) {
        BgInstance inst = instances[iid];
        float2 corner = quadVerts[vid];
        float2 px = inst.origin + corner * inst.size;
        VOut out;
        out.position = float4(pixelToNDC(px, viewport), 0.0, 1.0);
        out.color = inst.color;
        out.uv = float2(0.0, 0.0);
        return out;
    }

    fragment float4 bg_fragment(VOut in [[stage_in]]) {
        return in.color;
    }

    vertex VOut glyph_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant GlyphInstance *instances [[buffer(0)]],
                             constant float2 &viewport [[buffer(1)]]) {
        GlyphInstance inst = instances[iid];
        float2 corner = quadVerts[vid];
        float2 px = inst.origin + corner * inst.size;
        VOut out;
        out.position = float4(pixelToNDC(px, viewport), 0.0, 1.0);
        out.color = inst.color;
        out.uv = inst.uvOrigin + corner * inst.uvSize;
        return out;
    }

    fragment float4 glyph_fragment(VOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        float coverage = atlas.sample(samp, in.uv).r;
        return float4(in.color.rgb, in.color.a * coverage);
    }
    """
}
