import AppKit
import OmacVMWindow
import SwiftUI

/// Under the header when a check (weekly, or Check Now) found a new version
/// and it is downloaded and checked: what it brings and Update Now. While a
/// VM runs from this app the update waits until it has shut down. Hidden
/// while update checks are off, unless a check by hand found it; Later hides
/// it until the next launch.
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    var running: Bool
    var whatsNew: () -> Void

    var body: some View {
        if let s = updater.staged, updater.enabled || updater.lastOutcome != nil, updater.later != s.version {
            let news = updater.whatsNew(s)
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Product.name) \(s.version) is ready").font(.system(size: 13, weight: .semibold))
                    Text(line(news))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if news != nil || s.notes != nil {
                    Button("What’s New") { if news != nil { whatsNew() } else if let n = s.notes { NSWorkspace.shared.open(n) } }
                        .buttonStyle(.link)
                        .layoutProbe("whats-new")
                }
                if !updater.installWhenIdle && !updater.restarting {
                    Button("Later") { updater.later = s.version }
                    Button(UpdateBanner.updateTitle(running: running)) { UpdateBanner.update(updater) }
                        .buttonStyle(.borderedProminent)
                        .layoutProbe("update-now")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Look.banner, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) { Rectangle().fill(Look.bannerLine).frame(height: 1) }
            .accessibilityElement(children: .contain)
            .layoutProbe("update-banner")
        }
    }

    private func line(_ news: WhatsNewList?) -> String {
        if updater.restarting { return "The VM shuts down for the update and starts again with the new version." }
        if updater.installWhenIdle { return "It goes in once the VM has shut down. Your VMs are not changed." }
        return news?.summary() ?? "You have \(updater.currentVersion). Your VMs are not changed."
    }

    static func updateTitle(running: Bool) -> String { running ? "Update After Shutdown" : "Update Now" }

    /// Now (the app restarts with the new version), or once the VM has shut
    /// down (Updater.install waits for it).
    static func update(_ updater: Updater) {
        updater.install()
    }
}

/// What's New: the new version's section of its CHANGELOG.md, and when the
/// update skips versions, theirs too (newest first, each under its version).
struct WhatsNewSheet: View {
    @ObservedObject var updater: Updater
    var running: Bool
    var done: () -> Void

    var body: some View {
        let s = updater.staged
        let news = s.flatMap { updater.whatsNew($0) }
        let sections = news?.sections ?? []
        SheetFrame(title: "What’s New in \(Product.name) \(s?.version ?? "")") {
            if sections.count <= 1 {
                // One version: as it always looked.
                if let intro = sections.first?.news.intro {
                    Text(Self.markdown(intro)).fixedSize(horizontal: false, vertical: true)
                }
                ScrollView { Self.card(sections.first?.news.items ?? []) }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 440)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Several: all in the one scroll area, so the sheet keeps its height.
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { i, section in
                            Text(section.version)
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.top, i == 0 ? 0 : 8)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityLabel("\(Product.name) \(section.version)")
                            if let intro = section.news.intro {
                                Text(Self.markdown(intro)).fixedSize(horizontal: false, vertical: true)
                            }
                            if !section.news.items.isEmpty { Self.card(section.news.items) }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note = news?.omittedNote {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link("Changelog on GitHub", destination: WhatsNewList.changelogURL).fixedSize()
                }
                .font(.subheadline)
            } else if let n = s?.notes {
                Link("Release notes on GitHub", destination: n).font(.subheadline)
            }
        } buttons: {
            Button("Skip This Version") { updater.skip(); done() }
                .disabled(updater.restarting)
            Spacer()
            Button("Later") { if let v = s?.version { updater.later = v }; done() }
                .keyboardShortcut(.cancelAction)
            if !updater.installWhenIdle && !updater.restarting {
                Button(UpdateBanner.updateTitle(running: running)) { done(); UpdateBanner.update(updater) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func card(_ items: [String]) -> some View {
        Card {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(markdown(item))
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Delete: the VM's name typed exactly, or nothing happens. Cancel is the
/// default (Return); not while the VM runs.
struct DeleteSheet: View {
    let vm: VMConfig
    let size: Int64?
    let running: Bool
    var done: (Bool) -> Void
    @State private var typed = ""

    private var ok: Bool { !running && DeleteConfirm.matches(typed: typed, name: vm.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Look.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete “\(vm.name)”?").font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Its disk\(size.map { " (\(Storage.format($0)))" } ?? "") and everything in \(vm.name) go to the Trash.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if running {
                        Text("Shut down \(vm.name) first.").foregroundStyle(Look.red)
                    } else {
                        TextField("Type \(vm.name) to confirm", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Type the VM's name to confirm")
                            // Return in the field does not delete: Cancel is the default.
                            .onSubmit {}
                            .layoutProbe("delete-name")
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(false) }
                    .keyboardShortcut(.defaultAction)
                Button { if ok { done(true) } } label: {
                    Text("Delete").foregroundStyle(ok ? Look.red : Color(nsColor: .disabledControlTextColor))
                }
                    .disabled(!ok)
                    .layoutProbe("delete-button")
            }
        }
        .padding(16)
        .frame(width: 430)
        .background(Look.window, ignoresSafeAreaEdges: [])
        .onExitCommand { done(false) }
    }
}
