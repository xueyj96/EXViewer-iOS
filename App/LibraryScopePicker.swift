import SwiftUI

struct LibraryFloatingHeader<Controls: View>: View {
    @Binding private var selection: Int
    private let scopeEnabled: Bool
    private let controls: Controls

    init(selection: Binding<Int>, scopeEnabled: Bool = true, @ViewBuilder controls: () -> Controls) {
        _selection = selection
        self.scopeEnabled = scopeEnabled
        self.controls = controls()
    }

    var body: some View {
        FloatingHeaderPanel {
            VStack(spacing: 0) {
                LibraryScopePicker(selection: $selection).disabled(!scopeEnabled)
                controls.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .padding(.horizontal, -6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct LibraryHeaderCount: View {
    let title: String
    let symbol: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var symbolWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: symbolWidth)
            Text(title)
        }
            .fixedSize(horizontal: true, vertical: false)
            .font(.subheadline).foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(minHeight: 44)
            .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
    }
}

struct LibrarySortMenuLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: "arrow.up.arrow.down").labelStyle(.titleAndIcon)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct LibraryScopePicker: View {
    @Binding var selection: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    private let titles = ["稍后再读", "站点收藏", "阅读历史", "下载"]
    private let symbols = ["text.badge.plus", "heart", "clock", "arrow.down.circle"]
    var body: some View {
        if typeSize.isAccessibilitySize {
            scopeMenu
        } else {
            ViewThatFits(in: .horizontal) {
                FeedScopePicker(selection: $selection, options: titles.indices.map { .init(id: $0, title: titles[$0], symbol: symbols[$0]) }, identifier: "library.scope")
                scopeMenu
            }
        }
    }
    private var scopeMenu: some View {
            Menu {
                ForEach(titles.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        if selection == index { Label(titles[index], systemImage: "checkmark") }
                        else { Text(titles[index]) }
                    }.accessibilityIdentifier("library.scope.\(index)")
                }
            } label: {
                HStack { Label(titles[selection], systemImage: symbols[selection]); Spacer(); Image(systemName: "chevron.down") }
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 10)
                    .frame(minHeight: 44).contentShape(Rectangle())
                    .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
            }.accessibilityIdentifier("library.scope.menu")
    }
}

struct ReadLaterSelectionActions: View {
    @ObservedObject var summary: LibrarySelectionSummary
    let store: LibrarySelectionStore
    var onRemove: () -> Void
    var body: some View {
        HStack {
            Button(summary.value.allLoadedSelected ? "取消全选" : "全选") { store.toggleAllLoaded() }
                .buttonStyle(AppActionButtonStyle(singleLine: true)).frame(minHeight: 44)
                .accessibilityIdentifier("read-later.select-all")
            Spacer()
            Button("移出稍后再读", role: .destructive, action: onRemove)
                .buttonStyle(AppActionButtonStyle(singleLine: true)).frame(minHeight: 44)
                .disabled(summary.value.count == 0).accessibilityIdentifier("read-later.remove")
        }
        .padding(8).background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20).accessibilityElement(children: .contain)
        .accessibilityIdentifier("read-later.actions")
    }
}
