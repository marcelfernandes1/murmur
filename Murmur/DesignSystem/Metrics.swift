import CoreGraphics

/// Spacing rhythm — a 4-pt base scale. Use these instead of magic numbers so
/// every surface breathes the same way.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48
}

/// Corner-radius scale. Liquid Glass concave shapes read best on the larger end.
enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
    /// Effectively a capsule for pill-shaped glass (the notch, badges).
    static let pill: CGFloat = 999
}
