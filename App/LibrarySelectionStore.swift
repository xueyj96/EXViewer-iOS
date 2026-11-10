import Combine
import Foundation

@MainActor
struct LibrarySelectionSummaryState: Equatable {
    var count = 0
    var allLoadedSelected = false
}

@MainActor
final class LibrarySelectionSummary: ObservableObject {
    @Published private(set) var value = LibrarySelectionSummaryState()

    fileprivate func update(count: Int, allLoadedSelected: Bool) {
        let next = LibrarySelectionSummaryState(count: count, allLoadedSelected: allLoadedSelected)
        if value != next { value = next }
    }
}

@MainActor
final class LibrarySelectionEntry: ObservableObject {
    @Published private(set) var isSelected: Bool

    fileprivate init(isSelected: Bool) { self.isSelected = isSelected }

    fileprivate func update(_ selected: Bool) {
        if isSelected != selected { isSelected = selected }
    }
}

/// Owns selection without broadcasting a whole-feed update for each tap.
/// Visible cells observe only their stable per-ID entry; count and select-all
/// controls observe a separate summary object.
@MainActor
final class LibrarySelectionStore: ObservableObject {
    let summary = LibrarySelectionSummary()
    private(set) var selectedIDs = Set<String>()
    private var loadedIDs = Set<String>()
    private var entries: [String: LibrarySelectionEntry] = [:]

    func entry(for id: String) -> LibrarySelectionEntry {
        if let entry = entries[id] { return entry }
        let entry = LibrarySelectionEntry(isSelected: selectedIDs.contains(id))
        entries[id] = entry
        return entry
    }

    /// Dataset membership changes only when the filtered gallery identities
    /// change. Adding a page preserves the existing selection.
    func updateLoadedIDs(_ ids: Set<String>) {
        guard loadedIDs != ids else { return }
        let removed = selectedIDs.subtracting(ids)
        for id in removed { entries[id]?.update(false) }
        selectedIDs.subtract(removed)
        loadedIDs = ids
        entries = entries.reduce(into: [:]) { retained, element in
            if ids.contains(element.key) { retained[element.key] = element.value }
        }
        publishSummary()
    }

    @discardableResult
    func beginSelecting(_ id: String) -> Bool {
        guard loadedIDs.contains(id) else { return false }
        for (entryID, entry) in entries where selectedIDs.contains(entryID) && entryID != id {
            entry.update(false)
        }
        selectedIDs = [id]
        entry(for: id).update(true)
        publishSummary()
        return true
    }

    @discardableResult
    func toggle(_ id: String) -> Bool {
        guard loadedIDs.contains(id) else { return false }
        if selectedIDs.remove(id) != nil {
            entries[id]?.update(false)
        } else {
            selectedIDs.insert(id)
            entries[id]?.update(true)
        }
        publishSummary()
        return true
    }

    func toggleAllLoaded() {
        guard !loadedIDs.isEmpty else { return }
        if summary.value.allLoadedSelected {
            for id in loadedIDs {
                selectedIDs.remove(id)
                entries[id]?.update(false)
            }
        } else {
            for id in loadedIDs {
                selectedIDs.insert(id)
                entries[id]?.update(true)
            }
        }
        publishSummary()
    }

    func remove(_ ids: [String]) {
        for id in ids {
            guard selectedIDs.remove(id) != nil else { continue }
            entries[id]?.update(false)
        }
        publishSummary()
    }

    func clear() {
        for (id, entry) in entries where selectedIDs.contains(id) { entry.update(false) }
        selectedIDs.removeAll(keepingCapacity: true)
        publishSummary()
    }

    private func publishSummary() {
        // A selection can only contain loaded IDs, including after the feed changes.
        summary.update(count: selectedIDs.count,
                       allLoadedSelected: !loadedIDs.isEmpty && selectedIDs.count == loadedIDs.count)
    }
}
