import SwiftUI

struct AttributedTextView: NSViewRepresentable {
	let attributedString: NSAttributedString
	let fontSize: CGFloat
	var maxLayoutWidth: CGFloat = 240

	func makeNSView(context: Context) -> NSTextField {
		let field = NSTextField(frame: .zero)
		field.isEditable = false
		field.isSelectable = true
		// Selecting installs the window's field editor over the field; without this
		// it is configured for plain text and strips the attributed string's
		// colors and fonts on the first click.
		field.allowsEditingTextAttributes = true
		field.isBordered = false
		field.drawsBackground = false
		field.lineBreakMode = .byWordWrapping
		field.preferredMaxLayoutWidth = maxLayoutWidth
		field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		return field
	}

	func updateNSView(_ field: NSTextField, context: Context) {
		field.attributedStringValue = attributedString
		field.preferredMaxLayoutWidth = maxLayoutWidth
	}
}
