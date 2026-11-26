import Foundation

/// Pile annuler / rétablir illimitée. Chaque commande enregistre l'état du projet avant modification.
/// Les réglages continus (curseurs, glisser) d'un même paramètre sont regroupés en une seule étape.
struct UndoStack {
    struct Entry {
        var state: Project
        var name: String
        var coalesceKey: String?
        var date: Date
    }

    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []

    /// Délai pendant lequel des modifications de même clé sont fusionnées.
    var coalesceInterval: TimeInterval = 1.5

    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var undoName: String? { undoEntries.last?.name }
    var redoName: String? { redoEntries.last?.name }

    mutating func record(before: Project, name: String, coalesceKey: String? = nil, now: Date = Date()) {
        if let key = coalesceKey, let last = undoEntries.last, last.coalesceKey == key,
           now.timeIntervalSince(last.date) < coalesceInterval {
            undoEntries[undoEntries.count - 1].date = now
            redoEntries.removeAll()
            return
        }
        undoEntries.append(Entry(state: before, name: name, coalesceKey: coalesceKey, date: now))
        redoEntries.removeAll()
    }

    mutating func undo(current: Project) -> Project? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(state: current, name: entry.name, coalesceKey: nil, date: Date()))
        return entry.state
    }

    mutating func redo(current: Project) -> Project? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(state: current, name: entry.name, coalesceKey: nil, date: Date()))
        return entry.state
    }

    mutating func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}
