import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var appMenuVisible = false
}

private extension EnvironmentValues {
    @Entry var appMenuPresentation: Binding<Bool>? = nil
    @Entry var appMenuMaximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    @Entry var hasAppMenuHost = false
}

/// A single anchored menu surface for value selectors and action menus.
/// UIKit chooses the available side of the anchor; compact screens keep a popover.
struct AppMenu<Options: View, LabelContent: View>: View {
    var onOpen: (() -> Void)? = nil
    @ViewBuilder let content: () -> Options
    @ViewBuilder let label: () -> LabelContent
    @State private var presented = false

    var body: some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            onOpen?()
            presented = true
        } label: { label() }
        .modifier(AppMenuPresentation(presented: $presented, options: content))
    }

}

struct AppMenuItem: View {
    let title: String
    var systemImage: String? = nil
    var isSelected = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: FeedChrome.iconLabelSpacing) {
                if let systemImage { Image(systemName: systemImage).frame(width: 16).accessibilityHidden(true) }
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: FeedChrome.panelSpacing)
                if isSelected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .font(.footnote)
            .foregroundStyle(role == .destructive ? Color.red : isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, FeedChrome.contentSpacing)
            .frame(maxWidth: .infinity, minHeight: FormMenuMetrics.rowHeight, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: AppShape.control)
            .contentShape(AppShape.control)
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct AppMenuContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AppMenuPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.appMenuMaximumSize) private var maximumSize
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let limit = FormMenuMetrics.height(rows: FormMenuMetrics.visibleRows(isLandscape: verticalSizeClass == .compact))
        ScrollView {
            VStack(alignment: .leading, spacing: FeedChrome.panelSpacing, content: content)
                .padding(FeedChrome.panelSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: AppMenuContentHeight.self, value: geometry.size.height)
                    }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: min(FormMenuMetrics.width, maximumSize.width),
               height: min(max(FormMenuMetrics.height(rows: 1), contentHeight), limit, maximumSize.height))
        .onPreferenceChange(AppMenuContentHeight.self) { contentHeight = $0 }
        .font(.footnote)
        .accessibilityElement(children: .contain).accessibilityIdentifier("app.menu.panel")
        .buttonStyle(AppMenuOptionStyle())
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: AppShape.card)
        .overlay { AppShape.card.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5).allowsHitTesting(false) }
    }
}

/// Preserve Button actions, disabled state, accessibility and destructive roles while closing first.
private struct AppMenuOptionStyle: PrimitiveButtonStyle {
    @Environment(\.appMenuPresentation) private var presentation
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            presentation?.wrappedValue = false
            configuration.trigger()
        } label: { configuration.label }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.38)
    }
}

extension View {
    func appContextMenu<Options: View>(enabled: Bool = true, @ViewBuilder content: @escaping () -> Options) -> some View {
        modifier(AppContextMenu(enabled: enabled, options: content))
    }
}

private struct AppContextMenu<Options: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let options: () -> Options
    @State private var presented = false

    func body(content: Content) -> some View {
        if enabled {
            content
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    presented = true
                })
                .accessibilityAction(named: Text("更多操作")) {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    presented = true
                }
                .modifier(AppMenuPresentation(presented: $presented, options: options))
        } else { content }
    }
}

private struct AppConfirmationRequest {
    let id: UUID
    let render: () -> AnyView
    let dismiss: () -> Void
}
private struct AppConfirmationRequests: PreferenceKey {
    static var defaultValue: [AppConfirmationRequest] = []
    static func reduce(value: inout [AppConfirmationRequest], nextValue: () -> [AppConfirmationRequest]) { value.append(contentsOf: nextValue()) }
}
private struct AppConfirmationVisible: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
private struct AppConfirmationPresentation: ViewModifier {
    @Binding var presented: Bool
    let title: String
    let message: String
    let confirm: String
    let cancel: String
    let identifier: String
    let action: () -> Void
    @State private var id = UUID()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.headerSectionContext) private var section
    func body(content: Content) -> some View {
        content
            .preference(key: AppConfirmationVisible.self, value: presented)
            .preference(key: AppConfirmationRequests.self, value: presented ? [.init(id: id, render: {
                AnyView(VStack(spacing: 8) {
                    Text(title).font(FeedChrome.emphasizedLabelFont).lineLimit(1)
                    Text(message).font(FeedChrome.labelFont).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    HStack {
                        Button(cancel) { presented = false }
                            .buttonStyle(AppActionButtonStyle()).frame(width: 88)
                            .accessibilityIdentifier(identifier + ".cancel")
                        Spacer(minLength: 16)
                        Button(confirm, role: .destructive) { presented = false; action() }
                            .buttonStyle(AppActionButtonStyle(tone: .destructive)).frame(width: 88)
                            .accessibilityIdentifier(identifier + ".confirm")
                    }
                }.padding(16).frame(height: 180)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: AppShape.card)
                    .overlay(AppShape.card.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .environment(\.colorScheme, colorScheme)
                    .accessibilityElement(children: .contain).accessibilityIdentifier(identifier + ".dialog"))
            }, dismiss: { presented = false })] : [])
            .onChange(of: presented) { _, visible in section?.pager.setMenuPresentation(id, visible: visible) }
            .onDisappear { presented = false; section?.pager.setMenuPresentation(id, visible: false) }
    }
}
extension View {
    func appConfirmationDialog(_ title: String, message: String, isPresented: Binding<Bool>,
                               confirm: String = "取消收藏", cancel: String = "保留收藏", identifier: String,
                               action: @escaping () -> Void) -> some View {
        modifier(AppConfirmationPresentation(presented: isPresented, title: title, message: message,
                                            confirm: confirm, cancel: cancel, identifier: identifier, action: action))
    }
}

private struct AppMenuRequest {
    let id: UUID
    let anchor: CGRect
    let render: (CGSize, UserInterfaceSizeClass?) -> AnyView
    let dismiss: () -> Void
}
private struct AppMenuRequests: PreferenceKey {
    static var defaultValue: [AppMenuRequest] = []
    static func reduce(value: inout [AppMenuRequest], nextValue: () -> [AppMenuRequest]) { value.append(contentsOf: nextValue()) }
}
private struct AppMenuVisibility: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct AppMenuPresentation<Options: View>: ViewModifier {
    @Binding var presented: Bool
    @ViewBuilder let options: () -> Options
    @State private var presentationID = UUID()
    @State private var anchor = CGRect.zero
    @Environment(\.headerSectionContext) private var section
    @Environment(\.headerSectionSuspended) private var suspended
    @Environment(\.hasAppMenuHost) private var hasHost
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { anchor = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { _, frame in anchor = frame }
                }
            }
            .preference(key: AppMenuRequests.self, value: request.map { [$0] } ?? [])
            .preference(key: AppMenuVisibility.self, value: presented && hasHost)
            .onChange(of: presented) { _, visible in
                if visible && !hasHost {
                    assertionFailure("App menu requires a host on its page or modal root")
                    presented = false
                    return
                }
                section?.pager.setMenuPresentation(presentationID, visible: visible)
            }
            .onChange(of: enabled) { _, enabled in if !enabled { presented = false } }
            .onChange(of: suspended) { _, suspended in if suspended { presented = false } }
            .onDisappear {
                presented = false
                section?.pager.setMenuPresentation(presentationID, visible: false)
            }
    }

    private var request: AppMenuRequest? {
        guard presented, hasHost, anchor.width > 0, anchor.height > 0 else { return nil }
        // Emit the latest source content on every body update, not a snapshot taken at opening.
        return .init(id: presentationID, anchor: anchor, render: { size, verticalSizeClass in
            // Inherit the host's clean environment; only resolved appearance crosses this boundary.
            // Transporting a List/Button's entire environment also transports its interaction transforms.
            return AnyView(AppMenuPanel(content: options)
                .environment(\.colorScheme, colorScheme)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.locale, locale)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.legibilityWeight, legibilityWeight)
                .environment(\.isEnabled, enabled)
                .environment(\.verticalSizeClass, verticalSizeClass)
                .environment(\.appMenuPresentation, $presented)
                .environment(\.appMenuMaximumSize, size))
        }, dismiss: { presented = false })
    }
}

/// Placement is independent of rendering, using host-local safe-area coordinates.
enum AppMenuPlacement {
    static func frame(anchor: CGRect, available: CGRect, contentHeight: CGFloat, maximumRows: Int) -> CGRect {
        let width = min(FormMenuMetrics.width, max(0, available.width))
        let wanted = min(max(FormMenuMetrics.height(rows: 1), contentHeight), FormMenuMetrics.height(rows: maximumRows))
        let gap = FeedChrome.panelSpacing
        let top = min(max(anchor.minY, available.minY), available.maxY)
        let bottom = min(max(anchor.maxY, available.minY), available.maxY)
        let below = max(0, available.maxY - bottom - gap)
        let above = max(0, top - gap - available.minY)
        let usesBelow = below >= wanted || below >= above
        let space = usesBelow ? below : above
        let fittingRows = max(1, Int(max(0, space - FeedChrome.panelSpacing) / (FormMenuMetrics.rowHeight + FeedChrome.panelSpacing)))
        let height = min(wanted, FormMenuMetrics.height(rows: fittingRows), space)
        let x = min(max(anchor.midX - width / 2, available.minX), available.maxX - width)
        let y = usesBelow ? bottom + gap : top - gap - height
        return CGRect(x: x, y: min(max(y, available.minY), available.maxY - height), width: width, height: height)
    }
}

extension View {
    func appMenuHost(enabled: Bool = true) -> some View { modifier(AppMenuHost(enabled: enabled)) }
}
private struct AppMenuHost: ViewModifier {
    let enabled: Bool
    @State private var menuVisible = false
    @State private var confirmationVisible = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    func body(content: Content) -> some View {
        if enabled {
            ZStack {
                content.environment(\.hasAppMenuHost, true).environment(\.appMenuVisible, menuVisible || confirmationVisible).accessibilityHidden(menuVisible || confirmationVisible)
            }
                .overlayPreferenceValue(AppMenuRequests.self) { requests in
                    ZStack {
                        if let request = requests.last {
                            AppMenuOverlay(request: request).id(request.id).transition(.opacity)
                        }
                    }
                    .animation(reducedMotion ? nil : .easeOut(duration: 0.14), value: requests.last?.id)
                }
                .overlayPreferenceValue(AppConfirmationRequests.self) { requests in
                    GeometryReader { geometry in
                        if let request = requests.last {
                            ZStack {
                                Color.black.opacity(0.35).ignoresSafeArea().contentShape(Rectangle())
                                    .onTapGesture(perform: request.dismiss).accessibilityHidden(true)
                                request.render().frame(width: min(320, max(0, geometry.size.width - 2 * FeedChrome.contentInset)))
                                    .accessibilityAction(.escape, request.dismiss)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                                .transition(.opacity)
                        }
                    }.animation(reducedMotion ? nil : .easeOut(duration: 0.14), value: requests.last?.id)
                        .allowsHitTesting(!requests.isEmpty)
                }
                .onPreferenceChange(AppMenuVisibility.self) { menuVisible = $0 }
                .onPreferenceChange(AppConfirmationVisible.self) { confirmationVisible = $0 }
                .transformPreference(AppConfirmationRequests.self) { $0 = [] }
                .transformPreference(AppConfirmationVisible.self) { $0 = false }
                // Modal hosts consume their own requests so an underlying host never draws them.
                .transformPreference(AppMenuRequests.self) { $0 = [] }
                .transformPreference(AppMenuVisibility.self) { $0 = false }
        } else { content }
    }
}

private struct AppMenuOverlay: View {
    let request: AppMenuRequest
    @State private var contentHeight: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        GeometryReader { geometry in
            let verticalEdge = FeedChrome.panelSpacing
            let horizontalEdge = FeedChrome.contentInset
            let insets = geometry.safeAreaInsets
            let available = CGRect(x: insets.leading + horizontalEdge, y: insets.top + verticalEdge,
                                   width: max(0, geometry.size.width - insets.leading - insets.trailing - horizontalEdge * 2),
                                   height: max(0, geometry.size.height - insets.top - insets.bottom - verticalEdge * 2))
            let origin = geometry.frame(in: .global).origin
            let anchor = request.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
            let frame = AppMenuPlacement.frame(anchor: anchor, available: available, contentHeight: contentHeight,
                                               maximumRows: FormMenuMetrics.visibleRows(isLandscape: verticalSizeClass == .compact))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture(perform: request.dismiss)
                    .accessibilityHidden(true)
                request.render(frame.size, verticalSizeClass)
                    .onPreferenceChange(AppMenuContentHeight.self) { height in
                        if height.isFinite && abs(height - contentHeight) > 0.5 { contentHeight = height }
                    }
                    .opacity(contentHeight > 0 ? 1 : 0)
                    .shadow(color: .black.opacity(0.24), radius: 10, y: 3)
                    .offset(x: frame.minX, y: frame.minY)
                    .accessibilityAction(.escape, request.dismiss)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
    }
}

struct AppMenuValueLabel: View {
    let title: String
    var width: CGFloat? = nil
    var systemImage: String? = nil
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: FeedChrome.iconLabelSpacing) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            else { Text(title).lineLimit(1).truncationMode(.tail) }
            Image(systemName: "chevron.down").imageScale(.small)
        }
        .font(.footnote).foregroundStyle(Color.primary)
        .padding(.horizontal, FeedChrome.contentSpacing)
        .frame(width: width, height: FeedChrome.compactFormRowHeight)
        .contentShape(AppShape.control)
        .appControlSurface(insets: EdgeInsets(top: FormMenuMetrics.valueFaceInset, leading: 0,
                                            bottom: FormMenuMetrics.valueFaceInset, trailing: 0))
        .opacity(enabled ? 1 : 0.38)
    }
}
