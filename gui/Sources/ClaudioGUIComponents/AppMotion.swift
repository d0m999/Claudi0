import SwiftUI

public enum AppMotion {
    public static var spring: Animation {
        .interpolatingSpring(mass: 1, stiffness: 380, damping: 30, initialVelocity: 0)
    }
}

/// Equal vertex counts preserve winding and visual identity through triangle → square.
public struct PreviewMorphGlyph: Shape {
    public var progress: CGFloat
    public var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    public init(progress: CGFloat) { self.progress = progress }
    public func path(in rect: CGRect) -> Path {
        let p = min(1, max(0, progress))
        let triangle: [CGPoint] = [
            CGPoint(x: 0.24, y: 0.12), CGPoint(x: 0.76, y: 0.40),
            CGPoint(x: 0.92, y: 0.50), CGPoint(x: 0.76, y: 0.60),
            CGPoint(x: 0.24, y: 0.88), CGPoint(x: 0.24, y: 0.50),
        ]
        let square: [CGPoint] = [
            CGPoint(x: 0.20, y: 0.20), CGPoint(x: 0.80, y: 0.20),
            CGPoint(x: 0.80, y: 0.50), CGPoint(x: 0.80, y: 0.80),
            CGPoint(x: 0.20, y: 0.80), CGPoint(x: 0.20, y: 0.50),
        ]
        let points = zip(triangle, square).map { a, b in
            CGPoint(
                x: rect.minX + (a.x + (b.x - a.x) * p) * rect.width,
                y: rect.minY + (a.y + (b.y - a.y) * p) * rect.height)
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}
