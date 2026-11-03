import SwiftUI

struct StartupLoadingSlideshowView: View {
    let onReachLastSlide: () -> Void
    let onFinish: () -> Void

    @State private var selectedIndex = 0
    @State private var hasTriggeredWarmup = false

    private let slides = LoadingSlide.all

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.12), Color(red: 0.15, green: 0.18, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        LoadingSlideCard(slide: slide, onFinish: onFinish)
                            .tag(index)
                            .padding(.horizontal, 6)
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
            }
        }
        .onChange(of: selectedIndex) { _, newIndex in
            guard newIndex == slides.count - 1, !hasTriggeredWarmup else { return }
            hasTriggeredWarmup = true
            onReachLastSlide()
        }
    }
}

private struct LoadingSlideCard: View {
    let slide: LoadingSlide
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(slide.badgeLeading)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(slide.badgeColor)
                    Text(slide.badgeTrailing)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.white.opacity(0.12))
                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                .clipShape(Capsule())

                Text(slide.title)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(slide.subtitle)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.64))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 26)
            .background(slide.headerGradient)

            slide.visual
                .frame(maxWidth: .infinity)
                .frame(height: slide.isSummary ? nil : 210)
                .padding(.vertical, slide.isSummary ? 24 : 0)
                .background(slide.visualBackground)

            VStack(alignment: .leading, spacing: 12) {
                if let actionLabel = slide.actionLabel,
                   let actionIcon = slide.actionIcon {
                    HStack(spacing: 10) {
                        Text(actionIcon)
                            .font(.system(size: 22))
                        Text(actionLabel)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(slide.accent)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(slide.softAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                ForEach(slide.bodySections) { section in
                    switch section {
                    case let .text(text):
                        Text(text)
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
                            .lineSpacing(4)
                    case let .requirement(icon, title, description, pill):
                        HStack(alignment: .top, spacing: 14) {
                            Text(icon)
                                .font(.system(size: 20))
                                .frame(width: 40, height: 40)
                                .background(slide.softAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(title)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))
                                Text(description)
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
                                    .lineSpacing(3)
                                if let pill {
                                    Text(pill)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(slide.accent)
                                        .clipShape(Capsule())
                                        .padding(.top, 2)
                                }
                            }
                        }
                    }
                }

                if slide.isSummary {
                    Button("Open Camera") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.11, green: 0.11, blue: 0.12))
                    .frame(maxWidth: .infinity, alignment: .center)
                    Text("Review the gestures, then open the live camera feed.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            .background(Color.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

private struct SetupVisual: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("📱")
                .font(.system(size: 36))
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.04, green: 0.52, blue: 1.0), Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .overlay {
                    Text("3 m")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.04, green: 0.52, blue: 1.0))
                        .padding(.horizontal, 6)
                        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
                }
            Text("🧍")
                .font(.system(size: 42))
        }
        .padding(.horizontal, 28)
    }
}

private struct GestureCircleVisual: View {
    let symbol: String
    let accent: Color
    let hint: String

    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 16) {
            Text(symbol)
                .font(.system(size: 72))
                .frame(width: 140, height: 140)
                .background(Color.white)
                .clipShape(Circle())
                .scaleEffect(isAnimating ? 1.04 : 1.0)
                .shadow(color: accent.opacity(isAnimating ? 0.35 : 0.25), radius: isAnimating ? 22 : 18, y: 8)
                .overlay(Circle().stroke(accent.opacity(isAnimating ? 0.1 : 0.16), lineWidth: isAnimating ? 6 : 2))
                .animation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true), value: isAnimating)

            Text(hint)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .textCase(.uppercase)
        }
        .onAppear { isAnimating = true }
    }
}

private struct HorizontalSwipeVisual: View {
    let symbol: String
    let accent: Color
    let arrow: String
    let label: String
    let symbolFirst: Bool

    @State private var isAnimating = false

    private var direction: CGFloat { symbolFirst ? 1 : -1 }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                if symbolFirst {
                    badge
                    arrowText
                } else {
                    arrowText
                    badge
                }
            }

            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .textCase(.uppercase)
        }
        .onAppear { isAnimating = true }
    }

    private var badge: some View {
        Text(symbol)
            .font(.system(size: 64))
            .frame(width: 130, height: 130)
            .background(Color.white)
            .clipShape(Circle())
            .shadow(color: accent.opacity(0.24), radius: 18, y: 8)
            .overlay(Circle().stroke(accent.opacity(0.16), lineWidth: 2))
            .offset(x: isAnimating ? (20 * direction) : (-20 * direction))
            .opacity(isAnimating ? 1.0 : 0.35)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: isAnimating)
    }

    private var arrowText: some View {
        Text(arrow)
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
            .offset(x: isAnimating ? (-8 * direction) : (8 * direction))
            .opacity(isAnimating ? 1.0 : 0.2)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: isAnimating)
    }
}

private struct VerticalSwipeVisual: View {
    let symbol: String
    let accent: Color
    let arrow: String
    let label: String
    let arrowFirst: Bool

    @State private var isAnimating = false

    private var direction: CGFloat { arrowFirst ? -1 : 1 }

    var body: some View {
        VStack(spacing: 12) {
            if arrowFirst {
                arrowText
                badge
            } else {
                badge
                arrowText
            }

            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .textCase(.uppercase)
        }
        .onAppear { isAnimating = true }
    }

    private var badge: some View {
        Text(symbol)
            .font(.system(size: 64))
            .frame(width: 130, height: 130)
            .background(Color.white)
            .clipShape(Circle())
            .shadow(color: accent.opacity(0.24), radius: 18, y: 8)
            .overlay(Circle().stroke(accent.opacity(0.16), lineWidth: 2))
            .offset(y: isAnimating ? (20 * direction) : (-20 * direction))
            .opacity(isAnimating ? 1.0 : 0.35)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: isAnimating)
    }

    private var arrowText: some View {
        Text(arrow)
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
            .offset(y: isAnimating ? (-8 * direction) : (8 * direction))
            .opacity(isAnimating ? 1.0 : 0.2)
            .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: isAnimating)
    }
}

private struct SummaryRowView: View {
    let item: SummaryItem

    var body: some View {
        HStack(spacing: 14) {
            Text(item.icon)
                .font(.system(size: 24))
                .frame(width: 48, height: 48)
                .background(item.background)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.11, green: 0.11, blue: 0.12))
                Text(item.action)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.56, green: 0.56, blue: 0.58))
            }

            Spacer()

            Text(item.trailing)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(item.color)
                .frame(width: 28, height: 28)
                .background(item.background)
                .clipShape(Circle())
        }
    }
}

private struct LoadingSlide {
    let badgeLeading: String
    let badgeTrailing: String
    let title: String
    let subtitle: String
    let accent: Color
    let softAccent: Color
    let badgeColor: Color
    let headerGradient: LinearGradient
    let visualBackground: LinearGradient
    let actionIcon: String?
    let actionLabel: String?
    let bodySections: [SlideBodySection]
    let isSummary: Bool
    let visual: AnyView
}

private enum SlideBodySection: Identifiable {
    case text(String)
    case requirement(icon: String, title: String, description: String, pill: String?)

    var id: String {
        switch self {
        case let .text(text):
            return text
        case let .requirement(icon, title, _, _):
            return icon + title
        }
    }
}

private struct SummaryItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let action: String
    let trailing: String
    let color: Color
    let background: Color
}

private extension LoadingSlide {
    static let summaryItems: [SummaryItem] = [
        SummaryItem(icon: "👍", title: "Thumbs Up", action: "Play / Stop and Select", trailing: "▶", color: Color(red: 0.04, green: 0.52, blue: 1.0), background: Color(red: 0.91, green: 0.96, blue: 1.0)),
        SummaryItem(icon: "👎", title: "Thumbs Down", action: "Back", trailing: "←", color: Color(red: 1.0, green: 0.27, blue: 0.23), background: Color(red: 1.0, green: 0.94, blue: 0.93)),
        SummaryItem(icon: "🖐️", title: "Open Palm → Left", action: "Swipe Left", trailing: "←", color: Color(red: 0.19, green: 0.82, blue: 0.35), background: Color(red: 0.93, green: 1.0, blue: 0.95)),
        SummaryItem(icon: "🖐️", title: "Open Palm → Right", action: "Swipe Right", trailing: "→", color: Color(red: 0.75, green: 0.35, blue: 0.95), background: Color(red: 0.96, green: 0.93, blue: 1.0)),
        SummaryItem(icon: "🖐️", title: "Open Palm → Up", action: "Swipe Up", trailing: "↑", color: Color(red: 0.2, green: 0.68, blue: 0.9), background: Color(red: 0.9, green: 0.97, blue: 1.0)),
        SummaryItem(icon: "🖐️", title: "Open Palm → Down", action: "Swipe Down", trailing: "↓", color: Color(red: 1.0, green: 0.62, blue: 0.04), background: Color(red: 1.0, green: 0.97, blue: 0.9)),
    ]

    static let all: [LoadingSlide] = [
        LoadingSlide(
            badgeLeading: "01",
            badgeTrailing: "of 07",
            title: "Setup",
            subtitle: "Before you start",
            accent: Color(red: 0.04, green: 0.52, blue: 1.0),
            softAccent: Color(red: 0.91, green: 0.96, blue: 1.0),
            badgeColor: Color(red: 0.04, green: 0.52, blue: 1.0),
            headerGradient: LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.17, green: 0.17, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing),
            visualBackground: LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.11, green: 0.11, blue: 0.12)], startPoint: .top, endPoint: .bottom),
            actionIcon: nil,
            actionLabel: nil,
            bodySections: [
                .requirement(icon: "📶", title: "Same Wi-Fi Network", description: "Your phone must be connected to the same network as Apple TV.", pill: nil),
                .requirement(icon: "📍", title: "Stay Close", description: "Remain within range of your iPhone camera.", pill: "within 3 meters · 10 feet"),
            ],
            isSummary: false,
            visual: AnyView(SetupVisual())
        ),
        gestureSlide(step: "02", title: "Thumbs Up", subtitle: "Play / Stop and Select", accent: Color(red: 0.04, green: 0.52, blue: 1.0), softAccent: Color(red: 0.91, green: 0.96, blue: 1.0), headerColors: [Color(red: 0.0, green: 0.24, blue: 0.6), Color(red: 0.04, green: 0.52, blue: 1.0)], visualColors: [Color(red: 0.91, green: 0.96, blue: 1.0), Color(red: 0.94, green: 0.97, blue: 1.0)], actionIcon: "▶️", actionLabel: "Play / Stop and Select", description: "Raise your thumb up to play or stop the current media, or to select the highlighted item on screen.", visual: AnyView(GestureCircleVisual(symbol: "👍", accent: Color(red: 0.04, green: 0.52, blue: 1.0), hint: "↑ Point thumb upward"))),
        gestureSlide(step: "03", title: "Thumbs Down", subtitle: "Back", accent: Color(red: 1.0, green: 0.27, blue: 0.23), softAccent: Color(red: 1.0, green: 0.94, blue: 0.93), headerColors: [Color(red: 0.17, green: 0.06, blue: 0.06), Color(red: 0.35, green: 0.12, blue: 0.12)], visualColors: [Color(red: 1.0, green: 0.94, blue: 0.93), Color(red: 1.0, green: 0.96, blue: 0.96)], actionIcon: "←", actionLabel: "Go Back", description: "Point your thumb down to navigate back to the previous screen or menu.", visual: AnyView(GestureCircleVisual(symbol: "👎", accent: Color(red: 1.0, green: 0.27, blue: 0.23), hint: "↓ Point thumb downward"))),
        gestureSlide(step: "04", title: "Open Palm Move Left", subtitle: "Swipe Left", accent: Color(red: 0.19, green: 0.82, blue: 0.35), softAccent: Color(red: 0.93, green: 1.0, blue: 0.95), headerColors: [Color(red: 0.1, green: 0.18, blue: 0.1), Color(red: 0.11, green: 0.36, blue: 0.16)], visualColors: [Color(red: 0.93, green: 1.0, blue: 0.95), Color(red: 0.96, green: 1.0, blue: 0.97)], actionIcon: "◀️", actionLabel: "Swipe Left", description: "Hold out an open palm and move it to the left to swipe left through content on screen.", visual: AnyView(HorizontalSwipeVisual(symbol: "🖐️", accent: Color(red: 0.19, green: 0.82, blue: 0.35), arrow: "←", label: "Move open palm leftward", symbolFirst: false))),
        gestureSlide(step: "05", title: "Open Palm Move Right", subtitle: "Swipe Right", accent: Color(red: 0.75, green: 0.35, blue: 0.95), softAccent: Color(red: 0.96, green: 0.93, blue: 1.0), headerColors: [Color(red: 0.16, green: 0.1, blue: 0.23), Color(red: 0.37, green: 0.23, blue: 0.54)], visualColors: [Color(red: 0.96, green: 0.93, blue: 1.0), Color(red: 0.98, green: 0.96, blue: 1.0)], actionIcon: "▶️", actionLabel: "Swipe Right", description: "Hold out an open palm and move it to the right to swipe right through content on screen.", visual: AnyView(HorizontalSwipeVisual(symbol: "🖐️", accent: Color(red: 0.75, green: 0.35, blue: 0.95), arrow: "→", label: "Move open palm rightward", symbolFirst: true))),
        gestureSlide(step: "06", title: "Open Palm Move Up", subtitle: "Swipe Up", accent: Color(red: 0.39, green: 0.82, blue: 1.0), softAccent: Color(red: 0.9, green: 0.97, blue: 1.0), headerColors: [Color(red: 0.1, green: 0.16, blue: 0.23), Color(red: 0.1, green: 0.32, blue: 0.47)], visualColors: [Color(red: 0.9, green: 0.97, blue: 1.0), Color(red: 0.94, green: 0.98, blue: 1.0)], actionIcon: "⬆️", actionLabel: "Swipe Up", description: "Hold out an open palm and move it upward to scroll or swipe up on the Apple TV interface.", visual: AnyView(VerticalSwipeVisual(symbol: "🖐️", accent: Color(red: 0.39, green: 0.82, blue: 1.0), arrow: "↑", label: "Move open palm upward", arrowFirst: true))),
        gestureSlide(step: "07", title: "Open Palm Move Down", subtitle: "Swipe Down", accent: Color(red: 1.0, green: 0.62, blue: 0.04), softAccent: Color(red: 1.0, green: 0.97, blue: 0.9), headerColors: [Color(red: 0.16, green: 0.1, blue: 0.06), Color(red: 0.54, green: 0.29, blue: 0.1)], visualColors: [Color(red: 1.0, green: 0.97, blue: 0.9), Color(red: 1.0, green: 0.99, blue: 0.94)], actionIcon: "⬇️", actionLabel: "Swipe Down", description: "Hold out an open palm and move it downward to scroll or swipe down on the Apple TV interface.", visual: AnyView(VerticalSwipeVisual(symbol: "🖐️", accent: Color(red: 1.0, green: 0.62, blue: 0.04), arrow: "↓", label: "Move open palm downward", arrowFirst: false))),
        LoadingSlide(
            badgeLeading: "★",
            badgeTrailing: "Quick Reference",
            title: "Summary",
            subtitle: "All gestures at a glance",
            accent: Color(red: 1.0, green: 0.84, blue: 0.04),
            softAccent: Color(red: 0.95, green: 0.95, blue: 0.96),
            badgeColor: Color(red: 1.0, green: 0.84, blue: 0.04),
            headerGradient: LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.12), Color(red: 0.23, green: 0.23, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing),
            visualBackground: LinearGradient(colors: [Color.white, Color.white], startPoint: .top, endPoint: .bottom),
            actionIcon: nil,
            actionLabel: nil,
            bodySections: [],
            isSummary: true,
            visual: AnyView(
                VStack(spacing: 0) {
                    ForEach(summaryItems.indices, id: \.self) { index in
                        SummaryRowView(item: summaryItems[index])
                        if index < summaryItems.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 28)
            )
        ),
    ]

    static func gestureSlide(
        step: String,
        title: String,
        subtitle: String,
        accent: Color,
        softAccent: Color,
        headerColors: [Color],
        visualColors: [Color],
        actionIcon: String,
        actionLabel: String,
        description: String,
        visual: AnyView
    ) -> LoadingSlide {
        LoadingSlide(
            badgeLeading: step,
            badgeTrailing: "of 07",
            title: title,
            subtitle: subtitle,
            accent: accent,
            softAccent: softAccent,
            badgeColor: accent,
            headerGradient: LinearGradient(colors: headerColors, startPoint: .topLeading, endPoint: .bottomTrailing),
            visualBackground: LinearGradient(colors: visualColors, startPoint: .top, endPoint: .bottom),
            actionIcon: actionIcon,
            actionLabel: actionLabel,
            bodySections: [.text(description)],
            isSummary: false,
            visual: visual
        )
    }
}