import SwiftUI

struct CompletionListView: View {
	@ObservedObject var viewModel: CompletionViewModel
	let showDocPanel: Bool
	let docPanelWidth: CGFloat
	@EnvironmentObject var theme: OakThemeEnvironment

	private var isVerticalDocLayout: Bool {
		viewModel.docPanelPosition == .below || viewModel.docPanelPosition == .above
	}

	var body: some View {
		Group {
			if !showDocPanel || viewModel.docPanelPosition == .right {
				HStack(spacing: 0) {
					itemsList
					if showDocPanel {
						Divider()
						docPanel
					}
				}
			} else if viewModel.docPanelPosition == .above {
				VStack(spacing: 0) {
					docPanel
					Divider()
					itemsList
				}
			} else {
				VStack(spacing: 0) {
					itemsList
					Divider()
					docPanel
				}
			}
		}
		// The stock popup material, so the panel reads as part of the system
		// rather than as a rectangle of theme color pasted over the editor. The
		// panel's appearance is pinned to the theme's brightness, so the
		// material resolves on the same side of light/dark as the syntax colors
		// drawn on it. hudWindow rather than menu: the menu material transmits
		// so little in dark mode that it comes out flat.
		.background(VisualEffectBackground(material: .hudWindow))
		.clipShape(RoundedRectangle(cornerRadius: 6))
	}

	private var itemsList: some View {
		ScrollViewReader { proxy in
			ScrollView(.vertical) {
				LazyVStack(spacing: 0) {
					ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
						CompletionRowView(
							item: item,
							isSelected: index == viewModel.selectedIndex
						)
						.id(item.id)
						.accessibilityElement(children: .ignore)
						.accessibilityLabel(item.label)
						.accessibilityHint(item.detail)
						.accessibilityAddTraits(index == viewModel.selectedIndex ? .isSelected : [])
					}
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 4)
			}
			.accessibilityElement(children: .contain)
			.onChange(of: viewModel.selectedIndex) { _, newValue in
				guard newValue < viewModel.filteredItems.count else { return }
				withAnimation(.easeOut(duration: 0.1)) {
					proxy.scrollTo(viewModel.filteredItems[newValue].id, anchor: .center)
				}
			}
		}
	}

	private var docPanel: some View {
		Group {
			if let docs = viewModel.resolvedDocumentation, docs.length > 0 {
				DocDetailView(documentation: docs, isVerticalLayout: isVerticalDocLayout, width: docPanelWidth)
					.transition(.opacity)
			} else if !isVerticalDocLayout {
				Color.clear
					.frame(width: docPanelWidth)
			}
		}
		.animation(.easeIn(duration: 0.1), value: viewModel.resolvedDocumentation != nil)
	}
}
