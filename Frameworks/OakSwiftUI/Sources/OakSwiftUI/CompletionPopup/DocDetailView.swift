import SwiftUI

struct DocDetailView: View {
	let documentation: NSAttributedString
	var isVerticalLayout: Bool = false
	var width: CGFloat = 260
	@EnvironmentObject var theme: OakThemeEnvironment

	private static let padding: CGFloat = 10

	var body: some View {
		ScrollView {
			AttributedTextView(attributedString: documentation,
			                   fontSize: max(theme.fontSize - 1, 10),
			                   maxLayoutWidth: width - 2 * Self.padding)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(Self.padding)
		}
		.modifier(DocPanelFrameModifier(isVerticalLayout: isVerticalLayout, width: width))
	}
}

private struct DocPanelFrameModifier: ViewModifier {
	let isVerticalLayout: Bool
	let width: CGFloat

	func body(content: Content) -> some View {
		if isVerticalLayout {
			content
				.frame(maxWidth: .infinity)
				.frame(maxHeight: 200)
		} else {
			content
				.frame(width: width)
		}
	}
}
