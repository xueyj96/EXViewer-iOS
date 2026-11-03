import SwiftUI

struct MainTabsHiddenPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct FloatingFeedLayout<Feed: View, Header: View>: View {
    @State private var headerHeight: CGFloat = 0
    private let feed: (CGFloat) -> Feed
    private let header: Header

    init(@ViewBuilder feed: @escaping (CGFloat) -> Feed, @ViewBuilder header: () -> Header) {
        self.feed = feed
        self.header = header()
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                feed(headerHeight)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                header
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background {
                        GeometryReader { headerGeometry in
                            Color.clear
                                .onAppear { updateHeaderHeight(headerGeometry.size.height) }
                                .onChange(of: headerGeometry.size.height) { _, height in updateHeaderHeight(height) }
                        }
                    }
                    .zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func updateHeaderHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(headerHeight - height) > 0.5 else { return }
        headerHeight = height
    }
}

struct FloatingHeaderPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
    }
}

struct FeedHeaderButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
    }
}

struct FeedScopeOption: Identifiable {
    let id: Int
    let title: String
    let symbol: String
}

struct FeedScopePicker: View {
    @Binding var selection: Int
    let options: [FeedScopeOption]
    let identifier: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button { selection = option.id } label: {
                    Label(option.title, systemImage: option.symbol).labelStyle(.titleAndIcon)
                        .font(.footnote.weight(selection == option.id ? .semibold : .regular))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selection == option.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                .padding(.vertical, typeSize.isAccessibilitySize ? 4 : 8)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(selection == option.id ? Color.accentColor : Color.primary)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(option.id)")
            }
        }
        .padding(.horizontal, 3).appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }
}

struct CompactMainTabs<Content: View>: View {
    @Binding var selection: Int
    @State private var hiddenByContent = false
    let content: Content

    private struct Destination: Identifiable {
        var id: Int
        var title: String
        var symbol: String
        var identifier: String
    }

    private let destinations = [
        Destination(id: 0, title: "发现", symbol: "square.grid.2x2", identifier: "main.tab.discover"),
        Destination(id: 1, title: "资料库", symbol: "books.vertical", identifier: "main.tab.library"),
        Destination(id: 2, title: "我的", symbol: "person.crop.circle", identifier: "main.tab.account")
    ]

    init(selection: Binding<Int>, @ViewBuilder content: () -> Content) {
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { if !hiddenByContent { compactBar } }
            .onPreferenceChange(MainTabsHiddenPreference.self) { hiddenByContent = $0 }
    }

    private var compactBar: some View {
        HStack(spacing: 0) {
            ForEach(destinations, id: \.id) { destination in
                Button { selection = destination.id } label: {
                    VStack(spacing: 2) {
                        Image(systemName: destination.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .frame(height: 18)
                        Text(destination.title)
                            .font(.caption2.weight(selection == destination.id ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 4)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(selection == destination.id ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(destination.title)
                .accessibilityIdentifier(destination.identifier)
                .accessibilityAddTraits(selection == destination.id ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .background(FloatingChrome.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier("main.tabs.compact")
    }
}
