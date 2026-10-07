import ImageIO
import PDFKit
import SwiftUI
import UIKit

/// One viewable page of a batch's source files: an image, or one page of a PDF.
struct IntakeViewerPage: Identifiable, Equatable, Sendable {
  var id: String
  /// Index into the job's `sourceFiles`, which proposals point at.
  var fileIndex: Int
  var url: URL
  var kind: InboxPayloadKind
  var pdfPage: Int
}

/// Decodes source pages off the main actor, to a pixel budget rather than a
/// long-edge cap so a tall screenshot stays readable when zoomed.
enum IntakeSourceImage {
  /// About ten megapixels per decoded page.
  static let pixelBudget: Double = 10_000_000

  /// Decodes one page in a detached task that is cancelled with the caller.
  static func load(_ page: IntakeViewerPage) async -> UIImage? {
    let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
      guard !Task.isCancelled else {
        return nil
      }
      switch page.kind {
      case .image: return downsampled(page.url)
      case .pdf: return renderPDFPage(url: page.url, index: page.pdfPage)
      case .text: return nil
      }
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static func pdfPageCount(_ url: URL) async -> Int {
    await Task.detached(priority: .userInitiated) {
      PDFDocument(url: url)?.pageCount ?? 0
    }.value
  }

  static func downsampled(_ url: URL) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      return nil
    }
    var maxPixel = 4096.0
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
       let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
       width > 0, height > 0 {
      let longEdge = max(width, height)
      maxPixel = width * height > pixelBudget ? longEdge * (pixelBudget / (width * height)).squareRoot() : longEdge
    }
    guard !Task.isCancelled else {
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

  /// Draws a PDF page onto white at scale 1, from its crop box and honouring
  /// the page's rotation, within the pixel budget.
  static func renderPDFPage(url: URL, index: Int) -> UIImage? {
    guard let document = PDFDocument(url: url),
          let page = document.page(at: index),
          let pageRef = page.pageRef else {
      return nil
    }
    let box = pageRef.getBoxRect(.cropBox)
    guard box.width > 0, box.height > 0 else {
      return nil
    }
    let turned = pageRef.rotationAngle % 180 != 0
    let natural = turned ? CGSize(width: box.height, height: box.width) : box.size
    let scale = (pixelBudget / Double(natural.width * natural.height)).squareRoot()
    let target = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    guard !Task.isCancelled else {
      return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let bounds = CGRect(origin: .zero, size: target)
    return UIGraphicsImageRenderer(size: target, format: format).image { context in
      UIColor.white.setFill()
      context.fill(bounds)
      let cgContext = context.cgContext
      cgContext.translateBy(x: 0, y: target.height)
      cgContext.scaleBy(x: 1, y: -1)
      cgContext.concatenate(pageRef.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
      cgContext.drawPDFPage(pageRef)
    }
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

  private static let maxDots = 10

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
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment:
          page = min(page + 1, pages.count - 1)
        case .decrement:
          page = max(page - 1, 0)
        @unknown default:
          break
        }
      }

      if isExpanded {
        TabView(selection: $page) {
          ForEach(pages.indices, id: \.self) { index in
            IntakeViewerPageView(
              page: pages[index],
              number: index + 1,
              total: pages.count,
              isNear: abs(index - page) <= 1
            )
            .tag(index)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: height)

        VStack(spacing: 4) {
          if pages.count > 1, pages.count <= Self.maxDots {
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
            Text("Swipe the pages to find each row’s source")
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

/// A page keeps its decoded image only while it is within one page of the
/// current one, and drops it when it leaves the screen.
private struct IntakeViewerPageView: View {
  let page: IntakeViewerPage
  let number: Int
  let total: Int
  let isNear: Bool
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
    .task(id: "\(page.id)-\(isNear)") {
      guard isNear else {
        image = nil
        return
      }
      guard image == nil else {
        return
      }
      let decoded = await IntakeSourceImage.load(page)
      guard !Task.isCancelled else {
        return
      }
      image = decoded
      failed = decoded == nil
    }
    .onDisappear {
      image = nil
      failed = false
    }
  }
}

/// Pinch to zoom, drag while zoomed, double tap to zoom in or reset. Dragging
/// is only a gesture of this view while zoomed in, so a pan never pages the
/// viewer, and it is limited to the letterboxed image.
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
        .gesture(
          DragGesture()
            .onChanged { value in
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
            },
          including: scale > 1 ? .all : .subviews
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

  /// The image as drawn at scale 1, letterboxed inside `size`.
  private func fitted(in size: CGSize) -> CGSize {
    guard image.size.width > 0, image.size.height > 0 else {
      return size
    }
    let ratio = min(size.width / image.size.width, size.height / image.size.height)
    return CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
  }

  /// Keeps the zoomed image from being dragged past its own edges: a side
  /// that still fits inside the frame does not move.
  private func clamped(_ value: CGSize, in size: CGSize) -> CGSize {
    let fit = fitted(in: size)
    let limitX = max(0, (fit.width * scale - size.width) / 2)
    let limitY = max(0, (fit.height * scale - size.height) / 2)
    return CGSize(
      width: min(max(value.width, -limitX), limitX),
      height: min(max(value.height, -limitY), limitY)
    )
  }
}
