import AppKit
import SwiftUI

/// The stock macOS popup material, for panels that should read as part of the
/// system rather than as a flat rectangle of theme color. The window it is
/// hosted in must be non-opaque with a clear background for `.behindWindow`
/// blending to take effect, and its appearance decides whether the material
/// resolves light or dark.
struct VisualEffectBackground: NSViewRepresentable {
	var material: NSVisualEffectView.Material = .hudWindow
	var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

	func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.state = .active
		return view
	}

	func updateNSView(_ view: NSVisualEffectView, context: Context) {
		view.material = material
		view.blendingMode = blendingMode
		view.state = .active
	}
}
