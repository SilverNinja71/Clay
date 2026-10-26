// Metal Shading Language source for the Clay viewport.
//
// It lives in a Swift string (instead of a .metal file) and is compiled at runtime with
// `MTLDevice.makeLibrary(source:)`. That keeps the package buildable with only the Command Line
// Tools, which ship without Apple's offline `metal` compiler.

enum ClayShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4x4 model;
    float4 cameraPos;     // xyz eye, w = 1 for orthographic
    float4 viewDir;       // camera forward
    float4 albedo;        // clay colour (linear)
    float4 rim;           // rgb tint, a strength
    float4 keyLight;      // xyz direction toward light, w intensity
    float4 fillLight;
    float4 skyColor;
    float4 groundColor;
    float4 reveal;        // x height, y glow width, z enabled, w time
    float4 brush;         // xyz centre, w radius (0 = hidden)
    float4 brushColor;
    float4 viewport;      // xy drawable size in pixels
    float4 lineColor;
    float4 shadow;        // xyz centre on ground, w radius
    float4 grid;          // x minor spacing, y major spacing, z half extent, w ground height
    float4 gridColor;
    float4 axisX;
    float4 axisZ;
    float4 bgTop;
    float4 bgBottom;
};

// ---------------------------------------------------------------- background

struct BgOut { float4 position [[position]]; float2 uv; };

vertex BgOut bg_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    BgOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment float4 bg_fragment(BgOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float3 c = mix(u.bgTop.rgb, u.bgBottom.rgb, smoothstep(0.0, 1.0, in.uv.y));
    float2 d = in.uv - 0.5;
    c *= 1.0 - dot(d, d) * 0.35;   // soft studio vignette
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- clay surface

struct ClayOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
};

vertex ClayOut clay_vertex(uint vid [[vertex_id]],
                           const device float3* positions [[buffer(0)]],
                           const device float3* normals [[buffer(1)]],
                           constant Uniforms& u [[buffer(2)]]) {
    ClayOut o;
    float4 wp = u.model * float4(positions[vid], 1.0);
    o.position = u.viewProj * wp;
    o.worldPos = wp.xyz;
    o.normal = (u.model * float4(normals[vid], 0.0)).xyz;
    return o;
}

fragment float4 clay_fragment(ClayOut in [[stage_in]],
                              bool frontFacing [[front_facing]],
                              constant Uniforms& u [[buffer(0)]]) {
    if (u.reveal.z > 0.5 && in.worldPos.y > u.reveal.x) discard_fragment();

    float3 n = normalize(in.normal);
    if (!frontFacing) n = -n;
    float3 v = u.cameraPos.w > 0.5 ? -u.viewDir.xyz : normalize(u.cameraPos.xyz - in.worldPos);

    // Studio clay look: wrapped key + cool fill + hemisphere ambient, soft spec and a fresnel rim.
    float3 L1 = normalize(u.keyLight.xyz);
    float3 L2 = normalize(u.fillLight.xyz);
    const float wrap = 0.4;
    float d1 = saturate((dot(n, L1) + wrap) / (1.0 + wrap));
    float d2 = saturate((dot(n, L2) + wrap) / (1.0 + wrap));
    float3 ambient = mix(u.groundColor.rgb, u.skyColor.rgb, n.y * 0.5 + 0.5);
    float3 base = u.albedo.rgb;
    float3 color = base * (ambient * 0.6
                           + d1 * u.keyLight.w * float3(1.0, 0.96, 0.9)
                           + d2 * u.fillLight.w * float3(0.82, 0.88, 1.0));
    float3 h = normalize(L1 + v);
    color += pow(saturate(dot(n, h)), 40.0) * 0.16 * u.keyLight.w;
    float fres = pow(1.0 - saturate(dot(n, v)), 3.0);
    color += u.rim.rgb * fres * u.rim.a;

    // Screen-space curvature darkens creases a little, so sculpted detail reads clearly.
    float curv = length(fwidth(n));
    color *= 1.0 - saturate(curv * 1.2) * 0.22;

    if (u.reveal.z > 0.5) {
        float d = u.reveal.x - in.worldPos.y;
        float g = exp(-max(d, 0.0) / max(u.reveal.y, 0.01));
        color = mix(color, u.rim.rgb * 1.3 + 0.25, saturate(g));
    }

    if (u.brush.w > 0.0) {
        float dist = length(in.worldPos - u.brush.xyz);
        float r = u.brush.w;
        float px = max(fwidth(dist), 1e-4);
        float ring = 1.0 - smoothstep(px * 0.75, px * 2.25, abs(dist - r));
        float inner = (1.0 - smoothstep(0.0, r, dist)) * 0.1;
        color = mix(color, u.brushColor.rgb, saturate(ring * u.brushColor.a + inner));
    }
    return float4(color, 1.0);
}

// ---------------------------------------------------------------- wireframe

struct WireOut { float4 position [[position]]; };

vertex WireOut wire_vertex(uint vid [[vertex_id]],
                           const device float3* positions [[buffer(0)]],
                           constant Uniforms& u [[buffer(2)]]) {
    WireOut o;
    o.position = u.viewProj * u.model * float4(positions[vid], 1.0);
    return o;
}

fragment float4 wire_fragment(WireOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    return u.lineColor;
}

// ---------------------------------------------------------------- thick anti-aliased lines

struct Segment { float4 a; float4 b; float4 color; };   // a.w = width in pixels

struct LineOut {
    float4 position [[position]];
    float4 color;
    float side;
};

vertex LineOut thick_vertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            const device Segment* segs [[buffer(0)]],
                            constant Uniforms& u [[buffer(2)]]) {
    Segment s = segs[iid];
    float4 ca = u.viewProj * float4(s.a.xyz, 1.0);
    float4 cb = u.viewProj * float4(s.b.xyz, 1.0);
    float2 half_vp = u.viewport.xy * 0.5;
    float2 sa = ca.xy / max(ca.w, 1e-4) * half_vp;
    float2 sb = cb.xy / max(cb.w, 1e-4) * half_vp;
    float2 dir = sb - sa;
    float len = length(dir);
    dir = len > 1e-5 ? dir / len : float2(1.0, 0.0);
    float2 nrm = float2(-dir.y, dir.x);
    float w = s.a.w * 0.5 + 1.0;
    bool isB = vid >= 2;
    float side = (vid & 1) ? 1.0 : -1.0;
    float4 c = isB ? cb : ca;
    float2 sp = (isB ? sb : sa) + nrm * side * w + (isB ? dir : -dir) * (s.a.w * 0.5);
    c.xy = sp / half_vp * max(c.w, 1e-4);
    LineOut o;
    o.position = c;
    o.color = s.color;
    o.side = side * w / max(s.a.w * 0.5, 0.5);
    return o;
}

fragment float4 thick_fragment(LineOut in [[stage_in]]) {
    float a = 1.0 - smoothstep(0.75, 1.0 + fwidth(in.side), abs(in.side));
    return float4(in.color.rgb, in.color.a * a);
}

// ---------------------------------------------------------------- ground grid + contact shadow

struct GridOut { float4 position [[position]]; float3 worldPos; };

vertex GridOut grid_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(2)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 c = corners[vid] * u.grid.z;
    GridOut o;
    o.worldPos = float3(c.x, u.grid.w, c.y);
    o.position = u.viewProj * float4(o.worldPos, 1.0);
    return o;
}

static float gridLine(float2 p, float spacing, float thickness) {
    float2 q = p / spacing;
    float2 g = abs(fract(q - 0.5) - 0.5) / max(fwidth(q), float2(1e-5));
    return 1.0 - min(min(g.x, g.y) / thickness, 1.0);
}

fragment float4 grid_fragment(GridOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 p = in.worldPos.xz;
    float minor = gridLine(p, u.grid.x, 1.0) * 0.45;
    float major = gridLine(p, u.grid.y, 1.3);
    float lines = max(minor, major);
    float3 col = u.gridColor.rgb;
    float2 ap = abs(p) / max(fwidth(p), float2(1e-5));
    if (ap.y < 1.5) { col = u.axisX.rgb; lines = max(lines, 1.0 - ap.y / 1.5); }
    if (ap.x < 1.5) { col = u.axisZ.rgb; lines = max(lines, 1.0 - ap.x / 1.5); }

    float dist = length(in.worldPos - u.cameraPos.xyz);
    float fade = 1.0 - smoothstep(u.grid.z * 0.25, u.grid.z * 0.9, length(p - u.shadow.xz));
    fade *= 1.0 - smoothstep(u.grid.z * 0.6, u.grid.z * 1.6, dist);
    float la = lines * u.gridColor.a * fade;

    float sd = length(p - u.shadow.xz) / max(u.shadow.w, 1e-3);
    float sa = (1.0 - smoothstep(0.15, 1.0, sd)) * 0.32;

    float a = la + sa * (1.0 - la);
    float3 rgb = a > 1e-4 ? (col * la) / a : float3(0.0);
    return float4(rgb, a);
}
"""#
}
