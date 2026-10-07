import ImageIO
import PDFKit
import SwiftUI
import UIKit

/// One viewable page of a batch's source files: an image, or one page of a PDF.
struct IntakeViewerPage: Identifiable, Equatable {
  var id: String
  /// Index into the job's `sourceFiles`, which proposals point at.
  var fileIndex: Int
  var url: URL
  var kind: InboxPayloadKind
  var pdfPage: Int
}

/// Decodes source pages at a size the viewer can zoom into without holding a
/// full-resolution screenshot in memory.
enum IntakeSourceImage {
  static let maxPixel: CGFloat = 2400

  static func downsampled(_ url: URL, maxPixel: CGFloat = maxPixel) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: image)
  }

  static func pdfPage(url: URL, index: Int, maxPixel: CGFloat = maxPixel) -> UIImage? {
    guard let document = PDFDocument(url: url), let page = document.page(at: index) else {
      return nil
    }
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else {
      return nil
    }
    let scale = maxPixel / max(bounds.width, bounds.height)
    return page.thumbnail(
      of: CGSize(width: bounds.width * scale, height: bounds.height * scale),
      for: .mediaBox
    )
  }
}

/// The collapsible source viewer at the top of the batch review: swipe between
/// pages, pinch to zoom, page dots. It shows the files as shared; it does not
/// outline rows on them yet.
struct IntakeDocumentViewer: View {
  let pages: [IntakeViewerPage]
  @Binding var page: Int
  @Binding var isExpanded: Bool
  /// Height of the pages themselves when expanded.
  let height: CGFloat
  var showsHint = true
  var onToggle: () -> Void = {}

  var body: some View {
    VStack(spacing: 0) {
      Button(action: onToggle) {
        HStack(spacing: 8) {
          Image(systemName: "doc.text.image")
            .foregroundStyle(Theme.accent)
            .accessibilityHidden(true)
          Text("Original")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
          if pages.count > 1 {
            Text("Page \(page + 1) of \(pages.count)")
              .font(.subheadline)
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          Image(systemName: "chevron.down")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isExpanded ? "Hide original" : "Show original")
      .accessibilityValue(pages.count > 1 ? "Page \(page + 1) of \(pages.count)" : "")

      if isExpanded {
        TabView(selection: $page) {
          ForEach(pages.indices, id: \.self) { index in
            IntakeViewerPageView(page: pages[index], number: index + 1, total: pages.count)
              .tag(index)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)

        VStack(spacing: 4) {
          if pages.count > 1 {
            HStack(spacing: 6) {
              ForEach(pages.indices, id: \.self) { index in
                Circle()
                  .fill(index == page ? Theme.accent : Color.secondary.opacity(0.35))
                  .frame(width: 7, height: 7)
              }
            }
            .accessibilityHidden(true)
          }
          if showsHint {
            Text("Tap a row to see where it came from")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
      }
    }
    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
  }
}

private struct IntakeViewerPageView: View {
  let page: IntakeViewerPage
  let number: Int
  let total: Int
  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      if let image {
        IntakeZoomableImage(image: image)
          .accessibilityLabel(total > 1 ? "Original, page \(number) of \(total)" : "Original")
          .accessibilityAddTraits(.isImage)
      } else if failed {
        Label("Couldn’t show this page", systemImage: "exclamationmark.triangle")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding()
      } else {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: page.id) {
      await load()
    }
  }

  private func load() async {
    let url = page.url
    switch page.kind {
    case .image:
      image = await Task.detached(priority: .userInitiated) {
        IntakeSourceImage.downsampled(url)
      }.value
    case .pdf:
      image = IntakeSourceImage.pdfPage(url: url, index: page.pdfPage)
    case .text:
      image = nil
    }
    failed = image == nil
  }
}

/// Pinch to zoom, drag while zoomed, double tap to zoom in or reset. Zoom
/// resets by double tap, so Reduce Motion needs no animation here.
private struct IntakeZoomableImage: View {
  let image: UIImage
  @State private var scale: CGFloat = 1
  @State private var committedScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var committedOffset: CGSize = .zero

  private static let maxScale: CGFloat = 5

  var body: some View {
    GeometryReader { proxy in
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: proxy.size.width, height: proxy.size.height)
        .scaleEffect(scale)
        .offset(offset)
        .gesture(
          MagnifyGesture()
            .onChanged { value in
              scale = min(max(committedScale * value.magnification, 1), Self.maxScale)
              offset = clamped(committedOffset, in: proxy.size)
            }
            .onEnded { _ in
              committedScale = scale
              if scale <= 1.01 {
                reset()
              } else {
                committedOffset = clamped(offset, in: proxy.size)
                offset = committedOffset
              }
            }
        )
        .simultaneousGesture(
          DragGesture()
            .onChanged { value in
              guard scale > 1 else {
                return
              }
              offset = clamped(
                CGSize(
                  width: committedOffset.width + value.translation.width,
                  height: committedOffset.height + value.translation.height
                ),
                in: proxy.size
              )
            }
            .onEnded { _ in
              committedOffset = offset
            }
        )
        .onTapGesture(count: 2) {
          if scale > 1 {
            reset()
          } else {
            scale = 2.5
            committedScale = 2.5
          }
        }
    }
    .clipped()
  }

  private func reset() {
    scale = 1
    committedScale = 1
    offset = .zero
    committedOffset = .zero
  }

  /// Keeps the zoomed image from being dragged off its own edges.
  private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
    let limitX = max(0, size.width * (scale - 1) / 2)
    let limitY = max(0, size.height * (scale - 1) / 2)
    return CGSize(
      width: min(max(value.width, -limitX), limitX),
      height: min(max(value.height, -limitY), limitY)
    )
  }
}
