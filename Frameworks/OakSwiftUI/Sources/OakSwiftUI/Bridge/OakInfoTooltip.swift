import AppKit
import SwiftUI

// MARK: - OakInfoTooltip

private let kMaxWidth: CGFloat = 600
private let kMaxContentHeight: CGFloat = 350
private let kTabBarHeight: CGFloat = 32

@MainActor @objc public class OakInfoTooltip: NSObject, NSPopoverDelegate {
	@objc public weak var delegate: OakInfoTooltipDelegate?

	private let popover: NSPopover
	private let theme: OakThemeEnvironment
	private let selection = TooltipSelection()

	@objc public init(theme: OakThemeEnvironment) {
		self.theme = theme

		self.popover = NSPopover()
		self.popover.behavior = .semitransient
		self.popover.animates = true

		super.init()
		self.popover.delegate = self
	}

	// MARK: - Public API

	@objc public func show(in view: NSView, at rect: NSRect, content: OakTooltipContent) {
		show(in: view, at: rect, content: content, preservingSelection: false)
	}

	/// Every presentation installs a fresh hosting controller, so SwiftUI `@State`
	/// cannot hold the selected tab across one. The selection therefore lives here
	/// and is keyed by section label, not by position: a caller that re-presents
	/// updated content — diagnostics republished under an open tooltip — passes
	/// `preservingSelection` so the reader stays on the tab they were on, even
	/// though a section may have appeared or disappeared above it.
	@objc public func show(in view: NSView, at rect: NSRect, content: OakTooltipContent, preservingSelection: Bool) {
		if !preservingSelection {
			selection.label = nil
		}

		let hostingController = NSHostingController(
			rootView: AnyView(
				TooltipContentView(content: content, selection: selection)
					.environmentObject(theme)
			)
		)
		hostingController.sizingOptions = [.preferredContentSize]

		// Measure eager sections for width; use max height cap so tab switch doesn't resize
		let padding: CGFloat = 24
		let measureWidth = kMaxWidth - padding
		var maxContentWidth: CGFloat = 0
		var maxContentHeight: CGFloat = 0
		for section in content.sections where section.isEager {
			let boundingRect = section.content.boundingRect(
				with: NSSize(width: measureWidth, height: .greatestFiniteMagnitude),
				options: [.usesLineFragmentOrigin, .usesFontLeading]
			)
			maxContentWidth = max(maxContentWidth, ceil(boundingRect.width))
			maxContentHeight = max(maxContentHeight, ceil(boundingRect.height))
		}

		let contentWidth = min(max(maxContentWidth + padding, 200), kMaxWidth)
		let tabBar: CGFloat = content.sections.count > 1 ? kTabBarHeight : 0
		let hasLazy = content.sections.contains { !$0.isEager }
		let height = hasLazy ? kMaxContentHeight : maxContentHeight + 20
		let contentHeight = min(height + tabBar, kMaxContentHeight + tabBar)

		popover.contentSize = NSSize(width: contentWidth, height: contentHeight)
		// The tooltip body is syntax-highlighted with the editor theme, so the
		// popover chrome has to follow the theme rather than the system
		// appearance — otherwise a dark theme draws light text on a light
		// popover.
		popover.appearance = theme.appearance
		popover.contentViewController = hostingController

		if popover.isShown {
			popover.positioningRect = rect
		} else {
			popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
		}
	}

	@objc public func dismiss() {
		guard popover.isShown else { return }
		popover.close()
	}

	@objc public var isVisible: Bool {
		popover.isShown
	}

	@objc public var isMouseInside: Bool {
		guard popover.isShown,
			  let popoverWindow = popover.contentViewController?.view.window else {
			return false
		}
		return popoverWindow.frame.contains(NSEvent.mouseLocation)
	}

	// MARK: - NSPopoverDelegate

	nonisolated public func popoverDidClose(_ notification: Notification) {
		MainActor.assumeIsolated {
			delegate?.infoTooltipDidDismiss(self)
		}
	}
}
