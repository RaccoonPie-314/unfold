import Foundation

/// Which transition, with what timing, moving what.
enum TransitionID: String, CaseIterable {
    case rowInsert, rowRemove, selectionMorph, paneReveal, statusMorph
    case promptPresent, promptDismiss
}

enum Curve: Equatable {
    /// A damped spring with one knob. `damping` is the damping ratio ζ, and second-order systems only
    /// overshoot for ζ < 1 (ζ = 0.85 peaks at ~0.63% of the step, so the settle reads as a stop, not a
    /// bounce). There is deliberately **no** settle-time parameter: the transition's `duration` *is* the
    /// settle time, and `Motion` derives the stiffness that makes `CASpringAnimation.settlingDuration`
    /// land on it. Two clocks that can disagree is what left every spring truncated mid-ramp with a
    /// visible pop, so one of them had to go (Ruling AC #1).
    case spring(damping: Double)
    /// Four control points. The approved shape is (0.33, 1, 0.68, 1).
    case easeOut(Double, Double, Double, Double)
}

/// The kinds of motion the shell can express. There is no `.fade` member: opacity is an anti-flash
/// ramp inside a geometric transition, never a transition, and a type that cannot say "fade only" is
/// how that stays true.
enum Geometry {
    case scaleFromGap      // a row unfolds out of the gap it is opening
    case collapseToGap     // a row shrinks into the gap it is closing
    case growFromEdge      // a pane grows from the divider side
    case positionCrossfade // shared element from one rect to another
    case symbolMorph       // SF Symbol replacement plus a width change
}

struct Transition: Equatable {
    let id: TransitionID
    let duration: Double
    let curve: Curve
    let geometry: Geometry
    /// The anti-flash ramp, as a fraction of the timeline. Kept at 0.2 so opacity never carries motion:
    /// the ramp only ever *starts* an element slightly transparent, and the geometry does the telling.
    let opacityRamp: Double
}

/// Seam note: durations and curve parameters are `Double` here while the geometry is `CGFloat`
/// (`MotionGeometry`), and the driver (Task 10) owns the conversion between the two.
enum MotionPlan {
    static let all: [Transition] = [
        .init(id: .rowInsert, duration: 0.26, curve: .spring(damping: 0.85),
              geometry: .scaleFromGap, opacityRamp: 0.2),
        .init(id: .rowRemove, duration: 0.22, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .collapseToGap, opacityRamp: 0.2),
        .init(id: .selectionMorph, duration: 0.20, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .positionCrossfade, opacityRamp: 0.2),
        .init(id: .paneReveal, duration: 0.28, curve: .spring(damping: 0.85),
              geometry: .growFromEdge, opacityRamp: 0.2),
        .init(id: .statusMorph, duration: 0.24, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .symbolMorph, opacityRamp: 0.2),
        .init(id: .promptPresent, duration: 0.22, curve: .spring(damping: 0.85),
              geometry: .positionCrossfade, opacityRamp: 0.2),
        .init(id: .promptDismiss, duration: 0.18, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .positionCrossfade, opacityRamp: 0.2),
    ]

    /// `promptPresent` and `promptDismiss` are declared here and wired in Plan 4, whose prompt panel is
    /// the only thing that uses them. They belong to the plan now so the table is the complete contract
    /// and Task 11's assertions do not have to be edited later.
    static func lookup(_ id: TransitionID) -> Transition? {
        all.first { $0.id == id }
    }
}
