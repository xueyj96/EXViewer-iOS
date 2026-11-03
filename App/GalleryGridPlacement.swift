import Foundation

/// Preview geometry only. Keep source dimensions intact for the reader.
enum GalleryCoverLayout {
    static let fallbackAspect = 0.71
    static let minimumAspect = 0.5
    static let maximumAspect = 2.0

    static func displayAspect(_ source: Double) -> Double {
        guard source.isFinite, source > 0 else { return fallbackAspect }
        return min(maximumAspect, max(minimumAspect, source))
    }
}

/// A feed keeps existing cards in their columns as covers resolve and pages
/// append. A new ordering starts a new placement; deletions only close gaps.
struct GalleryGridPlacement {
    private(set) var order: [String] = []
    private(set) var columns: [[String]] = [[], []]

    mutating func update(ids: [String], aspects: [String: Double]) {
        var seen = Set<String>()
        let incoming = ids.filter { seen.insert($0).inserted }
        guard incoming != order else { return }
        let incomingSet = Set(incoming)
        let retained = order.filter { incomingSet.contains($0) }
        // Preserve only an existing prefix followed by new items. A prepend,
        // insertion or explicit sort must display the new source order.
        if Array(incoming.prefix(retained.count)) != retained {
            columns = [[], []]
        } else {
            columns = columns.map { $0.filter { incomingSet.contains($0) } }
        }
        // Removing every card from one column must not strand all survivors
        // in the other. Ordinary metadata changes and appends stay stable.
        if incoming.count > 1, columns.contains(where: \.isEmpty), !columns.allSatisfy(\.isEmpty) {
            columns = [[], []]
        }
        func height(_ id: String) -> Double {
            1 / GalleryCoverLayout.displayAspect(aspects[id] ?? GalleryCoverLayout.fallbackAspect) + 0.36
        }
        var heights = columns.map { $0.reduce(0) { $0 + height($1) } }
        let assigned = Set(columns.flatMap { $0 })
        for id in incoming where !assigned.contains(id) {
            let column = heights[0] <= heights[1] ? 0 : 1
            columns[column].append(id)
            heights[column] += height(id)
        }
        order = incoming
    }
}
