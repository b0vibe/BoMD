import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable {
    case dark, light

    var title: String { self == .light ? "浅色" : "深色" }
    var appearance: NSAppearance? { NSAppearance(named: self == .light ? .aqua : .darkAqua) }
    var background: NSColor {
        self == .light
            ? NSColor(red: 0.973, green: 0.976, blue: 0.980, alpha: 1)
            : NSColor(red: 0.188, green: 0.212, blue: 0.227, alpha: 1)
    }
    var text: NSColor {
        self == .light ? NSColor(red: 0.20, green: 0.25, blue: 0.32, alpha: 1) : .white.withAlphaComponent(0.76)
    }
    var lineNumber: NSColor { self == .light ? .secondaryLabelColor : .white.withAlphaComponent(0.28) }
    var selection: NSColor {
        self == .light ? NSColor(red: 0.79, green: 0.87, blue: 0.96, alpha: 1) : .selectedTextBackgroundColor
    }
}

/// Presentation-only preference, shared by existing and newly opened windows.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var selection: AppTheme {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: "appearance.theme")
            applyAppearance()
        }
    }

    private init() {
        selection = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appearance.theme") ?? "") ?? .dark
    }

    func applyAppearance() {
        NSApp.appearance = selection.appearance
        NSApp.windows.forEach { $0.appearance = selection.appearance }
    }
}
