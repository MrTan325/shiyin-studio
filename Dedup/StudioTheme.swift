import SwiftUI
import AppKit

/// Semantic system colors adapt in the host window and in presented sheets.
/// No app, window or SwiftUI appearance override is installed.
enum StudioTheme {
    static let sidebar=Color(nsColor:.windowBackgroundColor)
    static let content=Color(nsColor:.textBackgroundColor)
    static let panel=Color(nsColor:.controlBackgroundColor)
    static let row=Color(nsColor:.textBackgroundColor)
    static let border=Color(nsColor:.separatorColor)
    static let accent=Color.accentColor
    static let selection=Color.accentColor.opacity(0.12)
}
