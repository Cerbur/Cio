@testable import CioUI
import AppKit
import SwiftUI
import XCTest

final class BrowserComponentThemeTests: XCTestCase {
  @MainActor
  func testV1WithoutComponentsKeepsExistingColorsAndGlass() throws {
    var original = SpaceTheme()
    original.accent = ThemeColor(.orange)
    original.glassStyle = .clear
    original.glassTintOpacity = 0.43
    original.sidebarColorOpacity = 0.27
    original.selectionOpacity = 0.31
    original.stableOpacity = 0.67
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "components")

    let restored = try JSONDecoder().decode(SpaceTheme.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(restored.accent, original.accent)
    XCTAssertEqual(restored.sidebarColorOpacity, 0.27)
    XCTAssertEqual(restored.component(.navigation).glassStyle, .clear)
    XCTAssertEqual(restored.component(.addressBar).glassTintOpacity, 0.43)
    XCTAssertEqual(restored.component(.spotlightSuggestions).highlightOpacity, 0.31)
    XCTAssertEqual(restored.component(.splitStable).highlightOpacity, 0.67)
    // Spotlight's second refractive pass used clear, untinted glass in v1.
    XCTAssertEqual(restored.component(.spotlightEdge).glassStyle, .clear)
    XCTAssertEqual(restored.component(.spotlightEdge).glassTintOpacity, 0)
  }

  @MainActor
  func testComponentChangesRoundTripIndependentlyAndResetLocally() throws {
    var space = SpaceTheme()
    let originalNavigation = space.component(.navigation)
    var address = space.component(.addressBar)
    address.glassStyle = .clear
    address.glassTint = ThemeColor(.purple)
    address.glassTintOpacity = 0.7
    space.setComponent(address, for: .addressBar)
    var spotlight = space.component(.spotlightSuggestions)
    spotlight.accent = ThemeColor(.green)
    spotlight.highlightOpacity = 0.6
    space.setComponent(spotlight, for: .spotlightSuggestions)

    var restored = try JSONDecoder().decode(SpaceTheme.self, from: JSONEncoder().encode(space))
    XCTAssertEqual(restored.component(.addressBar), address)
    XCTAssertEqual(restored.component(.spotlightSuggestions), spotlight)
    XCTAssertEqual(restored.component(.navigation), originalNavigation)
    XCTAssertEqual(restored.component(.addressSuggestions).highlightOpacity, 0.24)
    restored.resetComponent(.addressBar)
    XCTAssertEqual(restored.component(.addressBar), SpaceTheme().component(.addressBar))
    XCTAssertEqual(restored.component(.spotlightSuggestions), spotlight)
  }

  @MainActor
  func testComponentColorCanFollowSpaceOrRemainIndependent() {
    var space = SpaceTheme()
    space.accent = ThemeColor(.orange)
    var focus = space.component(.addressFocus)
    focus.accent = ThemeColor(.purple)
    space.setComponent(focus, for: .addressFocus)
    space.accent = ThemeColor(.green)

    XCTAssertEqual(space.customAccent(for: .addressFocus), focus.accent)
    XCTAssertEqual(space.customAccent(for: .splitStable), space.accent)
    space.resetComponent(.addressFocus)
    XCTAssertEqual(space.customAccent(for: .addressFocus), space.accent)
  }

  @MainActor
  func testOlderBackdropWithoutMixKeepsItsMaterialAndTint() throws {
    var original = ShellTheme()
    original.material = .hudWindow
    original.tint = ThemeColor(.orange)
    original.tintOpacity = 0.37
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
    json.removeValue(forKey: "colorMix")
    let restored = try JSONDecoder().decode(ShellTheme.self, from: JSONSerialization.data(withJSONObject: json))

    XCTAssertEqual(restored, original)
    XCTAssertNil(restored.colorMix)
    XCTAssertEqual(restored.resolvedColorMix.primary, original.tint)
    XCTAssertEqual(restored.resolvedColorMix.secondary, original.tint)
    XCTAssertEqual(restored.resolvedColorMix.frostOpacity, 1)
    XCTAssertEqual(restored.resolvedColorMix.grainOpacity, 0)
  }

  @MainActor
  func testThreeMixDimensionsPersistSeparatelyForShellAndSpaces() throws {
    let suite = "CioTests.ThemeMix.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = BrowserThemePreferences(defaults: defaults)
    var mix = BackdropColorMix()
    mix.primary = ThemeColor(.green)
    mix.secondary = ThemeColor(.purple)
    mix.balance = 0.314159
    mix.grain = 0.271828
    mix.backgroundContribution = 0.618034
    mix.primaryPosition = ThemeBrushPoint(x: 0.19, y: 0.72)
    mix.secondaryPosition = ThemeBrushPoint(x: 0.8, y: 0.3)
    preferences.shell.colorMix = mix
    let firstID = UUID(), secondID = UUID()
    var first = SpaceTheme()
    let originalNavigation = first.component(.navigation)
    mix.balance = 0.8
    first.sidebarColorMix = mix
    var preview = first.component(.splitPreview)
    mix.grain = 0.1
    preview.backdrop.colorMix = mix
    first.setComponent(preview, for: .splitPreview)
    preferences.setTheme(first, for: firstID)

    let restored = BrowserThemePreferences(defaults: defaults)
    XCTAssertEqual(restored.shell, preferences.shell)
    XCTAssertEqual(restored.theme(for: firstID), first)
    XCTAssertEqual(restored.theme(for: firstID).sidebarSurface, .frosted)
    XCTAssertEqual(restored.theme(for: firstID).component(.navigation), originalNavigation)
    XCTAssertEqual(restored.theme(for: firstID).component(.splitPreview), preview)
    XCTAssertEqual(restored.theme(for: secondID), SpaceTheme())
  }

  @MainActor
  func testClarityControlsFrostAndKeepsNativeClearGlassMounted() {
    _ = NSApplication.shared
    let view = ThemeBackdropView()
    var theme = ShellTheme()
    theme.material = .hudWindow
    theme.colorMix = BackdropColorMix()
    for clarity in [0.0, 0.44, 0.74, 1.0] {
      theme.colorMix?.backgroundContribution = clarity
      view.apply(theme, reduceTransparency: false)
      XCTAssertEqual(view.frost.alphaValue, 1 - clarity, accuracy: 0.000001)
      XCTAssertEqual(view.frost.material, .hudWindow)
      XCTAssertEqual(view.clearGlass.style, .clear)
      XCTAssertEqual(view.clearGlass.alphaValue, 1)
      XCTAssertTrue(view.frost.superview === view.clearGlass.contentView)
      XCTAssertTrue(view.tint.superview === view.clearGlass.contentView)
    }
    theme.colorMix?.grain = 1
    view.apply(theme, reduceTransparency: false)
    XCTAssertEqual(view.frost.alphaValue, 0, "Grain must not thicken the glass")
    view.apply(theme, reduceTransparency: true)
    XCTAssertEqual(view.frost.alphaValue, 1)
    theme.colorMix = nil
    theme.opacity = 0.64
    view.apply(theme, reduceTransparency: false)
    XCTAssertEqual(view.frost.alphaValue, 0.64)
  }

  @MainActor
  func testBrushesKeepTheirOwnHueAndPaintAtIndependentPositions() throws {
    let view = BackdropTintView()
    var mix = BackdropColorMix()
    mix.primary = ThemeColor(.red)
    mix.secondary = ThemeColor(.blue)
    mix.primaryPosition = ThemeBrushPoint(x: 0.17, y: 0.63)
    mix.secondaryPosition = ThemeBrushPoint(x: 0.82, y: 0.24)
    var theme = ShellTheme()
    for balance in [0.0, 0.5, 1.0] {
      mix.balance = balance
      for clarity in [0.0, 1.0] {
        mix.backgroundContribution = clarity
        theme.colorMix = mix
        view.apply(theme)
        XCTAssertEqual(view.primaryBrush.type, .radial)
        XCTAssertEqual(view.secondaryBrush.type, .radial)
        XCTAssertEqual(view.primaryBrush.startPoint, mix.primaryCenter)
        XCTAssertEqual(view.secondaryBrush.startPoint, mix.secondaryCenter)
        let first = try XCTUnwrap(view.primaryBrush.colors as? [CGColor])
        let second = try XCTUnwrap(view.secondaryBrush.colors as? [CGColor])
        XCTAssertEqual(NSColor(cgColor: first[0])?.usingColorSpace(.sRGB)?.redComponent,
                       NSColor(mix.primary.color).usingColorSpace(.sRGB)?.redComponent)
        XCTAssertEqual(NSColor(cgColor: second[0])?.usingColorSpace(.sRGB)?.blueComponent,
                       NSColor(mix.secondary.color).usingColorSpace(.sRGB)?.blueComponent)
        XCTAssertEqual(first[0].alpha, BackdropColorMix.maximumColorOpacity, accuracy: 0.000001)
        XCTAssertEqual(first.last?.alpha, 0, "Each brush must feather to transparent")
      }
    }
    // Old mix records lack brush positions; they still decode with two centers.
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mix)) as? [String: Any])
    json.removeValue(forKey: "primaryPosition")
    json.removeValue(forKey: "secondaryPosition")
    let old = try JSONDecoder().decode(BackdropColorMix.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertNotEqual(old.primaryCenter, old.secondaryCenter)
  }

  @MainActor
  func testSidebarClarityRemovesSharedFrostOnlyWithinItsOwnBounds() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 240),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = try XCTUnwrap(window.contentView)
    let root = ThemeBackdropView(frame: host.bounds)
    var shell = ShellTheme()
    shell.colorMix = BackdropColorMix()
    shell.colorMix?.backgroundContribution = 0
    root.apply(shell, reduceTransparency: false)
    host.addSubview(root)
    let sidebar = SidebarBackdropRegionView(frame: CGRect(x: 0, y: 0, width: 100, height: 240))
    var local = ShellTheme()
    local.colorMix = BackdropColorMix()
    local.colorMix?.backgroundContribution = 1
    sidebar.apply(local, reduceTransparency: false)
    host.addSubview(sidebar)
    root.layout()
    sidebar.layout()
    let mask = try XCTUnwrap(root.frost.maskImage)
    let bitmap = try XCTUnwrap(mask.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    XCTAssertEqual(bitmap.colorAt(x: 50, y: 120)?.alphaComponent, 0)
    XCTAssertEqual(bitmap.colorAt(x: 200, y: 120)?.alphaComponent, 1)
    sidebar.unregister()
    XCTAssertNil(root.frost.maskImage)
  }

  @MainActor
  func testSidebarMixPreservesItsExistingGlassSurface() {
    for surface in [SidebarSurface.frosted, .liquid] {
      var space = SpaceTheme()
      space.sidebarSurface = surface
      space.sidebarMaterial = .thin
      space.sidebarOpacity = 0.83
      var sidebar = space.component(.sidebar)
      sidebar.glassStyle = .clear
      space.setComponent(sidebar, for: .sidebar)
      space.sidebarColorMix = BackdropColorMix()
      XCTAssertEqual(space.sidebarSurface, surface)
      XCTAssertEqual(space.sidebarGlassSurface, surface)
      XCTAssertEqual(space.sidebarMaterial, .thin)
      XCTAssertEqual(space.sidebarOpacity, 0.83)
      XCTAssertEqual(space.component(.sidebar).glassStyle, .clear)
    }
    var previousVersion = SpaceTheme()
    previousVersion.sidebarSurface = .colorMix
    previousVersion.sidebarColorMix = BackdropColorMix()
    XCTAssertEqual(previousVersion.sidebarGlassSurface, .frosted)
  }
}
