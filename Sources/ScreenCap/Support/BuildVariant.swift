/// Compile-time product split. The open-source ScreenCap 3 target is the
/// default; the Pro target is enabled only when the private Player sources are
/// staged and SwiftPM receives `SCREENCAP_PRO=1`.
enum BuildVariant {
#if SCREENCAP_PRO
    static let isPro = true
    static let productName = "ScreenCap 3 Pro"
    static let fallbackBundleIdentifier = "com.vertusdesign.ScreenCap.Pro3"
    static let fallbackURLScheme = "screencap-pro3"
#else
    static let isPro = false
    static let productName = "ScreenCap 3"
    static let fallbackBundleIdentifier = "com.vertusdesign.ScreenCap"
    static let fallbackURLScheme = "screencap"
#endif
}
