import SwiftUI

/// The silhouette of a folder: a small tab on the top left, then the body.
struct FolderShape: InsettableShape {
    var tabWidth: CGFloat = 0.42
    var tabHeight: CGFloat = 14
    var cornerRadius: CGFloat = 18
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> FolderShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: inset, dy: inset)
        let radius = min(cornerRadius, box.width / 4, box.height / 4)
        let tab = min(box.width * tabWidth, box.width - 2 * radius)
        let lip = min(tabHeight, box.height / 5)
        let shoulder = lip * 0.9
        let tabRadius = radius * 0.45

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + x, y: box.minY + y)
        }

        var path = Path()
        path.move(to: point(0, box.height - radius))
        path.addLine(to: point(0, tabRadius))
        path.addQuadCurve(to: point(tabRadius, 0), control: point(0, 0))
        path.addLine(to: point(tab - tabRadius, 0))
        // The shoulder between the tab and the body.
        path.addQuadCurve(to: point(tab + shoulder * 0.45, lip * 0.6), control: point(tab + tabRadius * 0.3, 0))
        path.addQuadCurve(to: point(tab + shoulder, lip), control: point(tab + shoulder * 0.85, lip))
        path.addLine(to: point(box.width - radius, lip))
        path.addQuadCurve(to: point(box.width, lip + radius), control: point(box.width, lip))
        path.addLine(to: point(box.width, box.height - radius))
        path.addQuadCurve(to: point(box.width - radius, box.height), control: point(box.width, box.height))
        path.addLine(to: point(radius, box.height))
        path.addQuadCurve(to: point(0, box.height - radius), control: point(0, box.height))
        path.closeSubpath()
        return path
    }
}
