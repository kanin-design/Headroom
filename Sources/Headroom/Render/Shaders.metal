#include <metal_stdlib>
using namespace metal;

// Colours are linear Display P3. Values can pass 1.0 on a display that has the headroom for it.

struct Segment {
    float4 from;        // start angle, end angle, inner radius, outer radius. Angles run clockwise from 12 o'clock.
    float4 to;
    float4 colorFrom;   // alpha fades pieces in and out
    float4 colorTo;
    float4 params;      // style, seed, how far it steps back until pointed at, how much of it goes on past the last ring
    float4 plan;        // planned at the start of the transition, planned at the end
};

struct Uniforms {
    float2 viewport;    // pixels
    float2 center;      // pixels
    float radius;       // pixels
    float t;            // transition progress, may overshoot slightly
    float scale;        // backing scale
    float dim;          // how far pieces without emphasis recede, 0...1
    float liftPixels;   // how far emphasis pushes a piece outward
    float bloom;        // glow strength
    float headroom;     // extra brightness the display allows, 1.0 on SDR
    float ghost;        // share of the disk a cleanup would free
    float freeStart;    // where the free wedge begins
    float hideScale;    // 1 leaves out the scale around the disk
    float restSaturation;   // how much colour a piece keeps until you point at it, 0...1
    float glowAtRest;       // how much glow a piece gives off until you point at it, 0...1
    float previewShare;     // what the thing you're pointing at would add to the free space
    float ghostCount;       // how many colours the new free space has
    float freeOuter;        // how far out the free wedge reaches, as a share of the radius
    float4 previewColor;
    float4 ghostSlices[12]; // each colour, and in w where it ends, as a share of the whole
};

enum Style { StyleNormal = 0, StyleFree = 1, StyleHidden = 2, StyleSmaller = 3, StyleFile = 4, StyleMark = 5 };

struct SegmentOut {
    float4 position [[position]];
    float2 p;                       // pixels from the centre
    float a0 [[flat]];
    float a1 [[flat]];
    float r0 [[flat]];
    float r1 [[flat]];
    float4 color [[flat]];
    float style [[flat]];
    float seed [[flat]];
    float calm [[flat]];
    float deeper [[flat]];
    float emphasis [[flat]];
    float planned [[flat]];
};

static float2 onCircle(float a, float r) { return float2(sin(a), -cos(a)) * r; }

// How far, in points, a folder that goes on past the outermost ring fades out beyond its edge.
constant float tailPoints = 10.0;

vertex SegmentOut segment_vertex(uint vid [[vertex_id]],
                                 uint iid [[instance_id]],
                                 const device Segment *segments [[buffer(0)]],
                                 constant Uniforms &u [[buffer(1)]],
                                 const device float *emphasis [[buffer(2)]]) {
    const Segment s = segments[iid];
    float4 g = mix(s.from, s.to, u.t);
    float e = emphasis[iid];
    float lift = max(e - 1.0, 0.0) * u.liftPixels;
    float a0 = g.x, a1 = g.y;
    float r0 = max(g.z * u.radius, 0.0);
    float r1 = max(g.w * u.radius, r0) + lift;
    // Its fade past the edge, if it goes on, is part of what's drawn.
    float reach = r1 + (s.params.w > 0.0 ? u.scale * tailPoints : 0.0);

    // The smallest box around the arc: its four corners, and the circle's extremes where the arc crosses an axis.
    float2 lo = min(min(onCircle(a0, r0), onCircle(a1, r0)), min(onCircle(a0, reach), onCircle(a1, reach)));
    float2 hi = max(max(onCircle(a0, r0), onCircle(a1, r0)), max(onCircle(a0, reach), onCircle(a1, reach)));
    float quarter = M_PI_2_F;
    int k0 = int(ceil(a0 / quarter)), k1 = int(floor(a1 / quarter));
    for (int k = k0; k <= k1 && k < k0 + 5; k++) {
        float2 c = onCircle(float(k) * quarter, reach);
        lo = min(lo, c);
        hi = max(hi, c);
    }
    const float pad = 2.0;
    lo -= pad; hi += pad;

    float2 corner = float2((vid & 1) ? hi.x : lo.x, (vid & 2) ? hi.y : lo.y);
    float2 pixel = u.center + corner;

    SegmentOut o;
    o.position = float4(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0, 0.0, 1.0);
    o.p = corner;
    o.a0 = a0; o.a1 = a1; o.r0 = r0; o.r1 = r1;
    o.color = mix(s.colorFrom, s.colorTo, saturate(u.t));
    o.style = s.params.x;
    o.seed = s.params.y;
    o.calm = s.params.z;
    o.deeper = s.params.w;
    o.emphasis = e;
    o.planned = mix(s.plan.x, s.plan.y, saturate(u.t));
    return o;
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

struct PieceOut {
    float4 color [[color(0)]];
    float4 glow [[color(1)]];       // what this piece gives off, which the blur spreads into its halo
};

fragment PieceOut segment_fragment(SegmentOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    if (in.color.a <= 0.002) discard_fragment();
    float r = length(in.p);
    float theta = atan2(in.p.x, -in.p.y);
    float mid = (in.a0 + in.a1) * 0.5;
    float halfSweep = max((in.a1 - in.a0) * 0.5, 0.0);
    float delta = theta - mid;
    delta -= 2.0 * M_PI_F * floor(delta / (2.0 * M_PI_F) + 0.5);
    float along = abs(delta);

    float width = in.r1 - in.r0;
    float rm = (in.r0 + in.r1) * 0.5;
    float halfLen = halfSweep * rm;

    // Gaps stay the same on screen at every radius, and give way on the smallest pieces so they don't vanish.
    float gap = in.style == StyleMark ? 0.0 : u.scale * 0.75;
    float radialGap = min(gap, width * 0.22);
    float angularGap = min(gap, halfLen * 0.42);
    float corner = min(min(u.scale * 3.5, (width - 2.0 * radialGap) * 0.42), max(halfLen - angularGap, 0.0) * 0.9);
    corner = max(corner, 0.0);

    float x = (halfSweep >= M_PI_F - 0.0005) ? -1e4 : along * r - (halfSweep * r - angularGap);
    float y = abs(r - rm) - (width * 0.5 - radialGap);
    float2 q = float2(x, y) + corner;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - corner;
    float coverage = saturate(0.5 - d);
    // A folder in the outermost ring that goes on doesn't stop at its edge: it fades out past it, stronger the more of it
    // is in folders. One that ends keeps its clean edge.
    float tail = 0.0;
    if (in.deeper > 0.0) {
        float beyond = r - (in.r1 - radialGap);
        float fade = saturate(1.0 - beyond / (u.scale * tailPoints)) * step(0.0, beyond);
        tail = saturate(0.5 - x) * fade * fade * in.deeper;
    }
    if (coverage <= 0.0 && tail <= 0.0) discard_fragment();

    float e = saturate(in.emphasis);
    float recede = (1.0 - e) * u.dim;
    float radial = saturate((r - in.r0) / max(width, 1.0));
    float3 base = in.color.rgb;
    float3 color;
    float alpha = in.color.a;

    // A broad light from the upper left, so the ring reads as one lit object.
    float2 dir = in.p / max(r, 1.0);
    float lit = dot(dir, normalize(float2(-0.55, -0.83)));

    float edge = 1.0 - saturate(-d / (u.scale * 1.6));
    edge *= edge;

    if (in.style == StyleMark) {
        // A tick outside the ring. What's planned is brighter than what's only suggested.
        color = base * mix(0.46, 1.25, in.planned);
    } else if (in.style == StyleFree) {
        // Free space is an open window: almost nothing inside, with a clean, fine edge.
        float wash = 0.010 + 0.016 * radial * radial;
        color = float3(wash * 0.85, wash * 1.05, wash * 1.3);
        float line = 1.0 - saturate(-d / (u.scale * 0.8));
        color += float3(0.20, 0.25, 0.31) * line * line * (0.75 + 0.25 * e);
        color += float3(0.05, 0.20, 0.15) * e * 0.5;
    } else if (in.style == StyleHidden) {
        // Hidden space is hatched: it's real, but you can't see into it.
        float stripes = smoothstep(0.42, 0.58, fract((in.p.x + in.p.y) / (u.scale * 8.0)));
        color = float3(0.028, 0.030, 0.038) + float3(0.040, 0.044, 0.056) * stripes;
        float line = 1.0 - saturate(-d / (u.scale * 0.8));
        color += float3(0.09, 0.10, 0.125) * line * line;
    } else {
        // Pieces glow toward their outer edge, like petals catching the light, and stay deep at the root.
        float shade = mix(0.40, 1.10, pow(radial, 0.85));
        shade *= 1.0 + 0.16 * lit;
        // A little variation keeps neighbouring pieces distinct, without inventing a meaning.
        shade *= 0.93 + 0.14 * in.seed;
        // The colour drifts very slightly around the ring, so large pieces don't read as flat paint.
        float3 drift = float3(sin(theta * 2.0 + 0.0), sin(theta * 2.0 + 2.1), sin(theta * 2.0 + 4.2));
        color = base * shade * (1.0 + 0.085 * drift);
        // Thin, bright rim on the outer edge, and a faint one all round.
        float outer = saturate(1.0 - (in.r1 - radialGap - r) / (u.scale * 1.1));
        color += (base * 0.55 + float3(0.035)) * outer * outer;
        color += base * 0.10 * edge;
        // Smaller items stay in their wedge's colour, only quieter, so the wedge still reads as one group.
        if (in.style == StyleSmaller) color = mix(color, float3(dot(color, float3(0.3, 0.6, 0.1))), 0.3) * 0.55;
        // At rest, colours sit a step below full, and tiny pieces lower still. Pointing at something brings it all the way up.
        float strength = mix(u.restSaturation * (1.0 - 0.5 * in.calm), 1.0, e);
        color = mix(float3(dot(color, float3(0.3, 0.6, 0.1))), color, strength);
        color *= mix(1.0 - 0.2 * in.calm, 1.0, e);
        // Planned to go: striped and see-through, with a thin bright edge. Solid stays, striped goes.
        if (in.planned > 0.001) {
            float across = fract((in.p.x - in.p.y) / (u.scale * 10.0));
            float stripe = smoothstep(0.0, 0.08, across) * (1.0 - smoothstep(0.5, 0.58, across));
            float3 striped = mix(color * 0.10, color * 1.05, stripe);
            color = mix(color, striped, in.planned);
            float rim = 1.0 - saturate(-d / (u.scale * 1.15));
            color += (base * 0.75 + float3(0.10)) * rim * rim * in.planned;
        }
    }

    // Emphasis lifts a piece; everything else steps back.
    color *= mix(1.0, 0.20, recede);
    float desat = 0.5 * recede;
    color = mix(color, float3(dot(color, float3(0.3, 0.6, 0.1))), desat);
    color *= 1.0 + 0.30 * e * u.dim;

    // Past the edge, the fade carries the colour of the edge outward.
    alpha *= max(coverage, tail * 0.6);
    // Each piece gives off its own glow. Only what you're pointing at, and what's inside it, gets the full amount. The
    // folders it sits in get none of that, and everything else keeps its faint glow, which fades as it dims.
    PieceOut out;
    out.color = float4(color * alpha, alpha);
    out.glow = out.color * mix(u.glowAtRest, 1.0, smoothstep(0.7, 1.0, e));
    return out;
}

// MARK: Light

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut quad_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    QuadOut o;
    o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

constexpr sampler linearClamp(address::clamp_to_zero, filter::linear);

// Dual-filter blur: a wide, soft glow from very few samples.
fragment float4 blur_down(QuadOut in [[stage_in]], texture2d<float> source [[texture(0)]], constant float2 &texel [[buffer(0)]]) {
    float2 uv = in.uv, h = texel;
    float4 c = source.sample(linearClamp, uv) * 4.0;
    c += source.sample(linearClamp, uv - h);
    c += source.sample(linearClamp, uv + h);
    c += source.sample(linearClamp, uv + float2(h.x, -h.y));
    c += source.sample(linearClamp, uv - float2(h.x, -h.y));
    return c / 8.0;
}

fragment float4 blur_up(QuadOut in [[stage_in]], texture2d<float> source [[texture(0)]], constant float2 &texel [[buffer(0)]]) {
    float2 uv = in.uv, h = texel;
    float4 c = source.sample(linearClamp, uv + float2(-h.x * 2.0, 0.0));
    c += source.sample(linearClamp, uv + float2(-h.x, h.y)) * 2.0;
    c += source.sample(linearClamp, uv + float2(0.0, h.y * 2.0));
    c += source.sample(linearClamp, uv + float2(h.x, h.y)) * 2.0;
    c += source.sample(linearClamp, uv + float2(h.x * 2.0, 0.0));
    c += source.sample(linearClamp, uv + float2(h.x, -h.y)) * 2.0;
    c += source.sample(linearClamp, uv + float2(0.0, -h.y * 2.0));
    c += source.sample(linearClamp, uv + float2(-h.x, -h.y)) * 2.0;
    return c / 12.0;
}

fragment float4 composite(QuadOut in [[stage_in]],
                          texture2d<float> pieces [[texture(0)]],
                          texture2d<float> glow [[texture(1)]],
                          texture2d<float> wide [[texture(2)]],
                          constant Uniforms &u [[buffer(1)]]) {
    float2 pixel = in.uv * u.viewport;
    float2 fromCenter = pixel - u.center;
    float dist = length(fromCenter) / max(u.radius, 1.0);

    // Near-black with the faintest cool lift, so the glow has something to fall on.
    float3 background = float3(0.0024, 0.0026, 0.0040);
    background += float3(0.0016, 0.0018, 0.0034) * exp(-dist * dist * 0.5);

    float4 p = pieces.sample(linearClamp, in.uv);
    float3 near = glow.sample(linearClamp, in.uv).rgb;
    float3 far = wide.sample(linearClamp, in.uv).rgb;

    float3 color = background + near * u.bloom * 0.13 + far * u.bloom * 0.17;

    // A fine scale around the disk: a mark for every 1%, a longer one for every 10%.
    float scalePx = u.scale;
    float rPx = length(fromCenter);
    float a = atan2(fromCenter.x, -fromCenter.y);
    float steps = 100.0;
    float cell = (a / (2.0 * M_PI_F) + 1.0) * steps;
    float toMark = abs(fract(cell + 0.5) - 0.5) / steps * 2.0 * M_PI_F * rPx;
    float isMajor = step(abs(fract(cell / 10.0 + 0.5 / 10.0) - 0.5 / 10.0) * 10.0, 0.5);
    float base = u.radius + 9.0 * scalePx;
    float length0 = mix(3.0, 8.0, isMajor) * scalePx;
    float inBand = smoothstep(base - 0.5, base + 0.5, rPx) * (1.0 - smoothstep(base + length0 - 0.5, base + length0 + 0.5, rPx));
    float tick = inBand * (1.0 - smoothstep(0.35 * scalePx, 0.35 * scalePx + 1.0, toMark));
    color += float3(0.16, 0.17, 0.20) * tick * mix(0.22, 0.60, isMajor) * (1.0 - u.hideScale);

    color = color * (1.0 - p.a) + p.rgb;

    // What a cleanup would free, previewed as the free wedge growing back over what's there now, in the colours of what's going.
    if (u.ghost > 0.0005 || u.previewShare > 0.0005) {
        float full = 2.0 * M_PI_F;
        float sweep = u.ghost * full;
        float back = u.freeStart - a;
        back -= full * floor(back / full);
        float arc = back * rPx;
        float inner = 0.34 * u.radius, outer = u.freeOuter * u.radius;
        float rad = max(inner - rPx, rPx - outer);
        if (u.ghost > 0.0005) {
            float along = max(-arc, arc - sweep * rPx);
            float d = max(rad, along);
            float inside = saturate(0.5 - d);
            float rim = inside * (1.0 - saturate(-d / (scalePx * 1.1)));
            float where = back / max(sweep, 0.0001);
            float3 tint = float3(0.16, 0.95, 0.56);
            float seam = 1e4;
            int count = int(u.ghostCount);
            bool found = false;
            for (int i = 0; i < count; i++) {
                float end = u.ghostSlices[i].w;
                if (!found && where <= end) {
                    tint = u.ghostSlices[i].rgb;
                    found = true;
                }
                if (i < count - 1) seam = min(seam, abs(where - end) * sweep * rPx);
            }
            float radial = saturate((rPx - inner) / max(outer - inner, 1.0));
            color = mix(color, color * 0.22 + tint * mix(0.16, 0.38, radial), inside);
            color += tint * rim * rim * 0.8;
            color *= mix(1.0, 0.4, inside * (1.0 - smoothstep(0.4 * scalePx, 1.1 * scalePx, seam)));
        }
        if (u.previewShare > 0.0005) {
            float wide = sweep + u.previewShare * full;
            float along = max(sweep * rPx - arc, arc - wide * rPx);
            float d = max(rad, along);
            float inside = saturate(0.5 - d);
            float rim = inside * (1.0 - saturate(-d / (scalePx * 1.0)));
            float dash = step(0.5, fract((arc + rPx) / (scalePx * 9.0)));
            float3 tint = u.previewColor.rgb;
            color = mix(color, color * 0.45 + tint * 0.13, inside);
            color += tint * rim * rim * 0.9 * dash;
        }
    }

    // The hole in the middle sits a little deeper than the page.
    float hole = smoothstep(0.40, 0.0, dist);
    color *= 1.0 - 0.35 * hole;

    // Corners fall away, so the eye stays on the ring.
    float2 edge = (in.uv - 0.5) * 2.0;
    float vignette = 1.0 - 0.34 * smoothstep(0.55, 1.5, length(edge));
    color *= vignette;

    // A soft shoulder near full brightness, higher where the display can go higher.
    float top = max(u.headroom, 1.0);
    color = color / (1.0 + max(color - 0.85, 0.0) * (1.0 / top));

    // One pixel of noise removes banding from the dark gradients.
    float n = hash21(pixel) - 0.5;
    color += n * (0.0018 + 0.004 * sqrt(max(dot(color, float3(0.33)), 0.0)));
    return float4(max(color, 0.0), 1.0);
}
