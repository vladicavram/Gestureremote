import SwiftUI

extension Notification.Name {
    static let showGestureSlides = Notification.Name("showGestureSlides")
}

@main
struct GestureRemoteApp: App {
    init() {
        print("[STARTUP] GestureRemoteApp.init")
    }
    var body: some Scene {
        WindowGroup {
            let _ = print("[STARTUP] WindowGroup body")
            AppRootView()
        }
    }
}

struct AppRootView: View {
    @AppStorage("hasSeenGestureSlides") private var hasSeenGestureSlides = false
    @State private var showSlides = true
    @State private var loadingSlidesDismissed = false

    var body: some View {
        ZStack {
            // Only initialize heavy managers if slides are dismissed or already seen
            if loadingSlidesDismissed || hasSeenGestureSlides {
                ContentView()
                    .transition(.opacity)
            }

            // Show slides immediately on top
            if showSlides {
                StartupLoadingSlideshowView(
                    onReachLastSlide: startWarmup,
                    onFinish: completeSlides
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            // If slides already seen, skip them and go straight to content
            if hasSeenGestureSlides {
                showSlides = false
                loadingSlidesDismissed = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGestureSlides)) { _ in
            showSlides = true
            // Keep content view alive underneath so camera can keep warming/running.
            loadingSlidesDismissed = true
        }
    }

    private func startWarmup() {
        // Slides are still visible, start warmup in background
        // ContentView will handle this via onAppear when loadingSlidesDismissed becomes true
    }

    private func completeSlides() {
        hasSeenGestureSlides = true
        showSlides = false
        loadingSlidesDismissed = true
    }
}
