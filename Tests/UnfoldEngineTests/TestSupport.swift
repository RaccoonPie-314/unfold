import Foundation
@testable import UnfoldEngine

func makeCombo(
    _ trigger: String,
    replacement: String = "x",
    enabled: Bool = true
) -> Combo {
    Combo(
        id: UUID(),
        trigger: trigger,
        label: trigger,
        enabled: enabled,
        parts: [.text(replacement)],
        insertion: .paste
    )
}
