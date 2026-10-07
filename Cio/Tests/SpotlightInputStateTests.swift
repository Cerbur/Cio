@testable import CioEngine
import XCTest

final class SpotlightInputStateTests: XCTestCase {
  private func website(_ address: String) -> SpotlightSuggestion {
    SpotlightSuggestion(
      title: "Page", subtitle: "", mode: .website(URL(string: address)!),
      kind: .historyAddress, score: 80)
  }

  private func search(_ query: String, kind: SpotlightSuggestion.Kind = .onlineSearch) -> SpotlightSuggestion {
    SpotlightSuggestion(title: query, subtitle: "", mode: .googleSearch(query), kind: kind, score: 80)
  }

  func testMovingBetweenCandidatesKeepsQueryAndRestoresOriginalInput() {
    var input = SpotlightInputState()
    input.edit("bil", isComposing: false, allowsAutomaticCompletion: true)
    input.preview(website("https://www.bilibili.com/"), explicit: false)
    XCTAssertEqual(input.text, "bilibili.com")
    XCTAssertEqual(input.selection, NSRange(location: 3, length: 9))

    input.preview(search("bil", kind: .input), explicit: true)
    XCTAssertEqual(input.text, "bil")
    XCTAssertEqual(input.selection, NSRange(location: 3, length: 0))
    XCTAssertNil(input.previewID)

    input.preview(website("https://billboard.com/"), explicit: true)
    XCTAssertEqual(input.text, "billboard.com")
    XCTAssertEqual(input.selection, NSRange(location: 3, length: 10))
    XCTAssertEqual(input.userInput, "bil")
  }

  func testNonPrefixURLPreservesPathQueryAndFragmentWithCaretAtEnd() {
    var input = SpotlightInputState()
    input.edit("bil", isComposing: false, allowsAutomaticCompletion: true)
    let suggestion = website("https://message.bilibili.com/?spm_id_from=333.337.0.0#/love")
    input.preview(suggestion, explicit: false)
    XCTAssertEqual(input.text, "bil")
    input.preview(suggestion, explicit: true)
    XCTAssertEqual(input.text, "message.bilibili.com/?spm_id_from=333.337.0.0#/love")
    XCTAssertEqual(input.selection, NSRange(location: (input.text as NSString).length, length: 0))
    XCTAssertEqual(input.userInput, "bil")
  }

  func testAcceptingSuffixAndProviderUpdatesPreserveQueryAndCaret() {
    var input = SpotlightInputState()
    let suggestion = search("swift concurrency")
    input.edit("swift", isComposing: false, allowsAutomaticCompletion: true)
    input.preview(suggestion, explicit: true)
    input.acceptCompletion()
    let revision = input.revision
    input.preview(suggestion, explicit: true)
    XCTAssertEqual(input.revision, revision)
    XCTAssertEqual(input.selection, NSRange(location: 17, length: 0))
    XCTAssertEqual(input.userInput, "swift")

    input.edit("swift concurrency book", isComposing: false, allowsAutomaticCompletion: true)
    XCTAssertEqual(input.userInput, "swift concurrency book")
    XCTAssertNil(input.previewID)
  }

  func testCompositionAndDeletionDoNotAutomaticallyReinsertCompletion() {
    var input = SpotlightInputState()
    input.edit("中", isComposing: true, allowsAutomaticCompletion: false)
    input.preview(search("中文"), explicit: true)
    XCTAssertEqual(input.text, "中")
    XCTAssertNil(input.selection)

    input.edit("bil", isComposing: false, allowsAutomaticCompletion: false)
    input.preview(website("https://bilibili.com/"), explicit: false)
    XCTAssertEqual(input.text, "bil")
    input.preview(website("https://bilibili.com/"), explicit: true)
    XCTAssertEqual(input.text, "bilibili.com")
  }

  func testSelectionUsesUTF16AndCaseInsensitivePrefix() {
    var input = SpotlightInputState()
    input.edit("🎉中", isComposing: false, allowsAutomaticCompletion: true)
    input.preview(search("🎉中文"), explicit: true)
    XCTAssertEqual(input.selection, NSRange(location: 3, length: 1))

    input.edit("BIL", isComposing: false, allowsAutomaticCompletion: true)
    input.preview(website("https://bilibili.com/"), explicit: false)
    XCTAssertEqual(input.selection, NSRange(location: 3, length: 9))
  }

  func testExplicitSchemeAndRootQueryAreRetained() {
    var input = SpotlightInputState()
    input.edit("https://bil", isComposing: false, allowsAutomaticCompletion: true)
    input.preview(website("https://www.bilibili.com/"), explicit: true)
    XCTAssertEqual(input.text, "https://bilibili.com")
    XCTAssertEqual(input.selection, NSRange(location: 11, length: 9))
    input.preview(website("https://bilibili.com/?page=2"), explicit: true)
    XCTAssertEqual(input.text, "https://bilibili.com/?page=2")
    input.edit("www.bil", isComposing: false, allowsAutomaticCompletion: true)
    input.preview(website("https://www.bilibili.com/"), explicit: false)
    XCTAssertEqual(input.text, "www.bilibili.com")
    XCTAssertEqual(input.selection, NSRange(location: 7, length: 9))
  }
}
