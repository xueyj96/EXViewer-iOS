import SwiftUI

private struct PinnedHeader {
    let transitionID: String
    let twoRows: Bool
    let view: AnyView
}

private struct PinnedHeaderPreference: PreferenceKey {
    static let defaultValue: [PinnedHeader] = []
    static func reduce(value: inout [PinnedHeader], nextValue: () -> [PinnedHeader]) {
        value.append(contentsOf: nextValue())
    }
}

private enum PinnedBottomContent {
    case custom(id: String, view: AnyView)
    case hidden

    var id: String {
        switch self {
        case let .custom(id, _): id
        case .hidden: "reader"
        }
    }
}

private struct PinnedBottomPreference: PreferenceKey {
    static let defaultValue: PinnedBottomContent? = nil
    static func reduce(value: inout PinnedBottomContent?, nextValue: () -> PinnedBottomContent?) {
        value = nextValue() ?? value
    }
}

extension EnvironmentValues {
    @Entry fileprivate var pinsPageChrome = false
}

struct PinnedBottomSlot<Content: View>: View {
    @Environment(\.pinsPageChrome) private var pinsPageChrome
    let id: String
    @ViewBuilder let content: Content

    var body: some View {
        if pinsPageChrome {
            Color.clear.frame(height: 0)
                .preference(key: PinnedBottomPreference.self, value: .custom(id: id, view: AnyView(content)))
        } else {
            FloatingBottomBar { content }
        }
    }
}

enum FeedHeaderRow { case primary, secondary, single }

enum FeedChrome {
    static let contentInset: CGFloat = 20
    static let systemGroupedListInset: CGFloat = 16
    static let contentSpacing: CGFloat = 8
    static let headerOuterInset: CGFloat = 4
    static let contentTopGap = contentSpacing - headerOuterInset
    static let sectionSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 44
    static let compactFormRowHeight: CGFloat = 36
    static let compactPickerHeight: CGFloat = 32
    static let controlSpacing: CGFloat = 8
    private static let textSize: Font.TextStyle = .footnote
    static let labelFont = Font.system(textSize, weight: .medium)
    static let iconScale: Image.Scale = .small
    static let iconLabelSpacing: CGFloat = 4
    static let emphasizedLabelFont = Font.system(textSize, weight: .semibold)
    static let panelSpacing: CGFloat = 4
    static let panelShape = AppShape.aligned(with: AppShape.control, offset: panelSpacing)
    static let rowSurfaceHeight: CGFloat = 34
    // Single-row bars share this surface height; page-side actions are squares.
    static let pageActionWidth = rowSurfaceHeight
    static let singleRowPanelHeight = rowSurfaceHeight + 2 * panelSpacing
    static let singleRowOverhang = (rowHeight - singleRowPanelHeight) / 2
    static let singleRowSurfaceInset = verticalHitInset(for: rowSurfaceHeight)
    static let doubleRowPanelHeight = 2 * rowSurfaceHeight + 3 * panelSpacing
    static let doubleRowOverhang = (2 * rowHeight - doubleRowPanelHeight) / 2

    enum ReaderBar {
        static let maximumWidth: CGFloat = 460
    }

    enum DetailCard {
        static let inset: CGFloat = 6
        static let metadataFont = Font.footnote
        static let tagGroupInset = FeedChrome.panelSpacing
        static let coverWidth: CGFloat = 84
        static let compactCoverWidth: CGFloat = 80
        static let coverHeightRatio: CGFloat = 1.5
    }

    static func verticalHitInset(for surfaceHeight: CGFloat) -> CGFloat {
        max(0, rowHeight - surfaceHeight) / 2
    }

    static func surfaceInsets(for size: DynamicTypeSize, row: FeedHeaderRow?) -> EdgeInsets {
        guard !size.isAccessibilitySize else { return EdgeInsets() }
        let middle = panelSpacing / 2
        let outer = rowHeight - rowSurfaceHeight - middle
        switch row {
        case .primary:
            return EdgeInsets(top: outer, leading: 0, bottom: middle, trailing: 0)
        case .secondary:
            return EdgeInsets(top: middle, leading: 0, bottom: outer, trailing: 0)
        case .single:
            return EdgeInsets(top: singleRowSurfaceInset, leading: 0, bottom: singleRowSurfaceInset, trailing: 0)
        case nil:
            return EdgeInsets(top: panelSpacing, leading: 0, bottom: panelSpacing, trailing: 0)
        }
    }

    static func rowSpacing(for size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? panelSpacing : 0
    }

    static func contentOffset(for insets: EdgeInsets) -> CGFloat {
        (insets.top - insets.bottom) / 2
    }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.pinsPageChrome) private var pinsPageChrome
    let identifier: String
    let transitionID: String
    let twoRows: Bool
    let canPin: Bool
    let content: Content

    init(identifier: String, transitionID: String? = nil, twoRows: Bool = false, canPin: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.transitionID = transitionID ?? identifier
        self.twoRows = twoRows
        self.canPin = canPin
        self.content = content()
    }

    var body: some View {
        if pinsPageChrome && canPin {
            panel.hidden().accessibilityHidden(true)
                .preference(key: PinnedHeaderPreference.self, value: [.init(transitionID: transitionID, twoRows: twoRows, view: AnyView(panel))])
        } else {
            panel
        }
    }

    private var panel: some View {
        let overhang = typeSize.isAccessibilitySize ? 0
            : (twoRows ? FeedChrome.doubleRowOverhang : FeedChrome.singleRowOverhang)
        return content
            // Keep the full hit targets inside the overall layout, with the visible panel drawn tighter.
            .padding(.vertical, typeSize.isAccessibilitySize ? FeedChrome.panelSpacing : -overhang)
            .floatingFeedPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .padding(.horizontal, FeedChrome.contentInset)
            .padding(.vertical, max(FeedChrome.headerOuterInset, overhang))
    }
}

private extension View {
    func floatingFeedPanel() -> some View {
        frame(maxWidth: .infinity)
            .padding(.horizontal, FeedChrome.panelSpacing)
            .background(FloatingChrome.headerBackground, in: FeedChrome.panelShape)
            .overlay {
                FeedChrome.panelShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
    }
}

struct FloatingTwoRowHeader: View {
    let identifier: String
    let transitionID: String
    let primaryLayout: String
    let secondaryLayout: String
    let note: AnyView?
    private let primary: AnyView
    private let secondary: AnyView
    @Environment(\.dynamicTypeSize) private var typeSize

    init<Primary: View, Secondary: View>(identifier: String, transitionID: String, primaryLayout: String,
                                         secondaryLayout: String, note: AnyView? = nil,
                                         @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.identifier = identifier
        self.transitionID = transitionID
        self.primaryLayout = primaryLayout
        self.secondaryLayout = secondaryLayout
        self.note = note
        self.primary = AnyView(primary())
        self.secondary = AnyView(secondary())
    }

    var body: some View {
        FloatingHeaderPanel(identifier: identifier, transitionID: transitionID, twoRows: true) {
            VStack(spacing: FeedChrome.rowSpacing(for: typeSize)) {
                note
                FloatingHeaderRow(layout: primaryLayout, content: primary)
                    .environment(\.feedHeaderRow, .primary)
                FloatingHeaderRow(layout: secondaryLayout, content: secondary)
                    .environment(\.feedHeaderRow, .secondary)
            }
        }
    }
}

private struct FloatingHeaderRow: View {
    let layout: String
    let content: AnyView
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight, alignment: .leading)
                .id(layout)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: layout)
    }
}

struct FloatingPageTitleRow<Leading: View, Trailing: View>: View {
    let title: String
    let identifier: String
    var balancesActions = true
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        PageTitleLayout(balancesActions: balancesActions) {
            HStack(spacing: FeedChrome.panelSpacing, content: leading)
                .labelStyle(.iconOnly)
                .environment(\.pageHeaderAction, true)
            Text(title)
                .font(FeedChrome.emphasizedLabelFont)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .feedHeaderControl(typeSize: typeSize, expandsHorizontally: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(identifier)
            HStack(spacing: FeedChrome.panelSpacing, content: trailing)
                .labelStyle(.iconOnly)
                .environment(\.pageHeaderAction, true)
        }
        .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight)
    }
}

private struct PageTitleLayout: Layout {
    let balancesActions: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sides = sideWidths(subviews)
        let width = proposal.width ?? subviews[1].sizeThatFits(.unspecified).width + sides.leading + sides.trailing
        let title = subviews[1].sizeThatFits(.init(width: max(0, width - sides.leading - sides.trailing), height: nil))
        let height = max(title.height, subviews[0].sizeThatFits(.unspecified).height,
                         subviews[2].sizeThatFits(.unspecified).height)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sides = sideWidths(subviews)
        let titleWidth = max(0, bounds.width - sides.leading - sides.trailing)
        let gap = FeedChrome.panelSpacing
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: .init(width: max(0, sides.leading - gap), height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + sides.leading + titleWidth / 2, y: bounds.midY), anchor: .center,
                          proposal: .init(width: titleWidth, height: nil))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: .init(width: max(0, sides.trailing - gap), height: nil))
    }

    private func sideWidths(_ subviews: Subviews) -> (leading: CGFloat, trailing: CGFloat) {
        let left = subviews[0].sizeThatFits(.unspecified).width
        let right = subviews[2].sizeThatFits(.unspecified).width
        let leading = balancesActions ? max(left, right) : left
        let trailing = balancesActions ? max(left, right) : right
        let gap = FeedChrome.panelSpacing
        return (leading > 0 ? leading + gap : 0, trailing > 0 ? trailing + gap : 0)
    }
}

struct CompactFormValueRow<Label: View>: View {
    let value: String
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FeedChrome.panelSpacing) {
            label().layoutPriority(1)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(minHeight: FeedChrome.compactFormRowHeight)
        .accessibilityElement(children: .combine)
    }
}

private struct FloatingBackPageHeader<Trailing: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FloatingHeaderPanel(identifier: "\(identifier).header") {
            FloatingPageTitleRow(title: title, identifier: "\(identifier).title") {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .accessibilityLabel("返回").accessibilityIdentifier("BackButton")
            } trailing: {
                trailing()
            }
            .environment(\.feedHeaderRow, .single)
        }
    }
}

extension View {
    func suppressPinnedChromePreferences(_ suppress: Bool) -> some View {
        replacingPinnedChrome(suppress, bottom: nil)
    }

    func hidePinnedChromeForReader(_ showingReader: Bool) -> some View {
        replacingPinnedChrome(showingReader, bottom: .hidden)
    }

    private func replacingPinnedChrome(_ replace: Bool, bottom: PinnedBottomContent?) -> some View {
        transformPreference(PinnedHeaderPreference.self) { if replace { $0 = [] } }
            .transformPreference(PinnedBottomPreference.self) { if replace { $0 = bottom } }
    }

    func localPageChrome() -> some View {
        environment(\.pinsPageChrome, false)
    }

    func feedPageContent(topGap: CGFloat = FeedChrome.contentTopGap) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FeedChrome.contentInset)
            .padding(.top, topGap)
    }

    func floatingGroupedPageContent() -> some View {
        contentMargins(.top, FeedChrome.contentTopGap, for: .scrollContent)
            .padding(.horizontal, FeedChrome.contentInset - FeedChrome.systemGroupedListInset)
            .background(Color(uiColor: .systemGroupedBackground))
    }

    func accountPageListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: FeedChrome.panelSpacing, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    func accountPageCard(compactRows: Bool = false) -> some View {
        padding(.horizontal, FeedChrome.contentSpacing)
            .padding(.vertical, compactRows ? 0 : FeedChrome.contentSpacing)
            .frame(maxWidth: .infinity,
                   minHeight: compactRows ? FeedChrome.compactFormRowHeight : FeedChrome.rowHeight,
                   alignment: .leading)
            .formRowSurface()
            .accountPageListRow()
    }

    func accountSubpageHeader<Trailing: View>(_ title: String, identifier: String,
                                             @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        accountSubpageContent()
            .floatingBackPageChrome(title, identifier: identifier, trailing: trailing)
    }

    func accountSubpageContent() -> some View {
        listStyle(.plain)
            .environment(\.defaultMinListRowHeight, FeedChrome.compactFormRowHeight)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, FeedChrome.contentTopGap, for: .scrollContent)
            .padding(.horizontal, FeedChrome.contentInset)
            .background(Color(uiColor: .systemGroupedBackground))
            .buttonStyle(.borderless)
            .font(.subheadline)
            .imageScale(.small)
    }

    private func floatingBackPageChrome<Trailing: View>(_ title: String, identifier: String,
                                                       @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        appNavigationChrome(backButton: true, showsToolbarBackButton: false)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                FloatingBackPageHeader(title: title, identifier: identifier, trailing: trailing)
            }
    }

    func floatingPageHeader<Leading: View, Trailing: View>(
        _ title: String, identifier: String, balancesActions: Bool = true, pinned: Bool = false,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                FloatingHeaderPanel(identifier: "\(identifier).header", canPin: pinned) {
                    FloatingPageTitleRow(title: title, identifier: "\(identifier).title", balancesActions: balancesActions,
                                         leading: leading, trailing: trailing)
                        .environment(\.feedHeaderRow, .single)
                }
            }
    }
}

/// Divides the row into equal tracks, with each control spanning one or more tracks.
struct FeedHeaderGrid: Layout {
    let spans: [Int]
    private let spacing = FeedChrome.panelSpacing
    private var columnCount: Int { spans.reduce(0, +) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let column = columnWidth(for: proposal.width)
        let height = zip(subviews, spans).map { view, span in
            view.sizeThatFits(.init(width: width(of: span, column: column), height: nil)).height
        }.max() ?? 0
        return CGSize(width: width(of: columnCount, column: column), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(for: bounds.width)
        var x = bounds.minX
        for (view, span) in zip(subviews, spans) {
            let width = width(of: span, column: column)
            view.place(at: CGPoint(x: x + width / 2, y: bounds.midY), anchor: .center,
                       proposal: .init(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func columnWidth(for width: CGFloat?) -> CGFloat {
        max(FeedChrome.rowHeight, ((width ?? 0) - CGFloat(columnCount - 1) * spacing) / CGFloat(columnCount))
    }

    private func width(of span: Int, column: CGFloat) -> CGFloat {
        CGFloat(span) * column + CGFloat(span - 1) * spacing
    }
}

struct FeedHeaderButtonStyle: ButtonStyle {
    var truncatesLabel = false
    var expandsHorizontally = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.dynamicTypeSize) private var typeSize

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1).fixedSize(horizontal: !truncatesLabel, vertical: false)
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .feedHeaderControl(typeSize: typeSize, expandsHorizontally: expandsHorizontally)
    }
}

extension EnvironmentValues {
    @Entry var feedHeaderRow: FeedHeaderRow? = nil
    @Entry var pageHeaderAction = false
}

extension View {
    func feedHeaderControl(typeSize: DynamicTypeSize, expandsHorizontally: Bool = false) -> some View {
        modifier(FeedHeaderControlSurface(typeSize: typeSize, expandsHorizontally: expandsHorizontally))
    }
}

private struct FeedHeaderControlSurface: ViewModifier {
    let typeSize: DynamicTypeSize
    let expandsHorizontally: Bool
    @Environment(\.feedHeaderRow) private var row
    @Environment(\.pageHeaderAction) private var pageAction

    func body(content: Content) -> some View {
        let insets = FeedChrome.surfaceInsets(for: typeSize, row: row)
        let square = pageAction && !expandsHorizontally
        content
            .font(FeedChrome.labelFont)
            .imageScale(FeedChrome.iconScale)
            .padding(.horizontal, square ? 0 : FeedChrome.controlSpacing)
            .offset(y: FeedChrome.contentOffset(for: insets))
            .frame(minWidth: square ? FeedChrome.pageActionWidth : FeedChrome.rowHeight, minHeight: FeedChrome.rowHeight)
            .frame(width: square ? FeedChrome.pageActionWidth : nil)
            .frame(maxWidth: expandsHorizontally ? .infinity : nil, alignment: square ? .center : .leading)
            .contentShape(Rectangle())
            .appControlSurface(insets: insets)
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
    var showsSymbols = true
    var alignsToHeaderGrid = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.feedHeaderRow) private var row

    var body: some View {
        let surfaceInsets = FeedChrome.surfaceInsets(for: typeSize, row: row)
        Group {
            if alignsToHeaderGrid {
                FeedHeaderGrid(spans: options.map { _ in 1 }) {
                    optionButtons(surfaceInsets: surfaceInsets)
                }
            } else {
                HStack(spacing: 2) {
                    optionButtons(surfaceInsets: surfaceInsets)
                }
                .padding(.horizontal, AppShape.segmentInset)
                .appControlSurface(insets: surfaceInsets)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }

    private func optionButtons(surfaceInsets: EdgeInsets) -> some View {
        ForEach(options) { option in
            let isSelected = selection == option.id
            Button { selection = option.id } label: {
                let label = optionLabel(option, surfaceInsets: surfaceInsets)
                if alignsToHeaderGrid {
                    label.appControlSurface(selected: isSelected, insets: surfaceInsets)
                } else {
                    label.background {
                        AppShape.segment
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                            .padding(.vertical, AppShape.segmentInset)
                            .padding(surfaceInsets)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("\(identifier).\(option.id)")
        }
    }

    private func optionLabel(_ option: FeedScopeOption, surfaceInsets: EdgeInsets) -> some View {
        Group {
            if alignsToHeaderGrid {
                HStack(spacing: FeedChrome.iconLabelSpacing) {
                    Image(systemName: option.symbol).imageScale(FeedChrome.iconScale)
                    Text(option.title).lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                }
            } else if showsSymbols {
                Label(option.title, systemImage: option.symbol).fixedSize(horizontal: true, vertical: false)
            } else {
                Text(option.title).fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(FeedChrome.labelFont)
        .padding(.horizontal, alignsToHeaderGrid ? 3 : 5)
        .offset(y: FeedChrome.contentOffset(for: surfaceInsets))
        .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight)
        .contentShape(Rectangle())
    }

}

private struct PinnedHeaderRowTransition: ViewModifier, Animatable {
    enum Phase { case expand, collapse, showSingle, hideSingle }
    let phase: Phase
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Spend the first part changing the lower edge, then crossfade the upper controls.
        let edge = min(1, progress / 0.65)
        let fade = max(0, (progress - 0.65) / 0.35)
        switch phase {
        case .expand, .collapse:
            let growing = phase == .expand
            let revealed = growing ? edge : 1 - edge
            content.mask(alignment: .top) {
                GeometryReader { geometry in
                    let shortHeight = FeedChrome.singleRowPanelHeight + FeedChrome.headerOuterInset * 2
                    let height = shortHeight + max(0, geometry.size.height - shortHeight) * revealed
                    let shape = UnevenRoundedRectangle(bottomLeadingRadius: FeedChrome.panelShape.cornerSize.width,
                                                       bottomTrailingRadius: FeedChrome.panelShape.cornerSize.width)
                    if revealed >= 1 {
                        Rectangle()
                    } else {
                        shape.frame(height: height).padding(.horizontal, FeedChrome.contentInset)
                    }
                }
            }
            .opacity(growing ? 1 : 1 - fade)
        case .showSingle, .hideSingle:
            content.opacity(phase == .showSingle ? fade : 1 - fade)
        }
    }

    static func transition(insertion: Phase, removal: Phase) -> AnyTransition {
        func animate(_ phase: Phase, from start: CGFloat, to end: CGFloat) -> AnyTransition {
            .modifier(active: Self(phase: phase, progress: start),
                      identity: Self(phase: phase, progress: end))
        }
        return .asymmetric(insertion: animate(insertion, from: 0, to: 1),
                           removal: animate(removal, from: 1, to: 0))
    }
}

struct CompactMainTabs<Content: View>: View {
    @Binding var selection: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
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

    private var chromeFade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.16)
    }

    var body: some View {
        content
            .environment(\.pinsPageChrome, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: FeedChrome.rowHeight - FeedChrome.singleRowOverhang + FeedChrome.headerOuterInset)
                    .accessibilityHidden(true)
            }
            .overlayPreferenceValue(PinnedHeaderPreference.self, alignment: .top) { headers in
                ZStack(alignment: .top) {
                    if let header = headers.last {
                        pinnedHeader(header).transition(.opacity)
                    }
                }
                .animation(chromeFade, value: headers.last != nil)
            }
            .overlayPreferenceValue(PinnedBottomPreference.self, alignment: .bottom) { replacement in
                if case .hidden? = replacement {
                    EmptyView()
                } else {
                    FloatingBottomBar {
                        ZStack {
                            if case let .custom(id, view)? = replacement {
                                view.id(id).transition(.opacity)
                            } else {
                                tabButtons.transition(.opacity)
                            }
                        }
                        .animation(chromeFade, value: replacement?.id)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(replacement == nil ? .isTabBar : [])
                    .accessibilityIdentifier(replacement?.id ?? "main.tabs.compact")
                }
            }
    }

    private func pinnedHeader(_ header: PinnedHeader) -> some View {
        let animatesRows = !reduceMotion && !typeSize.isAccessibilitySize
        return ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                if header.twoRows {
                    headerContent(header)
                        .transition(animatesRows ? PinnedHeaderRowTransition.transition(insertion: .expand, removal: .collapse) : .opacity)
                }
            }
            .allowsHitTesting(header.twoRows)

            ZStack(alignment: .top) {
                if !header.twoRows {
                    headerContent(header)
                        .transition(animatesRows ? PinnedHeaderRowTransition.transition(insertion: .showSingle, removal: .hideSingle) : .opacity)
                }
            }
            .allowsHitTesting(!header.twoRows)
            .zIndex(1)
        }
        .animation(animatesRows ? .easeInOut(duration: 0.26) : chromeFade, value: header.twoRows)
        .animation(chromeFade, value: header.transitionID)
    }

    private func headerContent(_ header: PinnedHeader) -> some View {
        ZStack(alignment: .top) {
            header.view.id(header.transitionID).transition(.opacity)
        }
    }

    private var tabButtons: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            ForEach(destinations, id: \.id) { destination in
                Button { selection = destination.id } label: {
                    VStack(spacing: 1) {
                        Image(systemName: destination.symbol)
                            .imageScale(FeedChrome.iconScale)
                            .frame(height: 16)
                        Text(destination.title)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                            .padding(.horizontal, 4)
                    }
                    .font(FeedChrome.labelFont)
                    .frame(height: FeedChrome.rowSurfaceHeight)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: FeedChrome.rowHeight)
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
    }
}

struct FloatingBottomBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(height: FeedChrome.rowHeight)
            .padding(.vertical, -FeedChrome.singleRowOverhang)
            .floatingFeedPanel()
            .padding(.top, FeedChrome.singleRowOverhang)
            .padding(.horizontal, FeedChrome.contentInset)
            .padding(.bottom, FeedChrome.headerOuterInset)
    }
}
