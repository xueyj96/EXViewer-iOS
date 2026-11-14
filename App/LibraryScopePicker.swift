import SwiftUI

struct LibraryFloatingHeader<Controls: View>: View {
    @Binding private var selection: Int
    private let scopeEnabled: Bool
    private let identifier: String
    private let isSelecting: Bool
    private let controls: Controls

    init(selection: Binding<Int>, scopeEnabled: Bool = true, identifier: String, isSelecting: Bool,
         @ViewBuilder controls: () -> Controls) {
        _selection = selection
        self.scopeEnabled = scopeEnabled
        self.identifier = identifier
        self.isSelecting = isSelecting
        self.controls = controls()
    }

    var body: some View {
        FloatingTwoRowHeader(identifier: identifier, transitionID: "library", primaryLayout: "scopes",
                             secondaryLayout: "\(selection)-\(isSelecting)") {
            LibraryScopePicker(selection: $selection).disabled(!scopeEnabled)
        } secondary: {
            controls
        }
    }
}

struct AccessibilityHeaderActions<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: FeedChrome.rowSpacing(for: typeSize)) {
            leading()
            trailing().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct LibraryFilterMenu<Option: Hashable & RawRepresentable>: View where Option.RawValue == String {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    let label: String
    let identifier: String
    let symbol: String
    @Environment(\.dynamicTypeSize) private var typeSize

    private var expands: Bool { !typeSize.isAccessibilitySize }

    var body: some View {
        AppMenu {
            ForEach(options, id: \.self) { option in
                AppMenuItem(title: title(option), isSelected: option == selection) {
                    selection = option
                }
                .accessibilityIdentifier("\(identifier).\(option.rawValue)")
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                LibraryMenuLabel(title: title(selection), symbol: symbol).fixedSize()
                Text(title(selection)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: expands ? .infinity : nil)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: expands))
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
        .accessibilityIdentifier(identifier)
    }
}

struct LibraryMenuLabel: View {
    let title: String
    var symbol = "arrow.up.arrow.down"
    var body: some View {
        HStack(spacing: FeedChrome.iconLabelSpacing) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

struct LibrarySortControlLabel: View {
    let title: String
    var fillsWidth = true
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                LibraryMenuLabel(title: title).fixedSize()
                Text(title).fixedSize()
            }
            Image(systemName: "arrow.up.arrow.down")
        }
        .frame(maxWidth: fillsWidth && !typeSize.isAccessibilitySize ? .infinity : nil)
    }
}

struct LibraryScopePicker: View {
    @Binding var selection: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    private let titles = ["稍后再读", "站点收藏", "阅读历史", "离线下载"]
    private let symbols = ["text.badge.plus", "heart", "clock", "arrow.down.circle"]
    var body: some View {
        if typeSize >= .xxLarge {
            scopeMenu
        } else {
            ViewThatFits(in: .horizontal) {
                FeedScopePicker(selection: $selection, options: titles.indices.map { .init(id: $0, title: titles[$0], symbol: symbols[$0]) }, identifier: "library.scope", alignsToHeaderGrid: true)
                scopeMenu
            }
        }
    }
    private var scopeMenu: some View {
            AppMenu {
                ForEach(titles.indices, id: \.self) { index in
                    AppMenuItem(title: titles[index], isSelected: selection == index) { selection = index }
                        .accessibilityIdentifier("library.scope.\(index)")
                }
            } label: {
                HStack { Label(titles[selection], systemImage: symbols[selection]); Spacer(); Image(systemName: "chevron.down") }
            }
            .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true))
            .accessibilityIdentifier("library.scope.menu")
    }
}
