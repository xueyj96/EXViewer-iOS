import SwiftUI

private struct PinnedHeader {
    let identifier: String
    let transitionID: String
    let contentID: String
    let twoRows: Bool
    let view: AnyView
    var retentionID: String = ""
    var owner: UUID? = nil
    var hidden = false
    var retainsViewport = false
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
    @Entry fileprivate var feedRetainsViewport = false
    @Entry var mainTabSelection: Binding<Int>? = nil
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

/// WebKit can extend into inherited safe-area insets; reserve the shared bar
/// explicitly for non-scrolling page content, without duplicating its geometry.
private struct PinnedBottomBarClearance: ViewModifier {
    @Environment(\.pinsPageChrome) private var pinsPageChrome
    func body(content: Content) -> some View {
        content.padding(.bottom, pinsPageChrome ? FeedChrome.bottomBarReservedHeight : 0)
    }
}

extension View {
    func avoidingPinnedBottomBar() -> some View { modifier(PinnedBottomBarClearance()) }
}

private struct PinnedClearanceKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
private extension EnvironmentValues {
    var pinnedHeaderClearance: CGFloat? {
        get { self[PinnedClearanceKey.self] }
        set { self[PinnedClearanceKey.self] = newValue }
    }
}

private enum ShellClearanceResizeKey: TransactionKey { static let defaultValue = false }
private extension Transaction {
    var isShellClearanceResize: Bool {
        get { self[ShellClearanceResizeKey.self] }
        set { self[ShellClearanceResizeKey.self] = newValue }
    }
}

/// Release the page gate when the rendered clearance reaches its target.
/// Transaction completions may remain pending in a mounted navigation subtree.
private struct FeedLayoutSettlementMotion: AnimatableModifier {
    var clearance: CGFloat
    let target: CGFloat
    let owner: UUID
    let pager: HeaderSectionPager?
    var animatableData: CGFloat {
        get { clearance }
        set {
            clearance = newValue
            if abs(newValue - target) < 0.01 {
                let pager = pager, owner = owner
                Task { @MainActor in pager?.finishLayoutSettlement(owner) }
            }
        }
    }
    func body(content: Content) -> some View {
        content.frame(width: 1, height: max(0, clearance)).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Interpolates the fixed shell surface only. Page geometry uses its own stable
/// layout target, so a navigation preview and its live route share one clearance.
private struct ChromeClearanceMotion: AnimatableModifier {
    var clearance: CGFloat
    var animatableData: CGFloat { get { clearance } set { clearance = newValue } }
    func body(content: Content) -> some View {
        content.environment(\.pinnedHeaderClearance, clearance)
            .background(alignment: .topLeading) {
                if AppMode.qa { ChromeMotionQA(clearance: clearance).frame(width: 1, height: 1) }
            }
            .transaction {
                // Only consume the shell's resize transaction; page swipes and rebounds
                // keep their own spring/ease-out animations.
                if $0.isShellClearanceResize { $0.animation = nil }
            }
    }
}

enum FeedHeaderRow { case primary, secondary, single }

/// One timing vocabulary for the fixed app shell. No delayed page-owned completion tasks.
enum ChromeMotion {
    static let resizeDuration: Double = 0.24
    static let replacementDuration: Double = 0.16
    static let controlDuration: Double = 0.18
    static let resize = Animation.easeInOut(duration: resizeDuration)
    static let replace = Animation.easeInOut(duration: replacementDuration)
    static let control = Animation.easeInOut(duration: controlDuration)
}

enum FeedChrome {
    static let contentInset: CGFloat = 20
    static let systemGroupedListInset: CGFloat = 16
    static let contentSpacing: CGFloat = 8
    static let headerOuterInset: CGFloat = 4
    static let contentTopGap = contentSpacing - headerOuterInset
    static let sectionSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 44
    static let compactFormRowHeight: CGFloat = 36
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
    static let bottomBarReservedHeight = rowHeight - singleRowOverhang + headerOuterInset
    static let singleRowSurfaceInset = verticalHitInset(for: rowSurfaceHeight)
    static let doubleRowPanelHeight = 2 * rowSurfaceHeight + 3 * panelSpacing
    static func headerClearance(twoRows: Bool) -> CGFloat {
        (twoRows ? doubleRowPanelHeight : singleRowPanelHeight) + 2 * headerOuterInset
    }
    static let doubleRowOverhang = (2 * rowHeight - doubleRowPanelHeight) / 2

    enum ReaderBar {
        static let maximumWidth: CGFloat = 460
        static let pageDigitFont = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let pageDigitLineHeight: CGFloat = 13
        static let pageSeparatorWidth: CGFloat = 22
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
    let twoRows: Bool
    let retainsViewport: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.headerSectionPreviewClearance) private var previewClearance
    @Environment(\.headerSectionContext) private var sectionContext
    @State private var renderedClearance: CGFloat?
    @State private var layoutOwner = UUID()
    @State private var visible = false
    private let feed: (CGFloat) -> Feed
    private let header: Header

    init(twoRows: Bool, retainsViewport: Bool = false, @ViewBuilder feed: @escaping (CGFloat) -> Feed, @ViewBuilder header: () -> Header) {
        self.twoRows = twoRows
        self.retainsViewport = retainsViewport
        self.feed = feed
        self.header = header()
    }

    var body: some View {
        // Each route owns its layout. A covered double-row source must not adopt
        // the detail route's single-row clearance before its return snapshot is used.
        let destinationHeight = (retainsViewport ? nil : previewClearance) ?? FeedChrome.headerClearance(twoRows: twoRows)
        let height = renderedClearance ?? destinationHeight
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                feed(height)
                    .scrollClipDisabled()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                header
                    .environment(\.feedRetainsViewport, retainsViewport)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .zIndex(1)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Palette.background.ignoresSafeArea(.container))
        .background(alignment: .topLeading) {
            Color.clear.modifier(FeedLayoutSettlementMotion(clearance: height, target: height,
                owner: layoutOwner, pager: sectionContext?.pager))
        }
        .background {
            if AppMode.qa {
                Color.clear.modifier(FeedClearanceMotionQA(clearance: height))
                    .frame(width: 1, height: 1).allowsHitTesting(false)
            }
        }
        .avoidingPinnedBottomBar()
        .onAppear {
            visible = true
            sectionContext?.pager.finishLayoutSettlement(layoutOwner)
            renderedClearance = destinationHeight
        }
        .onDisappear {
            visible = false
            sectionContext?.pager.finishLayoutSettlement(layoutOwner)
        }
        .onChange(of: destinationHeight) { _, value in
            guard visible, let previous = renderedClearance, abs(previous - value) > 0.5 else {
                sectionContext?.pager.finishLayoutSettlement(layoutOwner)
                renderedClearance = value
                return
            }
            // The horizontal handoff is intentionally atomic. Start the separate
            // vertical resize here, after the incoming pane has reached its slot.
            var transaction = Transaction(animation: reduceMotion ? nil : ChromeMotion.resize)
            transaction.disablesAnimations = false
            let pager = sectionContext?.pager
            pager?.finishLayoutSettlement(layoutOwner)
            let owner = UUID()
            layoutOwner = owner
            pager?.beginLayoutSettlement(owner)
            withTransaction(transaction) { renderedClearance = value }
            if reduceMotion { pager?.finishLayoutSettlement(owner) }
        }
    }
}

struct FloatingHeaderPanel<Content: View>: View {
    @State private var owner = UUID()
    @Environment(\.headerSectionContext) private var sectionContext
    @Environment(\.pinsPageChrome) private var pinsPageChrome
    @Environment(\.feedRetainsViewport) private var retainsViewport
    let identifier: String
    let transitionID: String
    let contentID: String
    let retentionID: String
    let twoRows: Bool
    let canPin: Bool
    let content: Content

    init(identifier: String, transitionID: String? = nil, contentID: String? = nil, retentionID: String? = nil, twoRows: Bool = false, canPin: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.transitionID = transitionID ?? identifier
        self.contentID = contentID ?? transitionID ?? identifier
        self.retentionID = retentionID ?? self.contentID
        self.twoRows = twoRows
        self.canPin = canPin
        self.content = content()
    }

    var body: some View {
        if pinsPageChrome && canPin {
            Color.clear.frame(height: FeedChrome.headerClearance(twoRows: twoRows))
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) {
                    if AppMode.qa {
                        ChromeMotionQA(clearance: FeedChrome.headerClearance(twoRows: twoRows), identifier: "chrome.placeholder.\(identifier)")
                            .frame(width: 1, height: 1)
                    }
                }
                .preference(key: PinnedHeaderPreference.self, value: [.init(identifier: identifier, transitionID: transitionID, contentID: contentID,
                                                   twoRows: twoRows, view: AnyView(content.environment(\.headerSectionContext, sectionContext)), retentionID: retentionID, owner: owner, retainsViewport: retainsViewport)])
        } else {
            panel
        }
    }

    private var panel: some View {
        FloatingHeaderSurface(identifier: identifier, contentID: contentID, twoRows: twoRows, content: AnyView(content))
    }
}

/// Concrete outer surface survives content-type changes between section owners.
/// Only its controls fade; the border, fill and external spacing stay fixed.
private struct FloatingHeaderSurface: View {
    let identifier: String
    let contentID: String
    let twoRows: Bool
    let content: AnyView
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pinnedHeaderClearance) private var sharedClearance
    @Environment(\.edgeReturnChromeHandoff) private var edgeReturn

    var body: some View {
        let overhang = typeSize.isAccessibilitySize ? 0
            : (twoRows ? FeedChrome.doubleRowOverhang : FeedChrome.singleRowOverhang)
        ZStack(alignment: .top) {
            content.id(contentID).transition(.opacity)
        }
        .animation(reduceMotion ? nil : ChromeMotion.replace, value: contentID)
        .frame(height: typeSize.isAccessibilitySize ? nil : sharedClearance.map { max(0, $0 - 2 * FeedChrome.headerOuterInset + 2 * overhang) }
            ?? FeedChrome.rowHeight * (twoRows ? 2 : 1), alignment: .top)
        .clipped()
        .padding(.vertical, typeSize.isAccessibilitySize ? FeedChrome.panelSpacing : -overhang)
        .floatingFeedPanel()
        .overlay {
            if AppMode.qa {
                Color.clear.accessibilityElement()
                    .accessibilityLabel("栏外框")
                    .accessibilityIdentifier("chrome.surface.geometry")
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion || sharedClearance != nil ? nil : ChromeMotion.resize, value: twoRows)
        .transaction { if edgeReturn?.pending == true { $0.animation = nil; $0.disablesAnimations = true } }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        FloatingHeaderPanel(identifier: identifier, transitionID: transitionID,
                            contentID: "\(transitionID):two-row", retentionID: "\(primaryLayout):\(secondaryLayout)", twoRows: true) {
            VStack(spacing: FeedChrome.rowSpacing(for: typeSize)) {
                note
                ZStack { primary.id(primaryLayout).transition(.opacity) }
                    .animation(reduceMotion ? nil : ChromeMotion.replace, value: primaryLayout)
                    .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight, alignment: .leading)
                    .environment(\.feedHeaderRow, .primary)
                ZStack { secondary.id(secondaryLayout).transition(.opacity) }
                    .animation(reduceMotion ? nil : ChromeMotion.replace, value: secondaryLayout)
                    .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight, alignment: .leading)
                    .environment(\.feedHeaderRow, .secondary)
            }
        }
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
        .formRowLayout(.compact, horizontalInset: 0)
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
        transformPreference(PinnedHeaderPreference.self) {
            if replace {
                if case .hidden? = bottom {
                    $0 = [.init(identifier: "reader.hidden", transitionID: "reader", contentID: "reader", twoRows: false, view: AnyView(EmptyView()), hidden: true)]
                } else { $0 = [] }
            }
        }
            .transformPreference(PinnedBottomPreference.self) { if replace { $0 = bottom } }
    }

    func localPageChrome() -> some View {
        environment(\.pinsPageChrome, false).environment(\.edgeReturnChromeHandoff, nil).appMenuHost()
    }

    func feedPageContent(topGap: CGFloat = FeedChrome.contentTopGap) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FeedChrome.contentInset)
            .padding(.top, topGap)
    }

    func floatingGroupedPageContent() -> some View {
        contentMargins(.top, FeedChrome.contentTopGap, for: .scrollContent)
            .padding(.horizontal, FeedChrome.contentInset - FeedChrome.systemGroupedListInset)
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea(.container))
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
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea(.container))
            .buttonStyle(.borderless)
            .font(.footnote)
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
    var highlightsSelection = true
    var onSelection: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.feedHeaderRow) private var row

    @Environment(\.headerSectionContext) private var sectionContext
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private var pager: HeaderSectionPager? { sectionContext?.identifier == identifier ? sectionContext?.pager : nil }

    var body: some View {
        let surfaceInsets = FeedChrome.surfaceInsets(for: typeSize, row: row)
        // Read observable progress in this body, not inside GeometryReader's retained closure.
        let selectedIndex = CGFloat(options.firstIndex(where: { $0.id == selection }) ?? 0)
        let position = pager?.position ?? selectedIndex
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button {
                    onSelection?()
                    if highlightsSelection, let pager { pager.select(option.id, reducedMotion: reducedMotion) }
                    else { selection = option.id }
                } label: { optionLabel(option, surfaceInsets: surfaceInsets) }
                .buttonStyle(.plain)
                .foregroundStyle(highlightsSelection && selection == option.id ? Color.accentColor : Color.primary)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(highlightsSelection && selection == option.id ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(option.id)")
            }
        }
        .padding(.horizontal, AppShape.segmentInset)
        .background {
            GeometryReader { geometry in
                if highlightsSelection {
                    SelectionBackground(position: position, count: options.count, surfaceInsets: surfaceInsets)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .appControlSurface(insets: surfaceInsets)
        .accessibilityElement(children: .contain).accessibilityIdentifier(identifier)
    }

    /// Drawing copies inside one canvas keeps wrapped paint out of layout and accessibility bounds.
    private struct SelectionBackground: View, Animatable {
        var position: CGFloat
        let count: Int
        let surfaceInsets: EdgeInsets
        var animatableData: CGFloat {
            get { position }
            set { position = newValue }
        }

        var body: some View {
            Canvas { context, size in
                let inset = CGFloat(AppShape.segmentInset)
                let width = max(0, (size.width - inset * 2 - CGFloat(max(0, count - 1)) * 2) / CGFloat(max(1, count)))
                let height = max(0, size.height - surfaceInsets.top - surfaceInsets.bottom - inset * 2)
                context.clip(to: Path(CGRect(x: inset, y: 0, width: max(0, size.width - inset * 2), height: size.height)))
                let copies: [CGFloat] = count > 1 ? [-CGFloat(count), 0, CGFloat(count)] : [0]
                for cycle in copies {
                    let rect = CGRect(x: inset + (position + cycle) * (width + 2), y: surfaceInsets.top + inset,
                                      width: width, height: height)
                    context.fill(AppShape.segment.path(in: rect), with: .color(Color.accentColor.opacity(0.12)))
                }
            }
        }
    }

    private func optionLabel(_ option: FeedScopeOption, surfaceInsets: EdgeInsets) -> some View {
        Group {
            if alignsToHeaderGrid {
                HStack(spacing: FeedChrome.iconLabelSpacing) {
                    if !option.symbol.isEmpty { Image(systemName: option.symbol).imageScale(FeedChrome.iconScale) }
                    Text(option.title).lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                }
            } else if showsSymbols && !option.symbol.isEmpty {
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

private struct PinnedHeaderHost: View {
    @Environment(\.edgeReturnChromeHandoff) private var edgeReturn
    let incoming: PinnedHeader?
    let resize: (CGFloat, Bool) -> Void
    let clearance: CGFloat
    @State private var retained: PinnedHeader?
    private var signature: String? {
        incoming.map { "\($0.identifier)|\($0.contentID)|\($0.retentionID)|\($0.owner?.uuidString ?? "")|\($0.twoRows)|\($0.hidden)|\($0.retainsViewport)" }
    }
    var body: some View {
        Group {
            if let header = incoming?.hidden == false ? incoming : retained {
                FloatingHeaderSurface(identifier: header.identifier, contentID: header.contentID,
                                      twoRows: header.twoRows, content: header.view)
                    .modifier(ChromeClearanceMotion(clearance: clearance))
                    .opacity(incoming?.hidden == true ? 0 : 1)
                    .allowsHitTesting(incoming != nil && incoming?.hidden == false)
                    .accessibilityHidden(incoming == nil || incoming?.hidden == true)
            }
        }
        .onChange(of: signature, initial: true) { _, _ in
            guard let incoming, !incoming.hidden else { return }
            retained = incoming
            resize(FeedChrome.headerClearance(twoRows: incoming.twoRows), incoming.retainsViewport)
            edgeReturn?.destinationHeaderDidCommit()
        }
    }
}

struct CompactMainTabs<Content: View>: View {
    @Binding var selection: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let content: Content
    @State private var headerClearance = FeedChrome.singleRowPanelHeight + 2 * FeedChrome.headerOuterInset
    @State private var edgeReturn = EdgeReturnChromeHandoff()
    @State private var edgeTouches = EdgeTouchGate()
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
        reduceMotion ? nil : ChromeMotion.replace
    }

    var body: some View {
        content
            .background(Palette.background.ignoresSafeArea(.container))
            .environment(\.pinsPageChrome, true)
            .environment(\.mainTabSelection, $selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: FeedChrome.bottomBarReservedHeight)
                    .accessibilityHidden(true)
            }
            .overlayPreferenceValue(PinnedHeaderPreference.self, alignment: .top) { headers in
                PinnedHeaderHost(incoming: headers.last, resize: { clearance, _ in
                    guard abs(headerClearance - clearance) > 0.5 else { return }
                    // Native navigation may suppress its second pop animation after an edge return.
                    // The fixed shell still owns its independent structural animation.
                    // The native pop stays atomic, but the shell interpolates its
                    // own height independently. Suppressing both also loses expansion.
                    var transaction = Transaction(animation: reduceMotion ? nil : ChromeMotion.resize)
                    transaction.disablesAnimations = false
                    transaction.isShellClearanceResize = true
                    withTransaction(transaction) { headerClearance = clearance }
                }, clearance: headerClearance)
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
            .appMenuHost()
            .environment(\.edgeReturnChromeHandoff, edgeReturn)
            .environment(\.edgeTouchGate, edgeTouches)
            .background { EdgeTouchWindowProbe(gate: edgeTouches).allowsHitTesting(false) }
            .overlay(alignment: .bottomLeading) {
                if AppMode.qa { ChromeEdgeInteractionQA(handoff: edgeReturn, gate: edgeTouches).frame(width: 1, height: 1).allowsHitTesting(false) }
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
