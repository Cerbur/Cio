//
//  DownloadManagerTests.swift
//  NativeBrowserTests
//
//  CEF-free tests for download state and destination policy.
//

import XCTest

@MainActor
final class DownloadManagerTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("NativeBrowserDownloadTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory {
      try? FileManager.default.removeItem(at: directory)
    }
    try super.tearDownWithError()
  }

  private func manager() -> DownloadManager {
    DownloadManager(downloadsDirectory: directory)
  }

  private var sourceURL: URL { URL(string: "http://127.0.0.1:43123/download")! }

  func testSafeFilenameIsPreserved() {
    XCTAssertEqual(DownloadManager.sanitizedFileName("report.pdf"), "report.pdf")
  }

  func testPathTraversalIsSanitized() {
    let name = DownloadManager.sanitizedFileName("../escape/report.pdf")
    XCTAssertFalse(name.contains("/"))
    XCTAssertFalse(name.contains("\\"))
    XCTAssertEqual(name, ".._escape_report.pdf")
  }

  func testAbsolutePathSuggestionIsSanitized() {
    let name = DownloadManager.sanitizedFileName("/private/tmp/report.pdf")
    XCTAssertFalse(name.hasPrefix("/"))
    XCTAssertFalse(name.contains("/"))
  }

  func testSlashBackslashAndControlCharactersAreHandled() {
    let name = DownloadManager.sanitizedFileName("a/b\\c\u{0000}d.bin")
    XCTAssertEqual(name, "a_b_cd.bin")
    XCTAssertFalse(name.unicodeScalars.contains { $0.value < 0x20 })
  }

  func testEmptySuggestionGetsFallback() {
    XCTAssertEqual(DownloadManager.sanitizedFileName("\n\t"), "download")
    XCTAssertEqual(DownloadManager.sanitizedFileName(".."), "download")
  }

  func testExistingFilenameGetsUniqueDestination() throws {
    let firstManager = manager()
    let first = try XCTUnwrap(firstManager.prepareDownload(
      downloadID: 1, sourceURL: sourceURL, suggestedFileName: "report.pdf"))
    FileManager.default.createFile(atPath: first.path, contents: Data([1]))
    let secondManager = manager()
    let second = try XCTUnwrap(secondManager.prepareDownload(
      downloadID: 2, sourceURL: sourceURL, suggestedFileName: "report.pdf"))
    XCTAssertEqual(second.lastPathComponent, "report (1).pdf")
  }

  func testReservedFilenameGetsUniqueDestinationBeforeFirstFileExists() throws {
    let manager = manager()
    let first = try XCTUnwrap(manager.prepareDownload(
      downloadID: 10, sourceURL: sourceURL, suggestedFileName: "report.pdf"))
    let second = try XCTUnwrap(manager.prepareDownload(
      downloadID: 11, sourceURL: sourceURL, suggestedFileName: "report.pdf"))
    XCTAssertEqual(first.lastPathComponent, "report.pdf")
    XCTAssertEqual(second.lastPathComponent, "report (1).pdf")
  }

  func testDestinationRemainsInsideConfiguredDirectory() throws {
    let manager = manager()
    let destination = try XCTUnwrap(manager.prepareDownload(
      downloadID: 3, sourceURL: sourceURL, suggestedFileName: "/../../escape.bin"))
    let root = directory.standardizedFileURL.path + "/"
    XCTAssertTrue(destination.standardizedFileURL.path.hasPrefix(root))
  }

  func testPendingThenDownloadingProgressUpdates() throws {
    let manager = manager()
    _ = manager.prepareDownload(downloadID: 4, sourceURL: sourceURL, suggestedFileName: "fixture.bin")
    manager.update(
      downloadID: 4,
      sourceURL: sourceURL,
      suggestedFileName: "fixture.bin",
      destinationURL: nil,
      receivedBytes: 20,
      totalBytes: 100,
      isInProgress: true,
      isComplete: false,
      isCancelled: false,
      isInterrupted: false)
    let item = try XCTUnwrap(manager.items.first)
    XCTAssertEqual(item.state, .downloading)
    XCTAssertEqual(item.receivedBytes, 20)
    XCTAssertEqual(item.totalBytes, 100)
    XCTAssertEqual(item.progress, 0.2)
  }

  func testUnknownTotalIsIndeterminate() throws {
    let manager = manager()
    manager.update(
      downloadID: 5,
      sourceURL: sourceURL,
      suggestedFileName: "stream.bin",
      destinationURL: nil,
      receivedBytes: 20,
      totalBytes: nil,
      isInProgress: true,
      isComplete: false,
      isCancelled: false,
      isInterrupted: false)
    let item = try XCTUnwrap(manager.items.first)
    XCTAssertNil(item.totalBytes)
    XCTAssertNil(item.progress)
  }

  func testCompletedStateStoresDestination() throws {
    let manager = manager()
    let destination = try XCTUnwrap(manager.prepareDownload(
      downloadID: 6, sourceURL: sourceURL, suggestedFileName: "done.bin"))
    manager.update(
      downloadID: 6,
      sourceURL: sourceURL,
      suggestedFileName: "done.bin",
      destinationURL: destination,
      receivedBytes: 4,
      totalBytes: 4,
      isInProgress: false,
      isComplete: true,
      isCancelled: false,
      isInterrupted: false)
    let item = try XCTUnwrap(manager.items.first)
    XCTAssertEqual(item.state, .completed)
    XCTAssertEqual(item.destinationURL, destination)
    XCTAssertNotNil(item.finishedAt)
  }

  func testCancelledState() throws {
    let manager = manager()
    manager.update(
      downloadID: 7,
      sourceURL: sourceURL,
      suggestedFileName: "cancelled.bin",
      destinationURL: nil,
      receivedBytes: 2,
      totalBytes: 4,
      isInProgress: false,
      isComplete: false,
      isCancelled: true,
      isInterrupted: false)
    XCTAssertEqual(try XCTUnwrap(manager.items.first).state, .cancelled)
  }

  func testFailedState() throws {
    let manager = manager()
    manager.update(
      downloadID: 8,
      sourceURL: sourceURL,
      suggestedFileName: "failed.bin",
      destinationURL: nil,
      receivedBytes: 2,
      totalBytes: 4,
      isInProgress: false,
      isComplete: false,
      isCancelled: false,
      isInterrupted: true)
    XCTAssertEqual(try XCTUnwrap(manager.items.first).state, .failed)
  }

  func testDuplicateCEFUpdateDoesNotCreateDuplicateItem() {
    let manager = manager()
    let update = {
      manager.update(
        downloadID: 9,
        sourceURL: self.sourceURL,
        suggestedFileName: "duplicate.bin",
        destinationURL: nil,
        receivedBytes: 1,
        totalBytes: 2,
        isInProgress: true,
        isComplete: false,
        isCancelled: false,
        isInterrupted: false)
    }
    update()
    update()
    XCTAssertEqual(manager.items.count, 1)
    XCTAssertEqual(manager.items.first?.receivedBytes, 1)
  }
}
