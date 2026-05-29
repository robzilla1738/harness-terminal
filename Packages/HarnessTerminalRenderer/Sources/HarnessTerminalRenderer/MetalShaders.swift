/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)` so the
/// package needs no `.metal` build step or shader resource bundle.
///
/// Three pipelines share one unit-quad (drawn as a 4-vertex triangle strip, expanded per
/// instance): a solid-fill background pass, a texture-sampled glyph pass (with optional
/// gamma-correct coverage), and a procedural line-decoration pass (underline family,
/// strikethrough, overline — including antialiased undercurl). Positions are supplied in
/// pixels and mapped to NDC in the vertex stage (y-down screen space).
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

    // Procedural line decoration. `params` = (centerY, thickness, amplitude, period) in px;
    // `kind` selects the style.
    struct DecoInstance {
        float4 color;
        float4 params;
        float2 origin;
        float2 size;
        uint kind;
    };

    struct VOut {
        float4 position [[position]];
        float4 color;
        float2 uv;
    };

    struct DecoOut {
        float4 position [[position]];
        float4 color;
        float4 params;
        float2 localPx;
        uint kind [[flat]];
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
                                   sampler samp [[sampler(0)]],
                                   constant float &gamma [[buffer(0)]]) {
        float coverage = atlas.sample(samp, in.uv).r;
        // Gamma-correct ("linear-corrected") coverage thickens light-on-dark antialiasing.
        // gamma == 1 is native (no change).
        coverage = pow(coverage, gamma);
        return float4(in.color.rgb, in.color.a * coverage);
    }

    vertex DecoOut deco_vertex(uint vid [[vertex_id]],
                               uint iid [[instance_id]],
                               constant DecoInstance *instances [[buffer(0)]],
                               constant float2 &viewport [[buffer(1)]]) {
        DecoInstance inst = instances[iid];
        float2 corner = quadVerts[vid];
        float2 px = inst.origin + corner * inst.size;
        DecoOut out;
        out.position = float4(pixelToNDC(px, viewport), 0.0, 1.0);
        out.color = inst.color;
        out.params = inst.params;
        out.localPx = corner * inst.size;
        out.kind = inst.kind;
        return out;
    }

    fragment float4 deco_fragment(DecoOut in [[stage_in]]) {
        float centerY = in.params.x;
        float thickness = in.params.y;
        float amplitude = in.params.z;
        float period = in.params.w;
        float x = in.localPx.x;
        float y = in.localPx.y;
        float halfThick = max(thickness * 0.5, 0.5);
        float coverage = 0.0;

        if (in.kind == 1u) {
            // double underline: two thin lines straddling centerY
            float gap = thickness + 1.0;
            float d1 = abs(y - (centerY - gap));
            float d2 = abs(y - (centerY + gap));
            float t = min(thickness * 0.5, 0.6);
            coverage = max(1.0 - smoothstep(t, t + 1.0, d1), 1.0 - smoothstep(t, t + 1.0, d2));
        } else if (in.kind == 4u) {
            // undercurl: a sine wave centered on centerY
            float wave = centerY + amplitude * sin((x / max(period, 1.0)) * 6.2831853);
            coverage = 1.0 - smoothstep(halfThick, halfThick + 1.0, abs(y - wave));
        } else {
            // solid (0), dotted (2), dashed (3): a straight line, optionally gated on x
            coverage = 1.0 - smoothstep(halfThick, halfThick + 1.0, abs(y - centerY));
            if (in.kind == 2u) { // dotted
                float on = fract(x / max(period, 1.0));
                coverage *= step(on, 0.5);
            } else if (in.kind == 3u) { // dashed
                float on = fract(x / max(period, 1.0));
                coverage *= step(on, 0.66);
            }
        }
        return float4(in.color.rgb, in.color.a * coverage);
    }
    """
}
