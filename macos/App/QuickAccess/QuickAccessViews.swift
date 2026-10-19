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
                    .onDrag { NSItemProvider(contentsOf: card.item.url) ?? NSItemProvider() }
            } else {
                Color.gray.opacity(0.3)
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
                        iconButton("pencil", help: "Edit") { actions.edit(card) }
                        if actions.hasPin() {
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
        .onHover { card.hovering = $0 }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.6)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
