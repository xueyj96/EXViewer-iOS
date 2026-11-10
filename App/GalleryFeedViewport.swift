import SwiftUI
import ExViewerCore

struct GalleryFeedViewport {
    var space: String
    var height: CGFloat
    var topOcclusion: CGFloat = 0
    var contentTop: CGFloat { min(max(0, topOcclusion), max(0, height)) }

    static func restorationID(for galleryID: String) -> String { "feed.restore.\(galleryID)" }

    // The one-point marker restores immediately below the floating header,
    // independently of the cover's aspect ratio.
    var restorationAlignment: UnitPoint {
        UnitPoint(x: 0.5, y: min(max(0, topOcclusion) / max(1, height - 1), 1))
    }

    struct CoverEdge: Equatable {
        let id: String
        let width: CGFloat
    }

    func coverEdges(in frames: [String: CGRect]) -> [CoverEdge] {
        guard height > contentTop else { return [] }
        // Each masonry column has a different bottom visible card.
        var columns: [CGFloat: (id: String, frame: CGRect)] = [:]
        for (id, frame) in frames where frame.maxY > contentTop && frame.minY < height && frame.width > 0 {
            if let current = columns[frame.minX], current.frame.minY >= frame.minY { continue }
            columns[frame.minX] = (id, frame)
        }
        return columns.keys.sorted().compactMap { columns[$0] }
            .map { CoverEdge(id: $0.id, width: $0.frame.width) }
    }

    static func upcomingCovers(after id: String, in columns: [[Gallery]]) -> ArraySlice<Gallery> {
        for column in columns {
            guard let index = column.firstIndex(where: { $0.id == id }) else { continue }
            return column.dropFirst(index + 1).prefix(2)
        }
        return []
    }

    func nearestVisibleAnchor(in frames: [String: CGRect]) -> String? {
        guard height > contentTop else { return nil }
        return frames.filter { $0.value.maxY > contentTop && $0.value.minY < height }.min { lhs, rhs in
            let a = abs(lhs.value.minY - contentTop), b = abs(rhs.value.minY - contentTop)
            if a != b { return a < b }
            if lhs.value.minY != rhs.value.minY { return lhs.value.minY < rhs.value.minY }
            if lhs.value.minX != rhs.value.minX { return lhs.value.minX < rhs.value.minX }
            return lhs.key < rhs.key
        }?.key
    }
}
