import SwiftUI

struct LibraryFloatingHeader<Controls: View>: View {
    @Binding private var selection: Int
    private let scopeEnabled: Bool
    private let identifier: String
    private let controls: Controls

    init(selection: Binding<Int>, scopeEnabled: Bool = true, identifier: String, @ViewBuilder controls: () -> Controls) {
        _selection = selection
        self.scopeEnabled = scopeEnabled
        self.identifier = identifier
        self.controls = controls()
    }

    var body: some View {
        FloatingHeaderPanel(identifier: identifier, twoRows: true) {
            FeedHeaderRows {
                LibraryScopePicker(selection: $selection).disabled(!scopeEnabled)
            } secondary: {
                controls
            }
        }
    }
}

struct LibraryHeaderActions<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: FeedChrome.rowSpacing(for: typeSize)) {
                leading()
                trailing().frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: FeedChrome.panelSpacing) {
                leading()
                Spacer(minLength: 0)
                trailing().layoutPriority(1)
            }
        }
    }
}

struct LibraryHeaderCount: View {
    let title: String
    let symbol: String
    var fillsWidth = false
    var detail: String? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if let detail {
                HStack(spacing: FeedChrome.controlSpacing) {
                    count.layoutPriority(1)
                    Spacer(minLength: 0)
                    Text(detail)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            } else {
                count
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .foregroundStyle(.secondary)
        .feedHeaderControl(typeSize: typeSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
    }

    private var count: some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol).fixedSize()
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct LibraryMenuLabel: View {
    let title: String
    var symbol = "arrow.up.arrow.down"
    var fillsWidth = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title).lineLimit(1).truncationMode(.tail)
            if fillsWidth { Spacer(minLength: 0) }
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
            Menu {
                ForEach(titles.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        if selection == index { Label(titles[index], systemImage: "checkmark") }
                        else { Text(titles[index]) }
                    }.accessibilityIdentifier("library.scope.\(index)")
                }
            } label: {
                HStack { Label(titles[selection], systemImage: symbols[selection]); Spacer(); Image(systemName: "chevron.down") }
            }
            .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true))
            .accessibilityIdentifier("library.scope.menu")
    }
}
