/// The features a new OmacVM.app VM starts with (vm.env's FEATURES, which
/// `omacvm apply` reads). Apart from the UI so it can be tested without a
/// Mac with a notch: `swift run features-tests`.
public enum NewVMFeatures {
    /// Omanotch is on where there is a notch: the app's full screen sits
    /// below the camera, and Omanotch fills the strip beside it.
    public static func string(bridge: Bool = true, gestures: Bool = true, autologin: Bool = false,
                              hasBattery: Bool, hasNotch: Bool) -> String {
        let on = { (b: Bool) in b ? "on" : "off" }
        return "bridge=\(on(bridge)) wallpaper=\(on(bridge)) gestures=\(on(gestures)) scroll-momentum=\(on(gestures)) omanotch=\(on(hasNotch)) mac-clock=on camera=on battery=\(on(hasBattery)) external-brightness=\(on(bridge)) chromium-video=on no-idle-lock=off autologin=\(on(autologin)) thp-kernel=off"
    }
}
