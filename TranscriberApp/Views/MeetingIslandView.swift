import Observation
import SwiftUI
import TranscriberCore

/// What the island shows. The presenter builds one per offer (start or stop) and owns the callbacks.
struct MeetingIslandOffer {
    let title: String
    var subtitle: String
    let primaryTitle: String
    let primary: @MainActor () -> Void
    /// Secondary choices behind the chevron: ("Name it first…", …), ("Not now", …), …
    let menu: [(title: String, action: @MainActor () -> Void)]
    /// Compact state text: the app name ("Zoom").
    let compactLabel: String
}

/// What restarts the collapse countdown. `generation` is what makes a *re-show* count: a stop offer
/// replacing an already-expanded start offer leaves `isExpanded` at `true`, and a SwiftUI `.task(id:)`
/// only restarts when the id's value changes — without the generation the new offer would inherit the
/// old offer's remaining seconds and could vanish moments after appearing.
struct MeetingIslandCollapseKey: Equatable {
    let isExpanded: Bool
    let generation: Int
}

@MainActor
@Observable
final class MeetingIslandModel {
    var offer: MeetingIslandOffer
    var isExpanded: Bool
    var isHovering = false
    /// Bumped by the controller on every `show()`.
    var generation = 0

    var collapseKey: MeetingIslandCollapseKey {
        MeetingIslandCollapseKey(isExpanded: isExpanded, generation: generation)
    }

    init(offer: MeetingIslandOffer, isExpanded: Bool) {
        self.offer = offer
        self.isExpanded = isExpanded
    }
}

/// Notion-style pill: icon · title + subtitle · ONE primary button · chevron menu. Compact = red dot +
/// app name. Sizes and position come from `MeetingIslandPlacement`; this view only lays the pill out
/// inside the (larger, transparent) panel, top-anchored so collapsing shrinks it in place.
struct MeetingIslandView: View {
    let model: MeetingIslandModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        pill
            .padding(.top, MeetingIslandPlacement.topGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: model.isExpanded)
            // Armed when the island expands and re-armed when a new offer arrives; SwiftUI cancels it
            // when the island collapses or the panel goes away. One sleep at a time, and it only
            // repeats while the pointer rests on the pill — an app with no offer on screen holds none.
            .task(id: model.collapseKey) {
                guard model.isExpanded else { return }
                await MeetingIslandCollapse.run(
                    sleep: { try? await Task.sleep(for: .seconds(MeetingIslandCollapse.delaySeconds)) },
                    isHovering: { model.isHovering },
                    collapse: { model.isExpanded = false }
                )
            }
    }

    private var pill: some View {
        Group {
            if model.isExpanded { expanded } else { compact }
        }
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .onHover { model.isHovering = $0 }
    }

    private var expanded: some View {
        HStack(spacing: 12) {
            // Decorative: the title beside it says who is asking.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.offer.title).font(.headline).lineLimit(1)
                Text(model.offer.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // Deliberately NO .keyboardShortcut(.defaultAction): the panel is non-activating and never
            // becomes key, so the shortcut could only ever fire from somewhere else in the app — a
            // stray Return starting a recording is not a trade worth making for a shortcut that
            // cannot work here anyway.
            Button(model.offer.primaryTitle) { model.offer.primary() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            Menu {
                ForEach(Array(model.offer.menu.enumerated()), id: \.offset) { _, item in
                    Button(item.title) { item.action() }
                }
            } label: {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .accessibilityLabel("More options")
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 8)
        .frame(width: MeetingIslandPlacement.expandedSize.width,
               height: MeetingIslandPlacement.expandedSize.height)
    }

    private var compact: some View {
        HStack(spacing: 8) {
            // The design system's dot. Not pulsing: a start offer is not a recording, and the same pill
            // serves both offers — a pulse here would claim Parley is already capturing.
            StatusDot(color: .red)
            Text(model.offer.compactLabel).font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(width: MeetingIslandPlacement.compactSize.width,
               height: MeetingIslandPlacement.compactSize.height)
        .contentShape(Capsule())
        .onTapGesture { model.isExpanded = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(model.offer.title) — \(model.offer.compactLabel). Activate to expand.")
    }
}
