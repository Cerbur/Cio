#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Increase blur from the fixed Space title row's bottom edge to its top edge.
// The viewport fades every scrolling surface, including glass and borders.
[[ stitchable ]] half4 sidebarScrollEdgeBlur(
    float2 position, SwiftUI::Layer layer, float originY,
    float transitionHeight, float maxRadius, float2 axis) {
  float y = position.y + originY;
  float progress = clamp(y / transitionHeight, 0.0, 1.0);
  float eased = progress * progress * progress * (progress * (progress * 6.0 - 15.0) + 10.0);
  float radius = maxRadius * (1.0 - eased);
  if (radius < 0.01) return layer.sample(position);

  // Dense, truncated Gaussian sampling avoids the separated copies of text
  // produced by widely spaced taps. radius covers three standard deviations.
  half4 color = half4(0);
  float totalWeight = 0.0;
  for (int i = -16; i <= 16; ++i) {
    float distance = float(i) / 16.0;
    float weight = exp(-4.5 * distance * distance);
    color += layer.sample(position + axis * (distance * radius)) * half(weight);
    totalWeight += weight;
  }
  return color / half(totalWeight);
}
