import SwiftUI
import UIKit

/// Drag-to-confirm gesture component. Tx irreversibility justifies the
/// extra 300ms of drag time over a thumb-tap; connect / sign / chain-
/// switch keep the tap (per §8). VoiceOver / Switch Control bypass the
/// gesture via the "Approve" accessibility action.
@MainActor
struct SlideToApprove: View {
    let title: String
    let action: () -> Void

    init(title: String = "Slide to approve", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    private let height: CGFloat = 56
    private let thumbInset: CGFloat = 4
    private let completionThreshold: Double = 0.85
    private let postCompletionHold: Duration = .milliseconds(250)

    private static let snapBackSpring: Animation = .spring(response: 0.35, dampingFraction: 0.8)
    private static let lockInSpring: Animation = .spring(response: 0.30, dampingFraction: 0.85)

    @State private var dragOffset: CGFloat = 0
    @State private var isCompleted = false
    @State private var didHapticAtThreshold = false
    @State private var commitTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let thumbDiameter = height - thumbInset * 2
            let maxOffset = max(0, trackWidth - thumbDiameter - thumbInset * 2)
            let progress = maxOffset > 0 ? min(1, dragOffset / maxOffset) : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.15))

                Capsule()
                    .fill(Color.accentColor.opacity(0.30))
                    .frame(width: dragOffset + thumbDiameter + thumbInset * 2)

                Text(isCompleted ? "Approved" : title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .opacity(isCompleted ? 1 : 1 - progress)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .allowsHitTesting(false)

                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: isCompleted ? "checkmark" : "chevron.right")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                }
                .frame(width: thumbDiameter, height: thumbDiameter)
                .offset(x: thumbInset + dragOffset)
                .gesture(dragGesture(maxOffset: maxOffset))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCompleted ? "Approved" : title)
        .accessibilityHint("Drag from left to right to approve.")
        .accessibilityAction(named: "Approve", action)
        .onDisappear { commitTask?.cancel() }
    }

    private func dragGesture(maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isCompleted, maxOffset > 0 else { return }
                let newOffset = max(0, min(value.translation.width, maxOffset))
                let crossed = newOffset / maxOffset >= completionThreshold
                if crossed && !didHapticAtThreshold {
                    didHapticAtThreshold = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else if !crossed && didHapticAtThreshold {
                    didHapticAtThreshold = false
                }
                dragOffset = newOffset
            }
            .onEnded { _ in
                guard !isCompleted, maxOffset > 0 else { return }
                if dragOffset / maxOffset >= completionThreshold {
                    complete(maxOffset: maxOffset)
                } else {
                    withAnimation(Self.snapBackSpring) { dragOffset = 0 }
                    didHapticAtThreshold = false
                }
            }
    }

    private func complete(maxOffset: CGFloat) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(Self.lockInSpring) {
            dragOffset = maxOffset
            isCompleted = true
        }
        // Cancellable so a mid-hold dismissal (sheet swipe / app backgrounding)
        // doesn't fire `action()` against a torn-down sheet.
        commitTask = Task {
            try? await Task.sleep(for: postCompletionHold)
            if Task.isCancelled { return }
            action()
        }
    }
}
