//
//  AddressFieldIsolationTests.swift
//  NativeBrowserTests
//
//  The "one address field, one tab" rule from Milestone 3 sections 13 and 14,
//  tested without Chromium.
//
//  The guarantee is structural: every BrowserSession owns its own
//  AddressFieldModel, and AddressFieldModel only mirrors the committed URL while
//  the user is not editing. These tests pin both halves of that down, so the
//  named failure condition "a background callback overwrites the selected tab's
//  address state" cannot return unnoticed.
//

import XCTest

@MainActor
final class AddressFieldIsolationTests: XCTestCase {
  private func url(_ string: String) -> URL {
    URL(string: string)!
  }

  func testTypingSurvivesABrowserURLCallback() {
    let model = AddressFieldModel()
    model.applyBrowserURL(url("https://example.com/"))
    XCTAssertEqual(model.editText, "https://example.com/")
    XCTAssertFalse(model.isEditing)

    XCTAssertTrue(model.userChangedText("half-typed query"))
    XCTAssertTrue(model.isEditing)

    // A URL callback arrives for the same tab while the user is typing.
    model.applyBrowserURL(url("https://example.com/redirected"))

    XCTAssertEqual(model.editText, "half-typed query", "the edit buffer must not be overwritten")
    XCTAssertEqual(model.committedURL?.absoluteString, "https://example.com/redirected")
  }

  func testOneTabsCallbacksCannotTouchAnotherTabsBuffer() {
    // Two tabs, therefore two models: nothing is shared between them.
    let selected = AddressFieldModel()
    let background = AddressFieldModel()
    selected.applyBrowserURL(url("https://selected.example/"))
    background.applyBrowserURL(url("https://background.example/"))

    selected.userChangedText("unsubmitted address")

    // The background tab navigates, is redirected and reports a new URL - all of
    // it lands on the background model only.
    background.applyBrowserURL(url("https://background.example/step-1"))
    background.applyBrowserURL(url("https://background.example/step-2"))

    XCTAssertEqual(selected.editText, "unsubmitted address")
    XCTAssertEqual(
      selected.committedURL?.absoluteString, "https://selected.example/",
      "a background navigation must not move the selected tab's committed URL")
    XCTAssertEqual(background.editText, "https://background.example/step-2")
  }

  func testEndingEditingLetsTheNextURLCallbackThrough() {
    let model = AddressFieldModel()
    model.applyBrowserURL(url("https://example.com/"))
    model.userChangedText("typed")
    model.endEditing()

    model.applyBrowserURL(url("https://example.com/after-submit"))

    XCTAssertEqual(model.editText, "https://example.com/after-submit")
    XCTAssertEqual(model.committedURL?.absoluteString, "https://example.com/after-submit")
  }

  func testCancelEditingRestoresTheCommittedURL() {
    let model = AddressFieldModel()
    model.applyBrowserURL(url("https://example.com/committed"))
    model.userChangedText("abandoned edit")

    model.cancelEditing()

    XCTAssertFalse(model.isEditing)
    XCTAssertEqual(model.editText, "https://example.com/committed")
  }

  func testFieldIsEmptyUntilChromiumReportsAPage() {
    let model = AddressFieldModel()
    XCTAssertEqual(model.editText, "")
    XCTAssertNil(model.committedURL)

    model.applyBrowserURL(nil)
    XCTAssertEqual(model.editText, "")
  }

  func testUnchangedTextIsNotReportedAsAChange() {
    let model = AddressFieldModel()
    XCTAssertTrue(model.userChangedText("one"))
    XCTAssertFalse(model.userChangedText("one"))
  }
}
