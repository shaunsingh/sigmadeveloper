import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

/// Wraps `UIActivityViewController` so developed files can be saved to Files,
/// shared, AirDropped, or added to Photos.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

extension View {
    /// Hand developed files to the user: the share sheet on iOS, the native
    /// save panel on macOS (exports live in the session temp dir, so a move
    /// is the correct disposition — cancelling just leaves them there).
    @ViewBuilder
    func exportPresenter(isPresented: Binding<Bool>, items: [URL],
                         onError: @escaping (Error) -> Void) -> some View {
        #if os(iOS)
        sheet(isPresented: isPresented) { ShareSheet(items: items) }
        #elseif os(macOS)
        fileMover(isPresented: isPresented, files: items) { result in
            if case .failure(let error) = result { onError(error) }
        }
        #endif
    }
}

enum ImportTypes {
    /// File importer / open panel content types.
    /// Photos, RAW/X3F, TIFF, and folders — never video (unsupported).
    static let content: [UTType] = {
        var types: [UTType] = [.folder, .image, .rawImage, .tiff, .data]
        if let x3f = UTType(filenameExtension: "x3f") { types.insert(x3f, at: 0) }
        return types
    }()
}
