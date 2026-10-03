#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Blur the actual scrolling layer, increasing the radius toward the fixed pins.
// Two separable passes keep sampling confined to the small transition band.
[[ stitchable ]] half4 sidebarScrollEdgeBlur(
    float2 position, SwiftUI::Layer layer, float originY,
    float transitionHeight, float maxRadius, float2 axis) {
  float y = position.y + originY;
  float progress = 1.0 - smoothstep(0.0, transitionHeight, y);
  float radius = maxRadius * progress;
  if (radius < 0.01) return layer.sample(position);

  constexpr float weights[9] = {1, 8, 28, 56, 70, 56, 28, 8, 1};
  half4 color = half4(0);
  for (int i = 0; i < 9; ++i) {
    float2 offset = axis * (float(i - 4) * radius / 4.0);
    color += layer.sample(position + offset) * half(weights[i] / 256.0);
  }
  if (axis.y > 0) {
    // Fade after the final pass, leaving the lower edge crisp.
    color *= half(smoothstep(transitionHeight * 0.08, transitionHeight * 0.75, y));
  }
  return color;
}
