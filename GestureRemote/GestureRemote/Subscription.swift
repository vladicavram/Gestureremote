import StoreKit
import SwiftUI

/// Gesture TV Control Pro: $1.99/month auto-renewing subscription with a 3-day free trial
/// (configured in App Store Connect). Gestures need an active subscription, which includes the
/// trial. People who got the app before subscriptions existed keep full access.
@MainActor
final class SubscriptionManager: ObservableObject {
    enum Access: Equatable {
        case checking
        case subscribed
        case grandfathered
        case locked
    }

    static let productID = "com.example.GestureRemote.monthly"
    /// First build number sold with the subscription. App Store installs from earlier builds
    /// (1.0 and 1.1, builds 1–3) keep the app free.
    private static let firstSubscriptionBuild = 4

    @Published private(set) var access: Access = .checking
    @Published private(set) var product: Product?
    @Published private(set) var trialAvailable = false
    @Published private(set) var isPurchasing = false
    @Published var errorMessage: String?

    var hasAccess: Bool { access == .subscribed || access == .grandfathered }

    private var updates: Task<Void, Never>?

    init() {
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    deinit { updates?.cancel() }

    func refresh() async {
        if await isGrandfathered() {
            access = .grandfathered
            return
        }
        access = await hasActiveSubscription() ? .subscribed : .locked
        if access == .locked, product == nil { await loadProduct() }
    }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            if let subscription = product?.subscription {
                let eligible = await subscription.isEligibleForIntroOffer
                trialAvailable = eligible && subscription.introductoryOffer?.paymentMode == .freeTrial
            }
            if product == nil { errorMessage = "The subscription isn't available right now. Please try again later." }
        } catch {
            errorMessage = "Couldn't reach the App Store. Check your connection and try again."
        }
    }

    func purchase() async {
        guard let product else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                if case .verified(let transaction) = result { await transaction.finish() }
                await refresh()
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "The purchase didn't go through. Please try again."
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = "Couldn't restore purchases. Please try again."
        }
        await refresh()
        if access == .locked { errorMessage = "No active subscription found for this Apple ID." }
    }

    private func hasActiveSubscription() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil else { continue }
            if let expiry = transaction.expirationDate, expiry < Date() { continue }
            return true
        }
        return false
    }

    /// App Store installs that started before the subscription build. On iOS, originalAppVersion
    /// is the build number (CFBundleVersion) first downloaded. Sandbox and TestFlight always
    /// report "1.0", so they're never grandfathered (the paywall stays testable).
    private func isGrandfathered() async -> Bool {
        guard let result = try? await AppTransaction.shared,
              case .verified(let appTransaction) = result,
              appTransaction.environment == .production,
              let firstBuild = Int(appTransaction.originalAppVersion) else { return false }
        return firstBuild < Self.firstSubscriptionBuild
    }
}

// MARK: - Paywall

struct PaywallView: View {
    @ObservedObject var store: SubscriptionManager
    @Environment(\.openURL) private var openURL

    private let accent = Color(red: 0.25, green: 0.62, blue: 1.0)
    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://vladicavram.github.io/Gestureremote/privacy-policy.html")!

    private var price: String { store.product?.displayPrice ?? "$1.99" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.35), .clear], center: .top, startRadius: 20, endRadius: 520)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Text("🖐️")
                        .font(.system(size: 72))
                        .frame(width: 130, height: 130)
                        .background(accent.opacity(0.18))
                        .clipShape(Circle())
                        .padding(.top, 36)

                    VStack(spacing: 8) {
                        Text("Gesture TV Control Pro")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text("Control your Apple TV with your hand.")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        feature("hand.raised.fill", "Point, select and go back with simple gestures")
                        feature("cube.transparent", "LiDAR hand tracking from across the room (iPhone 15 Pro and newer)")
                        feature("speaker.wave.2.fill", "Volume with two fingers")
                        feature("keyboard", "Type in the Apple TV keyboard by pinching")
                    }
                    .padding(18)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(spacing: 10) {
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            Group {
                                if store.isPurchasing {
                                    ProgressView().tint(.black)
                                } else {
                                    Text(store.trialAvailable ? "Start 3-Day Free Trial" : "Subscribe for \(price)/month")
                                }
                            }
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 17)
                            .background(accent)
                            .clipShape(Capsule())
                        }
                        .disabled(store.product == nil || store.isPurchasing)

                        Text(store.trialAvailable
                             ? "Free for 3 days, then \(price) per month. Cancel anytime."
                             : "\(price) per month. Cancel anytime.")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    if let error = store.errorMessage {
                        Text(error)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        if store.product == nil {
                            Button("Try Again") {
                                store.errorMessage = nil
                                Task { await store.loadProduct() }
                            }
                            .foregroundStyle(accent)
                        }
                    }

                    HStack(spacing: 22) {
                        Button("Restore Purchases") { Task { await store.restore() } }
                        Button("Terms of Use") { openURL(termsURL) }
                        Button("Privacy Policy") { openURL(privacyURL) }
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))

                    Text("Payment is charged to your Apple ID when the free trial ends, or at purchase if no trial applies. The subscription renews automatically each month unless it's cancelled at least 24 hours before the end of the current period. Manage or cancel it anytime in Settings › Apple ID › Subscriptions.")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 26)
            Text(text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
