import SwiftUI

/// iOS 26+ Liquid Glass with a graceful pre-26 fallback. The deployment
/// target is iOS 17.0 so every `glassEffect` / `GlassEffectContainer`
/// call site has to be runtime-gated; centralizing the branch here keeps
/// the pill views readable.
extension View {
    @ViewBuilder
    func glassPill() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(in: .capsule)
        } else {
            self.background(.regularMaterial, in: .capsule)
        }
    }

    /// A round glass control (the tab overview's + and Done).
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                self.glassEffect(.regular.tint(tint).interactive(), in: .circle)
            } else {
                self.glassEffect(.regular.interactive(), in: .circle)
            }
        } else {
            self.background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.regularMaterial), in: .circle)
        }
    }
}

/// Wraps adjacent glass surfaces so the iOS 26 light-blending engine sees
/// them as a single visual group (matters when one resizes — Safari's
/// pill morph). On older iOS, behaves as a transparent passthrough.
struct GlassChromeGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
