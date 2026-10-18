import AppKit
import FxEngine
import SwiftUI

/// Native translucent material (the sidebar).
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Large page title with its explanation behind an ⓘ.
struct PageHeader: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 30, weight: .bold))
            InfoTip(info)
            Spacer()
        }
        .padding(.bottom, 18)
    }
}

/// ⓘ that shows its text in a popover.
struct InfoTip: View {
    let text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").fontWeight(.semibold).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading).padding(14)
        }
    }
}

/// Rounded group of rows, separated by hairlines.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }
}

/// One row of a card: 42 pt minimum, hairline above unless first.
struct CardRow<Content: View>: View {
    var first = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !first { Divider().padding(.leading, 14) }
            HStack(spacing: 10) { content }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .frame(minHeight: 42)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold))
            .padding(.leading, 4).padding(.top, 18).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An app as a small capsule with its icon.
struct AppChip: View {
    let app: Rules.App

    var body: some View {
        HStack(spacing: 5) {
            AppIcon(app: app, size: 14)
            Text(app.name).font(.system(size: 12))
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Color.black.opacity(0.25), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
