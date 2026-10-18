import XCTest
import AppKit
@testable import AutomaterKit

/// Clipboard auto-cleanup coverage: count limit excludes pins, age expiry
/// boundary, paused idle cleanup, load-time pruning, preference round-trip,
/// selection fallback, expired image-asset pruning, unpin policy.
/// Isolation: named pasteboards, temp repositories, suite UserDefaults only.
final class ClipboardRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func text(_ value: String, age: TimeInterval = 0, pinned: Bool = false) -> ClipboardEntry {
        var entry = ClipboardEntry(text: value, copiedAt: now.addingTimeInterval(-age))
        entry.isPinned = pinned
        return entry
    }

    // MARK: - History semantics

    func testLimitCountsUnpinnedOnlyAndPinsNeverDrop() {
        var history = ClipboardHistory()
        history.entries = [
            text("new1"), text("new2"),
            text("old-pin", age: 10_000, pinned: true),
            text("old1", age: 100), text("old2", age: 200), text("old3", age: 300),
            text("pinned2", age: 20_000, pinned: true),
        ]
        history.applyRetention(limit: 3)
        XCTAssertEqual(history.entries.count, 5)
        XCTAssertTrue(history.entries.contains { $0.text == "old-pin" && $0.isPinned })
        XCTAssertTrue(history.entries.contains { $0.text == "pinned2" && $0.isPinned })
        XCTAssertEqual(Set(history.entries.filter { !$0.isPinned }.map(\.text)),
                       ["new1", "new2", "old1"])
    }

    func testAgeBoundaryDropsExpiredUnpinnedButKeepsPinned() {
        var history = ClipboardHistory()
        let boundary = text("boundary", age: 900)
        let fresh = text("fresh", age: 899)
        var pinned = text("pinned-old", age: 10_000); pinned.isPinned = true
        history.entries = [boundary, fresh, pinned]
        history.applyRetention(limit: 100, maxAge: 900, now: now)
        XCTAssertEqual(Set(history.entries.map(\.text)), ["fresh", "pinned-old"])
    }

    func testExpirationNeverKeepsEverythingWithinLimit() {
        var history = ClipboardHistory()
        history.entries = [text("a", age: 10_000_000), text("b", age: 20_000_000)]
        history.applyRetention(limit: 100, maxAge: nil, now: now)
        XCTAssertEqual(history.entries.count, 2)
    }

    func testInsertTrimsToLimitExcludingPins() {
        var history = ClipboardHistory()
        var pinned = ClipboardEntry(text: "pin"); pinned.isPinned = true
        history.insert(pinned)
        for index in 0..<5 { history.insert(ClipboardEntry(text: "Item \(index)"), limit: 3) }
        XCTAssertEqual(history.entries.count, 4)
        XCTAssertTrue(history.entries.contains { $0.id == pinned.id })
    }

    func testExpirationRawValuesAndMaxAge() {
        XCTAssertEqual(ClipboardExpiration.allCases.map(\.rawValue),
                       [0, 900, 3600, 86400, 604800, 2592000])
        XCTAssertNil(ClipboardExpiration.never.maxAge)
        XCTAssertEqual(ClipboardExpiration.fifteenMinutes.maxAge, 900)
        XCTAssertEqual(ClipboardExpiration.thirtyDays.maxAge, 2_592_000)
    }

    // MARK: - Monitor behavior

    @MainActor func testPausedIdleCleanupPrunesExpiredWithoutNewCopy() async {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        monitor.expiration = .fifteenMinutes
        monitor.history = ClipboardHistory(entries: [
            text("old", age: 3600), text("fresh", age: 60),
        ])
        monitor.isPaused = true
        fixture.pasteboard.clearContents()
        monitor.poll()
        XCTAssertEqual(monitor.history.entries.map(\.text), ["fresh"])
    }

    @MainActor func testInitPrunesLoadedHistoryWithConfiguredPolicy() async throws {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        fixture.preferences.set(2, forKey: "clipboard.limit")
        fixture.preferences.set(ClipboardExpiration.fifteenMinutes.rawValue, forKey: "clipboard.expiration")
        try fixture.repository.save(ClipboardHistory(entries: [
            text("expired1", age: 3600), text("expired2", age: 7200),
            text("fresh1", age: 60), text("fresh2", age: 120), text("fresh3", age: 180),
        ]))
        let monitor = fixture.makeMonitor()
        XCTAssertEqual(Set(monitor.history.entries.map(\.text)), ["fresh1", "fresh2"])
        XCTAssertEqual(try fixture.repository.load().entries.count, 2)
    }

    @MainActor func testPreferenceRoundTripAndClamping() async {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        XCTAssertEqual(monitor.limit, 100)
        XCTAssertEqual(monitor.expiration, .never)
        monitor.limit = 5
        monitor.expiration = .oneHour
        XCTAssertEqual(fixture.preferences.integer(forKey: "clipboard.limit"), 5)
        XCTAssertEqual(fixture.preferences.integer(forKey: "clipboard.expiration"), 3600)
        monitor.limit = 0
        XCTAssertEqual(monitor.limit, 1)
        monitor.limit = 5000
        XCTAssertEqual(monitor.limit, 1000)
        let reloaded = fixture.makeMonitor()
        XCTAssertEqual(reloaded.limit, 1000)
        XCTAssertEqual(reloaded.expiration, .oneHour)
        fixture.preferences.set(12345, forKey: "clipboard.expiration")
        XCTAssertEqual(fixture.makeMonitor().expiration, .never)
    }

    @MainActor func testChangingPreferencesAppliesImmediately() async {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        monitor.history = ClipboardHistory(entries: (0..<5).map { text("Item \($0)", age: TimeInterval($0)) })
        monitor.limit = 2
        XCTAssertEqual(monitor.history.entries.count, 2)
        monitor.history = ClipboardHistory(entries: [
            text("old", age: 3600), text("fresh", age: 60),
        ])
        monitor.expiration = .fifteenMinutes
        XCTAssertEqual(monitor.history.entries.map(\.text), ["fresh"])
    }

    @MainActor func testSelectionFallsBackWhenSelectedEntryExpires() async {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        let entries = [text("new1"), text("mid1", age: 60), text("old1", age: 3600)]
        monitor.history = ClipboardHistory(entries: entries)
        monitor.selectedID = entries[2].id
        monitor.expiration = .fifteenMinutes
        XCTAssertEqual(monitor.selectedID, entries[0].id)
    }

    @MainActor func testSelectionBecomesNilWhenEverythingExpires() async {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        let entries = [text("old1", age: 3600)]
        monitor.history = ClipboardHistory(entries: entries)
        monitor.selectedID = entries[0].id
        monitor.expiration = .fifteenMinutes
        XCTAssertTrue(monitor.history.entries.isEmpty)
        XCTAssertNil(monitor.selectedID)
    }

    @MainActor func testExpiredImageEntryPrunesItsAsset() async throws {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?.representation(using: .png, properties: [:]))
        let image = ClipboardEntry(kind: .image, imageData: png, copiedAt: now.addingTimeInterval(-3600))
        try fixture.repository.saveImage(png, for: image)
        let asset = try XCTUnwrap(fixture.repository.imageURL(for: image))
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.path))
        monitor.history = ClipboardHistory(entries: [image, text("fresh", age: 60)])
        monitor.expiration = .fifteenMinutes
        XCTAssertEqual(monitor.history.entries.map(\.text), ["fresh"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path))
    }

    @MainActor func testUnpinAppliesPolicyImmediately() async {
        let fixture = RetentionFixture(now: now)
        defer { fixture.clean() }
        let monitor = fixture.makeMonitor()
        monitor.limit = 2
        let entries = [text("new1"), text("new2"), text("old", age: 300, pinned: true)]
        monitor.history = ClipboardHistory(entries: entries)
        XCTAssertEqual(monitor.history.entries.count, 3)
        monitor.togglePin(entries[2])
        XCTAssertFalse(monitor.history.entries.contains { $0.text == "old" })
        XCTAssertEqual(monitor.history.entries.count, 2)
    }
}

@MainActor private final class RetentionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "AutomaterClipboardRetentionTests." + UUID().uuidString
    let pasteboard = NSPasteboard(name: .init("AutomaterClipboardRetentionTests." + UUID().uuidString))
    let preferences: UserDefaults
    let repository: ClipboardRepository
    let now: Date
    init(now: Date) {
        self.now = now
        preferences = UserDefaults(suiteName: suite)!
        repository = ClipboardRepository(directory: directory)
    }
    func makeMonitor() -> ClipboardMonitor {
        ClipboardMonitor(pasteboard: pasteboard, repository: repository,
                         preferences: preferences, automaticallyPoll: false, now: { self.now })
    }
    func clean() {
        pasteboard.releaseGlobally()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
