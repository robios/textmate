import AppKit
import Combine

@MainActor @objc public class OakThemeEnvironment: NSObject, ObservableObject {
    @Published @objc public var fontName: String = "Menlo"
    @Published @objc public var fontSize: CGFloat = 12
    @Published @objc public var backgroundColor: NSColor = .textBackgroundColor
    @Published @objc public var foregroundColor: NSColor = .textColor
    @Published @objc public var selectionColor: NSColor = .selectedTextBackgroundColor
    @Published @objc public var keywordColor: NSColor = .systemBlue
    @Published @objc public var commentColor: NSColor = .systemGreen
    @Published @objc public var stringColor: NSColor = .systemRed

    @objc public var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Whether the *editor theme* is dark. This is deliberately not the system
    /// appearance: a dark theme under a light system appearance is the common
    /// case that made popup text unreadable.
    @objc public var isDark: Bool {
        guard let rgb = backgroundColor.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }

    /// Appearance to pin panels/popovers to, so that semantic colors
    /// (`.primary`, `.secondary`, control tints, dividers) resolve against the
    /// theme background they are actually drawn on.
    @objc public var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Callers re-apply the theme on every access (the environment outlives
    /// theme and font changes), so only assign properties whose value actually
    /// changed — a @Published setter fires objectWillChange even for an equal
    /// value, re-rendering every popup observing this environment.
    @objc public func applyTheme(_ dict: NSDictionary) {
        if let v = dict["fontName"] as? String, v != fontName { fontName = v }
        if let v = dict["fontSize"] as? NSNumber, CGFloat(v.doubleValue) != fontSize { fontSize = CGFloat(v.doubleValue) }
        if let v = dict["backgroundColor"] as? NSColor, v != backgroundColor { backgroundColor = v }
        if let v = dict["foregroundColor"] as? NSColor, v != foregroundColor { foregroundColor = v }
        if let v = dict["selectionColor"] as? NSColor, v != selectionColor { selectionColor = v }
        if let v = dict["keywordColor"] as? NSColor, v != keywordColor { keywordColor = v }
        if let v = dict["commentColor"] as? NSColor, v != commentColor { commentColor = v }
        if let v = dict["stringColor"] as? NSColor, v != stringColor { stringColor = v }
    }
}
