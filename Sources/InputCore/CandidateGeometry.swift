import Foundation
import CoreGraphics

public enum CandidateGeometry {
    public static func frame(size: CGSize, caret: CGRect, visible: CGRect) -> CGRect {
        let width = min(max(1, size.width), visible.width)
        let height = min(max(1, size.height), visible.height)
        let x = min(max(caret.minX, visible.minX), visible.maxX - width)
        let below = caret.minY - height - 6
        let preferredY = below >= visible.minY ? below : caret.maxY + 6
        let y = min(max(preferredY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
