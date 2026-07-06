// Spectral film simulation, inspired by vkdt itself a port of agx-emulsion
// As a derivative work of GPL-v3 code, I suppose this file is GPL-v3.
// rec2020 -> expose -> DIR -> develop -> print -> 'scan'

// if you are interested in this, see Yedlin's Display Prep Demo & FAQ

#include <metal_stdlib>
using namespace metal;

struct FilmSimParams {
    int   process;          // 0 = expose + print on paper, 1 = expose + scan negative/slide
    int   film;             // film stock row (0 ..< paperOffset)
    int   paper;            // print paper, relative index (paper_offset added here)
    int   paper_offset;     // first paper's stock row == film count
    float ev_film;          // film exposure compensation (stops)
    float gamma_film;       // film characteristic-curve gamma (dynamic range)
    float ev_paper;         // print exposure compensation (stops)
    float gamma_paper;      // paper characteristic-curve gamma (contrast)
    float couplers;         // DIR coupler amount (saturation / interlayer effect)
    float filter_c;         // enlarger cyan / magenta / yellow neutral filters
    float filter_m;
    float filter_y;
    float tune_m;           // magenta fine tune (green/magenta tint)
    float tune_y;           // yellow fine tune (warm/cool)
    int   grain;            // grain on/off
    float grain_size;       // grain size scale
    float grain_uniformity; // 1 = perfectly uniform
    int   preflash;         // paper pre-flashing on/off
    float pf_ev;            // pre-flash exposure
    float pf_m;             // pre-flash magenta / yellow offsets
    float pf_y;
    int   halation;         // 1 → the develop pass emits linear exposure for the halation blur
    float halation_scale;   // halo amount (0 disables)
    float halation_midtones;// highlight protection (0 = all tones, 1 = brightest only)
    float halation_r;       // per-channel halo strength
    float halation_g;       // the stock's anti-halation class (see FilmDefaults)
    float halation_b;
    int   couplers_diffused;// 1 → the develop pass reads a spatially-diffused coupler input
    float grain_amount;     // grain post-scale (1 = physical amplitude)
    float grain_saturation; // 1 = independent RGB, 0 = fully coupled monochrome grain
    uint  seed;             // grain seed (deterministic per render)
};

/// Per-dispatch tile payload
struct FilmSimTile {
    int2  origin;
    float scale;
    float pad;
};

// Precomputed spectral integration inputs
constant int SN = 41;
struct FilmTables {
    float4 expose_factor[41];   // film sensitivity · envelope / pdf
    float4 enlarger_dye[41];    // film CMY dye density (log2), for print modulation
    float4 enlarger_factor[41]; // paper sensitivity · print illuminant
    float4 scan_dye[41];        // scanned-stock CMY dye density (log2)
    float4 scan_factor[41];     // scan illuminant · CMF · base transmittance
    float4 preflash;            // integrated pre-flash light (paper)
    float4 M0, M1, M2;          // DIR coupler matrix rows
    float4 M_sum;               // M · (1,1,1)
};

// filmsim.lut
constant int s_sensitivity   = 0;
constant int s_dye_density    = 1;
constant int s_density_curve  = 2;
constant float dye_density_min_factor_film  = 1.0;
constant float dye_density_min_factor_paper = 0.4;
constant float log2_10 = 3.32192809489;      // log2(10): log10 density → log2
constant float log10_2 = 0.30102999566398114; // log10(2): log2 → log10

// matrices.h (D65)
inline float3 rec709_to_rec2020(float3 c) {
    return float3x3(float3(0.62750375, 0.06910828, 0.01639406),
                    float3(0.32927542, 0.91951916, 0.08801125),
                    float3(0.04330266, 0.0113596,  0.89538035)) * c;
}
inline float3 rec2020_to_rec709(float3 c) {
    return float3x3(float3(1.66022677, -0.12455334, -0.01815514),
                    float3(-0.58754761, 1.13292605, -0.10060303),
                    float3(-0.07283825, -0.00834963, 1.11899817)) * c;
}
inline float3 rec2020_to_xyz(float3 c) {
    return float3x3(float3(0.636958048301290991, 0.26270021201126692, 4.9999999999999999e-17),
                    float3(0.144616903586208406, 0.677998071518871148, 0.0280726930490874452),
                    float3(0.168880975164172054, 0.0593017164698619384, 1.06098505771079066)) * c;
}
inline float3 xyz_to_rec2020(float3 c) {
    return float3x3(float3(1.71665119, -0.66668435, 0.01763986),
                    float3(-0.35567078, 1.61648124, -0.04277061),
                    float3(-0.25336628, 0.01576855, 0.94210312)) * c;
}

// Analytic CIE 1931 colour-matching functions (Wyman/Sloan/Shirley), rt/colour.glsl.
inline float3 cmf_1931(float w) {
    float t1 = (w - 442.0) * (w < 442.0 ? 0.0624 : 0.0374);
    float t2 = (w - 599.8) * (w < 599.8 ? 0.0264 : 0.0323);
    float t3 = (w - 501.1) * (w < 501.1 ? 0.0490 : 0.0382);
    float X = 0.362 * exp(-0.5 * t1 * t1) + 1.056 * exp(-0.5 * t2 * t2) - 0.065 * exp(-0.5 * t3 * t3);
    float u1 = (w - 568.8) * (w < 568.8 ? 0.0213 : 0.0247);
    float u2 = (w - 530.9) * (w < 530.9 ? 0.0613 : 0.0322);
    float Y = 0.821 * exp(-0.5 * u1 * u1) + 0.286 * exp(-0.5 * u2 * u2);
    float v1 = (w - 437.0) * (w < 437.0 ? 0.0845 : 0.0278);
    float v2 = (w - 459.0) * (w < 459.0 ? 0.0385 : 0.0725);
    float Z = 1.217 * exp(-0.5 * v1 * v1) + 0.681 * exp(-0.5 * v2 * v2);
    return float3(X, Y, Z);
}

// Planck blackbody spectral radiance, scaled to ~1 at 6500 K (rt/colour.glsl).
inline float colour_blackbody(float lambda, float T) {
    const float h2 = 6.62606957e+11, h = 6.62606957e-34, c = 299792458.0, k = 1.3807e-23;
    float lambda_m = lambda * 1e-9;
    float l2 = lambda * lambda;
    float l5 = l2 * lambda * l2;
    float c1 = 2.0 * h2 * c * c / l5;
    float c2 = h * c / (lambda_m * T * k);
    return 1e-14 * c1 / (exp(c2) - 1.0);
}

// Jakob-style sigmoid emission upsampling, shared/upsample.glsl.
inline float2 tri2quad(float2 tc) {
    float y = tc.y / (1.0 - tc.x);
    float x = (1.0 - tc.x) * (1.0 - tc.x);
    return float2(x, y);
}
inline float4 fetch_coeff(float3 rgb, texture2d<float, access::read> img_coeff) {
    float3 xyz = rec2020_to_xyz(rgb);
    float b = xyz.x + xyz.y + xyz.z;
    float2 tc = tri2quad(xyz.xy / b);
    int2 sz = int2(img_coeff.get_width(), img_coeff.get_height());
    int2 tci = clamp(int2(tc * float2(sz) + 0.5), int2(0), sz - 1);
    float4 coeff = img_coeff.read(uint2(tci));
    coeff.w = b / coeff.w;
    return coeff;
}
inline float sigmoid_eval(float4 coeff, float lambda) {
    float x = (coeff.x * lambda + coeff.y) * lambda + coeff.z;
    float y = rsqrt(x * x + 1.0);
    return (0.5 * x * y + 0.5) * coeff.w;
}

// agx-emulsion contrast sigmoid and its derivative
inline float3 sigmoid(float3 x) {
    float3 ax = abs(x);
    float3 xb = ax * ax * ax * ax * sqrt(ax);
    return 0.5 + 0.5 * x * exp2(-0.2222222222222222 * log2(xb + 1.0));
}
inline void sigmoid_both(float3 x, thread float3 &sig, thread float3 &sig_d) {
    float3 ax = abs(x);
    float3 xb = ax * ax * ax * ax * sqrt(ax);
    float3 base = xb + 1.0;
    float3 rcp = exp2(-0.2222222222222222 * log2(base));
    sig = 0.5 + 0.5 * x * rcp;
    sig_d = 0.5 * rcp / base;
}

// film LUT has NaN sentinels for unmeasured spectral rows, but Metal's fast-math folds them :DDDDDD
inline bool3 nan_bits(float3 v) { return (as_type<uint3>(v) & 0x7fffffff) > 0x7f800000; }
inline bool4 nan_bits(float4 v) { return (as_type<uint4>(v) & 0x7fffffff) > 0x7f800000; }

// The LUT is rgba32Float, which is only filterable on Apple9+ (A17 Pro / M3). The host
// specialises the pipelines on MTLDevice.supports32BitFloatFiltering
constant bool hw_float_filtering [[function_constant(0)]];
// Pixel coords: y = row + 0.5 is exact (normalised y = (row+0.5)/84 isn't representable
// and can bleed the adjacent row — a different data type — into the lookup).
constexpr sampler lut_sampler(coord::pixel, filter::linear, address::clamp_to_edge);

inline uint lut_row(int type, int stock) { return uint(stock * 3 + type); }
inline float3 get_sensitivity(uint x, uint row, texture2d<float, access::sample> img_filmsim) {
    float3 log_sensitivity = img_filmsim.read(uint2(x, row)).rgb;
    return select(exp2(log_sensitivity * log2_10), float3(0.0), nan_bits(log_sensitivity));
}

// The UV/IR band-pass lives in the baked sensitivities
constant float envelope_scale = 1000.0;

// Coarse fit to the Thorlabs enlarger dichroic filters (filmsim.glsl).
inline float3 thorlabs_filters(float w) {
    float cyan    = 0.93 * smoothstep(345.0, 380.0, w) * (1.0 - smoothstep(545.0, 590.0, w)) + 0.7 * smoothstep(775.0, 810.0, w);
    float magenta = 0.9 * smoothstep(355.0, 380.0, w) * (1.0 - smoothstep(475.0, 505.0, w));
    if (w > 550.0) magenta = 0.9 * smoothstep(595.0, 645.0, w);
    float yellow  = 0.92 * smoothstep(492.0, 542.0, w) + 0.2 * (1.0 - smoothstep(370.0, 390.0, w));
    return float3(cyan, magenta, yellow);
}

// DIR coupler inter-layer inhibition matrix (init_coupler_matrix_shared). Columns, so `M * v`.
inline float3x3 coupler_matrix(float couplers) {
    float3x3 M = float3x3(float3(6.0, 4.0, 1.0), float3(4.0, 6.0, 4.0), float3(1.0, 4.0, 6.0));
    float3 amount = float3(0.1, 0.2, 0.5) * 3.0;
    M[0] *= (1.0 / 11.0) * amount.r * couplers;
    M[1] *= (1.0 / 14.0) * amount.g * couplers;
    M[2] *= (1.0 / 11.0) * amount.b * couplers;
    return M;
}

/// Precompute the spectral integration tables
kernel void filmsimSetup(
    texture2d<float, access::read>   img_coeff   [[texture(0)]],
    texture2d<float, access::sample> img_filmsim [[texture(1)]],
    constant FilmSimParams          &params      [[buffer(0)]],
    device   FilmTables             &t           [[buffer(1)]],
    uint tid [[thread_position_in_grid]])
{
    threadgroup float3 pf_partial[41];
    int i = int(tid);
    int film  = params.film;
    int paper = params.paper_offset + params.paper;
    bool print = params.process == 0;

    // Scan illuminant chromaticity is a fixed D50 upsample (init_scan_shared).
    float4 coeff_d50 = fetch_coeff(float3(0.9642, 1.0000, 0.8251), img_coeff);
    int scan_stock = print ? paper : film;
    float scan_factor_min = print ? dye_density_min_factor_paper : dye_density_min_factor_film;
    float scan_illum_scale = (print ? 4.0 : 4.7) / 41.0;

    // This wavelength's rows: the 10nm integration grid over the 5nm-sampled LUT.
    float lambda = 380.0 + i * 10.0;
    uint tx = uint(i * 2);
    float3 preflash = float3(0.0);

    {
        float3 sens = get_sensitivity(tx, lut_row(s_sensitivity, film), img_filmsim);
        float pdf = 2.0 * 41.0; // integration is -1 EV vs agx, hence the 2.0
        t.expose_factor[i] = float4(sens * (envelope_scale / pdf), 0.0);
    }

    {
        float4 dye = img_filmsim.read(uint2(tx, lut_row(s_dye_density, scan_stock)));
        dye = select(dye, float4(1000.0), nan_bits(dye));
        float3 dye_xyz = min(dye.xyz * log2_10, 300.0);
        float base_light = exp2(-(dye.w * scan_factor_min) * log2_10);
        float scan_illum = scan_illum_scale * sigmoid_eval(coeff_d50, lambda);
        t.scan_dye[i]    = float4(dye_xyz, 0.0);
        t.scan_factor[i] = float4(scan_illum * cmf_1931(lambda) * base_light, 0.0);
    }

    if (print) {
        float3 paper_sens = get_sensitivity(tx, lut_row(s_sensitivity, paper), img_filmsim);
        float4 film_dye = img_filmsim.read(uint2(tx, lut_row(s_dye_density, film)));
        film_dye = select(film_dye, float4(1000000.0), nan_bits(film_dye));

        float3 neutral = clamp(float3(params.filter_c,
                                      clamp(params.filter_m, 0.0, 1.0) + 0.1 * params.tune_m,
                                      clamp(params.filter_y, 0.0, 1.0) + 0.1 * params.tune_y),
                               0.0, 1.0);
        float illuminant = 0.002 * colour_blackbody(lambda, 2856.0);
        float base_light = exp2(-(film_dye.w * dye_density_min_factor_film) * log2_10);
        float common_light = illuminant * base_light * exp2(params.ev_paper) * 1000000.0;
        float3 enl = mix(float3(1.0), thorlabs_filters(lambda), neutral);
        float print_illuminant = enl.x * enl.y * enl.z * common_light;

        t.enlarger_dye[i]    = float4(film_dye.xyz * log2_10, 0.0);
        t.enlarger_factor[i] = float4(paper_sens * print_illuminant, 0.0);

        if (params.preflash != 0) {
            float3 pf_neutral = clamp(float3(params.filter_c,
                                             clamp(params.filter_m, 0.0, 1.0) + 0.1 * params.tune_m + params.pf_m,
                                             clamp(params.filter_y, 0.0, 1.0) + 0.1 * params.tune_y + params.pf_y),
                                      0.0, 1.0);
            float3 pf_enl = mix(float3(1.0), thorlabs_filters(lambda), pf_neutral);
            float pf_illum = pf_enl.x * pf_enl.y * pf_enl.z * common_light * exp2(params.pf_ev);
            preflash = paper_sens * pf_illum;
        }
    } else {
        t.enlarger_dye[i]    = float4(0.0);
        t.enlarger_factor[i] = float4(0.0);
    }

    pf_partial[i] = preflash;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (i == 0) {
        // DIR coupler diffusion matrix (interlayer inhibition)
        float3x3 M = coupler_matrix(params.couplers);
        t.M0 = float4(M[0], 0.0);
        t.M1 = float4(M[1], 0.0);
        t.M2 = float4(M[2], 0.0);
        t.M_sum = float4(M * float3(1.0), 0.0);
        float3 pf = float3(0.0);
        for (int k = 0; k < SN; ++k) pf += pf_partial[k];
        t.preflash = float4(pf, 0.0);
    }
}

inline float3 mulM(constant FilmTables &t, float3 v) {
    return t.M0.xyz * v.x + t.M1.xyz * v.y + t.M2.xyz * v.z;
}

/// Film exposure
inline float3 expose_film(float3 rgb, constant FilmSimParams &p,
                          constant FilmTables &t, texture2d<float, access::read> img_coeff) {
    rgb = max(float3(5e-4), rgb);                 // clamp dark noise to avoid NaNs
    float4 coeff = fetch_coeff(rgb, img_coeff);
    float3 raw = float3(0.0);
    for (int i = 0; i < SN; ++i) {
        float lambda = 380.0 + i * 10.0;
        float x = (coeff.x * lambda + coeff.y) * lambda + coeff.z;
        float val = (0.5 * x * rsqrt(x * x + 1.0) + 0.5) * coeff.w;
        raw += val * t.expose_factor[i].xyz;
    }
    float ev = p.ev_film + (p.process != 1 ? 0.0 : -2.0);
    return ev * log10_2 + log2(raw + 1e-10) * log10_2;
}

/// Newton solve that pre-inverts the DIR coupler feedback
inline float3 correct_exposure(float3 log_raw, float3 coupler, constant FilmSimParams &p,
                               constant FilmTables &t) {
    if (p.couplers <= 0.0) return log_raw;
    float3 ep = log_raw - coupler;
    float3 M_sum = t.M_sum.xyz;
    float3 e = (ep + 0.5 * M_sum) / (1.0 - 0.5 * M_sum);
    for (int i = 0; i < 5; ++i) {
        float3 sig, sig_d;
        sigmoid_both(e, sig, sig_d);
        e -= (e - ep - M_sum * sig) / (1.0 - M_sum * sig_d);
    }
    return e;
}

// procedural grain
inline float3 hash32(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}
inline float3 add_grain(int2 ipos, float3 density, float scale, constant FilmSimParams &p) {
    const float density_max = 3.3;
    float3 np = clamp(density / density_max, 0.0, 1.0);
    float3 p_dev_0 = clamp(np * 10.0, 0.0, 1.0);
    float3 p_dev_1 = clamp(np * 5.0 - 0.5, 0.0, 1.0);
    float3 p_dev_2 = clamp(np * 1.42857 - 0.42857, 0.0, 1.0);
    float u_scalar = pow(max(0.0, p.grain_uniformity), 0.333333);
    float3 u = clamp(float3(0.97, 0.97, 0.99) * u_scalar, 0.0, 1.0);
    float3 ch_scale = float3(0.8, 1.0, 2.0);
    float3 var_0 = p_dev_0 * max(1.0 - p_dev_0 * u, 0.0);
    float3 var_1 = p_dev_1 * max(1.0 - p_dev_1 * u, 0.0);
    float3 var_2 = p_dev_2 * max(1.0 - p_dev_2 * u, 0.0);
    float3 od_0 = 0.0066 * ch_scale * 2.5;
    float3 od_1 = 0.0066 * ch_scale * 1.0;
    float3 od_2 = 0.0066 * ch_scale * 0.5;
    float3 std_0 = sqrt(od_0 * (3.3 * 0.1) * var_0);
    float3 std_1 = sqrt(od_1 * (3.3 * 0.2) * var_1);
    float3 std_2 = sqrt(od_2 * (3.3 * 0.7) * var_2);
    float global_blur_sq = 0.65 * 0.65;
    float3 sigma_sq_0 = 1.0 * od_0 + global_blur_sq;
    float3 sigma_sq_1 = 1.0 * od_1 + global_blur_sq;
    float3 sigma_sq_2 = 1.0 * od_2 + global_blur_sq;
    float g_scale_sq = p.grain_size * p.grain_size;
    float coord_scale = max(1.0, p.grain_size);
    float inv_coord_scale = 1.0 / coord_scale;
    float3 inv_2sq_0 = 1.0 / (2.0 * sigma_sq_0 * g_scale_sq * inv_coord_scale * inv_coord_scale);
    float3 inv_2sq_1 = 1.0 / (2.0 * sigma_sq_1 * g_scale_sq * inv_coord_scale * inv_coord_scale);
    float3 inv_2sq_2 = 1.0 / (2.0 * sigma_sq_2 * g_scale_sq * inv_coord_scale * inv_coord_scale);

    float2 seed_offset = float2(fract(float(p.seed) * 0.1337) * 1000.0);
    // Pixel centres, not corners: (i + 0.5) · scale is the same full-res
    // coordinate at every render scale, so preview, zoom-tile and export grain
    // share one lattice (corner sampling drifts by 0.5·(scale−1) px).
    float2 pos = float2x2(float2(0.98006, -0.198669), float2(0.198669, 0.98006))
               * ((float2(ipos) + 0.5) * scale * inv_coord_scale + seed_offset);
    float2 pf = floor(pos);
    float2 f = fract(pos);

    float3 acc0 = float3(0.0), acc1 = float3(0.0), acc2 = float3(0.0);
    float3 wsq0 = float3(0.0), wsq1 = float3(0.0), wsq2 = float3(0.0);
    float3 l0 = inv_2sq_0 * 1.44269504, l1 = inv_2sq_1 * 1.44269504, l2 = inv_2sq_2 * 1.44269504;
    for (int y = -1; y <= 2; ++y) {
        float dy = float(y) - f.y, dy2 = dy * dy;
        for (int x = -1; x <= 2; ++x) {
            float dx = float(x) - f.x;
            float dist_sq = dx * dx + dy2;
            float window = max(0.0, 1.0 - dist_sq * 0.125);
            if (window <= 0.0) continue;
            float2 hp = pf + float2(x, y);
            float3 n0 = hash32(hp) * 2.0 - 1.0;
            float3 n1 = hash32(hp + 13.37) * 2.0 - 1.0;
            float3 n2 = hash32(hp + 42.0) * 2.0 - 1.0;
            float3 w0 = exp2(-dist_sq * l0) * window;
            float3 w1 = exp2(-dist_sq * l1) * window;
            float3 w2 = exp2(-dist_sq * l2) * window;
            acc0 += n0 * w0; acc1 += n1 * w1; acc2 += n2 * w2;
            wsq0 += w0 * w0; wsq1 += w1 * w1; wsq2 += w2 * w2;
        }
    }
    float3 bn0 = acc0 * 1.73205 * rsqrt(max(wsq0, 1e-6));
    float3 bn1 = acc1 * 1.73205 * rsqrt(max(wsq1, 1e-6));
    float3 bn2 = acc2 * 1.73205 * rsqrt(max(wsq2, 1e-6));
    float3 noise = bn0 * std_0 + bn1 * std_1 + bn2 * std_2;
    // Post controls
    float mono = (noise.r + noise.g + noise.b) * (1.0 / 3.0);
    noise = mix(float3(mono), noise, clamp(p.grain_saturation, 0.0, 1.0)) * max(p.grain_amount, 0.0);
    return clamp(density + noise, float3(0.0), float3(2.0));
}

/// Characteristic curve lookup on the 256-texel logE row. Compile-time specialised
/// fixed-function bilinear where 32-bit float filtering exists (Apple9+, Mac), manual
/// float32 lerp on older iOS hardware where sampling rgba32Float is undefined.
inline float3 develop_curve(float3 log_raw, float gamma, int stock,
                            texture2d<float, access::sample> img_filmsim) {
    uint row = lut_row(s_density_curve, stock);
    float3 d;
    if (hw_float_filtering) {
        float y = row + 0.5;
        // logE domain [-4, 4] over 256 texels; clamp_to_edge covers the ends
        float3 tcx = (gamma * log_raw + 4.0) * 32.0;
        d = float3(img_filmsim.sample(lut_sampler, float2(tcx.r, y)).r,
                   img_filmsim.sample(lut_sampler, float2(tcx.g, y)).g,
                   img_filmsim.sample(lut_sampler, float2(tcx.b, y)).b);
    } else {
        float3 xf = clamp((gamma * log_raw + 4.0) * 32.0 - 0.5, 0.0, 255.0);
        float3 x0 = floor(xf);
        float3 f = xf - x0;
        uint3 i0 = uint3(x0);
        uint3 i1 = min(i0 + 1, 255u);
        d = float3(
            mix(img_filmsim.read(uint2(i0.x, row)).r, img_filmsim.read(uint2(i1.x, row)).r, f.x),
            mix(img_filmsim.read(uint2(i0.y, row)).g, img_filmsim.read(uint2(i1.y, row)).g, f.y),
            mix(img_filmsim.read(uint2(i0.z, row)).b, img_filmsim.read(uint2(i1.z, row)).b, f.z));
    }
    return select(d, float3(0.0), nan_bits(d));
}

/// Enlarger exposure
inline float3 enlarger_expose(float3 density_cmy, constant FilmTables &t) {
    float3 raw = float3(0.0);
    for (int i = 0; i < SN; ++i) {
        float ds = dot(density_cmy, t.enlarger_dye[i].xyz);
        raw += exp2(-ds) * t.enlarger_factor[i].xyz;
    }
    return log2(raw + t.preflash.xyz + 1e-10) * log10_2;
}

/// Virtual scan; CMY dye density → transmitted spectrum → XYZ → linear rec2020
inline float3 scan(float3 density_cmy, constant FilmTables &t) {
    float3 raw = float3(0.0);
    for (int i = 0; i < SN; ++i) {
        float ds = dot(density_cmy, t.scan_dye[i].xyz);
        raw += exp2(-ds) * t.scan_factor[i].xyz;
    }
    return xyz_to_rec2020(clamp(raw, float3(0.0), float3(14.0)));
}

/// developed film → optional RA4 print → virtual scan → linear rec709.
inline float3 develop_to_rgb(float3 log_raw, int2 ipos, float scale, constant FilmSimParams &p,
                             constant FilmTables &t, texture2d<float, access::sample> img_filmsim) {
    float3 density = develop_curve(log_raw, p.gamma_film, p.film, img_filmsim);
    // Grain is invisible (and would alias) once a preview is ≥ 10× downscaled
    if (p.grain != 0 && scale < 10.0) density = add_grain(ipos, density, scale, p);
    if (p.process == 0) {                              // expose the negative onto print paper
        float3 lr = enlarger_expose(density, t);
        density = develop_curve(lr, p.gamma_paper, p.paper_offset + p.paper, img_filmsim);
    }
    return rec2020_to_rec709(scan(density, t));
}

// All per-pixel kernels share the same binding layout: input(s) at texture 0 (and 1),
// output at texture 2, the coeff/film LUTs at 3/4, and params/tables/tile-origin at
// buffers 0/1/2. The blur stages between them are CI CIGaussianBlur. The host uses
// dispatchThreads (non-uniform threadgroups), so the grid never exceeds the output
// and no bounds guards are needed.

kernel void filmsimProcess(
    texture2d<float, access::read>   img_in      [[texture(0)]],
    texture2d<float, access::write>  img_out     [[texture(2)]],
    texture2d<float, access::read>   img_coeff   [[texture(3)]],
    texture2d<float, access::sample> img_filmsim [[texture(4)]],
    constant FilmSimParams          &p           [[buffer(0)]],
    constant FilmTables             &t           [[buffer(1)]],
    constant FilmSimTile            &tile        [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    float3 log_raw = expose_film(rec709_to_rec2020(img_in.read(gid).rgb), p, t, img_coeff);
    if (p.couplers > 0.0)
        log_raw = correct_exposure(log_raw, mulM(t, sigmoid(log_raw)), p, t);
    float3 rgb = develop_to_rgb(log_raw, tile.origin + int2(gid), tile.scale, p, t, img_filmsim);
    img_out.write(float4(rgb, 1.0), gid);
}

/// Spatial stage 1: expose to (bounded) log raw exposure so it can be diffused.
kernel void filmsimExpose(
    texture2d<float, access::read>  img_in    [[texture(0)]],
    texture2d<float, access::write> img_out   [[texture(2)]],
    texture2d<float, access::read>  img_coeff [[texture(3)]],
    constant FilmSimParams         &p         [[buffer(0)]],
    constant FilmTables            &t         [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    float3 log_raw = expose_film(rec709_to_rec2020(img_in.read(gid).rgb), p, t, img_coeff);
    img_out.write(float4(clamp(log_raw, -10.0, 10.0), 1.0), gid);
}

/// Spatial stage 2: the DIR coupler signal to be spatially diffused (blurred).
kernel void filmsimCoupler(
    texture2d<float, access::read>  img_logexp [[texture(0)]],
    texture2d<float, access::write> img_out    [[texture(2)]],
    constant FilmSimParams         &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    float3 coupler = coupler_matrix(p.couplers) * sigmoid(img_logexp.read(gid).rgb);
    img_out.write(float4(clamp(coupler, -10.0, 10.0), 1.0), gid);
}

/// Spatial stage 3: correct exposure with the diffused couplers, then either develop
/// straight to the scanned print, or (for halation) emit the linear exposure to blur.
kernel void filmsimDevelop(
    texture2d<float, access::read>   img_logexp  [[texture(0)]],
    texture2d<float, access::read>   img_coupler [[texture(1)]],
    texture2d<float, access::write>  img_out     [[texture(2)]],
    texture2d<float, access::sample> img_filmsim [[texture(4)]],
    constant FilmSimParams          &p           [[buffer(0)]],
    constant FilmTables             &t           [[buffer(1)]],
    constant FilmSimTile            &tile        [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    float3 log_raw = img_logexp.read(gid).rgb;
    // Couplers are diffused (blurred) upstream, or formed per-pixel right here when they aren't.
    float3 coupler = p.couplers_diffused != 0 ? img_coupler.read(gid).rgb
                                              : coupler_matrix(p.couplers) * sigmoid(log_raw);
    log_raw = correct_exposure(log_raw, coupler, p, t);
    if (p.halation != 0)
        img_out.write(float4(exp2(log_raw * log2_10), 1.0), gid);   // linear exposure to blur
    else
        img_out.write(float4(develop_to_rgb(log_raw, tile.origin + int2(gid), tile.scale, p, t, img_filmsim), 1.0), gid);
}

/// Halation stage 4 (part2h): add the blurred halo to the exposure with midtone
/// protection, then develop, print and scan.
kernel void filmsimPrint(
    texture2d<float, access::read>   img_raw     [[texture(0)]],
    texture2d<float, access::read>   img_hal     [[texture(1)]],
    texture2d<float, access::write>  img_out     [[texture(2)]],
    texture2d<float, access::sample> img_filmsim [[texture(4)]],
    constant FilmSimParams          &p           [[buffer(0)]],
    constant FilmTables             &t           [[buffer(1)]],
    constant FilmSimTile            &tile        [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    float3 raw = img_raw.read(gid).rgb;
    float3 hal = img_hal.read(gid).rgb;
    // Per-channel halo strength follows the stock's anti-halation class (host-set)
    const float3 strength = float3(p.halation_r, p.halation_g, p.halation_b);
    float3 hs = p.halation_scale * strength;
    float x = max(0.0, (hal.x + hal.y + hal.z) / max(strength.x + strength.y + strength.z, 1e-4));
    float prot = exp2(-4.32808512266689 * p.halation_midtones / (1e-3 + 0.01 * x * x));  // -3·log2(e)·mids
    hs *= prot;
    float3 log_raw = log2((raw + hs * hal) / (1.0 + hs)) * log10_2;
    float3 rgb = develop_to_rgb(log_raw, tile.origin + int2(gid), tile.scale, p, t, img_filmsim);
    img_out.write(float4(rgb, 1.0), gid);
}
