import CoreImage
import Foundation
import Metal
import os
import simd

// GPU spectral film simulation host
// baked film data + spectral upsampling + metal compute -> coreimage

// MARK: User-facing

public struct FilmSimSettings: Sendable, Equatable, Hashable, Codable {
    public var film: Int = 2               // Kodak Portra 400
    public var paper: Int = 3              // Kodak Portra Endura
    /// Output the scanned negative/slide (process 1) instead of an RA4 print (process 0).
    public var negative = false
    public var evFilm: Float = 0
    public var evPaper: Float? = nil       // nil → neutral-balance default
    public var couplers: Float = 0.25      // DIR coupler amount (0 disables), vkdt default
    public var grain = true
    public var grainSize: Float = 1
    public var grainUniformity: Float = 1
    /// Grain post-scale (1 = the model's physical amplitude).
    public var grainAmount: Float = 1
    /// 1 = independent per-layer dye clouds, 0 = fully coupled (monochrome) grain
    public var grainSaturation: Float = 1
    /// Development-contrast trim
    public var gammaFilm: Float = 1
    public var gammaPaper: Float = 1
    public var filterC: Float? = nil       // nil → neutral-balance default
    public var filterM: Float? = nil
    public var filterY: Float? = nil
    public var tuneM: Float = 0            // green/magenta tint
    public var tuneY: Float = 0            // warm/cool
    public var preflash = false
    public var pfEV: Float = -2
    public var pfM: Float = 0
    public var pfY: Float = 0
    /// DIR coupler spatial diffusion radius, as a fraction of the long edge (0 = per-pixel only).
    public var couplersRadius: Float = 0.0015
    /// Halation: a soft reddish glow bleeding out of the highlights.
    public var halation = false
    public var halationStrength: Float = 0.35  // halo scale (vkdt `scale`)
    /// Per-channel halo strength; nil → the stock's anti-halation class default.
    public var halationColor: SIMD3<Float>? = nil
    public var halationRadius: Float = 0.0015  // fraction of the long edge
    public var halationMidtones: Float = 0      // highlight protection (1 = brightest only)

    public init() {}

    /// Pack into the kernel
    func kernelParams(seed: UInt32) -> FilmSimParams {
        let f = min(max(film, 0), FilmSimData.films.count - 1)
        let p = min(max(paper, 0), FilmSimData.papers.count - 1)
        let wb = FilmSimData.neutralWB[f][p]      // (printEV, filterC, filterM, filterY)
        let hal = halationColor ?? FilmSimData.films[f].antihalation.halationColor
        return FilmSimParams(
            process: negative ? 1 : 0, film: Int32(f), paper: Int32(p),
            paperOffset: Int32(FilmSimData.paperOffset),
            evFilm: evFilm, gammaFilm: gammaFilm,
            evPaper: evPaper ?? wb.x, gammaPaper: gammaPaper,
            couplers: max(0, couplers),
            filterC: filterC ?? wb.y, filterM: filterM ?? wb.z, filterY: filterY ?? wb.w,
            tuneM: tuneM, tuneY: tuneY,
            grain: grain ? 1 : 0, grainSize: max(0.1, grainSize),
            grainUniformity: min(max(grainUniformity, 0), 1),
            preflash: preflash ? 1 : 0, pfEV: pfEV, pfM: pfM, pfY: pfY,
            halation: halation ? 1 : 0,
            halationScale: halation ? max(0, halationStrength) : 0,
            halationMidtones: min(max(halationMidtones, 0), 1),
            halationR: hal.x, halationG: hal.y, halationB: hal.z,
            couplersDiffused: (couplers > 0 && couplersRadius > 0) ? 1 : 0,
            grainAmount: max(0, grainAmount),
            grainSaturation: min(max(grainSaturation, 0), 1),
            seed: seed)
    }
}

// MARK: - Kernel parameter block (mirrors FilmSimParams in FilmSim.metal, tight 4-byte scalars)

struct FilmSimParams: Equatable {
    var process: Int32; var film: Int32; var paper: Int32; var paperOffset: Int32
    var evFilm: Float; var gammaFilm: Float; var evPaper: Float; var gammaPaper: Float
    var couplers: Float; var filterC: Float; var filterM: Float; var filterY: Float
    var tuneM: Float; var tuneY: Float
    var grain: Int32; var grainSize: Float; var grainUniformity: Float
    var preflash: Int32; var pfEV: Float; var pfM: Float; var pfY: Float
    var halation: Int32; var halationScale: Float; var halationMidtones: Float
    var halationR: Float; var halationG: Float; var halationB: Float
    var couplersDiffused: Int32
    var grainAmount: Float; var grainSaturation: Float
    var seed: UInt32
}

extension FilmSimParams {
    /// projection of film sim params to handle cache hits
    var tablesKey: FilmSimParams {
        var k = self
        k.evFilm = 0; k.gammaFilm = 0; k.gammaPaper = 0
        k.grain = 0; k.grainSize = 0; k.grainUniformity = 0
        k.grainAmount = 0; k.grainSaturation = 0
        k.halation = 0; k.halationScale = 0; k.halationMidtones = 0
        k.halationR = 0; k.halationG = 0; k.halationB = 0
        k.couplersDiffused = 0; k.seed = 0
        return k
    }
}

// MARK: - Simulation resources

final class FilmSimulation: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let setup: MTLComputePipelineState
    let process: MTLComputePipelineState       // fused fast path (main.comp)
    let expose: MTLComputePipelineState        // spatial stage 1 → log exposure
    let coupler: MTLComputePipelineState       // spatial stage 2 → DIR coupler signal
    let develop: MTLComputePipelineState       // spatial stage 3 → print, or raw for halation
    let printer: MTLComputePipelineState       // halation stage 4 → print
    let coeff: MTLTexture     // spectral-upsampling coefficients (512×512)
    let film: MTLTexture      // per-stock spectral data (256×3·stocks)

    /// Last-computed FilmTables
    private let tablesCache = OSAllocatedUnfairLock<(key: FilmSimParams, buffer: MTLBuffer)?>(
        uncheckedState: nil)

    /// FilmTables byte size: 5 arrays of 41 float4 + preflash + 3 matrix rows + M·1.
    static let tablesLength = (41 * 5 + 5) * MemoryLayout<SIMD4<Float>>.stride

    static let shared: FilmSimulation? = {
        do { return try FilmSimulation() }
        catch {
            warnStderr("film simulation unavailable: \(error)")
            return nil
        }
    }()

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw FilmSimError.noDevice }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw FilmSimError.noDevice }
        self.queue = queue
        guard let libURL = filmSimMetalLibraryURL else { throw FilmSimError.missingResource("FilmSim metallib") }
        let library = try device.makeLibrary(URL: libURL)
        // Specialise the curve lookup: fixed-function bilinear on hardware that filters
        // rgba32Float (Apple9+ / Mac), manual float32 lerp on older iPhones
        let constants = MTLFunctionConstantValues()
        var hwFilter = device.supports32BitFloatFiltering
        constants.setConstantValue(&hwFilter, type: .bool, index: 0)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            let fn = try library.makeFunction(name: name, constantValues: constants)
            return try device.makeComputePipelineState(function: fn)
        }
        self.setup = try pipeline("filmsimSetup")
        self.process = try pipeline("filmsimProcess")
        self.expose = try pipeline("filmsimExpose")
        self.coupler = try pipeline("filmsimCoupler")
        self.develop = try pipeline("filmsimDevelop")
        self.printer = try pipeline("filmsimPrint")
        self.coeff = try FilmSimulation.loadLUT("SpectraEmission", device: device)
        self.film = try FilmSimulation.loadLUT("FilmSim", device: device)
    }

    /// Apply the film simulation to a scene-linear (extended-linear sRGB) image. The fused
    /// kernel handles the common case; coupler spatial diffusion and halation add
    /// blur-separated passes (vkdt part0 / part1 / part2h), composed with CIGaussianBlur.
    /// `cale is full-res pixels per rendered pixel keeping preview grain locked to the same full-res features as the export.
    func apply(_ image: CIImage, _ s: FilmSimSettings, seed: UInt32 = 0, scale: Float = 1) -> CIImage {
        let params = s.kernelParams(seed: seed)
        // The spectral tables depend only on the settings, so they are computed
        // once here and shared by every tile instead of re-run per tile.
        guard let tables = tables(for: params) else { return image }
        let extent = image.extent
        let diffuse = s.couplers > 0 && s.couplersRadius > 0
        if !diffuse && !s.halation {
            return run(stage(process, 1, tables: true, coeff: true, film: true), [image], params, tables, extent, scale) ?? image
        }
        let longEdge = Float(max(extent.width, extent.height))
        guard let logExp = run(stage(expose, 1, tables: true, coeff: true, film: false), [image], params, tables, extent, scale)
        else { return image }
        // Diffuse the coupler signal (part0 + blur) only when a radius is set; otherwise the
        // develop stage forms the coupler per-pixel and this second input is ignored.
        var couplerInput = logExp
        if diffuse {
            // Fail the whole apply if the coupler pass fails
            guard let coupler = run(stage(self.coupler, 1, tables: false, coeff: false, film: false), [logExp], params, tables, extent, scale) else { return image }
            couplerInput = blur(coupler, radius: s.couplersRadius * longEdge, extent: extent)
        }
        let developStage = stage(develop, 2, tables: true, coeff: false, film: true)
        guard let stage3 = run(developStage, [logExp, couplerInput], params, tables, extent, scale) else { return image }
        if !s.halation { return stage3 }                                   // stage3 is the final print
        let hal = blur(stage3, radius: max(1, s.halationRadius * longEdge), extent: extent)   // stage3 is raw exposure
        return run(stage(printer, 2, tables: true, coeff: false, film: true), [stage3, hal], params, tables, extent, scale) ?? image
    }

    /// The FilmTables buffer for `params`: cached, or computed by one setup
    /// dispatch on our own queue. `waitUntilCompleted` (µs-scale) makes the
    /// writes visible to Core Image's queue before any tile reads them.
    private func tables(for params: FilmSimParams) -> MTLBuffer? {
        // Cache on the exposure/grain/halation hits
        let key = params.tablesKey
        if let hit = tablesCache.withLockUnchecked({ $0 }), hit.key == key {
            return hit.buffer
        }
        guard let buffer = device.makeBuffer(length: Self.tablesLength, options: .storageModePrivate),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return nil }
        var p = key
        enc.setComputePipelineState(setup)
        enc.setTexture(coeff, index: 0)
        enc.setTexture(film, index: 1)
        enc.setBytes(&p, length: MemoryLayout<FilmSimParams>.stride, index: 0)
        enc.setBuffer(buffer, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: 41, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 41, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        tablesCache.withLockUnchecked { $0 = (key, buffer) }
        return buffer
    }

    private func stage(_ p: MTLComputePipelineState, _ inputs: Int, tables: Bool, coeff: Bool, film: Bool) -> FilmSimStage {
        FilmSimStage(pipeline: p, inputs: inputs, needsTables: tables, needsCoeff: coeff, needsFilm: film)
    }

    private func run(_ stage: FilmSimStage, _ inputs: [CIImage], _ params: FilmSimParams,
                     _ tables: MTLBuffer, _ extent: CGRect, _ scale: Float) -> CIImage? {
        let ctx = FilmSimContext(sim: self, params: params, stage: stage, tables: tables,
                                 scale: scale, extent: extent)
        return try? FilmSimProcessor.apply(withExtent: extent, inputs: inputs,
                                           arguments: [FilmSimProcessor.contextKey: ctx])
    }

    private func blur(_ image: CIImage, radius: Float, extent: CGRect) -> CIImage {
        guard radius > 0.5 else { return image }
        return image.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    /// Decode a baked `.lut` into a sampleable texture
    private static func loadLUT(_ name: String, device: MTLDevice) throws -> MTLTexture {
        guard let url = Bundle.module.url(forResource: name, withExtension: "lut", subdirectory: "Assets")
            ?? Bundle.module.url(forResource: name, withExtension: "lut") else {
            throw FilmSimError.missingResource("\(name).lut")
        }
        let data = try Data(contentsOf: url)
        // header: magic(i32) version(u16) channels(u8) datatype(u8) width(i32) height(i32) = 16 bytes
        let header = 16
        guard data.count >= header else { throw FilmSimError.missingResource("\(name).lut truncated") }
        let (w, h): (Int, Int) = data.withUnsafeBytes {
            (Int($0.loadUnaligned(fromByteOffset: 8, as: Int32.self)),
             Int($0.loadUnaligned(fromByteOffset: 12, as: Int32.self)))
        }
        guard w > 0, h > 0, data.count >= header + w * h * 16 else { throw FilmSimError.missingResource("\(name).lut truncated") }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw FilmSimError.noDevice }
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: raw.baseAddress!.advanced(by: header), bytesPerRow: w * 16)
        }
        return tex
    }
}

enum FilmSimError: Error { case noDevice, missingResource(String) }

/// One GPU stage: the kernel to run and which resources it needs bound.
private struct FilmSimStage {
    let pipeline: MTLComputePipelineState
    let inputs: Int            // 1 or 2 image inputs
    let needsTables: Bool      // bind the precomputed spectral tables
    let needsCoeff: Bool       // bind the spectral-upsampling texture
    let needsFilm: Bool        // bind the film-data texture
}

/// Per-invocation payload handed to the processor kernel through Core Image.
private final class FilmSimContext {
    let sim: FilmSimulation
    let params: FilmSimParams
    let stage: FilmSimStage
    let tables: MTLBuffer
    let scale: Float           // full-res pixels per rendered pixel (grain fidelity)
    let extent: CGRect         // full image extent, to anchor tile origins globally
    init(sim: FilmSimulation, params: FilmSimParams, stage: FilmSimStage, tables: MTLBuffer,
         scale: Float, extent: CGRect) {
        self.sim = sim; self.params = params; self.stage = stage; self.tables = tables
        self.scale = scale; self.extent = extent
    }
}

/// Mirrors FilmSimTile
private struct FilmSimTile {
    var origin: SIMD2<Int32>
    var scale: Float
    var pad: Float = 0
    /// Texel offsets of the output region within each input texture (see process()).
    var in0: SIMD2<Int32>
    var in1: SIMD2<Int32>
}

// MARK: - Core Image processor node

/// Runs one film-sim stage on Core Image's command buffer. Every stage shares the same
/// binding layout — input(s) at texture 0/1, output at 2, coeff/film LUTs at 3/4, and
/// params/tables/tile at buffers 0/1/2 — so this one node drives them all.
final class FilmSimProcessor: CIImageProcessorKernel {
    static let contextKey = "ctx"

    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    /// Point-wise stages (the blur between them is CIGaussianBlur): input ROI == output.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?,
                                arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let ctx = arguments?[contextKey] as? FilmSimContext,
              let inputs, let src0 = inputs.first?.metalTexture,
              let dst = output.metalTexture,
              let cb = output.metalCommandBuffer,
              let enc = cb.makeComputeCommandEncoder() else {
            throw FilmSimError.noDevice
        }
        let sim = ctx.sim, stage = ctx.stage
        var params = ctx.params
        let plen = MemoryLayout<FilmSimParams>.stride

        enc.setComputePipelineState(stage.pipeline)
        enc.setTexture(src0, index: 0)
        if stage.inputs > 1 {
            guard inputs.count > 1, let src1 = inputs[1].metalTexture else { enc.endEncoding(); throw FilmSimError.noDevice }
            enc.setTexture(src1, index: 1)
        }
        enc.setTexture(dst, index: 2)
        if stage.needsCoeff { enc.setTexture(sim.coeff, index: 3) }
        if stage.needsFilm { enc.setTexture(sim.film, index: 4) }
        enc.setBytes(&params, length: plen, index: 0)
        // Tables were computed once per render (see FilmSimulation.tables(for:)).
        if stage.needsTables { enc.setBuffer(ctx.tables, offset: 0, index: 1) }
        // `output.region` is bottom-up (Core Image space) while `gid` rows count
        // top-down within the texture; flip the origin so `origin + gid` is one
        // stable top-down image coordinate — identical whether CI renders the
        // frame whole, in internal tiles, or as a zoomed region crop. Grain is
        // seeded from this coordinate, so it must not depend on the tiling.
        //
        // Input textures cover their own `region`, which CI only guarantees to
        // *contain* the output ROI — cached/realigned intermediates shift it.
        // Each read is offset by the region delta (top-down, like `gid`);
        // reading at bare `gid` tears the image along CI's tile boundaries.
        let out = output.region
        func inputOffset(_ i: Int) -> SIMD2<Int32> {
            guard i < inputs.count else { return .zero }
            let r = inputs[i].region
            return SIMD2(Int32((out.minX - r.minX).rounded()),
                         Int32((r.maxY - out.maxY).rounded()))
        }
        var tile = FilmSimTile(origin: SIMD2<Int32>(Int32((out.minX - ctx.extent.minX).rounded()),
                                                    Int32((ctx.extent.maxY - out.maxY).rounded())),
                               scale: ctx.scale,
                               in0: inputOffset(0), in1: inputOffset(1))
        enc.setBytes(&tile, length: MemoryLayout<FilmSimTile>.stride, index: 2)
        // 16×8 measured fastest on M4 across the fused/spatial paths
        // 4 simdgroups hide the LUT/texture latency of
        // these register-heavy kernels better than larger groups
        let h = min(8, max(1, stage.pipeline.maxTotalThreadsPerThreadgroup / 16))
        let tg = MTLSize(width: 16, height: h, depth: 1)
        enc.dispatchThreads(MTLSize(width: dst.width, height: dst.height, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
    }
}

// MARK: - Metal library

let filmSimMetalLibraryURL: URL? = {
    #if os(macOS) || targetEnvironment(macCatalyst)
    let name = "FilmSim_macos"
    #elseif targetEnvironment(simulator)
    let name = "FilmSim_iossim"
    #else
    let name = "FilmSim_ios"
    #endif
    guard let url = Bundle.module.url(forResource: name, withExtension: "metallib", subdirectory: "Assets")
        ?? Bundle.module.url(forResource: name, withExtension: "metallib") else {
        warnStderr("film simulation metallib '\(name)' missing")
        return nil
    }
    return url
}()
