import ClaudioGUICore

package enum AICuePackDraftNameEdit: Equatable {
    case noDraft
    case unchanged
    case pending(AICuePackName)
    case invalid

    package var needsSave: Bool {
        switch self {
        case .pending, .invalid: true
        case .noDraft, .unchanged: false
        }
    }

    package var savableName: AICuePackName? {
        guard case .pending(let name) = self else { return nil }
        return name
    }
}

package func aiCuePackDraftNameEdit(draftName: String?, input: String) -> AICuePackDraftNameEdit {
    guard let draftName else { return .noDraft }
    guard let name = try? AICuePackName(input) else { return .invalid }
    if name.value == draftName { return .unchanged }
    return .pending(name)
}
