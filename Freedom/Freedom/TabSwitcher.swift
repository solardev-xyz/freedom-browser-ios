import SwiftUI
import UIKit

struct TabSwitcher: View {
    @Environment(TabStore.self) private var tabStore
    @Binding var isPresented: Bool
    /// Which group the grid shows — Safari's bottom switch. Starts on
    /// the active tab's group.
    @State private var showingPrivate = false

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    private var shown: [TabRecord] { tabStore.records.filter { $0.isPrivate == showingPrivate } }
    private var normalCount: Int { tabStore.records.filter { !$0.isPrivate }.count }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(shown, id: \.id) { record in
                            TabCard(
                                record: record,
                                isActive: record.id == tabStore.activeRecordID,
                                onActivate: {
                                    tabStore.activate(record.id)
                                    isPresented = false
                                }
                            )
                            .id(record.id)
                        }
                    }
                    .padding()
                    .animation(.spring, value: tabStore.records.count)
                }
                .scrollContentBackground(.hidden)
                .task {
                    // Land the viewport on the active card — Safari-style —
                    // so users with many tabs don't have to hunt for the one
                    // they're currently viewing. Scroll is synchronous and
                    // runs first so the position is right from frame one;
                    // captureActive then runs in parallel effectively,
                    // refreshing the card's snapshot (otherwise only taken
                    // on switch-away or background).
                    showingPrivate = tabStore.activeRecord?.isPrivate ?? false
                    if let active = tabStore.activeRecordID {
                        proxy.scrollTo(active, anchor: .center)
                    }
                    await tabStore.captureActive()
                }
            }
            .navigationTitle(showingPrivate ? "Private" : "Tabs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            // Safari's overview sits on a frosted version of the home
            // screen; ours on the home page's hero — same idea, our brand.
            .background {
                Image("HomeHero")
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 40, opaque: true)
                    .overlay(Color.black.opacity(0.45))
                    .ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            // Dark scheme for everything on the frosted hero, the bottom
            // bar included (it is outside the inset's content otherwise).
            .environment(\.colorScheme, .dark)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView {
                        Label(showingPrivate ? "No private tabs" : "No tabs", systemImage: showingPrivate ? "eye.slash" : "square.dashed")
                    } description: {
                        Text(showingPrivate
                            ? "Private tabs keep no history, cookies or logins and are gone after a restart."
                            : "Tap + to open a tab.")
                    }
                }
            }
        }
    }

    /// Safari's tab-overview bar: + (a tab in the shown group), the
    /// Private / N Tabs group switch, Done.
    private static let barControl: CGFloat = 52

    private var bottomBar: some View {
        GlassChromeGroup(spacing: 12) {
        HStack(spacing: 12) {
            // Tap: a new tab in the shown group. Long-press: the tabs
            // closed this run, to reopen (Safari hides it here too).
            Menu {
                Section("Recently closed") {
                    if tabStore.recentlyClosed.isEmpty {
                        Text("Nothing to reopen")
                    }
                    ForEach(tabStore.recentlyClosed.entries) { entry in
                        Button {
                            tabStore.reopen(entry)
                            isPresented = false
                        } label: {
                            Label(entry.displayTitle, systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .frame(width: Self.barControl, height: Self.barControl)
            } primaryAction: {
                tabStore.newTab(isPrivate: showingPrivate)
                isPresented = false
            }
            .tint(.white)
            .accessibilityLabel(showingPrivate ? "New private tab" : "New tab")
            .glassCircle()
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                groupButton(title: "Private", isPrivate: true)
                groupButton(title: normalCount == 1 ? "1 Tab" : "\(normalCount) Tabs", isPrivate: false)
            }
            .padding(4)
            .frame(height: Self.barControl)
            .glassPill()
            Spacer(minLength: 0)
            Button { isPresented = false } label: {
                Image(systemName: "checkmark")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.barControl, height: Self.barControl)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
            .glassCircle(tint: .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        }
    }

    private func groupButton(title: String, isPrivate: Bool) -> some View {
        let selected = showingPrivate == isPrivate
        return Button {
            withAnimation(.snappy(duration: 0.2)) { showingPrivate = isPrivate }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 18)
                .frame(maxHeight: .infinity)
                .background {
                    if selected {
                        Capsule().fill(Color.white.opacity(0.18))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

private struct TabCard: View {
    let record: TabRecord
    let isActive: Bool
    let onActivate: () -> Void
    @Environment(TabStore.self) private var tabStore

    @State private var dragOffset: CGFloat = 0
    @State private var isClosing = false

    // Drag past this or fling past the predicted threshold ⇒ dismiss.
    private static let dismissDistance: CGFloat = -100
    private static let dismissPredicted: CGFloat = -200
    private static let slideOffDuration: TimeInterval = 0.22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                // Visual only — SwipeCardOverlay handles the tap (the top-
                // right corner maps to close, rest of the card to activate).
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .font(.title3)
                    .padding(6)
            }
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(record.isPrivate ? Color.purple : Color.accentColor, lineWidth: 2)
                }
            }
            .overlay(alignment: .topLeading) {
                if record.isPrivate {
                    Image(systemName: "eye.slash.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Color.purple.opacity(0.85), in: Circle())
                        .padding(6)
                        .accessibilityLabel("Private tab")
                }
            }
            Text(displayTitle)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .offset(x: dragOffset)
        .opacity(isClosing ? 0 : max(0.3, 1.0 - abs(dragOffset) / 400.0))
        .overlay(
            SwipeCardOverlay(
                onActivate: onActivate,
                onClose: { tabStore.close(record.id) },
                onPanChanged: { dx in
                    dragOffset = min(0, dx)
                },
                onPanEnded: { dx, vx in
                    let crossed = dx < Self.dismissDistance
                        || dx + vx * 0.15 < Self.dismissPredicted
                    if crossed {
                        withAnimation(.easeOut(duration: Self.slideOffDuration)) {
                            dragOffset = -500
                            isClosing = true
                        } completion: {
                            tabStore.close(record.id)
                        }
                    } else {
                        withAnimation(.spring) {
                            dragOffset = 0
                        }
                    }
                }
            )
        )
    }

    @ViewBuilder private var thumbnail: some View {
        if let data = record.lastSnapshot, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 200)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.tertiarySystemBackground))
                .frame(height: 200)
                .overlay {
                    Image(systemName: "globe")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    private var displayTitle: String {
        if let t = record.title, !t.isEmpty { return t }
        if let host = record.url?.host { return host }
        return "New Tab"
    }
}

/// UIKit-bridged overlay that handles tap + horizontal-pan on a tab card
/// while letting the ancestor UIScrollView own vertical-pan for grid scroll.
/// SwiftUI's DragGesture inside a ScrollView can't be tuned (minimumDistance,
/// simultaneousGesture, axis gates) to reliably yield to scroll; a UIKit
/// UIPanGestureRecognizer with a `gestureRecognizerShouldBegin` delegate
/// that inspects initial velocity cooperates cleanly.
private struct SwipeCardOverlay: UIViewRepresentable {
    let onActivate: () -> Void
    let onClose: () -> Void
    let onPanChanged: (_ dx: CGFloat) -> Void
    let onPanEnded: (_ dx: CGFloat, _ vx: CGFloat) -> Void

    /// Top-right square that maps to "X" for the tap router. Tracks the
    /// painted X icon's visible footprint (`xmark.circle.fill` at .title3
    /// + 6pt padding ≈ 30pt; 44pt gives the standard Apple tap target).
    private static let closeHitRegion: CGFloat = 44

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        v.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        pan.delegate = context.coordinator
        v.addGestureRecognizer(pan)

        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SwipeCardOverlay
        init(_ parent: SwipeCardOverlay) { self.parent = parent }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let v = g.view else { return }
            let loc = g.location(in: v)
            let size = v.bounds.size
            let inCloseRegion = loc.x > size.width - SwipeCardOverlay.closeHitRegion
                && loc.y < SwipeCardOverlay.closeHitRegion
            if inCloseRegion { parent.onClose() } else { parent.onActivate() }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view else { return }
            let t = g.translation(in: v)
            switch g.state {
            case .changed:
                parent.onPanChanged(t.x)
            case .ended, .cancelled, .failed:
                parent.onPanEnded(t.x, g.velocity(in: v).x)
            default: break
            }
        }

        /// Only claim the touch when the initial motion is clearly
        /// horizontal — otherwise UIScrollView's vertical pan wins and
        /// the grid scrolls normally.
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }
    }
}
