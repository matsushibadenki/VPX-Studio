#include <metal_stdlib>
using namespace metal;

struct VideoParameters { float4 distortion; float4 intrinsics; float4 options; float4 range; float4 matrix; };
float3 decodeSDR(float3 c, uint transfer) {
    c = max(c, 0.0);
    if (transfer == 1) return select(pow((c+0.055)/1.055,float3(2.4)), c/12.92, c <= 0.04045);
    if (transfer == 2) return select(pow((c+0.099)/1.099,float3(1.0/0.45)), c/4.5, c < 0.081);
    return c;
}
float2 cameraSampleUV(float2 uv, constant VideoParameters& p) {
    float2 xy = (uv-p.intrinsics.xy)/p.intrinsics.zw;
    float r2 = dot(xy,xy);
    float radial = 1 + p.distortion.x*r2 + p.distortion.y*r2*r2 + p.distortion.z*r2*r2*r2;
    float p1=p.distortion.w, p2=p.options.x;
    float2 distorted = xy*radial + float2(2*p1*xy.x*xy.y+p2*(r2+2*xy.x*xy.x), p1*(r2+2*xy.y*xy.y)+2*p2*xy.x*xy.y);
    return p.intrinsics.xy + distorted*p.intrinsics.zw;
}

kernel void normalizeCamera(texture2d<float,access::sample> first [[texture(0)]],
    texture2d<float,access::sample> chroma [[texture(1)]], texture2d<float,access::write> output [[texture(2)]],
    constant VideoParameters& p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    float2 uv = (float2(gid)+0.5)/float2(output.get_width(),output.get_height());
    float2 sampleUV = cameraSampleUV(uv, p);
    bool leftHalf = uv.x < 0.5;
    // Lens comparison isolates the geometry while preserving identical color conversion.
    if (p.matrix.w == 1 && leftHalf) sampleUV = uv;
    float3 rgb = first.sample(s,sampleUV).rgb;
    if (p.options.w > 0.5) {
        float y = (rgb.r*p.matrix.z-p.range.x)*p.range.y;
        float2 cbcr = (chroma.sample(s,sampleUV).rg*p.matrix.z-p.range.z)*p.range.w;
        float kr=p.matrix.x, kb=p.matrix.y, kg=1-kr-kb;
        rgb = float3(y+2*(1-kr)*cbcr.y,
            y-2*kb*(1-kb)/kg*cbcr.x-2*kr*(1-kr)/kg*cbcr.y, y+2*(1-kb)*cbcr.x);
    }
    bool inBounds = all(sampleUV >= 0.0) && all(sampleUV <= 1.0);
    // Present the input RGB code values on the left of the color comparison
    // by compensating for the preview's sRGB output transfer.
    uint transfer = p.matrix.w == 2 && leftHalf ? 1 : uint(p.options.y);
    output.write(float4(decodeSDR(rgb,transfer), p.options.z*(inBounds ? 1.0 : 0.0)),gid);
}
float chromaAlpha(float3 rgb, float4 key) {
    float dominance = rgb.g - max(rgb.r, rgb.b);
    return 1.0 - smoothstep(key.y, key.y + max(key.z, 0.001), dominance);
}

float reliableDepth(uint2 pixel, uint2 imageSize, constant VideoParameters& p,
    texture2d<float,access::read> depth, texture2d<uint,access::read> confidence, thread bool& lowConfidence) {
    float2 uv = cameraSampleUV((float2(pixel)+0.5)/float2(imageSize), p);
    if (!all(isfinite(uv)) || any(uv < 0.0) || any(uv > 1.0)) return 0.0;
    uint2 size = uint2(depth.get_width(), depth.get_height());
    uint2 point = min(uint2(uv*float2(size)), size-1);
    float meters = depth.read(point).r;
    if (!isfinite(meters) || meters <= 0.0) return 0.0;
    lowConfidence = confidence.read(point).r != 2;
    return lowConfidence ? 0.0 : meters;
}

float reliableDepth(uint2 pixel, uint2 imageSize, constant VideoParameters& p,
    texture2d<float,access::read> depth, texture2d<uint,access::read> confidence) {
    bool lowConfidence = false;
    return reliableDepth(pixel, imageSize, p, depth, confidence, lowConfidence);
}

int confidentPersonClass(uint2 pixel, uint2 imageSize, constant VideoParameters& p,
    texture2d<float,access::read> mask) {
    float2 uv = cameraSampleUV((float2(pixel)+0.5)/float2(imageSize), p);
    if (!all(isfinite(uv)) || any(uv < 0.0) || any(uv > 1.0)) return -1;
    uint2 size = uint2(mask.get_width(), mask.get_height());
    float score = mask.read(min(uint2(uv*float2(size)), size-1)).r;
    return score >= 0.95 ? 1 : score <= 0.05 ? 0 : -1;
}

float rgbDistance(float3 a, float3 b) {
    float3 delta = abs(a-b);
    return max(delta.r, max(delta.g, delta.b));
}

// Match a small cross around a fractional edge. Reject border, invalid, and ambiguous patches.
int2 previousMattePosition(int2 pixel, texture2d<float,access::read> video,
    texture2d<float,access::read> previousVideo, constant float4& key) {
    int2 size = int2(video.get_width(), video.get_height());
    if (any(pixel < 2) || any(pixel >= size-2)) return pixel;
    constexpr int2 taps[] = {int2(0,0), int2(-1,0), int2(1,0), int2(0,-1), int2(0,1)};
    float3 current[5];
    for (uint i = 0; i < 5; ++i) {
        float4 color = video.read(uint2(pixel+taps[i]));
        if (color.a <= 0.0) return pixel;
        current[i] = color.rgb;
    }

    float best = 1.0, second = 1.0, stationary = 1.0;
    int2 match = pixel;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            int2 candidate = pixel+int2(x,y);
            float error = 0.0;
            for (uint i = 0; i < 5; ++i) {
                float4 prior = previousVideo.read(uint2(candidate+taps[i]));
                if (prior.a <= 0.0) { error = 5.0; break; }
                error += rgbDistance(current[i], prior.rgb);
            }
            error *= 0.2;
            if (x == 0 && y == 0) stationary = error;
            if (error < best) {
                second = best;
                best = error;
                match = candidate;
            } else {
                second = min(second, error);
            }
        }
    }
    if (best > 0.035 || second-best < 0.012 || stationary-best < 0.015) return pixel;
    float previousAlpha = chromaAlpha(previousVideo.read(uint2(match)).rgb, key);
    return previousAlpha > 0.0 && previousAlpha < 1.0 ? match : pixel;
}

kernel void buildMatte(texture2d<float,access::read> video [[texture(0)]],
    texture2d<float,access::write> matte [[texture(1)]],
    texture2d<float,access::read> previousVideo [[texture(2)]],
    texture2d<float,access::read> previousMatte [[texture(3)]],
    texture2d<float,access::write> trimap [[texture(4)]],
    texture2d<float,access::read> depth [[texture(5)]], texture2d<uint,access::read> confidence [[texture(6)]],
    texture2d<float,access::read> personMask [[texture(7)]],
    constant float4& key [[buffer(0)]], constant float4& temporal [[buffer(1)]],
    constant VideoParameters& videoParams [[buffer(2)]], constant uint& guidance [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= matte.get_width() || gid.y >= matte.get_height()) return;
    float4 color=video.read(gid);
    float base = color.a > 0.0 ? (key.x > 0.5 ? chromaAlpha(color.rgb, key) : 1.0) : 0.0;
    bool boundary = base > 0.0 && base < 1.0;
    if (key.w > 0.5) trimap.write(float4(boundary ? 0.5 : base), gid);
    float alpha = base;
    if (boundary && temporal.w > 1.5) {
        // Drawing the same captured frame again must not advance the filter.
        alpha = previousMatte.read(gid).r;
    } else if (boundary) {
        constexpr int2 offsets[] = {int2(-1,0), int2(1,0), int2(0,-1), int2(0,1)};
        int2 last = int2(video.get_width(), video.get_height()) - 1;
        uint2 imageSize = uint2(video.get_width(), video.get_height());
        // Lens comparison deliberately splits input geometry and bypasses depth guidance.
        float centerDepth = (guidance & 1) && videoParams.matrix.w != 1
            ? reliableDepth(gid, imageSize, videoParams, depth, confidence) : 0.0;
        int person = (guidance & 2) ? confidentPersonClass(gid, imageSize, videoParams, personMask) : -1;
        float sum = 0.0, total = 0.0, guidedSum = 0.0, guidedTotal = 0.0;
        bool foundReliableNeighbor = false;
        for (uint i = 0; i < 4; ++i) {
            int2 point = int2(gid) + offsets[i];
            if (any(point < 0) || any(point > last)) continue;
            float4 neighbor = video.read(uint2(point));
            float candidate = chromaAlpha(neighbor.rgb, key);
            if (neighbor.a <= 0.0 || candidate <= 0.0 || candidate >= 1.0) continue;
            float3 difference = abs(neighbor.rgb - color.rgb);
            float colorDistance = max(difference.r, max(difference.g, difference.b));
            float weight = (1.0 - smoothstep(0.03, 0.10, colorDistance))
                         * (1.0 - smoothstep(0.10, 0.30, abs(candidate - base)));
            if (person >= 0 && weight > 0.0) {
                int neighborPerson = confidentPersonClass(uint2(point), imageSize, videoParams, personMask);
                if (neighborPerson >= 0 && neighborPerson != person) weight = 0.0;
            }
            sum += candidate * weight;
            total += weight;
            if (centerDepth > 0.0 && weight > 0.0) {
                float neighborDepth = reliableDepth(uint2(point), imageSize, videoParams, depth, confidence);
                if (neighborDepth > 0.0) {
                    foundReliableNeighbor = true;
                    float tolerance = max(0.03, centerDepth*0.02);
                    float guidedWeight = weight * (1.0-smoothstep(tolerance, 2.0*tolerance, abs(centerDepth-neighborDepth)));
                    guidedSum += candidate * guidedWeight;
                    guidedTotal += guidedWeight;
                }
            }
        }
        if (foundReliableNeighbor) {
            sum = guidedSum;
            total = guidedTotal;
        }
        // Keep a dominant contribution from the current pixel, including fine fractional alpha.
        alpha = mix(base, (base + sum) / (1.0 + total), 0.35);
    }
    if (boundary && temporal.w > 0.5 && temporal.w <= 1.5 && alpha > 0.05 && alpha < 0.95) {
        float4 stationary = previousVideo.read(gid);
        int2 match = int2(gid);
        // Preserve the original inexpensive filter for stable pixels.
        if (stationary.a <= 0.0 || rgbDistance(color.rgb, stationary.rgb) > 0.04) {
            match = previousMattePosition(int2(gid), video, previousVideo, key);
        }
        float4 previous = previousVideo.read(uint2(match));
        float previousBase = chromaAlpha(previous.rgb, key);
        float3 difference=abs(color.rgb-previous.rgb);
        float change=max(difference.r,max(difference.g,difference.b));
        float prior=previousMatte.read(uint2(match)).r;
        float confidence=(1-smoothstep(0.04,temporal.y,change))*(1-smoothstep(0.1,temporal.z,abs(alpha-prior)));
        if (previous.a > 0.0 && previousBase > 0.0 && previousBase < 1.0 && prior > 0.0 && prior < 1.0) {
            float motionScale = all(match == int2(gid)) ? 1.0 : 0.65;
            alpha=mix(alpha,prior,clamp(temporal.x,0.0,0.8)*confidence*motionScale);
        }
    }
    matte.write(float4(alpha),gid);
}
struct SceneVertex { float4 position; float4 normal; };
struct SceneParameters { float4x4 viewProjection; float4x4 lightProjection; float4 camera; float4 lightDirection; float4 radiance; };
struct MaterialParameters { float4 baseColor; float4 factors; };
struct MeshOutput { float4 position [[position]]; float3 world; float3 normal; float4 shadow; };
vertex MeshOutput studioMeshVertex(uint id [[vertex_id]], device const SceneVertex* vertices [[buffer(0)]], constant SceneParameters& u [[buffer(1)]]) {
    MeshOutput v;
    v.position=u.viewProjection*vertices[id].position;
    v.world=vertices[id].position.xyz;
    v.normal=vertices[id].normal.xyz;
    v.shadow=u.lightProjection*vertices[id].position;
    return v;
}
vertex float4 studioShadowVertex(uint id [[vertex_id]], device const SceneVertex* vertices [[buffer(0)]], constant SceneParameters& u [[buffer(1)]]) {
    return u.lightProjection*vertices[id].position;
}
fragment float4 studioPBR(MeshOutput in [[stage_in]], constant SceneParameters& u [[buffer(0)]],
    constant MaterialParameters& m [[buffer(1)]], depth2d<float> shadow [[texture(0)]]) {
    constexpr sampler comparison(filter::linear,compare_func::less_equal,address::clamp_to_edge);
    float3 N=normalize(in.normal), L=normalize(u.lightDirection.xyz), V=normalize(u.camera.xyz-in.world), H=normalize(L+V);
    float nl=max(dot(N,L),0.0), nv=max(dot(N,V),0.001), nh=max(dot(N,H),0.0), vh=max(dot(V,H),0.0);
    float rough=clamp(m.factors.y,0.045,1.0), metal=clamp(m.factors.x,0.0,1.0);
    float a2=pow(rough,4.0), denominator=nh*nh*(a2-1)+1;
    float D=a2/(M_PI_F*denominator*denominator+0.0001);
    float k=pow(rough+1,2.0)/8;
    float G=(nv/(nv*(1-k)+k))*(nl/(nl*(1-k)+k));
    float3 F0=mix(float3(0.04),m.baseColor.rgb,metal);
    float3 F=F0+(1-F0)*pow(1-vh,5.0);
    float3 specular=D*G*F/(4*nv*max(nl,0.001)+0.0001);
    float3 diffuse=(1-F)*(1-metal)*m.baseColor.rgb/M_PI_F;
    float3 coord=in.shadow.xyz/in.shadow.w;
    float2 uv=coord.xy*float2(0.5,-0.5)+0.5;
    float visibility=1;
    if (all(uv >= 0.0) && all(uv <= 1.0) && coord.z >= 0 && coord.z <= 1)
        visibility=shadow.sample_compare(comparison,uv,coord.z-max(0.0005,0.002*(1-nl)));
    float3 color=(diffuse+specular)*u.radiance.rgb*nl*visibility + m.baseColor.rgb*0.035;
    return float4(color,1);
}
struct QuadOutput { float4 position [[position]]; float2 uv; };
vertex QuadOutput studioQuad(uint id [[vertex_id]]) {
    constexpr float2 p[]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    return {float4(p[id],0,1),p[id]*float2(0.5,-0.5)+0.5};
}
fragment float4 studioComposite(QuadOutput in [[stage_in]], texture2d<float> scene [[texture(0)]],
    texture2d<float> video [[texture(1)]], texture2d<float> matte [[texture(2)]],
    texture2d<float,access::read> depth [[texture(3)]], texture2d<uint,access::read> confidence [[texture(4)]],
    texture3d<float> lut [[texture(5)]], texture2d<float> trimap [[texture(6)]], constant float4& options [[buffer(0)]],
    constant float4& depthParameters [[buffer(1)]], constant float4& lutMin [[buffer(2)]],
    constant float4& lutMax [[buffer(3)]], depth2d<float> sceneDepth [[texture(7)]],
    texture2d<float,access::read> liveDepth [[texture(8)]], texture2d<uint,access::read> liveConfidence [[texture(9)]],
    constant VideoParameters& videoParams [[buffer(4)]], constant float2& projectionDepth [[buffer(5)]], device atomic_uint* occlusionFlags [[buffer(6)]]) {
    constexpr sampler s(filter::linear,address::clamp_to_edge);
    if (options.x == 4 || options.x == 5) {
        if (options.w < 0.5) return float4(0.015,0.015,0.015,1);
        float2 uv=in.uv;
        float rawAspect=float(depth.get_width())/float(depth.get_height());
        float targetAspect=depthParameters.y;
        if (rawAspect > targetAspect) uv.y=(uv.y-0.5)*(rawAspect/targetAspect)+0.5;
        else uv.x=(uv.x-0.5)*(targetAspect/rawAspect)+0.5;
        if (any(uv < 0.0) || any(uv > 1.0)) return float4(0,0,0,1);
        uint2 point=min(uint2(uv*float2(depth.get_width(),depth.get_height())),uint2(depth.get_width()-1,depth.get_height()-1));
        uint c=confidence.read(point).r;
        if (options.x == 5) return float4(c == 2 ? float3(0,1,0) : c == 1 ? float3(1,0.65,0) : float3(1,0,0),1);
        float meters=depth.read(point).r;
        if (!isfinite(meters) || meters <= 0 || c == 0) return float4(0,0,0,1);
        float t=clamp(meters/depthParameters.x,0.0,1.0);
        float3 color=float3(1-t,0.25+0.5*(1-abs(2*t-1)),t);
        return float4(color*(c == 2 ? 1.0 : 0.5),1);
    }
    if (options.y > 0.5) return float4(0.025,0.008,0.012,1);
    float3 background=scene.sample(s,in.uv).rgb;
    float3 foreground=video.sample(s,in.uv).rgb;
    float alpha=matte.sample(s,in.uv).r;
    if (options.x == 1) return float4(clamp(background,0.0,1.0),1);
    if (options.x == 2) return float4(clamp(foreground,0.0,1.0),1);
    if (options.x == 3) return float4(float3(alpha),1);
    if (options.x == 9) {
        constexpr sampler nearest(filter::nearest,address::clamp_to_edge);
        return float4(float3(trimap.sample(nearest,in.uv).r),1);
    }
    if (options.x == 6 || options.x == 7) {
        float valid = video.sample(s,in.uv).a;
        return float4(clamp(foreground,0.0,1.0)*valid,1);
    }
    foreground.g=mix(foreground.g,min(foreground.g,max(foreground.r,foreground.b)),(1-alpha)*options.z);
    if (depthParameters.w > 0.5 && alpha > 0.0) {
        constexpr sampler nearest(filter::nearest,address::clamp_to_edge);
        float z = sceneDepth.sample(nearest,in.uv);
        if (z >= 0.0 && z < 1.0) {
            // Invert the projection depth to positive axial distance in meters.
            float cgMeters = projectionDepth.y / (z + projectionDepth.x);
            uint2 imageSize = uint2(video.get_width(), video.get_height());
            uint2 pixel = min(uint2(in.uv*float2(imageSize)), imageSize-1);
            bool lowConfidence = false;
            float liveMeters = reliableDepth(pixel, imageSize, videoParams, liveDepth, liveConfidence, lowConfidence);
            // Preserve the keyed composite where the depth order is uncertain.
            bool applied = liveMeters > 0.0 && isfinite(cgMeters) && cgMeters > 0.0 &&
                liveMeters-cgMeters > max(0.03, liveMeters*0.02);
            if (applied) alpha = 0.0;
            // The recorder crops odd dimensions; ignore pixels outside the saved area.
            if (depthParameters.w > 1.5 && all(pixel < (imageSize & ~1u))) {
                uint flag = applied ? 1u : lowConfidence ? 4u : liveMeters <= 0.0 ? 2u : 0u;
                if (flag && !(atomic_load_explicit(occlusionFlags, memory_order_relaxed) & flag)) {
                    atomic_fetch_or_explicit(occlusionFlags, flag, memory_order_relaxed);
                }
            }
        }
    }
    // Linear Rec.709/sRGB primaries; the sRGB render target performs the output transfer once.
    float3 composite = foreground*alpha+background*(1-alpha);
    if (depthParameters.z > 0.5) {
        float side = float(lut.get_width());
        float3 coordinate = clamp((composite-lutMin.xyz)/(lutMax.xyz-lutMin.xyz),0.0,1.0);
        composite = lut.sample(s,(coordinate*(side-1.0)+0.5)/side).rgb;
    }
    return float4(clamp(composite,0.0,1.0),1);
}

// A thread writes one 2×2 block to video-range, MSB-aligned 10-bit 4:2:0.
kernel void packCompositeMain10(texture2d<float, access::read> linearRGB [[texture(0)]],
    texture2d<float, access::write> luma [[texture(1)]],
    texture2d<float, access::write> chroma [[texture(2)]], uint2 block [[thread_position_in_grid]]) {
    if (block.x >= chroma.get_width() || block.y >= chroma.get_height()) return;
    constexpr float3 weights = float3(0.2126, 0.7152, 0.0722);
    constexpr float pack = 64.0 / 65535.0;
    float2 uv = float2(0);
    for (uint y = 0; y < 2; ++y) {
        for (uint x = 0; x < 2; ++x) {
            uint2 pixel = block * 2 + uint2(x, y);
            float3 rgb = clamp(linearRGB.read(pixel).rgb, 0.0, 1.0);
            rgb = select(4.5 * rgb, 1.099 * pow(rgb, float3(0.45)) - 0.099, rgb >= 0.018);
            float Y = dot(rgb, weights);
            luma.write(float4(round(64.0 + 876.0 * Y) * pack), pixel);
            uv += float2((rgb.b - Y) / 1.8556, (rgb.r - Y) / 1.5748);
        }
    }
    chroma.write(float4(round(512.0 + 224.0 * uv) * pack, 0, 1), block);
}
