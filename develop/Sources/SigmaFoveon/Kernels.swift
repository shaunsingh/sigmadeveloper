import CoreImage
import Foundation

// Precompiled Core Image Metal kernels for the finishing graph.
//
// CI kernels need the metal compiler's `-fcikernel` and the metallib linker's
// `-cikernel` flags, which SwiftPM can't pass — so `Metal/LensCorrection.ci.metal`
// is precompiled per platform by `build_metallib.sh` and bundled as a resource. The
// one metallib holds every finishing kernel (`lensCorrect`, `gainExtend`); load it
// once here and hand the bytes to each kernel.

/// The platform-appropriate finishing metallib bytes, loaded once. nil (with a stderr
/// note) if the resource is missing — each dependent kernel then silently no-ops.
let foveonMetalLibrary: Data? = {
    #if os(macOS) || targetEnvironment(macCatalyst)
    let name = "LensCorrection_macos.ci"
    #elseif targetEnvironment(simulator)
    let name = "LensCorrection_iossim.ci"
    #else
    let name = "LensCorrection_ios.ci"
    #endif
    guard let url = Bundle.module.url(forResource: name, withExtension: "metallib", subdirectory: "Assets")
        ?? Bundle.module.url(forResource: name, withExtension: "metallib"),
        let data = try? Data(contentsOf: url)
    else {
        warnStderr("finishing metallib '\(name)' missing")
        return nil
    }
    return data
}()
