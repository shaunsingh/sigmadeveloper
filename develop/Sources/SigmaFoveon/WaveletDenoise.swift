import CoreImage
import Foundation
import Metal
import os
import simd

// GPU wavelet denoise host (see Metal/Denoise.metal)
// Edge-avoiding à-trous decomposition, Poisson-Gaussian noise model, garrote
// shrinkage per scale — profiled traditional denoising, no neural model needed.

/// Poisson-Gaussian sensor noise model in decoded scene-linear units:
/// `var(x) = a + b·x` per channel at base sensitivity. The SD14 has no analog
/// gain — ISO is a metadata push — so one base profile plus the exactly-known
/// digital EV gain describes every shot: after `y = g·x`,
/// `var(y) = g²·a + g·b·y`.
struct NoiseProfile: Sendable {
    var a: SIMD3<Float>
    var b: SIMD3<Float>

    func pushed(by gain: Float) -> NoiseProfile {
        NoiseProfile(a: a * gain * gain, b: b * gain)
    }
}

/// Wavelet pyramid depth. Support radius is Σ 2·2^i = 62 px, padded to 64.
private let waveletLevels = 5
let waveletPad = 64

/// Fraction of white-noise sigma landing in each à-trous detail band
/// (2D B3-spline, Starck et al.); thresholds scale by these per level.
private let waveletLevelNorm: [Float] = [0.8907, 0.2007, 0.0855, 0.0412, 0.0203]

/// Base shrink thresholds in sigmas at strength 1. Luma stays gentle — fine
/// grain reads as film-like and the profiled sigma partly includes real
/// micro-texture — while chroma (the Foveon failure mode) shrinks hard, scaled
/// further by the user-facing chroma multiplier.
private let waveletLumaThreshold: Float = 1.2
private let waveletChromaThreshold: Float = 2.5

/// Edge-stop softness in sigma units: differences beyond ~2σ count as edges.
private let waveletEdgeStop: Float = 2.0

/// Mirrors `DenoiseParams` in Denoise.metal (float4-aligned scalars).
private struct DenoiseKernelParams {
    var sigA: SIMD4<Float>
    var sigB: SIMD4<Float>
    var tLuma: Float
    var tChroma: Float
    var edge: Float
    var spacing: Int32
    var first: Int32
}

final class WaveletDenoise: @unchecked Sendable {
    let device: MTLDevice
    let atrous: MTLComputePipelineState
    let assemble: MTLComputePipelineState

    /// Intermediate-texture pool, keyed by size. Core Image renders many tiles
    /// (and previews re-render constantly); reusing the four pyramid textures
    /// avoids ~170 MB of allocation churn per tile and the transient memory
    /// spikes that make `makeTexture` fail under pressure.
    private let pool = OSAllocatedUnfairLock(uncheckedState: [String: [MTLTexture]]())

    func lease(width: Int, height: Int, count: Int) -> TextureLease? {
        let key = "\(width)x\(height)"
        var textures = pool.withLockUnchecked { cache -> [MTLTexture] in
            var have = cache[key] ?? []
            let taken = Array(have.suffix(count))
            have.removeLast(taken.count)
            cache[key] = have
            return taken
        }
        while textures.count < count {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite]
            desc.storageMode = .private
            guard let tex = device.makeTexture(descriptor: desc) else {
                giveBack(TextureLease(textures))   // return the partial lease before failing
                return nil
            }
            textures.append(tex)
        }
        return TextureLease(textures)
    }

    func giveBack(_ lease: TextureLease) {
        guard let first = lease.textures.first else { return }
        let key = "\(first.width)x\(first.height)"
        pool.withLockUnchecked { cache in
            var have = cache[key] ?? []
            // Keep at most one working set per size; sizes change rarely.
            let room = max(0, 4 - have.count)
            have.append(contentsOf: lease.textures.prefix(room))
            cache[key] = have
        }
    }

    /// Free the retained working set (~170 MB at full frame) — wired into the
    /// app's leave-viewer lifecycle rather than reacting to memory warnings.
    func drain() {
        pool.withLockUnchecked { $0.removeAll() }
    }

    static let shared: WaveletDenoise? = {
        do { return try WaveletDenoise() }
        catch {
            warnStderr("wavelet denoise unavailable: \(error)")
            return nil
        }
    }()

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FilmSimError.noDevice }
        self.device = device
        guard let libURL = denoiseMetalLibraryURL else { throw FilmSimError.missingResource("Denoise metallib") }
        let library = try device.makeLibrary(URL: libURL)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw FilmSimError.missingResource("kernel \(name)") }
            return try device.makeComputePipelineState(function: fn)
        }
        self.atrous = try pipeline("denoiseAtrous")
        self.assemble = try pipeline("denoiseAssemble")
    }

    /// Denoise a scene-linear image. `noise` must already be pushed into the
    /// image's current units (fold in any EV gain applied upstream).
    func apply(_ image: CIImage, noise: NoiseProfile, strength: Float, chroma: Float) -> CIImage {
        guard strength > 0 else { return image }
        let extent = image.extent
        guard !extent.isInfinite, extent.width >= 1, extent.height >= 1 else { return image }
        let ctx = WaveletDenoiseContext(sim: self, noise: noise, strength: strength, chroma: max(chroma, 0))
        let out = try? WaveletDenoiseProcessor.apply(
            withExtent: extent, inputs: [image.clampedToExtent()],
            arguments: [WaveletDenoiseProcessor.contextKey: ctx])
        return out?.cropped(to: extent) ?? image
    }
}

/// A leased set of pooled pyramid textures; handed to the command buffer's
/// completion handler, which requires a Sendable capture (`MTLTexture` isn't).
final class TextureLease: @unchecked Sendable {
    let textures: [MTLTexture]
    init(_ textures: [MTLTexture]) { self.textures = textures }
}

/// Per-invocation payload handed through Core Image.
private final class WaveletDenoiseContext {
    let sim: WaveletDenoise
    let noise: NoiseProfile
    let strength: Float
    let chroma: Float
    init(sim: WaveletDenoise, noise: NoiseProfile, strength: Float, chroma: Float) {
        self.sim = sim; self.noise = noise; self.strength = strength; self.chroma = chroma
    }
}

/// One Core Image processor node running the whole pyramid on CI's command
/// buffer: 5 à-trous levels ping-ponging private f16 textures, then an
/// assemble pass `out = input − removed`. The ROI pads by the pyramid's exact
/// support so tiled rendering stays seam-free.
final class WaveletDenoiseProcessor: CIImageProcessorKernel {
    static let contextKey = "ctx"

    override class var outputFormat: CIFormat { .RGBAh }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect.insetBy(dx: -CGFloat(waveletPad), dy: -CGFloat(waveletPad))
    }

    override class func process(with inputs: [CIImageProcessorInput]?,
                                arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let ctx = arguments?[contextKey] as? WaveletDenoiseContext,
              let input = inputs?.first, let src = input.metalTexture,
              let dst = output.metalTexture,
              let cb = output.metalCommandBuffer else {
            throw FilmSimError.noDevice
        }
        let sim = ctx.sim
        let pad = SIMD2<Int32>(Int32(max(0, output.region.minX - input.region.minX)),
                               Int32(max(0, input.region.maxY - output.region.maxY)))

        // Intermediates over the padded input region: coarse ping-pong + removed
        // ping-pong. f16 is exact enough (the source TIFF is f16 already). Under
        // memory pressure the tile must still be produced — pass it through
        // un-denoised rather than leaving CI to paint a blank square.
        guard let lease = sim.lease(width: src.width, height: src.height, count: 4),
              let enc = cb.makeComputeCommandEncoder() else {
            try Self.passThrough(src, to: dst, pad: pad, on: cb)
            return
        }
        let t = lease.textures
        let (coarse0, coarse1, removed0, removed1) = (t[0], t[1], t[2], t[3])
        cb.addCompletedHandler { _ in sim.giveBack(lease) }

        // 16×16: the tg sweep showed 0 benefit from other shapes à-trous scatter reads
        func tgSize(_ p: MTLComputePipelineState) -> MTLSize {
            MTLSize(width: 16, height: max(1, min(16, p.maxTotalThreadsPerThreadgroup / 16)), depth: 1)
        }
        let full = MTLSize(width: src.width, height: src.height, depth: 1)
        let plen = MemoryLayout<DenoiseKernelParams>.stride

        enc.setComputePipelineState(sim.atrous)
        let atrousTG = tgSize(sim.atrous)
        var cur = src
        var removed = removed0                      // meaningless on level 0 (`first`)
        for level in 0..<waveletLevels {
            let coarseOut = level % 2 == 0 ? coarse0 : coarse1
            let removedOut = level % 2 == 0 ? removed1 : removed0
            var params = DenoiseKernelParams(
                sigA: SIMD4<Float>(ctx.noise.a, 0), sigB: SIMD4<Float>(ctx.noise.b, 0),
                tLuma: ctx.strength * waveletLumaThreshold * waveletLevelNorm[level],
                tChroma: ctx.strength * ctx.chroma * waveletChromaThreshold * waveletLevelNorm[level],
                edge: waveletEdgeStop,
                spacing: Int32(1 << level),
                first: level == 0 ? 1 : 0)
            enc.setTexture(cur, index: 0)
            enc.setTexture(removed, index: 1)
            enc.setTexture(coarseOut, index: 2)
            enc.setTexture(removedOut, index: 3)
            enc.setBytes(&params, length: plen, index: 0)
            // A serial compute encoder executes dispatches in encode order with
            // coherent memory, so the ping-pong needs no explicit barriers.
            enc.dispatchThreads(full, threadsPerThreadgroup: atrousTG)
            cur = coarseOut
            removed = removedOut
        }

        // out = input − removed, shifted by the output region's offset inside
        // the padded input region (CI textures share a row order, so the
        // relative texel offset is convention-free for our symmetric padding).
        enc.setComputePipelineState(sim.assemble)
        var padArg = pad
        enc.setTexture(src, index: 0)
        enc.setTexture(removed, index: 1)
        enc.setTexture(dst, index: 2)
        enc.setBytes(&padArg, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1),
                            threadsPerThreadgroup: tgSize(sim.assemble))
        enc.endEncoding()
    }

    /// Last-resort tile fill: copy the input region into the output so the
    /// tile renders un-denoised (never blank). Requires matching formats,
    /// which `formatForInput`/`outputFormat` guarantee in practice.
    private static func passThrough(_ src: MTLTexture, to dst: MTLTexture,
                                    pad: SIMD2<Int32>, on cb: MTLCommandBuffer) throws {
        let ox = min(Int(pad.x), max(0, src.width - dst.width))
        let oy = min(Int(pad.y), max(0, src.height - dst.height))
        guard src.pixelFormat == dst.pixelFormat,
              src.width >= dst.width, src.height >= dst.height,
              let blit = cb.makeBlitCommandEncoder() else {
            throw FilmSimError.noDevice
        }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: ox, y: oy, z: 0),
                  sourceSize: MTLSize(width: dst.width, height: dst.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        warnStderr("wavelet denoise tile passed through (memory pressure)")
    }
}

// MARK: - Metal library

let denoiseMetalLibraryURL: URL? = {
    #if os(macOS) || targetEnvironment(macCatalyst)
    let name = "Denoise_macos"
    #elseif targetEnvironment(simulator)
    let name = "Denoise_iossim"
    #else
    let name = "Denoise_ios"
    #endif
    guard let url = Bundle.module.url(forResource: name, withExtension: "metallib", subdirectory: "Assets")
        ?? Bundle.module.url(forResource: name, withExtension: "metallib") else {
        warnStderr("denoise metallib '\(name)' missing")
        return nil
    }
    return url
}()
