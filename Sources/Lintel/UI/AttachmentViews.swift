import SwiftUI
import UniformTypeIdentifiers

/// The images added to a message, as small thumbnails you can remove.
struct AttachmentStrip: View {
    @Binding var images: [URL]

    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(images, id: \.self) { url in
                        thumbnail(url)
                            .overlay(alignment: .topTrailing) {
                                Button { withAnimation(.easeOut(duration: 0.15)) { images.removeAll { $0 == url } } } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.onAction)
                                        .frame(width: 16, height: 16)
                                        .background(Circle().fill(Theme.action))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                                .help("Remove")
                            }
                            .help(url.lastPathComponent)
                    }
                }
                .padding(.top, 6).padding(.trailing, 6)
            }
            .scrollIndicators(.never)
            .transition(.opacity)
        }
    }

    private func thumbnail(_ url: URL) -> some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.fill)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

/// 📎 — pick images to send along.
struct AttachButton: View {
    @Binding var images: [URL]
    var size: CGFloat = 28

    var body: some View {
        Button {
            Attachments.pick { urls in withAnimation(.easeOut(duration: 0.15)) { add(urls) } }
        } label: { Image(systemName: "paperclip").font(.system(size: 13, weight: .semibold)) }
        .buttonStyle(IconButtonStyle(size: size))
        .help("Attach images (or drop / paste them)")
    }

    private func add(_ urls: [URL]) { for u in urls where !images.contains(u) { images.append(u) } }
}

extension View {
    /// Accepts dropped image files and ⌘V-pasted images into `images`.
    func acceptsImages(_ images: Binding<[URL]>) -> some View {
        let add: ([URL]) -> Void = { urls in
            withAnimation(.easeOut(duration: 0.15)) {
                for u in urls where Attachments.isImage(u) && !images.wrappedValue.contains(u) { images.wrappedValue.append(u) }
            }
        }
        return self
            .dropDestination(for: URL.self) { urls, _ in
                let ok = urls.filter(Attachments.isImage)
                add(ok)
                return !ok.isEmpty
            }
            .onReceive(NotificationCenter.default.publisher(for: .lintelPastedImages)) { note in
                add(note.object as? [URL] ?? [])
            }
    }
}
