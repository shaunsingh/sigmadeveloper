import SwiftUI

struct LibraryCard: View {
    let item: LibraryItem
    let thumbnail: CGImage?

    var body: some View {
        Rectangle()
            .fill(SigmaTheme.surface)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Color.clear.overlay(alignment: .top) {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}
