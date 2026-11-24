// Rota 120 Hz single-pass instanced UI shader (Quads, Shadows, Mask Glyphs/Icons, Color Bitmaps).

struct Globals {
    viewport_size: vec2<f32>,
    scale_factor: f32,
    _pad: f32,
};

struct GpuPrimitive {
    bounds: vec4<f32>,       // x, y, width, height (logical points)
    clip_rect: vec4<f32>,    // min_x, min_y, max_x, max_y (logical points)
    corners: vec4<f32>,      // tl, tr, br, bl radii (logical points)
    fill_color: vec4<f32>,   // straight linear RGBA
    border_color: vec4<f32>, // straight linear RGBA
    shadow_color: vec4<f32>, // straight linear RGBA
    uv_rect: vec4<f32>,      // u0, v0, u1, v1
    params: vec4<f32>,       // border_width, shadow_blur, shadow_dx, shadow_dy
    kind_flags: vec4<u32>,   // kind (0=Quad, 1=Mask, 2=ColorBitmap), flags, pad, pad
};

@group(0) @binding(0) var<uniform> globals: Globals;
@group(0) @binding(1) var<storage, read> primitives: array<GpuPrimitive>;
@group(0) @binding(2) var mask_atlas: texture_2d<f32>;
@group(0) @binding(3) var color_atlas: texture_2d<f32>;
@group(0) @binding(4) var linear_sampler: sampler;

struct VertexOut {
    @builtin(position) clip_pos: vec4<f32>,
    @location(0) local_pos: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) @interpolate(flat) instance_idx: u32,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_idx: u32,
    @builtin(instance_index) instance_idx: u32,
) -> VertexOut {
    let prim = primitives[instance_idx];
    let kind = prim.kind_flags.x;
    let blur = prim.params.y;
    let shadow_off = prim.params.zw;

    var min_p = prim.bounds.xy;
    var max_p = prim.bounds.xy + prim.bounds.zw;

    // Expand quad geometry when drop-shadow blur is present so shadow falloff isn't clipped early.
    if (kind == 0u && blur > 0.0 && prim.shadow_color.a > 0.0) {
        let pad = blur * 2.5 + 2.0;
        min_p = min(min_p, prim.bounds.xy + shadow_off - vec2<f32>(pad, pad));
        max_p = max(max_p, prim.bounds.xy + prim.bounds.zw + shadow_off + vec2<f32>(pad, pad));
    }

    // Clamp vertex quad against clip_rect so completely culled regions cost zero fragment shading.
    let c_min = clamp(min_p, prim.clip_rect.xy, prim.clip_rect.zw);
    let c_max = clamp(max_p, prim.clip_rect.xy, prim.clip_rect.zw);

    var unit = vec2<f32>(0.0, 0.0);
    switch (vertex_idx) {
        case 0u: { unit = vec2<f32>(0.0, 0.0); }
        case 1u: { unit = vec2<f32>(1.0, 0.0); }
        case 2u: { unit = vec2<f32>(0.0, 1.0); }
        case 3u: { unit = vec2<f32>(0.0, 1.0); }
        case 4u: { unit = vec2<f32>(1.0, 0.0); }
        default: { unit = vec2<f32>(1.0, 1.0); }
    }

    let pos = mix(c_min, c_max, unit);
    let safe_size = max(prim.bounds.zw, vec2<f32>(1e-4, 1e-4));
    let rect_t = (pos - prim.bounds.xy) / safe_size;
    let uv = mix(prim.uv_rect.xy, prim.uv_rect.zw, rect_t);

    let ndc = vec2<f32>(
        (pos.x / globals.viewport_size.x) * 2.0 - 1.0,
        1.0 - (pos.y / globals.viewport_size.y) * 2.0,
    );

    var out: VertexOut;
    out.clip_pos = vec4<f32>(ndc, 0.0, 1.0);
    out.local_pos = pos;
    out.uv = uv;
    out.instance_idx = instance_idx;
    return out;
}

// Signed distance to a 2D box centered at origin with half-extents `b` and radii (tl, tr, br, bl).
fn sd_rounded_box(p: vec2<f32>, b: vec2<f32>, radii: vec4<f32>) -> f32 {
    let pair = select(radii.wz, radii.xy, p.y < 0.0);
    let r = min(select(pair.x, pair.y, p.x >= 0.0), min(b.x, b.y));
    let q = abs(p) - b + vec2<f32>(r, r);
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2<f32>(0.0, 0.0))) - r;
}

fn premultiply(c: vec4<f32>) -> vec4<f32> {
    return vec4<f32>(c.rgb * c.a, c.a);
}

fn over_premul(fg: vec4<f32>, bg: vec4<f32>) -> vec4<f32> {
    return fg + bg * (1.0 - fg.a);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let prim = primitives[in.instance_idx];
    if (in.local_pos.x < prim.clip_rect.x || in.local_pos.y < prim.clip_rect.y ||
        in.local_pos.x > prim.clip_rect.z || in.local_pos.y > prim.clip_rect.w) {
        discard;
    }

    let aa = 0.5 / max(globals.scale_factor, 1.0);
    var clip_cov = 1.0;
    let packed_cr = prim.kind_flags.z;
    if (packed_cr != 0u) {
        let cr = vec4<f32>(
            f32(packed_cr & 0xFFu) * 0.5,
            f32((packed_cr >> 8u) & 0xFFu) * 0.5,
            f32((packed_cr >> 16u) & 0xFFu) * 0.5,
            f32((packed_cr >> 24u) & 0xFFu) * 0.5,
        );
        let c_half = (prim.clip_rect.zw - prim.clip_rect.xy) * 0.5;
        let c_center = prim.clip_rect.xy + c_half;
        let d_clip = sd_rounded_box(in.local_pos - c_center, c_half, cr);
        clip_cov = 1.0 - smoothstep(-aa, aa, d_clip);
        if (clip_cov <= 0.001) {
            discard;
        }
    }

    let kind = prim.kind_flags.x;
    let half_size = prim.bounds.zw * 0.5;
    let center = prim.bounds.xy + half_size;
    let rel_p = in.local_pos - center;

    // Kind 1: Coverage mask glyph or monochrome vector icon with perceptual-to-linear stem calibration.
    if (kind == 1u) {
        let raw_a = clamp(textureSampleLevel(mask_atlas, linear_sampler, in.uv, 0.0).a, 0.0, 1.0);
        let is_icon = (prim.kind_flags.y & 2u) != 0u;
        var gamma = 0.88;
        if (!is_icon) {
            let fg_lum = clamp(dot(prim.fill_color.rgb, vec3<f32>(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
            gamma = mix(0.70, 1.08, fg_lum);
        }
        let mask_a = pow(raw_a, gamma);
        let out_c = vec4<f32>(prim.fill_color.rgb, prim.fill_color.a * mask_a * clip_cov);
        return premultiply(out_c);
    }

    // Kind 2: Color bitmap (emoji, harness logo, inline chat image) with optional rounded corners.
    if (kind == 2u) {
        let tex = textureSampleLevel(color_atlas, linear_sampler, in.uv, 0.0);
        let d = sd_rounded_box(rel_p, half_size, prim.corners);
        let corner_mask = (1.0 - smoothstep(-aa, aa, d)) * clip_cov;
        let is_premul = (prim.kind_flags.y & 1u) != 0u;
        if (is_premul) {
            let scale = prim.fill_color.a * corner_mask;
            return vec4<f32>(tex.rgb * prim.fill_color.rgb * scale, tex.a * scale);
        }
        let out_c = vec4<f32>(tex.rgb * prim.fill_color.rgb, tex.a * prim.fill_color.a * corner_mask);
        return premultiply(out_c);
    }

    // Kind 0: Rounded rectangle with optional soft shadow, fill, and crisp border.
    let d_outer = sd_rounded_box(rel_p, half_size, prim.corners);
    let outer_cov = 1.0 - smoothstep(-aa, aa, d_outer);

    var accum = vec4<f32>(0.0, 0.0, 0.0, 0.0);
    let blur = prim.params.y;
    if (blur > 0.0 && prim.shadow_color.a > 0.0) {
        let shadow_p = rel_p - prim.params.zw;
        let d_shadow = sd_rounded_box(shadow_p, half_size, prim.corners);
        let sigma = max(blur * 0.5, 0.5);
        let t = clamp(0.5 - 0.5 * (d_shadow / (sigma * 2.0)), 0.0, 1.0);
        let shadow_a = t * t * (3.0 - 2.0 * t);
        accum = premultiply(vec4<f32>(prim.shadow_color.rgb, prim.shadow_color.a * shadow_a));
    }

    let border_w = prim.params.x;
    if (border_w > 0.0 && prim.border_color.a > 0.0) {
        let ring_t = smoothstep(-aa, aa, d_outer + border_w);
        let base_pm = premultiply(prim.fill_color);
        let stroke_pm = premultiply(vec4<f32>(prim.border_color.rgb, prim.border_color.a * ring_t));
        let shape_pm = over_premul(stroke_pm, base_pm) * outer_cov;
        accum = over_premul(shape_pm, accum);
    } else {
        let fill_pm = premultiply(vec4<f32>(prim.fill_color.rgb, prim.fill_color.a * outer_cov));
        accum = over_premul(fill_pm, accum);
    }

    return accum * clip_cov;
}
