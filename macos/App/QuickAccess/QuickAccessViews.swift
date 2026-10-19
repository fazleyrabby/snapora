import AppKit
import SwiftUI

struct QuickAccessActions {
    let copy: (QuickAccessCard) -> Void
    let save: (QuickAccessCard) -> Void
    let edit: (QuickAccessCard) -> Void
    let pin: (QuickAccessCard) -> Void
    let hasPin: () -> Bool
    let close: (QuickAccessCard) -> Void
}

struct QuickAccessStackView: View {
    @ObservedObject var model: QuickAccessModel
    let actions: QuickAccessActions

    var body: some View {
        VStack(alignment: .leading, spacing: QuickAccessMetrics.spacing) {
            ForEach(model.cards) { card in
                QuickAccessCardView(card: card, actions: actions)
            }
        }
        .padding(QuickAccessMetrics.shadowPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

struct QuickAccessCardView: View {
    @ObservedObject var card: QuickAccessCard
    let actions: QuickAccessActions

    var body: some View {
        let size = card.displaySize
        ZStack {
            if let image = card.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else {
                Color.gray.opacity(0.3)
                if card.item.kind == .video { ProgressView().controlSize(.small) }
            }

            if card.item.kind == .video {
                videoBadges
            }

            if card.hovering {
                Color.black.opacity(0.35).allowsHitTesting(false)
                VStack {
                    HStack {
                        Spacer()
                        iconButton("xmark", help: "Close") { actions.close(card) }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        iconButton("doc.on.doc", help: "Copy") { actions.copy(card) }
                        iconButton("square.and.arrow.down", help: "Save") { actions.save(card) }
                        iconButton("pencil", help: "Edit", primary: true) { actions.edit(card) }
                        if card.item.kind == .image, actions.hasPin() {
                            iconButton("pin", help: "Pin") { actions.pin(card) }
                        }
                    }
                }
                .padding(8)
            }

            if let toast = card.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: card.item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { actions.edit(card) }
        .onHover { card.hovering = $0 }
    }

    private var videoBadges: some View {
        ZStack {
            if !card.hovering {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            if let duration = card.item.duration {
                VStack {
                    HStack {
                        Text(Self.format(duration))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
        .allowsHitTesting(false)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func iconButton(_ symbol: String, help: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(primary ? Color.accentColor : Color.black.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
