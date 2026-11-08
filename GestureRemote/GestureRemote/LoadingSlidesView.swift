import SwiftUI

/// Gesture tutorial shown on first launch (and from the top bar). Dark cards, one gesture each,
/// with an animated hand. The set depends on the phone: LiDAR iPhones use the pointer gestures,
/// others the classic swipe gestures.
struct StartupLoadingSlideshowView: View {
    let onReachLastSlide: () -> Void
    let onFinish: () -> Void

    @State private var selectedIndex = 0
    @State private var hasTriggeredWarmup = false

    private let slides = TutorialSlide.current

    private var accent: Color { slides[selectedIndex].accent }
    private var isLast: Bool { selectedIndex == slides.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.35), .clear], center: .top, startRadius: 20, endRadius: 520)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: selectedIndex)

            VStack(spacing: 18) {
                ProgressBar(count: slides.count, index: selectedIndex, accent: accent)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                TabView(selection: $selectedIndex) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { index, slide in
                        TutorialCard(slide: slide)
                            .padding(.horizontal, 20)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack {
                    if !isLast {
                        Button("Skip") { onFinish() }
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Button {
                        if isLast {
                            onFinish()
                        } else {
                            withAnimation { selectedIndex += 1 }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(isLast ? "Start" : "Next")
                            Image(systemName: isLast ? "checkmark" : "arrow.right")
                        }
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 14)
                        .background(accent)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedIndex) { _, newIndex in
            guard newIndex == slides.count - 1, !hasTriggeredWarmup else { return }
            hasTriggeredWarmup = true
            onReachLastSlide()
        }
    }
}

// MARK: - Pieces

private struct ProgressBar: View {
    let count: Int
    let index: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i <= index ? accent : Color.white.opacity(0.15))
                    .frame(height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
    }
}

private struct TutorialCard: View {
    let slide: TutorialSlide

    var body: some View {
        ScrollView(showsIndicators: false) {
            card
        }
    }

    private var card: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(LinearGradient(colors: [slide.accent.opacity(0.28), slide.accent.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(slide.accent.opacity(0.35), lineWidth: 1))
                HeroAnimation(kind: slide.hero, accent: slide.accent)
            }
            .frame(height: slide.hero == .summary ? 120 : 260)

            VStack(spacing: 10) {
                Text(slide.title)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(slide.instruction)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let result = slide.result {
                HStack(spacing: 10) {
                    Image(systemName: result.icon)
                        .font(.system(size: 17, weight: .bold))
                    Text(result.label)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(slide.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(slide.accent.opacity(0.14))
                .clipShape(Capsule())
            }

            if !slide.tips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(slide.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(slide.accent).frame(width: 6, height: 6).padding(.top, 7)
                            Text(tip)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            if slide.hero == .summary {
                SummaryList(items: slide.summary)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private struct SummaryList: View {
    let items: [SummaryItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 14) {
                    Text(item.hand)
                        .font(.system(size: 24))
                        .frame(width: 44, height: 44)
                        .background(item.color.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(item.gesture)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(item.action)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(item.color)
                }
                .padding(.vertical, 8)
                if index < items.count - 1 {
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Animated hands

private enum HeroKind: Equatable {
    case setup(distance: String), hold, move, pinch, flip, volume, sleep, thumbs(up: Bool), summary
}

private struct HeroAnimation: View {
    let kind: HeroKind
    let accent: Color

    @State private var phase = false

    var body: some View {
        content
            .onAppear {
                phase = false
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: autoreverses)) { phase = true }
            }
    }

    private var duration: Double {
        switch kind {
        case .hold: return 1.0
        case .pinch: return 0.6
        case .flip: return 1.1
        default: return 1.4
        }
    }

    private var autoreverses: Bool { kind != .hold }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .setup(let distance):
            HStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("📺").font(.system(size: 54))
                    Text("📱").font(.system(size: 30))
                }
                VStack(spacing: 6) {
                    Text(distance).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(accent)
                    Capsule().fill(accent.opacity(0.6)).frame(width: 90, height: 3)
                        .scaleEffect(x: phase ? 1 : 0.6)
                }
                Text("🛋️").font(.system(size: 60))
            }

        case .hold:
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 8).frame(width: 170, height: 170)
                Circle().trim(from: 0, to: phase ? 1 : 0)
                    .stroke(accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 170, height: 170)
                Text("🖐️").font(.system(size: 84))
                Text("1 s").font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(accent).offset(y: 105)
            }

        case .move:
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Image(systemName: ["arrow.up", "arrow.right", "arrow.down", "arrow.left"][i])
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(accent.opacity(0.7))
                        .offset(x: [0, 100, 0, -100][i], y: [-95, 0, 95, 0][i])
                }
                Text("🖐️").font(.system(size: 84))
                    .offset(x: phase ? 40 : -40, y: phase ? -14 : 14)
            }

        case .pinch:
            ZStack {
                Circle().fill(accent.opacity(phase ? 0.35 : 0.08)).frame(width: phase ? 150 : 110, height: phase ? 150 : 110)
                Text("🤏").font(.system(size: 90)).scaleEffect(phase ? 0.88 : 1.05)
            }

        case .flip:
            Text("🖐️").font(.system(size: 96))
                .rotation3DEffect(.degrees(phase ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(phase ? 0.75 : 1)

        case .volume:
            HStack(spacing: 26) {
                Text("✌️").font(.system(size: 88)).offset(y: phase ? -36 : 36)
                VStack(spacing: 40) {
                    Image(systemName: "speaker.plus.fill").opacity(phase ? 1 : 0.3)
                    Image(systemName: "speaker.minus.fill").opacity(phase ? 0.3 : 1)
                }
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(accent)
            }

        case .sleep:
            ZStack {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(accent)
                    .offset(x: 70, y: -70)
                    .opacity(phase ? 1 : 0.3)
                Text("🖐️").font(.system(size: 84))
                    .offset(y: phase ? 60 : -10)
                    .opacity(phase ? 0.25 : 1)
            }

        case .thumbs(let up):
            Text(up ? "👍" : "👎").font(.system(size: 96))
                .offset(y: phase ? (up ? -14 : 14) : 0)

        case .summary:
            HStack(spacing: 14) {
                ForEach(["🖐️", "🤏", "✌️"], id: \.self) { hand in
                    Text(hand).font(.system(size: 56))
                        .scaleEffect(phase ? 1.06 : 0.94)
                }
            }
        }
    }
}

// MARK: - Content

private struct SummaryItem {
    let hand: String
    let gesture: String
    let action: String
    let color: Color
}

private struct TutorialSlide {
    let title: String
    let instruction: String
    let result: (icon: String, label: String)?
    let tips: [String]
    let accent: Color
    let hero: HeroKind
    var summary: [SummaryItem] = []

    static var current: [TutorialSlide] { LiDARSupport.isSupported ? lidar : classic }

    private static let blue = Color(red: 0.25, green: 0.62, blue: 1.0)
    private static let green = Color(red: 0.25, green: 0.86, blue: 0.5)
    private static let yellow = Color(red: 1.0, green: 0.82, blue: 0.2)
    private static let purple = Color(red: 0.72, green: 0.5, blue: 1.0)
    private static let orange = Color(red: 1.0, green: 0.6, blue: 0.25)
    private static let pink = Color(red: 1.0, green: 0.42, blue: 0.6)
    private static let teal = Color(red: 0.3, green: 0.85, blue: 0.9)

    // iPhone 15 Pro and newer: rear LiDAR camera, live palm pointer.
    static let lidar: [TutorialSlide] = [
        TutorialSlide(
            title: "Set Up",
            instruction: "Stand your iPhone near the TV with the back camera facing your couch.",
            result: nil,
            tips: ["iPhone and Apple TV on the same Wi-Fi",
                   "Sit 1–4 m away — it works from the couch",
                   "Use your left hand"],
            accent: blue, hero: .setup(distance: "1–4 m")),
        TutorialSlide(
            title: "Wake",
            instruction: "Raise your left hand and hold your open palm toward the phone for a second.",
            result: ("bolt.fill", "Gestures on"),
            tips: ["The phone's flash blinks once", "The hand on screen turns green"],
            accent: yellow, hero: .hold),
        TutorialSlide(
            title: "Point",
            instruction: "Keep your palm open and move it. The selection on the TV follows your hand.",
            result: ("hand.point.up.left.fill", "Move the selection"),
            tips: ["Small moves step one item, quick moves travel further",
                   "Make a fist to pause the pointer"],
            accent: green, hero: .move),
        TutorialSlide(
            title: "Pinch",
            instruction: "Tap your thumb and index finger together.",
            result: ("checkmark.circle.fill", "Select"),
            tips: ["Works in the TV keyboard to type the highlighted key"],
            accent: blue, hero: .pinch),
        TutorialSlide(
            title: "Flip",
            instruction: "Turn your open hand over so the back faces the phone.",
            result: ("arrow.uturn.backward.circle.fill", "Back"),
            tips: ["Turn your palm back to flip again"],
            accent: pink, hero: .flip),
        TutorialSlide(
            title: "Volume",
            instruction: "Raise two fingers ✌️ and move your hand up or down.",
            result: ("speaker.wave.2.fill", "Volume up / down"),
            tips: ["Needs Apple TV volume control set up for your TV or speakers"],
            accent: purple, hero: .volume),
        TutorialSlide(
            title: "Rest",
            instruction: "Lower your hand. Gestures go to sleep after 5 seconds without a gesture.",
            result: ("moon.zzz.fill", "Gestures off"),
            tips: ["The flash blinks twice", "A resting hand in your lap is ignored"],
            accent: teal, hero: .sleep),
        TutorialSlide(
            title: "You're Ready",
            instruction: "All gestures at a glance.",
            result: nil,
            tips: [],
            accent: orange, hero: .summary,
            summary: [
                SummaryItem(hand: "🖐️", gesture: "Hold palm 1 s", action: "Wake", color: yellow),
                SummaryItem(hand: "🖐️", gesture: "Move open palm", action: "Point", color: green),
                SummaryItem(hand: "🤏", gesture: "Pinch", action: "Select", color: blue),
                SummaryItem(hand: "🔄", gesture: "Flip hand", action: "Back", color: pink),
                SummaryItem(hand: "✌️", gesture: "Two fingers up / down", action: "Volume", color: purple),
                SummaryItem(hand: "💤", gesture: "Lower hand", action: "Sleep", color: teal),
            ]),
    ]

    // Phones without LiDAR: front or back camera, swipe gestures.
    static let classic: [TutorialSlide] = [
        TutorialSlide(
            title: "Set Up",
            instruction: "Stand your iPhone near the TV, facing where you sit.",
            result: nil,
            tips: ["iPhone and Apple TV on the same Wi-Fi", "Stay within about 3 m of the camera"],
            accent: blue, hero: .setup(distance: "up to 3 m")),
        TutorialSlide(
            title: "Wake",
            instruction: "Hold your open palm toward the camera for a second.",
            result: ("bolt.fill", "Gestures on"),
            tips: ["The hand on screen turns green"],
            accent: yellow, hero: .hold),
        TutorialSlide(
            title: "Swipe",
            instruction: "Move your open palm left, right, up or down.",
            result: ("arrow.up.and.down.and.arrow.left.and.right", "Move the selection"),
            tips: [],
            accent: green, hero: .move),
        TutorialSlide(
            title: "Thumbs Up",
            instruction: "Make a fist with your thumb pointing up.",
            result: ("checkmark.circle.fill", "Select"),
            tips: [],
            accent: blue, hero: .thumbs(up: true)),
        TutorialSlide(
            title: "Thumbs Down or Flip",
            instruction: "Point your thumb down, or turn your open hand over.",
            result: ("arrow.uturn.backward.circle.fill", "Back"),
            tips: [],
            accent: pink, hero: .flip),
        TutorialSlide(
            title: "You're Ready",
            instruction: "All gestures at a glance.",
            result: nil,
            tips: [],
            accent: orange, hero: .summary,
            summary: [
                SummaryItem(hand: "🖐️", gesture: "Hold palm 1 s", action: "Wake", color: yellow),
                SummaryItem(hand: "🖐️", gesture: "Swipe open palm", action: "Move", color: green),
                SummaryItem(hand: "👍", gesture: "Thumbs up", action: "Select", color: blue),
                SummaryItem(hand: "👎", gesture: "Thumbs down / flip", action: "Back", color: pink),
                SummaryItem(hand: "💤", gesture: "Lower hand", action: "Sleep", color: teal),
            ]),
    ]
}
