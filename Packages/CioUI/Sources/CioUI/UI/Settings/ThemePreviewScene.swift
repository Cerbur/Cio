import SwiftUI

/// A real scrolling backdrop, with a stationary native material above it.
/// Keep these as separate layers: rasterizing the scene together would prevent
/// Liquid Glass from sampling the photographs and type as they pass underneath.
struct ThemePreviewScene<Overlay: View>: View {
  var overlayAllowsHitTesting = false
  @ViewBuilder var overlay: () -> Overlay

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 20) {
        photograph("PreviewForest", height: 200)
          .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 4) {
              Text("FIELD NOTES · 01").font(.caption2.weight(.semibold)).tracking(2)
              Text("走进山林之间").font(.title2.bold())
            }
            .foregroundStyle(.white)
            .padding(18)
          }

        VStack(alignment: .leading, spacing: 12) {
          Text("让光线穿过树梢").font(.title3.weight(.semibold))
          Text("清晨的森林，有深浅不同的绿色。叶片、岩石与细碎的光影，在一路向前的风景中交错。")
            .font(.callout).foregroundStyle(.secondary)
          HStack(spacing: 8) {
            Label("自然", systemImage: "leaf")
            Label("光影", systemImage: "sun.max")
            Label("探索", systemImage: "map")
          }
          .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)

        photograph("PreviewValley", height: 180)
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .padding(.horizontal, 18)

        VStack(alignment: .leading, spacing: 12) {
          Text("越过山谷，遇见远方").font(.title3.weight(.semibold))
          Text("从浓密的树冠到开阔的山谷，风景逐渐明亮。近处的纹理、远处的层次，让每一次停留都有新的发现。")
            .font(.callout).foregroundStyle(.secondary)
          HStack(spacing: 0) {
            ForEach([Color.teal, .green, .orange, .pink, .indigo], id: \.self) { color in
              Rectangle().fill(color).frame(height: 40)
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 8))
          Text("记下沿途的颜色").font(.headline)
          Text("图片、文字与色彩，构成一段可以慢慢浏览的旅程。向上或向下滚动，看看不同的风景。")
            .font(.callout).foregroundStyle(.secondary)
          Text("摄影：CHUTTERSNAP、Paul Pastourmatzis / Unsplash")
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 24)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.basedOnSize)
    .background(Color(nsColor: .textBackgroundColor))
    .accessibilityLabel("可滚动的图文预览背景")
    .overlay(alignment: .top) {
      overlay()
        .padding(18)
        // The preview has no real browser actions. Scrolling over the glass
        // should reach the scene's own ScrollView, not the surrounding Form.
        .allowsHitTesting(overlayAllowsHitTesting)
        .accessibilityHidden(!overlayAllowsHitTesting)
    }
    .clipShape(RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: BrowserLayout.contentCornerRadius)
        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private func photograph(_ name: String, height: CGFloat) -> some View {
    GeometryReader { geometry in
      Image(name, bundle: .module)
        .resizable()
        .scaledToFill()
        .frame(width: geometry.size.width, height: height)
        .clipped()
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}
