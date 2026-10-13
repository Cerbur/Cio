import AppKit
@testable import CioUI
import XCTest

@MainActor
final class NativeEditorFocusTests: XCTestCase {
  func testFailedPersistenceVetoesNativeWindowCloseBeforeSceneDelegate() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scene = CloseSceneDelegate()
    var canSave = false
    let delegate = BrowserFullScreenWindowDelegate(sceneDelegate: scene, shouldClose: { canSave })
    XCTAssertFalse(delegate.windowShouldClose(window))
    XCTAssertEqual(scene.closeChecks, 0)
    canSave = true
    XCTAssertTrue(delegate.windowShouldClose(window))
    XCTAssertEqual(scene.closeChecks, 1)
  }
  func testRetiredEditorCannotTakeKeyboardFromCurrentEditor() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let outgoing = CioAddressField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    let current = CioAddressField(frame: NSRect(x: 0, y: 40, width: 200, height: 28))
    window.contentView?.addSubview(outgoing)
    window.contentView?.addSubview(current)
    var presented = true
    outgoing.acceptsFocusRequest = { presented }
    outgoing.focusAndSelectAll()
    XCTAssertNotNil(outgoing.currentEditor())
    presented = false
    current.stringValue = "unsubmitted input"
    current.focusAndSelectAll()
    let responder = window.firstResponder
    outgoing.focusAndSelectAll()
    XCTAssertTrue(window.firstResponder === responder)
    XCTAssertNotNil(current.currentEditor())
    XCTAssertEqual(current.stringValue, "unsubmitted input")
  }

  func testHiddenFieldCannotReclaimSharedFieldEditor() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = CioAddressField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    window.contentView?.addSubview(field)
    field.isHidden = true
    window.makeFirstResponder(nil)
    let responder = window.firstResponder
    field.focusAndSelectAll()
    XCTAssertTrue(window.firstResponder === responder)
    XCTAssertNil(field.currentEditor())
  }

  func testHiddenEditorInVisibleCapsuleCanFocusButRetiredCapsuleCannot() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let field = CioAddressField(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
    window.contentView?.addSubview(field)
    var presented = true
    field.allowsHiddenEditorFocus = true
    field.acceptsFocusRequest = { presented }
    field.stringValue = "https://example.com/"
    field.isHidden = true
    field.focusAndSelectAll()
    XCTAssertNotNil(field.currentEditor(), "Compact label visibility cannot block explicit address focus")
    window.makeFirstResponder(nil)
    presented = false
    let responder = window.firstResponder
    field.focusAndSelectAll()
    XCTAssertTrue(window.firstResponder === responder, "A retired presentation must still reject focus")
  }
}

@MainActor
private final class CloseSceneDelegate: NSObject, NSWindowDelegate {
  var closeChecks = 0
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    closeChecks += 1
    return true
  }
}
