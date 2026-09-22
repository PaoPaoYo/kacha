struct AnnotationDocumentState: Equatable {
    var annotations: [Annotation]
    var selectedAnnotationID: Annotation.ID?
}

struct AnnotationHistory {
    private var undoStack: [AnnotationDocumentState] = []
    private var redoStack: [AnnotationDocumentState] = []
    private(set) var current: AnnotationDocumentState

    init(initial: AnnotationDocumentState) {
        current = initial
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    mutating func commit(_ state: AnnotationDocumentState) {
        guard state != current else { return }
        undoStack.append(current)
        current = state
        redoStack.removeAll()
    }

    mutating func undo() -> AnnotationDocumentState? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        current = previous
        return current
    }

    mutating func redo() -> AnnotationDocumentState? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        current = next
        return current
    }
}
