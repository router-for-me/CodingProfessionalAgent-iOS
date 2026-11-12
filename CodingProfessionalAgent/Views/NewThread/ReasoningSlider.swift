import SwiftUI

// Discrete capsule slider that selects one of the model's reasoning levels.
struct ReasoningSlider: View {
    let levels: [ReasoningChoice]
    @Binding var selection: String

    private let width: CGFloat = 340
    private let height: CGFloat = 70
    private let inset: CGFloat = 11
    private let knobSize: CGFloat = 40
    private let dotSize: CGFloat = 11

    private var innerHeight: CGFloat { height - inset * 2 }

    private var step: CGFloat {
        levels.count > 1 ? (width - inset * 2 - innerHeight) / CGFloat(levels.count - 1) : 0
    }

    private var selectedIndex: Int {
        levels.firstIndex { $0.id == selection } ?? 0
    }

    var body: some View {
        let current = position(of: selectedIndex)
        let fillWidth = current + innerHeight / 2 - inset

        ZStack {
            Capsule()
                .fill(Theme.accent)
                .frame(width: fillWidth, height: innerHeight)
                .position(x: inset + fillWidth / 2, y: height / 2)

            ForEach(Array(levels.enumerated()), id: \.element.id) { index, _ in
                Circle()
                    .fill(index < selectedIndex ? Color.white.opacity(0.35) : Color(.systemGray4))
                    .frame(width: dotSize, height: dotSize)
                    .position(x: position(of: index), y: height / 2)
                    .opacity(index == selectedIndex ? 0 : 1)
            }

            Circle()
                .fill(.white)
                .frame(width: knobSize, height: knobSize)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .position(x: current, y: height / 2)
        }
        .frame(width: width, height: height)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    select(at: value.location.x)
                }
        )
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func position(of index: Int) -> CGFloat {
        inset + innerHeight / 2 + CGFloat(index) * step
    }

    private func select(at x: CGFloat) {
        guard !levels.isEmpty, step > 0 else { return }
        let index = Int(((x - inset - innerHeight / 2) / step).rounded())
        let clamped = min(max(index, 0), levels.count - 1)
        let newValue = levels[clamped].id
        if newValue != selection {
            selection = newValue
        }
    }
}

// Blurred overlay that hosts the reasoning slider above the composer; tapping outside dismisses it.
// The reasoning title always opens the advanced settings; the model title only while `canChangeModel`
// (false e.g. while a run is active).
struct ReasoningOverlay: View {
    let modelTitle: String
    let reasoningTitle: String
    let levels: [ReasoningChoice]
    @Binding var selection: String
    var canChangeModel = true
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.55),
                            .init(color: .black, location: 0.75),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 24) {
                title
                ReasoningSlider(levels: levels, selection: $selection)
            }
            .padding(.bottom, 2)
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            if canChangeModel {
                Button(action: onOpenSettings) {
                    HStack(spacing: 8) {
                        modelLabel
                        reasoningLabel
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                modelLabel
                    // Swallows taps, which would otherwise reach the background and dismiss the overlay.
                    .contentShape(Rectangle())
                    .onTapGesture {}
                Button(action: onOpenSettings) {
                    reasoningLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 22, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 20)
    }

    private var modelLabel: some View {
        Text(modelTitle)
            .foregroundStyle(.primary)
    }

    private var reasoningLabel: some View {
        HStack(spacing: 8) {
            Text(reasoningTitle)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    @Previewable @State var selection = "high"
    ReasoningSlider(
        levels: ["low", "medium", "high", "xhigh", "max"].map { ReasoningChoice(id: $0, title: ReasoningChoice.title(for: $0)) },
        selection: $selection
    )
}
