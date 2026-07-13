#!/usr/bin/env python3
"""Bake spectral film-simulation data into SigmaFoveon resources.

* ``FilmSim.lut``          per-stock film/paper spectral data, byte-compatible with
                           vkdt's ``filmsim.lut``: header ``<iHBBii`` = (1234, 2, 4,
                           1, 256, 3*stocks) then, per stock, three 256-wide RGBA32F
                           rows —
                             row 0  log10 spectral sensitivity (cols 0..80 = 380..780nm @5nm)
                             row 1  CMY dye density .rgb + base density .a
                             row 2  characteristic curve, 256 samples over logE -4..+4
* ``SpectraEmission.lut``  Hanatos sigmoid spectral-upsampling coefficients (a,b,c,norm)
                           indexed by tri2quad(xy), copied from the spektrafilm LUT.

Film sensitivities are multiplied @ bake by each stock's UV/IR adaptation window;
self-normalised so the response to the stock's reference illuminant is left unchanged

emits FilmStocks.generated.swift
Usage:  python scripts/filmsim_bake.py [--verify]
NumPy required; SciPy required for the neutral-balance solve. Re-run when the stock
set or upstream data changes; commit outputs.
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

# Stock order is load-bearing: films first, then papers, matching vkdt's wb.h optimiser
# so the neutral-balance table indexes correctly. paperOffset == len(FILMS).
FILMS = [
    "kodak_ektar_100", "kodak_portra_160", "kodak_portra_400", "kodak_portra_800",
    "kodak_portra_800_push1", "kodak_portra_800_push2", "kodak_gold_200",
    "kodak_ultramax_400", "kodak_vision3_50d", "kodak_vision3_250d",
    "kodak_vision3_200t", "kodak_vision3_500t", "fujifilm_pro_400h",
    "fujifilm_xtra_400", "fujifilm_c200", "kodak_ektachrome_100",
    "kodak_kodachrome_64", "fujifilm_provia_100f", "fujifilm_velvia_100",
    "kodak_verita_200d",
]
PAPERS = [
    "kodak_endura_premier", "kodak_ektacolor_edge", "kodak_supra_endura",
    "kodak_portra_endura", "fujifilm_crystal_archive_typeii", "kodak_2383",
    "kodak_2393", "kodak_ultra_endura",
]

LUT_MAGIC = 1234
ROW_W = 256                                          # texture width (vkdt convention)
WAVELENGTHS = np.arange(380.0, 780.0 + 1e-6, 5.0)    # 81 canonical samples, 380..780nm @5nm
LOG_EXPOSURE = np.linspace(-4.0, 4.0, ROW_W)         # characteristic-curve domain

# vkdt lut header: magic(i32) version(u16) channels(u8) datatype(u8) width(i32) height(i32)
HEADER = struct.Struct("<iHBBii")

REPO = Path(__file__).resolve().parents[1]
PROFILES = REPO / "resources/spektrafilm-ofx/Resources/data/profiles"
SPECTRA_LUT = (REPO / "resources/spektrafilm-ofx/Resources/data/luts"
               / "spectral_upsampling/hanatos_irradiance_xy_coeffs_250304.lut")
OUT = REPO / "develop/Sources/SigmaFoveon/Assets"
GEN_SWIFT = REPO / "develop/Sources/SigmaFoveon/FilmStocks.generated.swift"


# ------------------------------------------------------------------------- film data

def _col(values, count):
    """A length-`count` NaN-preserving column (JSON null -> NaN), zero-padded to 256."""
    out = np.zeros(ROW_W, np.float32)
    out[:count] = [np.float32("nan") if v is None else np.float32(v) for v in values]
    return out


def _resample_curve(log_exposure, curve):
    """Characteristic curve onto the canonical -4..+4 logE grid (per channel)."""
    log_exposure = np.asarray(log_exposure, float)
    out = np.zeros((ROW_W, 3), np.float32)
    for ch in range(3):
        col = np.asarray([np.nan if v is None else v for v in curve[:, ch]], float)
        keep = ~np.isnan(col)
        out[:, ch] = np.interp(LOG_EXPOSURE, log_exposure[keep], col[keep])
    return out


def _load(name):
    return json.loads((PROFILES / f"{name}.json").read_text())


# --------------------------------------------------- UV/IR adaptation window
# CIE daylight components S0/S1/S2 (CIE 15, 380..780nm @10nm) for the D-series
# reference illuminants, plus Planck for the tungsten ones. Only the *shape* matters:
# the window normalisation below is a ratio, so constant scales cancel.

_CIE_S = np.array([
    # S0      S1     S2
    [63.4,   38.5,   3.0], [65.8,   35.0,   1.2], [94.8,   43.4,  -1.1],
    [104.8,  46.3,  -0.5], [105.9,  43.9,  -0.7], [96.8,   37.1,  -1.2],
    [113.9,  36.7,  -2.6], [125.6,  35.9,  -2.9], [125.5,  32.6,  -2.8],
    [121.3,  27.9,  -2.6], [121.3,  24.3,  -2.6], [113.5,  20.1,  -1.8],
    [113.1,  16.2,  -1.5], [110.8,  13.2,  -1.3], [106.5,   8.6,  -1.2],
    [108.8,   6.1,  -1.0], [105.3,   4.2,  -0.5], [104.4,   1.9,  -0.3],
    [100.0,   0.0,   0.0], [96.0,   -1.6,   0.2], [95.1,   -3.5,   0.5],
    [89.1,   -3.5,   2.1], [90.5,   -5.8,   3.2], [90.3,   -7.2,   4.1],
    [88.4,   -8.6,   4.7], [84.0,   -9.5,   5.1], [85.1,  -10.9,   6.7],
    [81.9,  -10.7,   7.3], [82.6,  -12.0,   8.6], [84.9,  -14.0,   9.8],
    [81.3,  -13.6,  10.2], [71.9,  -12.0,   8.3], [74.3,  -13.3,   9.6],
    [76.4,  -12.9,   8.5], [63.3,  -10.6,   7.0], [71.7,  -11.6,   7.6],
    [77.0,  -12.2,   8.0], [65.2,  -10.2,   6.7], [47.7,   -7.8,   5.2],
    [68.6,  -11.2,   7.4], [65.0,  -10.4,   6.8]])


def _daylight(wl, x_d, y_d):
    """CIE daylight-series SPD at chromaticity (x_d, y_d), interpolated onto `wl`."""
    m = 0.0241 + 0.2562 * x_d - 0.7341 * y_d
    m1 = (-1.3515 - 1.7703 * x_d + 5.9114 * y_d) / m
    m2 = (0.0300 - 31.4424 * x_d + 30.0717 * y_d) / m
    s = _CIE_S[:, 0] + m1 * _CIE_S[:, 1] + m2 * _CIE_S[:, 2]
    return np.interp(wl, np.arange(380.0, 780.1, 10.0), s)


def _planck(wl, temperature):
    """Blackbody spectral radiance shape on `wl` (nm); unnormalised."""
    h, c, k = 6.62607015e-34, 299792458.0, 1.380649e-23
    lam = wl * 1e-9
    return lam ** -5.0 / np.expm1(h * c / (lam * k * temperature))


def _reference_illuminant(label, wl):
    """The stock's balance illuminant (profile `info.reference_illuminant`).

    D55 for daylight stocks; "T" (studio tungsten, 3200K Planckian) for the
    tungsten-balanced cine stocks. Papers never take this path."""
    if label == "T":
        return _planck(wl, 3200.0)
    if label == "D55":
        return _daylight(wl, 0.33242, 0.34743)
    raise SystemExit(f"unhandled reference illuminant {label!r} for a film stock")


_erf = np.vectorize(math.erf)


def _adaptation_window(wl, params):
    """erf band-pass from `hanatos2025_adaptation_window_params` = [cUV, σUV, cIR, σIR]."""
    c_uv, s_uv, c_ir, s_ir = (float(v) for v in params)
    if s_uv <= 0.0 or s_ir <= 0.0:
        return np.ones_like(wl)
    sqrt2 = math.sqrt(2.0)
    edge_uv = 0.5 + 0.5 * _erf((wl - c_uv) / (s_uv * sqrt2))
    edge_ir = 0.5 - 0.5 * _erf((wl - c_ir) / (s_ir * sqrt2))
    return np.maximum(edge_uv * edge_ir, 1e-12)


def _windowed_log_sensitivity(data, info):
    """log10 sensitivity (81,3 object array) with the stock's UV/IR window folded in.

    Self-normalised per channel so the integrated response under the stock's
    reference illuminant matches the unwindowed sensitivity — the window shapes
    the band edges without shifting exposure or neutral balance conventions."""
    sens = np.array([[np.nan if v is None else float(v) for v in row]
                     for row in data["log_sensitivity"]])           # (81, 3)
    window = _adaptation_window(WAVELENGTHS, data["hanatos2025_adaptation_window_params"])
    ill = _reference_illuminant(info["reference_illuminant"], WAVELENGTHS)
    lin = np.where(np.isnan(sens), 0.0, 10.0 ** np.where(np.isnan(sens), 0.0, sens))
    ref = (lin * ill[:, None]).sum(0)
    norm = (lin * (ill * window)[:, None]).sum(0) / np.maximum(ref, 1e-20)
    shifted = sens + np.log10(window)[:, None] - np.log10(np.maximum(norm, 1e-12))[None, :]
    return np.asarray(shifted, object)                              # NaN sentinels intact


def _stock_rows(prof, window=False):
    """Three RGBA32F rows (sensitivity, dye density, characteristic curve) for one stock.

    Mirrors resources/vkdt/.../filmsim/mklut-profiles.py so the LUT layout is
    interchangeable with vkdt's and the kernel's sampling maths is identical.
    With `window=True` (film stocks) the sensitivity row carries the stock's
    normalised UV/IR adaptation window; see `_windowed_log_sensitivity`."""
    data = prof["data"]
    wl = np.asarray(data["wavelengths"], float)
    if wl.shape != WAVELENGTHS.shape or not np.allclose(wl, WAVELENGTHS):
        raise SystemExit(f"unexpected wavelength grid {wl[0]}..{wl[-1]} ({wl.size})")

    n = wl.size
    if window:
        sens = _windowed_log_sensitivity(data, prof["info"])    # (81,3) log10, NaN sentinels
    else:
        sens = np.asarray(data["log_sensitivity"], object)      # (81,3) log10, may hold None
    chan = np.asarray(data["channel_density"], object)          # (81,3) CMY dye density
    base = data["base_density"]                                 # (81,) film base density
    curve = np.asarray(data["density_curves"], float)           # (256,3) over log_exposure

    row0 = np.stack([_col(sens[:, 0], n), _col(sens[:, 1], n), _col(sens[:, 2], n),
                     np.ones(ROW_W, np.float32)], axis=1)
    row1 = np.stack([_col(chan[:, 0], n), _col(chan[:, 1], n), _col(chan[:, 2], n),
                     _col(base, n)], axis=1)
    curve_r = _resample_curve(data["log_exposure"], curve)
    row2 = np.concatenate([curve_r, np.ones((ROW_W, 1), np.float32)], axis=1)
    return np.stack([row0, row1, row2])                         # (3, 256, 4)


def bake_film_lut(stocks):
    films = set(FILMS)
    rows = np.concatenate([_stock_rows(_load(s), window=s in films)
                           for s in stocks])                         # (3*stocks, 256, 4)
    payload = HEADER.pack(LUT_MAGIC, 2, 4, 1, ROW_W, rows.shape[0]) + rows.astype("<f4").tobytes()
    out = OUT / "FilmSim.lut"
    out.write_bytes(payload)
    print(f"  {out.relative_to(REPO)}  {len(stocks)} stocks, {rows.shape[0]}x{ROW_W} RGBA32F "
          f"({out.stat().st_size} bytes)")
    return rows


def read_coeff_lut():
    """Return (w, h, coeff[h,w,4]) from the Hanatos spectral-upsampling LUT."""
    raw = SPECTRA_LUT.read_bytes()
    magic, ver, ch, dt, w, h = HEADER.unpack_from(raw, 0)
    if magic != LUT_MAGIC or ch != 4:
        raise SystemExit(f"unexpected coeff LUT header {(magic, ver, ch, dt, w, h)}")
    coeff = np.frombuffer(raw, np.float32, count=w * h * 4, offset=HEADER.size).reshape(h, w, 4)
    return w, h, coeff


def bake_spectra_lut():
    w, h, coeff = read_coeff_lut()                              # trailing metadata ignored
    payload = HEADER.pack(LUT_MAGIC, 2, 4, 1, w, h) + np.ascontiguousarray(coeff, "<f4").tobytes()
    out = OUT / "SpectraEmission.lut"
    out.write_bytes(payload)
    print(f"  {out.relative_to(REPO)}  {w}x{h} RGBA32F ({out.stat().st_size} bytes)")
    return w, h, coeff


# ---------------------------------------------------------------------------- codegen

def _name(prof, key):
    return prof.get("info", {}).get("name") or key.replace("_", " ").title()


def emit_swift(wb):
    films = [(k, _name(p, k), p.get("info", {}).get("type") == "positive",
              p.get("info", {}).get("antihalation", "strong"),
              p.get("info", {}).get("target_print"))
             for k in FILMS for p in [_load(k)]]
    papers = [(k, _name(_load(k), k)) for k in PAPERS]
    if bad := {ah for _, _, _, ah, _ in films} - {"strong", "weak", "no"}:
        raise SystemExit(f"unexpected antihalation classes {bad}")
    if bad := {tp for _, _, _, _, tp in films if tp is not None} - set(PAPERS):
        raise SystemExit(f"target_print stocks missing from PAPERS: {bad}")
    L = [
        "// Generated by scripts/filmsim_bake.py — do not edit by hand.",
        "// Ordered film/paper stocks for spectral film simulation",
        "import simd",
        "",
        "public enum Antihalation: String, Sendable, Hashable {",
        "    case strong, weak, no",
        "}",
        "",
        "/// One selectable emulsion. `index` is the value handed to the kernel:",
        "/// `film` (0..<paperOffset) for films, relative 0-based `paper` for papers.",
        "public struct FilmStock: Sendable, Hashable, Identifiable {",
        "    public let index: Int",
        "    public let key: String",
        "    public let name: String",
        "    public let isPaper: Bool",
        "    /// Reversal (slide) stock — best viewed via the scanned-positive path, not an RA4 print.",
        "    public let isPositive: Bool",
        "    /// Films: anti-halation class from the profile. Papers: always `.strong`.",
        "    public let antihalation: Antihalation",
        "    /// The profile's companion print stock (`target_print`), if any.",
        "    public let targetPaperKey: String?",
        "    public var id: String { (isPaper ? \"paper:\" : \"film:\") + key }",
        "}",
        "",
        "public enum FilmSimData {",
        "    /// First paper's row block in FilmSim.lut; equals the film count.",
        f"    public static let paperOffset = {len(FILMS)}",
        "",
        "    public static let films: [FilmStock] = [",
    ]
    def swift_str(s):
        return f'"{s}"' if s is not None else "nil"
    L += [f'        FilmStock(index: {i}, key: "{k}", name: "{n}", isPaper: false, '
          f'isPositive: {str(pos).lower()}, antihalation: .{ah}, targetPaperKey: {swift_str(tp)}),'
          for i, (k, n, pos, ah, tp) in enumerate(films)]
    L += ["    ]", "", "    public static let papers: [FilmStock] = ["]
    L += [f'        FilmStock(index: {i}, key: "{k}", name: "{n}", isPaper: true, '
          f'isPositive: false, antihalation: .strong, targetPaperKey: nil),'
          for i, (k, n) in enumerate(papers)]
    L += [
        "    ]",
        "",
        "    /// Neutral balance per [film][paper]: (printEV, filterC, filterM, filterY).",
        "    static let neutralWB: [[SIMD4<Float>]] = [",
    ]
    for fi in range(len(FILMS)):
        cells = ", ".join(
            f"SIMD4<Float>({wb[fi, pi, 0]:.6g}, {wb[fi, pi, 1]:.6g}, "
            f"{wb[fi, pi, 2]:.6g}, {wb[fi, pi, 3]:.6g})" for pi in range(len(PAPERS)))
        L.append(f"        [{cells}],")
    L += ["    ]", "}", ""]
    # Swift source is defined as UTF-8; pin the encoding so a non-UTF-8 locale (e.g. a
    # Windows cp1252 default) can't mangle the em-dash/× in the header into invalid bytes.
    # (L ends with "" so the join already terminates the file with a single newline.)
    GEN_SWIFT.write_text("\n".join(L), encoding="utf-8")
    print(f"  {GEN_SWIFT.relative_to(REPO)}  {len(films)} films, {len(papers)} papers")


# -------------------------------------------------------------------------- verify

REC2020_TO_XYZ = np.array([                                     # matrices.h, D65
    [0.636958048301290991, 0.144616903586208406, 0.168880975164172054],
    [0.26270021201126692, 0.677998071518871148, 0.0593017164698619384],
    [4.9999999999999999e-17, 0.0280726930490874452, 1.06098505771079066]])


def _cmf(w):  # analytic CIE 1931 fits (rt/colour.glsl)
    def g(x, m, a, b):
        s = np.where(x < m, a, b)
        return np.exp(-0.5 * (s * (x - m)) ** 2)
    X = 0.362 * g(w, 442.0, 0.0624, 0.0374) + 1.056 * g(w, 599.8, 0.0264, 0.0323) - 0.065 * g(w, 501.1, 0.0490, 0.0382)
    Y = 0.821 * g(w, 568.8, 0.0213, 0.0247) + 0.286 * g(w, 530.9, 0.0613, 0.0322)
    Z = 1.217 * g(w, 437.0, 0.0845, 0.0278) + 0.681 * g(w, 459.0, 0.0385, 0.0725)
    return np.stack([X, Y, Z], axis=1)


def _fetch_coeff(rgb, coeff, w, h):
    xyz = REC2020_TO_XYZ @ rgb
    b = xyz.sum()
    tc = xyz[:2] / b
    ty, tx = tc[1] / (1.0 - tc[0]), (1.0 - tc[0]) ** 2          # tri2quad
    xi = int(np.clip(round(tx * w), 0, w - 1))
    yi = int(np.clip(round(ty * h), 0, h - 1))
    c = coeff[yi, xi].astype(np.float64).copy()
    c[3] = b / c[3]
    return c


def verify():
    """Round-trip rec2020 colours through spectral upsampling -> CMF -> xy. Validates the
    shipped SpectraEmission LUT and the tri2quad/sigmoid maths the Metal kernel ports."""
    w, h, coeff = read_coeff_lut()
    lam = np.arange(380.0, 780.1, 5.0)
    cmf = _cmf(lam)
    tests = {
        "neutral": [0.18, 0.18, 0.18], "warm gray": [0.22, 0.19, 0.15],
        "red": [0.40, 0.05, 0.04], "green": [0.08, 0.35, 0.06], "blue": [0.05, 0.07, 0.35],
        "skin": [0.45, 0.28, 0.21], "sky": [0.18, 0.26, 0.42],
    }
    print("  spectral round-trip (rec2020 -> spectrum -> xy):")
    worst = 0.0
    for name, rgb in tests.items():
        rgb = np.array(rgb)
        c = _fetch_coeff(rgb, coeff, w, h)
        x = (c[0] * lam + c[1]) * lam + c[2]
        spec = (0.5 * x / np.sqrt(x * x + 1.0) + 0.5) * c[3]
        xyz = (spec[:, None] * cmf).sum(axis=0)
        xy = xyz[:2] / xyz.sum()
        xyz_in = REC2020_TO_XYZ @ rgb
        xy_in = xyz_in[:2] / xyz_in.sum()
        err = float(np.hypot(*(xy - xy_in)))
        worst = max(worst, err)
        print(f"    {name:10s} xy_in=({xy_in[0]:.3f},{xy_in[1]:.3f}) "
              f"xy_out=({xy[0]:.3f},{xy[1]:.3f})  dxy={err:.4f}  {'ok' if err < 0.02 else 'HIGH'}")
    print(f"  worst dxy = {worst:.4f}  ({'PASS' if worst < 0.02 else 'FAIL'})")
    return worst < 0.02


# ------------------------------------------------ reference pipeline / balance solve
# A NumPy port of develop/Metal/FilmSim.metal, run against the *baked* data. It doubles
# as the cross-check (filmsim_verify.py) and as the solver for the neutral enlarger
# balance: rather than borrow vkdt's constants (tuned for a subtly different pipeline),
# we optimise the CMY filters + print EV so a neutral scene prints neutral through *this*
# implementation. Kept faithful to the kernel so the balance transfers to the GPU.

LAM = np.arange(380.0, 780.1, 10.0)                            # 41 samples, as in the kernel
LOG2_10 = 3.32192809489
LOG10_2 = 0.30102999566398114
GRAY = np.array([0.184, 0.184, 0.184])
XYZ_TO_REC2020 = np.array([
    [1.71665119, -0.35567078, -0.25336628],
    [-0.66668435, 1.61648124, 0.01576855],
    [0.01763986, -0.04277061, 0.94210312]])
REC2020_TO_REC709 = np.array([               # kernel's final scan conversion (rec2020_to_rec709)
    [1.66022677, -0.58754761, -0.07283825],
    [-0.12455334, 1.13292605, -0.00834963],
    [-0.01815514, -0.10060303, 1.11899817]])

_FILM = None            # baked FilmSim.lut, (3·stocks, 256, 4)
_COEFF = None           # baked SpectraEmission.lut, (512, 512, 4)
_CMF41 = None
_BB2856 = None


def _read_baked(name):
    raw = (OUT / f"{name}.lut").read_bytes()
    h = HEADER.unpack_from(raw, 0)
    w, ht = h[4], h[5]
    return np.frombuffer(raw, np.float32, count=w * ht * 4, offset=HEADER.size).reshape(ht, w, 4).astype(np.float64)


def load_reference():
    global _FILM, _COEFF, _CMF41, _BB2856
    _FILM = _read_baked("FilmSim")
    _COEFF = _read_baked("SpectraEmission")
    _CMF41 = _cmf(LAM)
    _BB2856 = _blackbody(LAM, 2856.0)


def _blackbody(lam, T):
    h2, h, c, k = 6.62606957e+11, 6.62606957e-34, 299792458.0, 1.3807e-23
    l2 = lam * lam
    c1 = 2.0 * h2 * c * c / (l2 * lam * l2)
    c2 = h * c / (lam * 1e-9 * T * k)
    return 1e-14 * c1 / (np.exp(c2) - 1.0)


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


ENVELOPE_SCALE = 1000.0


def _thorlabs(w):
    cyan = 0.93 * _smoothstep(345.0, 380.0, w) * (1.0 - _smoothstep(545.0, 590.0, w)) + 0.7 * _smoothstep(775.0, 810.0, w)
    magenta = np.where(w > 550.0, 0.9 * _smoothstep(595.0, 645.0, w),
                       0.9 * _smoothstep(355.0, 380.0, w) * (1.0 - _smoothstep(475.0, 505.0, w)))
    yellow = 0.92 * _smoothstep(492.0, 542.0, w) + 0.2 * (1.0 - _smoothstep(370.0, 390.0, w))
    return np.stack([cyan, magenta, yellow], axis=-1)


def _get_sens(stock, cols):
    s = np.exp2(_FILM[stock * 3 + 0, cols, :3] * LOG2_10)
    return np.where(np.isnan(s), 0.0, s)


def _sig_eval(coeff, lam):
    x = (coeff[0] * lam + coeff[1]) * lam + coeff[2]
    return (0.5 * x / np.sqrt(x * x + 1.0) + 0.5) * coeff[3]


def _sigmoid(x):
    ax = np.abs(x)
    xb = ax ** 4 * np.sqrt(ax)
    return 0.5 + 0.5 * x * np.exp2(-0.2222222222222222 * np.log2(xb + 1.0))


def _sigmoid_both(x):
    ax = np.abs(x)
    base = ax ** 4 * np.sqrt(ax) + 1.0
    rcp = np.exp2(-0.2222222222222222 * np.log2(base))
    return 0.5 + 0.5 * x * rcp, 0.5 * rcp / base


def _curve(log_raw, gamma, stock):
    row = _FILM[stock * 3 + 2, :, :3]
    tcx = np.clip((gamma * log_raw + 4.0) / 8.0, 0.0, 1.0)
    out = np.empty(3)
    for ch in range(3):
        p = tcx[ch] * 256.0 - 0.5
        i0 = int(np.clip(np.floor(p), 0, 255))
        f = np.clip(p - np.floor(p), 0.0, 1.0)
        out[ch] = row[i0, ch] * (1 - f) + row[min(i0 + 1, 255), ch] * f
    return np.where(np.isnan(out), 0.0, out)


def ref_params(film, paper, **kw):
    p = dict(process=0, film=film, paper=paper, paper_offset=len(FILMS),
             ev_film=0.0, gamma_film=1.0, ev_paper=0.0, gamma_paper=1.0, couplers=1.0,
             filter_c=0.05, filter_m=0.5, filter_y=0.45, tune_m=0.0, tune_y=0.0)
    p.update(kw)
    return p


def ref_build_tables(p):
    film, paper = p["film"], p["paper_offset"] + p["paper"]
    print_ = p["process"] == 0
    cols = np.arange(41) * 2
    t = {"expose_factor": _get_sens(film, cols) * (ENVELOPE_SCALE / (2.0 * 41.0))}

    scan_stock = paper if print_ else film
    scan_min = 0.4 if print_ else 1.0
    dye = np.where(np.isnan(_FILM[scan_stock * 3 + 1, cols, :]), 1000.0, _FILM[scan_stock * 3 + 1, cols, :])
    t["scan_dye"] = np.minimum(dye[:, :3] * LOG2_10, 300.0)
    scan_illum = ((4.0 if print_ else 4.7) / 41.0) * _sig_eval(_fetch_coeff(np.array([0.9642, 1.0, 0.8251]), _COEFF, 512, 512), LAM)
    t["scan_factor"] = scan_illum[:, None] * _CMF41 * np.exp2(-(dye[:, 3] * scan_min) * LOG2_10)[:, None]

    if print_:
        fdye = np.where(np.isnan(_FILM[film * 3 + 1, cols, :]), 1e6, _FILM[film * 3 + 1, cols, :])
        t["enlarger_dye"] = fdye[:, :3] * LOG2_10
        neutral = np.clip([p["filter_c"], np.clip(p["filter_m"], 0, 1) + 0.1 * p["tune_m"],
                           np.clip(p["filter_y"], 0, 1) + 0.1 * p["tune_y"]], 0, 1)
        common = (0.002 * _BB2856) * np.exp2(-(fdye[:, 3] * 1.0) * LOG2_10) * (2.0 ** p["ev_paper"]) * 1e6
        enl = (1.0 - neutral) + _thorlabs(LAM) * neutral
        t["enlarger_factor"] = _get_sens(paper, cols) * (enl[:, 0] * enl[:, 1] * enl[:, 2] * common)[:, None]

    M = np.array([[6.0, 4.0, 1.0], [4.0, 6.0, 4.0], [1.0, 4.0, 6.0]])
    for cix, sc in enumerate((1 / 11, 1 / 14, 1 / 11)):
        M[:, cix] *= sc * (np.array([0.1, 0.2, 0.5]) * 3.0)[cix] * p["couplers"]
    t["M"], t["M_sum"], t["preflash"] = M, M @ np.ones(3), np.zeros(3)
    return t


def ref_process(rgb, p, t):
    rgb = np.maximum(5e-4, rgb)
    coeff = _fetch_coeff(rgb, _COEFF, 512, 512)
    x = (coeff[0] * LAM + coeff[1]) * LAM + coeff[2]
    raw = ((0.5 * x / np.sqrt(x * x + 1.0) + 0.5) * coeff[3])[:, None] * t["expose_factor"]
    raw = raw.sum(0)
    ev = p["ev_film"] + (0.0 if p["process"] == 0 else -2.0)
    log_raw = ev * LOG10_2 + np.log2(raw + 1e-10) * LOG10_2

    if p["couplers"] > 0:
        ep = log_raw - t["M"] @ _sigmoid(log_raw)
        Ms = t["M_sum"]
        e = (ep + 0.5 * Ms) / (1.0 - 0.5 * Ms)
        for _ in range(5):
            sig, sig_d = _sigmoid_both(e)
            e -= (e - ep - Ms * sig) / (1.0 - Ms * sig_d)
        log_raw = e

    density = _curve(log_raw, p["gamma_film"], p["film"])
    if p["process"] == 0:
        ds = (density[None, :] * t["enlarger_dye"]).sum(1)
        raw = (np.exp2(-ds)[:, None] * t["enlarger_factor"]).sum(0) + t["preflash"]
        density = _curve(np.log2(raw + 1e-10) * LOG10_2, p["gamma_paper"], p["paper_offset"] + p["paper"])

    ds = (density[None, :] * t["scan_dye"]).sum(1)
    xyz = np.clip((np.exp2(-ds)[:, None] * t["scan_factor"]).sum(0), 0.0, 14.0)
    return REC2020_TO_REC709 @ (XYZ_TO_REC2020 @ xyz)   # scan XYZ -> rec2020 -> rec709, as develop_to_rgb does


def _wb_cost(x, film, paper):
    c, m, y, ev = x
    p = ref_params(film, paper, filter_c=float(np.clip(c, 0, 1)), filter_m=float(np.clip(m, 0, 1)),
                   filter_y=float(np.clip(y, 0, 1)), ev_paper=float(ev), couplers=0.0)
    out = ref_process(GRAY, p, ref_build_tables(p))
    mean = out.mean()
    chroma = float(((out - mean) ** 2).sum())
    light = (mean - 0.184) ** 2
    oob = float(np.sum(np.clip([c, m, y], None, 0) ** 2) + np.sum(np.clip(np.array([c, m, y]) - 1, 0, None) ** 2))
    return 1e3 * chroma + 30.0 * light + 20.0 * oob


def optimize_wb():
    """Solve (filterC, filterM, filterY, printEV) per film×paper so a neutral scene prints
    neutral through this pipeline (couplers off, matching vkdt's balance convention). A few
    starts guard against local minima; positive/slide stocks printed on paper are degenerate
    (near-black) so their relative residual is uninformative and excluded from the summary."""
    from scipy.optimize import minimize
    starts = [np.array(s) for s in ([0.05, 0.5, 0.45, 0.0], [0.0, 0.3, 0.3, 0.5], [0.1, 0.7, 0.6, -0.5])]
    F, P = len(FILMS), len(PAPERS)
    wb = np.zeros((F, P, 4))
    worst = 0.0
    for f in range(F):
        positive = _load(FILMS[f]).get("info", {}).get("type") == "positive"
        for pa in range(P):
            best = min((minimize(_wb_cost, s, args=(f, pa), method="Nelder-Mead",
                                 options=dict(xatol=1e-4, fatol=1e-9, maxiter=3000)) for s in starts),
                       key=lambda r: r.fun)
            c, m, y, ev = best.x
            c, m, y = (float(np.clip(v, 0, 1)) for v in (c, m, y))
            wb[f, pa] = [float(ev), c, m, y]
            p = ref_params(f, pa, filter_c=c, filter_m=m, filter_y=y, ev_paper=float(ev), couplers=0.0)
            out = ref_process(GRAY, p, ref_build_tables(p))
            if not positive:                       # slides on paper are physically degenerate
                worst = max(worst, float(np.max(np.abs(out - out.mean())) / max(out.mean(), 0.05)))
    print(f"  optimised neutral balance for {F}×{P} pairs (worst residual chroma {worst:.3f}, negative stocks)")
    return wb


# ---------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Bake film-simulation resources.")
    ap.add_argument("--verify", action="store_true", help="only run the spectral round-trip self-test")
    args = ap.parse_args()

    if args.verify:
        return 0 if verify() else 1

    missing = [k for k in FILMS + PAPERS if not (PROFILES / f"{k}.json").exists()]
    if missing:
        print(f"error: missing profiles: {missing}", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)

    print("baking film-simulation data:")
    rows = bake_film_lut(FILMS + PAPERS)
    bake_spectra_lut()

    load_reference()
    try:
        wb = optimize_wb()
    except ImportError:
        # vkdt's wb.h balance was solved without the per-stock adaptation windows now
        # baked into the sensitivities, so it no longer transfers
        print("error: SciPy is required for the neutral-balance solve (pip install scipy)",
              file=sys.stderr)
        return 1
    emit_swift(wb)

    print("verifying:")
    ok = verify()
    finite = np.isfinite(rows).mean() * 100
    print(f"  film data finite {finite:.1f}%  curve range "
          f"[{np.nanmin(rows[2::3, :, :3]):.3f}, {np.nanmax(rows[2::3, :, :3]):.3f}]")
    print("done." if ok else "done (WARNING: spectral round-trip error high).")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
