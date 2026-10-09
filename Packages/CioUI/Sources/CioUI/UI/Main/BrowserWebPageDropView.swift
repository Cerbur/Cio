import AppKit
import CioModel

/// Only explicit web addresses qualify. Ordinary text, files and scripts keep
/// their native Chromium drop behavior.
enum BrowserWebPageDrop {
  enum Destination: Equatable {
    case tab(before: UUID?)
    case rightSplit
    case unavailableRightSplit
  }

  static func url(from pasteboard: NSPasteboard) -> URL? {
    let raw = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string)
    guard let raw, let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty else { return nil }
    return url
  }

  static func isRightSplitZone(_ point: CGPoint, in bounds: CGRect) -> Bool {
    bounds.width > 0 && bounds.height > 0 && bounds.contains(point)
      && point.x >= bounds.maxX - bounds.width * BrowserLayout.webPageSplitDropWidthFraction
  }
}

/// A native drag destination above the browser/sidebar. Mouse events pass
/// through until AppKit publishes a new URL drag pasteboard for this gesture.
/// This lets the outer right-edge target win over Chromium's own destination
/// without covering links, editors, hover feedback or in-page drag operations.
final class BrowserWebPageDropView: NSView {
  var destinationAtWindowPoint: ((CGPoint) -> BrowserWebPageDrop.Destination?)?
  var onPreview: ((BrowserWebPageDrop.Destination?) -> Void)?
  var onDrop: ((URL, BrowserWebPageDrop.Destination, CGRect) -> Bool)?
  nonisolated(unsafe) private var mouseDownMonitor: Any?
  private var gesturePasteboardChangeCount = NSPasteboard(name: .drag).changeCount
  private var isPointerDragging = false
  private var preview: BrowserWebPageDrop.Destination?
  private var dragOrigin: CGPoint?
  private var dragSequence: Int?
  private var splitIntentEstablished = false

  /// Capture the press before Chromium starts its native drag loop, including
  /// links whose source is already inside the right-edge destination.
  func beginPointerDrag(at point: CGPoint) {
    dragOrigin = point
    dragSequence = nil
    splitIntentEstablished = false
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.URL, .string])
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
    mouseDownMonitor = nil
    gesturePasteboardChangeCount = NSPasteboard(name: .drag).changeCount
    if window != nil {
      mouseDownMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
      ) { [weak self] event in
        MainActor.assumeIsolated {
          if event.type == .leftMouseDown, event.window === self?.window {
            self?.beginPointerDrag(at: event.locationInWindow)
          }
          if event.type == .leftMouseDragged {
            self?.isPointerDragging = true
          } else {
            self?.isPointerDragging = false
            self?.gesturePasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            if event.type == .leftMouseUp || event.type == .mouseMoved {
              self?.dragOrigin = nil
              self?.dragSequence = nil
              self?.splitIntentEstablished = false
            }
          }
        }
        return event
      }
    } else {
      updatePreview(nil)
    }
  }

  deinit {
    if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard !isHidden, bounds.contains(convert(point, from: superview)),
          isPointerDragging || NSEvent.pressedMouseButtons & 1 != 0 else { return nil }
    let pasteboard = NSPasteboard(name: .drag)
    guard pasteboard.changeCount != gesturePasteboardChangeCount,
          BrowserWebPageDrop.url(from: pasteboard) != nil,
          destinationAtWindowPoint?(superview?.convert(point, to: nil) ?? point) != nil else { return nil }
    return self
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDrag(sender)
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    updateDrag(sender)
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    updatePreview(nil)
  }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    !updateDrag(sender).isEmpty
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard !updateDrag(sender).isEmpty,
          let url = BrowserWebPageDrop.url(from: sender.draggingPasteboard),
          let destination = preview else { return false }
    let size = BrowserSplitRevealTransition.cardSize
    let point = sender.draggingLocation
    let source = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height)
    let committed = onDrop?(url, destination, source) ?? false
    updatePreview(nil)
    return committed
  }

  override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
    finishDrag()
  }

  override func draggingEnded(_ sender: any NSDraggingInfo) {
    finishDrag()
  }

  private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if dragSequence != sender.draggingSequenceNumber {
      // External drags have no local mouse-down event. Their first entry is
      // the origin; subsequent exits/re-entries keep the same gesture intent.
      if dragSequence != nil {
        dragOrigin = nil
        splitIntentEstablished = false
      }
      dragSequence = sender.draggingSequenceNumber
      if dragOrigin == nil { dragOrigin = sender.draggingLocation }
    }
    if sender.draggingLocation.x - (dragOrigin?.x ?? sender.draggingLocation.x)
      >= BrowserLayout.webPageSplitDragDistance { splitIntentEstablished = true }
    let mask = sender.draggingSourceOperationMask
    let operation: NSDragOperation = mask.contains(.copy) ? .copy
      : (mask.contains(.link) ? .link : (mask.contains(.generic) ? .generic : []))
    guard !operation.isEmpty, BrowserWebPageDrop.url(from: sender.draggingPasteboard) != nil,
          let destination = destinationAtWindowPoint?(sender.draggingLocation),
          destination != .unavailableRightSplit,
          destination != .rightSplit || splitIntentEstablished else {
      updatePreview(nil)
      return []
    }
    updatePreview(destination)
    return operation
  }

  private func updatePreview(_ destination: BrowserWebPageDrop.Destination?) {
    guard preview != destination else { return }
    preview = destination
    onPreview?(destination)
  }

  private func finishDrag() {
    updatePreview(nil)
    isPointerDragging = false
    dragOrigin = nil
    dragSequence = nil
    splitIntentEstablished = false
    gesturePasteboardChangeCount = NSPasteboard(name: .drag).changeCount
  }
}
