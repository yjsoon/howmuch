import XCTest
import UIKit
import ImageIO
@testable import HowMuch

final class InboxStoreTests: XCTestCase {
  private var directory: URL!
  private var store: InboxStore!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    store = InboxStore(container: directory)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testPreviewDownsamplesToDisplayPixelBoundAndPreservesOriginal() async throws {
    let data = try previewJPEG(width: 1200, height: 600)
    let item = try previewItem(data: data)
    for scale in [CGFloat(1), CGFloat(2), CGFloat(3)] {
      let result = try await InboxPreview.firstThumbnail(in: [item], displayScale: scale)
      let image = try XCTUnwrap(result)
      let bitmap = try XCTUnwrap(image.cgImage)
      XCTAssertEqual(bitmap.width, Int(168 * scale))
      XCTAssertEqual(bitmap.height, Int(84 * scale))
      XCTAssertEqual(image.scale, scale)
      XCTAssertEqual(image.imageOrientation, .up)
    }
    XCTAssertEqual(try item.payloadData(), data, "Preview must not replace the OCR payload")
    XCTAssertEqual(store.loadReading().map(\.id), [item.id])
  }

  func testPreviewAppliesEXIFRotationToBitmap() async throws {
    let item = try previewItem(data: previewJPEG(width: 1200, height: 600, orientation: 6))
    let result = try await InboxPreview.firstThumbnail(in: [item], displayScale: 2)
    let image = try XCTUnwrap(result)
    let bitmap = try XCTUnwrap(image.cgImage)
    XCTAssertEqual(bitmap.width, 168)
    XCTAssertEqual(bitmap.height, 336)
    XCTAssertEqual(image.imageOrientation, .up, "EXIF rotation must be baked into the thumbnail")
  }

  func testPreviewAppliesEXIFMirroringToPixels() async throws {
    let item = try previewItem(data: previewJPEG(width: 1200, height: 600, orientation: 2))
    let result = try await InboxPreview.firstThumbnail(in: [item], displayScale: 1)
    let bitmap = try XCTUnwrap(result?.cgImage)
    let context = try bitmapContext(width: bitmap.width, height: bitmap.height)
    context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
    let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let left = (bitmap.height / 2 * bitmap.width + bitmap.width / 4) * 4
    let right = (bitmap.height / 2 * bitmap.width + bitmap.width * 3 / 4) * 4
    XCTAssertGreaterThan(pixels[left + 2], pixels[left], "Mirrored left half should be blue")
    XCTAssertGreaterThan(pixels[right], pixels[right + 2], "Mirrored right half should be red")
  }

  func testPreviewSkipsTextAndCorruptImagesAndReturnsFirstUsableImageWithoutUpscaling() async throws {
    let text = try previewItem(data: previewJPEG(width: 80, height: 40), kind: .text)
    let corrupt = try previewItem(data: Data("not an image".utf8))
    let first = try previewItem(data: previewJPEG(width: 48, height: 24))
    let later = try previewItem(data: previewJPEG(width: 100, height: 200))
    let result = try await InboxPreview.firstThumbnail(
      in: [text, corrupt, first, later], displayScale: 3
    )
    let bitmap = try XCTUnwrap(result?.cgImage)
    XCTAssertEqual(bitmap.width, 48)
    XCTAssertEqual(bitmap.height, 24)
    let missing = try await InboxPreview.firstThumbnail(in: [text, corrupt], displayScale: 3)
    XCTAssertNil(missing)
  }

  func testCancelledPreviewThrowsAndKeepsReadingPayloadRecoverable() async throws {
    let data = try previewJPEG(width: 1200, height: 600)
    let item = try previewItem(data: data)
    let task = Task {
      // Cancel before entry deterministically, without timing sleeps or a production test hook.
      withUnsafeCurrentTask { $0?.cancel() }
      return try await InboxPreview.firstThumbnail(in: [item], displayScale: 3)
    }
    do {
      _ = try await task.value
      XCTFail("A cancelled preview must not deliver an image")
    } catch is CancellationError {
      // Expected.
    }
    XCTAssertEqual(store.loadReading().map(\.id), [item.id])
    XCTAssertEqual(try item.payloadData(), data)
    let recovered = try await InboxPreview.firstThumbnail(in: store.loadReading(), displayScale: 3)
    XCTAssertNotNil(recovered)
  }

  private func previewItem(data: Data, kind: InboxPayloadKind = .image) throws -> InboxItem {
    let id = UUID()
    try store.write(InboxWrite(
      id: id, source: .shareSheet, kind: kind, filename: "payload.jpg", data: data
    ))
    return try XCTUnwrap(try store.claim(id))
  }

  private func bitmapContext(width: Int, height: Int) throws -> CGContext {
    try XCTUnwrap(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    ))
  }

  private func previewJPEG(width: Int, height: Int, orientation: Int = 1) throws -> Data {
    let context = try bitmapContext(width: width, height: height)
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  func testWriteUsesPartialThenRename() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: Data("5 of Groceries on Everyday".utf8)
      )
    )
    let ready = store.inboxDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    let partial = store.inboxDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(store.hasReadyInboxItems())
    XCTAssertFalse(store.hasReadingItems())
  }

  func testClaimMovesInboxToReading() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: Data("12 coffee".utf8)
      )
    )
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.map(\.id), [id])
    XCTAssertEqual(claimed.first?.source, .shareSheet)
    XCTAssertEqual(claimed.first?.payloadText(), "12 coffee")
    XCTAssertFalse(store.hasReadyInboxItems())
    XCTAssertTrue(store.hasReadingItems())
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: store.readingDirectory.appendingPathComponent(id.uuidString).path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent(id.uuidString).path
      )
    )
  }

  func testSecondClaimOfTheSameIDIsANoOp() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .shareSheet,
        kind: .text,
        filename: "payload.txt",
        data: Data("5 groceries".utf8)
      )
    )
    XCTAssertEqual(try store.claim(id)?.id, id)
    XCTAssertNil(try store.claim(id))
    XCTAssertEqual(try store.claimInbox(), [])
    XCTAssertEqual(store.loadReading().map(\.id), [id])
  }

  func testClaimSkipsPartialDirectories() throws {
    let id = UUID()
    let partial = store.inboxDirectory.appendingPathComponent("\(id.uuidString).partial", isDirectory: true)
    try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
    try Data("incomplete".utf8).write(to: partial.appendingPathComponent("payload.txt"))
    XCTAssertEqual(try store.claimInbox(), [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertFalse(store.hasReadingItems())
  }

  func testOversizedPayloadIsRejectedAndLeavesNoPartial() {
    let id = UUID()
    let data = Data(repeating: 0x61, count: InboxStore.maxPayloadBytes + 1)
    XCTAssertThrowsError(
      try store.write(
        InboxWrite(
          id: id,
          source: .shareSheet,
          kind: .image,
          filename: "payload.jpg",
          data: data
        )
      )
    ) { error in
      XCTAssertEqual(error as? InboxStoreError, .payloadTooLarge)
    }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent(id.uuidString).path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent("\(id.uuidString).partial").path
      )
    )
  }

  func testAppIntentAndScreenshotSourcesAreRepresentable() throws {
    try store.write(
      InboxWrite(
        source: .appIntent,
        kind: .text,
        filename: "payload.txt",
        data: Data("intent".utf8)
      )
    )
    try store.write(
      InboxWrite(
        source: .detectedScreenshot,
        kind: .image,
        filename: "payload.png",
        data: Data([0x89, 0x50, 0x4E, 0x47])
      )
    )
    let claimed = try store.claimInbox()
    XCTAssertEqual(Set(claimed.map(\.source)), [.appIntent, .detectedScreenshot])
  }

  func testSanitizedFilenameRejectsManifestCollisionAndEmpty() {
    XCTAssertEqual(InboxStore.sanitizedFilename("payload.png"), "payload.png")
    XCTAssertEqual(InboxStore.sanitizedFilename("manifest.json"), "payload.bin")
    XCTAssertEqual(InboxStore.sanitizedFilename("../manifest.json"), "payload.bin")
    XCTAssertEqual(InboxStore.sanitizedFilename(".."), "payload.bin")
    XCTAssertEqual(InboxStore.sanitizedFilename(".hidden"), "payload.bin")
    XCTAssertEqual(InboxStore.sanitizedFilename(""), "payload.bin")
    XCTAssertEqual(InboxStore.sanitizedFilename("a/b/c.txt"), "c.txt")
    XCTAssertEqual(InboxStore.sanitizedFilename("../evil.png"), "evil.png")
  }

  func testWriteDoesNotLetPayloadFilenameClobberManifest() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .appIntent,
        kind: .image,
        filename: "manifest.json",
        data: Data("photo".utf8)
      )
    )
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.first?.filename, "payload.bin")
    XCTAssertEqual(try claimed.first?.payloadData(), Data("photo".utf8))
    XCTAssertEqual(claimed.first?.source, .appIntent)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: store.readingDirectory
          .appendingPathComponent(id.uuidString)
          .appendingPathComponent("manifest.json").path
      )
    )
  }

  func testWriteKeepsTraversalInsideTheItemDirectory() throws {
    let id = UUID()
    try store.write(
      InboxWrite(
        id: id,
        source: .appIntent,
        kind: .image,
        filename: "../evil.png",
        data: Data("photo".utf8)
      )
    )
    let claimed = try XCTUnwrap(try store.claim(id))
    XCTAssertEqual(claimed.filename, "evil.png")
    XCTAssertEqual(try claimed.payloadData(), Data("photo".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.inboxDirectory.appendingPathComponent("evil.png").path
      )
    )
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: store.readingDirectory.appendingPathComponent("evil.png").path
      )
    )
  }

  // Failure mode: manifests already on disk from an older app or extension build
  // (v1 shape, or a newer build's extra keys) must still load. E2E cannot plant these.
  func testV1ManifestOnDiskLoadsAsOneAutoSource() throws {
    let id = UUID()
    let folder = try plantManifest(id: id, json: """
      {"id":"\(id.uuidString)","source":"shareSheet","kind":"image",
       "filename":"payload.png","createdAt":"2026-01-01T00:00:00Z"}
      """, files: ["payload.png": Data([1, 2, 3])])
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    let item = try XCTUnwrap(try store.claim(id))
    XCTAssertEqual(item.sources.map(\.filename), ["payload.png"])
    XCTAssertEqual(item.sources.map(\.kind), [.image])
    XCTAssertEqual(item.kind, .image)
    XCTAssertEqual(item.hint, .auto)
    XCTAssertNil(item.accountID)
    XCTAssertFalse(item.decideAccount)
    XCTAssertNil(item.note)
    XCTAssertEqual(try item.payloadData(), Data([1, 2, 3]))
  }

  func testV2ManifestWithUnknownFutureKeyStillLoads() throws {
    let id = UUID()
    try plantManifest(id: id, json: """
      {"version":2,"id":"\(id.uuidString)","source":"shareSheet",
       "sources":[{"filename":"a.pdf","kind":"pdf","bytes":3,"sha256":null,"future":1}],
       "accountID":"acct-1","decideAccount":false,"hint":"fix","note":"hello",
       "createdAt":"2026-01-01T00:00:00Z","somethingNew":{"nested":[1,2]}}
      """, files: ["a.pdf": Data([1, 2, 3])])
    let item = try XCTUnwrap(try store.claim(id))
    XCTAssertEqual(item.sources.map(\.kind), [.pdf])
    XCTAssertEqual(item.accountID, "acct-1")
    XCTAssertEqual(item.hint, .fix)
    XCTAssertEqual(item.note, "hello")
  }

  func testMultiSourceWriteRoundTripsOrderAccountHintAndNote() throws {
    let id = UUID()
    let names = ["b.png", "a.png", "c.pdf"]
    let kinds: [InboxPayloadKind] = [.image, .image, .pdf]
    var sources: [InboxFileSource] = []
    for (name, kind) in zip(names, kinds) {
      let url = directory.appendingPathComponent("tmp-\(name)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(name.utf8).write(to: url)
      sources.append(InboxFileSource(filename: name, kind: kind, fileURL: url, sha256: "hash-\(name)"))
    }
    try store.write(InboxFileWrite(
      id: id,
      source: .shareSheet,
      sources: sources,
      accountID: "acct-9",
      decideAccount: false,
      hint: .new,
      note: "Grab, split with Sam",
      contentHash: "abc"
    ))
    let item = try XCTUnwrap(try store.claim(id))
    XCTAssertEqual(item.sources.map(\.filename), names)
    XCTAssertEqual(item.sources.map(\.kind), kinds)
    XCTAssertEqual(item.sources.map(\.sha256), names.map { Optional("hash-\($0)") })
    XCTAssertEqual(item.sources.map(\.bytes), names.map { $0.utf8.count })
    XCTAssertEqual(item.accountID, "acct-9")
    XCTAssertEqual(item.hint, .new)
    XCTAssertEqual(item.note, "Grab, split with Sam")
    XCTAssertEqual(item.contentHash, "abc")
    XCTAssertEqual(try Data(contentsOf: item.payloadURL(for: item.sources[2])), Data("c.pdf".utf8))
  }

  // Failure mode: a manifest from a newer build with a source kind this build does not know,
  // or one that cannot be decoded at all, must not strand the whole job or sit in Reading forever.
  func testUnknownSourceKindIsSkippedAndUndecodableManifestIsQuarantined() throws {
    let good = UUID()
    try plantManifest(id: good, json: """
      {"version":2,"id":"\(good.uuidString)","source":"somethingNew",
       "sources":[{"filename":"clip.mov","kind":"video","bytes":1},
                  {"filename":"a.png","kind":"image","bytes":3}],
       "createdAt":"2026-01-01T00:00:00Z"}
      """, files: ["a.png": Data([1, 2, 3]), "clip.mov": Data([9])])
    let bad = UUID()
    try plantManifest(id: bad, json: "not json at all", files: ["a.png": Data([1])])
    let claimed = try store.claimInbox()
    XCTAssertEqual(claimed.map(\.id), [good])
    XCTAssertEqual(claimed.first?.sources.map(\.filename), ["a.png"])
    XCTAssertEqual(store.loadReading().map(\.id), [good])
    store.discardReading(good)
    XCTAssertFalse(store.hasReadingItems())
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: store.quarantineDirectory.appendingPathComponent(bad.uuidString).path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: store.readingDirectory.appendingPathComponent(bad.uuidString).path
    ))
  }

  @discardableResult
  private func plantManifest(id: UUID, json: String, files: [String: Data]) throws -> URL {
    let folder = store.inboxDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: folder.appendingPathComponent("manifest.json"))
    for (name, data) in files {
      try data.write(to: folder.appendingPathComponent(name))
    }
    return folder
  }
}
