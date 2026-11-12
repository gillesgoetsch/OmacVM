import AppKit
import OmacVMWindow
import SwiftUI

/// The app's look (docs/design/settings-3.1/final.html): a pinned header, a
/// sidebar, sections of white cards with rows, switches and pictures. The
/// surfaces have the design's colours in light and dark; text, lines, the
/// accent and the controls are macOS's own.
enum Look {
    static func color(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    static let window = color(light: 0xF4F4F2, dark: 0x262628)
    static let sidebar = color(light: 0xE9E8E6, dark: 0x202023)
    static let header = color(light: 0xF0EFED, dark: 0x2A2A2C)
    static let card = color(light: 0xFFFFFF, dark: 0x2C2C2E)
    static let hairline = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
    static let cardBorder = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.06)
    static let chip = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.12)
    static let track = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.15)
    static let pill = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.10)
    /// Behind the pictures (Start in, the escape combo, Swipe out, Mission Control).
    static let panel = color(light: 0xFAFAF9, dark: 0x333336)
    static let key = color(light: 0xFFFFFF, dark: 0x48484B)
    static let pictureLine = color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)
    static let banner = color(light: 0xE4F0FE, dark: 0x1C3250)
    static let bannerLine = color(light: 0x0A84FF, dark: 0x0A84FF, lightAlpha: 0.30, darkAlpha: 0.40)
    static let red = Color(nsColor: .systemRed)
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)

    static let headerHeight: CGFloat = 52
    static let radius: CGFloat = 10
}

extension NSColor {
    convenience init(rgb: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: alpha)
    }
}

extension Color {
    init(rgb: UInt32) { self.init(nsColor: NSColor(rgb: rgb)) }
}

/// A section's title above its card.
struct SectionTitle: View {
    let text: String
    var first = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, first ? 4 : 22)
            .padding(.bottom, 8)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A white card of rows, a hairline between them (rows that show nothing
/// leave no line).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { RowDivider() }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Look.card, in: RoundedRectangle(cornerRadius: Look.radius))
        .overlay(RoundedRectangle(cornerRadius: Look.radius).strokeBorder(Look.cardBorder, lineWidth: 1))
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Look.hairline).frame(height: 1).padding(.leading, 16)
    }
}

/// One setting: its name (with a badge such as "experimental" and an (i)),
/// a grey line under it, and its controls at the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var badge: String? = nil
    var subtitle: String? = nil
    var subtitleIsError = false
    /// A note to see (orange): not an error, but easy to miss in grey.
    var subtitleIsNote = false
    var info: String? = nil
    var probe: String? = nil
    /// An (i) of its own (a picture in its popover) instead of info's text.
    var infoButton: AnyView? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge { Text("(\(badge))").font(.subheadline).foregroundStyle(.secondary) }
                    if let infoButton { infoButton } else if let info { InfoButton(topic: title, text: info) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(subtitleIsError ? Look.red : subtitleIsNote ? Look.orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { trailing }
                .fixedSize()
                .layoutProbe(probe.map { "trailing-\($0)" })
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

extension SettingRow where Trailing == EmptyView {
    init(_ title: String, badge: String? = nil, subtitle: String? = nil, subtitleIsError: Bool = false, info: String? = nil) {
        self.init(title: title, badge: badge, subtitle: subtitle, subtitleIsError: subtitleIsError, info: info) { EmptyView() }
    }

    init(title: String, badge: String? = nil, subtitle: String? = nil, subtitleIsError: Bool = false, info: String? = nil, probe: String?) {
        self.init(title: title, badge: badge, subtitle: subtitle, subtitleIsError: subtitleIsError, info: info, probe: probe) { EmptyView() }
    }
}

/// The macOS switch of a row, labelled for VoiceOver.
struct RowSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(!enabled)
    }
}

/// "● Stopped", "● Running" next to the VM's name.
struct StatusPill: View {
    let text: String
    var dot: Color = Color(nsColor: .tertiaryLabelColor)

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .background(Look.pill, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// The sidebar's coloured square with a symbol.
struct NavIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5.5)
            .fill(color)
            .frame(width: 21, height: 21)
            .overlay(Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

/// A − value + control (Resources, the disk's new size): macOS's own
/// Stepper is the small up and down arrows.
struct ValueStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    var minWidth: CGFloat = 50

    private var text: String { unit.isEmpty ? "\(value)" : "\(value) \(unit)" }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline)
            HStack(spacing: 0) {
                button("minus", "Less", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
                Text(text)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: minWidth)
                button("plus", "More", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
            }
            .background(Look.chip, in: RoundedRectangle(cornerRadius: 6))
        }
        // VoiceOver and the Accessibility API see macOS's own stepper.
        .accessibilityRepresentation {
            Stepper(value: $value, in: range, step: step) { Text(label) }
                .accessibilityValue(text)
        }
    }

    private func button(_ symbol: String, _ what: String, enabled: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help("\(what) \(label.lowercased())")
    }
}

/// A thin bar: how much of something is used.
struct UsageBar: View {
    let fraction: Double
    var width: CGFloat = 110
    var height: CGFloat = 4

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Look.track)
            Capsule().fill(Color.accentColor)
                .frame(width: max(fraction > 0 ? height : 0, width * min(max(fraction, 0), 1)))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// A picture to pick (Start in, the escape combo): a ring in the accent
/// colour around the chosen one, its name and a grey line under it.
struct PictureChoice<Picture: View>: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var width: CGFloat = 166
    let action: () -> Void
    @ViewBuilder var picture: Picture

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                picture
                    .padding(2)
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A small square button with a symbol (Show in Finder).
struct ChipButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Look.chip, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A sheet's frame: title, content, buttons at the bottom right.
struct SheetFrame<Content: View, Buttons: View>: View {
    let title: String
    var width: CGFloat = 500
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content
            HStack(spacing: 8) { buttons }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(Look.window)
    }
}

/// A grey heading inside a sheet ("Plugged in now").
struct SheetHeading: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
    }
}
