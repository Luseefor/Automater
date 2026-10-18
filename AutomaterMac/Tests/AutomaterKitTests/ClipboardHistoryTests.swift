import XCTest
import AppKit
@testable import AutomaterKit

final class ClipboardHistoryTests: XCTestCase {
    func testDeduplicationPreservesPinsAndKeepsNewestFirst() {
        var history = ClipboardHistory()
        var first = ClipboardEntry(text: "First", copiedAt: Date(timeIntervalSince1970: 1)); first.isPinned = true
        history.insert(first); history.insert(ClipboardEntry(text: "Second"))
        history.insert(ClipboardEntry(text: "First", copiedAt: Date(timeIntervalSince1970: 3)))
        XCTAssertEqual(history.entries.count, 2)
        XCTAssertEqual(history.entries[0].text, "First")
        XCTAssertTrue(history.entries[0].isPinned)
    }
    func testRetentionDropsOldestUnpinnedAndClearCanKeepPins() {
        var history = ClipboardHistory()
        var pinned = ClipboardEntry(text: "Keep me"); pinned.isPinned = true; history.insert(pinned)
        for index in 0..<5 { history.insert(ClipboardEntry(text: "Item \(index)"), limit: 3) }
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertTrue(history.entries.contains { $0.id == pinned.id })
        history.clear(keepingPinned: true); XCTAssertEqual(history.entries.count, 1)
        history.clear(keepingPinned: false); XCTAssertTrue(history.entries.isEmpty)
    }
    @MainActor func testFiveCopiedItemsAreCapturedAndEachCanBeRestored() async throws {
        let fixture = ClipboardFixture()
        defer { fixture.clean() }
        for index in 1...5 {
            fixture.pasteboard.clearContents(); fixture.pasteboard.setString("Copied item \(index)", forType: .string)
            fixture.monitor.poll()
        }
        XCTAssertEqual(fixture.monitor.history.entries.map(\.text), (1...5).reversed().map { "Copied item \($0)" })
        for entry in fixture.monitor.history.entries {
            try fixture.monitor.copy(entry)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), entry.text)
            fixture.monitor.poll()
        }
        XCTAssertEqual(fixture.monitor.history.entries.count, 5)
        fixture.monitor.save()
        XCTAssertEqual(try fixture.repository.load().entries.count, 5)
    }
    @MainActor func testPauseAndConcealedClipboardItemsAreNotRecorded() async {
        let fixture = ClipboardFixture(); defer { fixture.clean() }
        fixture.monitor.isPaused = true
        fixture.pasteboard.clearContents(); fixture.pasteboard.setString("Paused copy", forType: .string); fixture.monitor.poll()
        XCTAssertTrue(fixture.monitor.history.entries.isEmpty)
        fixture.monitor.isPaused = false
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("Private value", forType: .string)
        fixture.pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        fixture.monitor.poll(); XCTAssertTrue(fixture.monitor.history.entries.isEmpty)
        fixture.pasteboard.clearContents(); fixture.pasteboard.setString("Visible copy", forType: .string); fixture.monitor.poll()
        XCTAssertEqual(fixture.monitor.history.entries.first?.text, "Visible copy")
    }
    @MainActor func testAutomaticPollingCapturesFiveSuccessiveCopies() async throws {
        let fixture = ClipboardFixture(automaticallyPoll: true); defer { fixture.clean() }
        for index in 1...5 {
            fixture.pasteboard.clearContents()
            fixture.pasteboard.setString("Automatic copy \(index)", forType: .string)
            try await Task.sleep(nanoseconds: 320_000_000)
        }
        XCTAssertEqual(fixture.monitor.history.entries.map(\.text), (1...5).reversed().map { "Automatic copy \($0)" })
    }
    @MainActor func testCopiedFilesAndImagesRoundTripWithoutTouchingSystemClipboard() async throws {
        let fixture = ClipboardFixture(); defer { fixture.clean() }
        let file = fixture.directory.appendingPathComponent("example.txt")
        fixture.pasteboard.clearContents(); fixture.pasteboard.writeObjects([file as NSURL]); fixture.monitor.poll()
        let files = try XCTUnwrap(fixture.monitor.history.entries.first)
        XCTAssertEqual(files.kind, .files); XCTAssertEqual(files.paths, [file.path])
        try fixture.monitor.copy(files)
        let copied = fixture.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(copied, [file])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        fixture.pasteboard.clearContents(); fixture.pasteboard.setData(png, forType: .png); fixture.monitor.poll()
        let image = try XCTUnwrap(fixture.monitor.history.entries.first)
        XCTAssertEqual(image.kind, .image)
        let imageURL = try XCTUnwrap(fixture.monitor.imageURL(for: image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        try fixture.monitor.copy(image); XCTAssertEqual(fixture.pasteboard.data(forType: .png), png)
        fixture.monitor.clear(keepingPinned: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }
    func testClipboardAssetPathsCannotEscapeRepository() {
        var entry = ClipboardEntry(kind: .image, imageData: Data([1, 2, 3]))
        entry.id = "../escape"; entry.imageFilename = "../escape.png"
        XCTAssertNil(ClipboardRepository().imageURL(for: entry))
    }
}

@MainActor private final class ClipboardFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "AutomaterClipboardTests." + UUID().uuidString
    let pasteboard = NSPasteboard(name: .init("AutomaterClipboardTests." + UUID().uuidString))
    let preferences: UserDefaults
    let repository: ClipboardRepository
    let monitor: ClipboardMonitor
    init(automaticallyPoll: Bool = false) {
        preferences = UserDefaults(suiteName: suite)!
        repository = ClipboardRepository(directory: directory)
        monitor = ClipboardMonitor(pasteboard: pasteboard, repository: repository, preferences: preferences, automaticallyPoll: automaticallyPoll)
    }
    func clean() {
        pasteboard.releaseGlobally(); preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
