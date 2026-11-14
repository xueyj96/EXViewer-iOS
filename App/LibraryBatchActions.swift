import SwiftUI
import ExViewerCore

enum LibraryBatchSource: String {
    case discover, history = "reading-history", readLater = "read-later", favorites, downloads
}

private enum LibraryBatchAction: String, Identifiable {
    case readLater = "add-read-later", favorite, download, move, remove

    var id: Self { self }

    func title(in source: LibraryBatchSource) -> String {
        switch self {
        case .readLater: "稍后再读"
        case .favorite: "站点收藏"
        case .download: "下载"
        case .move: "移到分组"
        case .remove:
            switch source {
            case .favorites: "取消收藏"
            case .downloads: "移除本机副本"
            default: "移出"
            }
        }
    }

    var symbol: String {
        switch self {
        case .readLater: "text.badge.plus"
        case .favorite: "heart"
        case .download: "arrow.down.circle"
        case .move: "folder"
        case .remove: "trash"
        }
    }

    var tone: AppActionButtonStyle.Tone {
        switch self {
        case .favorite, .move: .accent
        case .remove: .destructive
        default: .neutral
        }
    }
}

struct LibraryBatchEntryButton: View {
    let identifier: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FeedChrome.iconLabelSpacing) {
                    Image(systemName: "checkmark.square").accessibilityHidden(true)
                    Text("批量管理")
                }
                .fixedSize()
                Text("批量管理").fixedSize()
                Image(systemName: "checkmark.square")
            }
            .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel("批量管理")
        .accessibilityIdentifier(identifier)
    }
}

struct LibraryBatchSelectionHeader: View {
    let source: LibraryBatchSource
    let store: LibrarySelectionStore
    @ObservedObject var summary: LibrarySelectionSummary
    var busy = false
    let onExit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: FeedChrome.panelSpacing))
            : AnyLayout(FeedHeaderGrid(spans: [1, 1]))
        layout {
            selectAllButton
            exitButton
        }
    }

    private var selectAllButton: some View {
        let all = summary.value.allLoadedSelected
        return Button { store.toggleAllLoaded() } label: {
            Text(all ? "取消全选" : "全选列表")
                .animation(nil, value: all)
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .disabled(busy)
        .accessibilityValue("已选 \(summary.value.count) 项")
        .accessibilityHint(all ? "清除当前选择" : "选中当前列表已加载的项目")
        .accessibilityIdentifier("\(source.rawValue).select-all")
    }

    private var exitButton: some View {
        Button(action: onExit) {
            Text("退出多选")
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .foregroundStyle(Color.accentColor)
        .disabled(busy)
        .accessibilityIdentifier(source == .favorites ? "favorites.edit" : "\(source.rawValue).exit")
    }
}

struct LibraryBatchToolbar: View {
    let source: LibraryBatchSource
    @ObservedObject var summary: LibrarySelectionSummary
    var busy = false
    var galleries: () -> [Gallery] = { [] }
    var onMove: () -> Void = {}
    var onRemove: () -> Void = {}
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
    }

    private var actions: [LibraryBatchAction] {
        switch source {
        case .discover, .history: [.readLater, .favorite, .download]
        case .readLater: [.favorite, .download, .remove]
        case .favorites: [.remove, .download, .move]
        case .downloads: [.remove]
        }
    }

    var body: some View {
        PinnedBottomSlot(id: "\(source.rawValue).actions") {
            HStack(spacing: FeedChrome.panelSpacing) {
                ForEach(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    let title = action.title(in: source)
                    let symbol = action == .remove && source == .favorites ? "heart.slash" : action.symbol
                    Button { perform(action) } label: {
                        ZStack {
                            HStack(spacing: FeedChrome.iconLabelSpacing) {
                                Image(systemName: symbol).imageScale(FeedChrome.iconScale)
                                if !typeSize.isAccessibilitySize || source == .downloads {
                                    Text(title).lineLimit(1).minimumScaleFactor(0.80)
                                }
                            }
                            .id(action)
                            .transition(.opacity)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AppActionButtonStyle(tone: action.tone, minSurfaceHeight: FeedChrome.rowSurfaceHeight,
                                                     labelFont: FeedChrome.labelFont))
                    .accessibilityLabel(accessibilityTitle(action, title: title))
                    .accessibilityIdentifier("\(source.rawValue).\(action.rawValue)")
                    .disabled(busy || (summary.value.count == 0))
                }
            }
            .appToast(message: Binding(get: { notice?.text }, set: { if $0 == nil { notice = nil } }),
                      identifier: "\(source.rawValue).feedback")
        }
    }

    private func accessibilityTitle(_ action: LibraryBatchAction, title: String) -> String {
        if action == .readLater { return "加入稍后再读" }
        if action == .remove, source == .readLater { return "移出稍后再读" }
        return title
    }

    private func perform(_ action: LibraryBatchAction) {
        switch action {
        case .move: onMove()
        case .remove: onRemove()
        case .readLater:
            guard library.owner == session.owner else { show("账号已切换 请重新选择作品"); return }
            let selected = galleries()
            let count = library.addReadLater(selected)
            show(count.map { resultText("已加入稍后再读", $0, of: selected.count, skipped: "已有") } ?? "稍后再读保存失败 请重试")
        case .download:
            let selected = galleries()
            let count = downloads.enqueueNew(selected)
            show(count.map { resultText("已加入下载队列", $0, of: selected.count, skipped: "已有记录") } ?? "下载队列保存失败 请重试")
        case .favorite:
            guard session.hasCredentials || AppMode.qa else { show("请先登录站点账号"); return }
            guard session.owner == library.owner else { show(ErrorMessages.message(ViewerError.stale)); return }
            let selected = galleries()
            guard !selected.isEmpty else { return }
            do {
                let count = try session.addToDefaultFavorites(selected)
                show(resultText("已加入收藏同步队列", count, of: selected.count, skipped: "已有待处理操作"))
            } catch { show(ErrorMessages.message(error)) }
        }
    }

    private func resultText(_ action: String, _ count: Int, of total: Int, skipped: String) -> String {
        let omitted = total - count
        return omitted > 0 ? "\(action) \(count) 项 · \(omitted) 项\(skipped)" : "\(action) \(count) 项"
    }

    private func show(_ text: String) { notice = Notice(text: text) }
}

struct FavoriteGroupChoice: Identifiable {
    let id: Int
    let name: String
    var siteNames: [GallerySite: String] = [:]
}

struct FavoriteGroupPicker: View {
    let count: Int
    let moving: Bool
    let load: () async throws -> [FavoriteGroupChoice]
    let onConfirm: (FavoriteGroupChoice) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [FavoriteGroupChoice] = []
    @State private var selected: Int?
    @State private var loadError: String?
    @State private var confirmError: String?
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if loadError != nil {
                    Button("重试加载") { attempt += 1 }.buttonStyle(AppActionButtonStyle(tone: .accent))
                } else if choices.isEmpty {
                    ProgressView("读取收藏分组…").frame(maxWidth: .infinity).padding(.vertical, 36)
                } else {
                    VStack(spacing: 0) {
                        ForEach(choices) { choice in
                            groupRow(choice)
                            if choice.id != choices.last?.id { Divider().padding(.horizontal, 10) }
                        }
                    }
                    .padding(FeedChrome.panelSpacing)
                    .background(FloatingChrome.headerBackground, in: FeedChrome.panelShape)
                    .overlay(FeedChrome.panelShape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, FeedChrome.contentInset)
            .padding(.top, FeedChrome.contentTopGap).padding(.bottom, 16)
        }
        .appToast(message: loadError ?? confirmError, identifier: "favorites.groups.error")
        .detailEdgeBack(commitAllowed: true, committing: { confirmSelection() })
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false, customEdgeBack: true)
        .floatingPageHeader(moving ? "移到分组" : "加入站点收藏", identifier: "favorites.groups", pinned: true) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel(moving ? "管理" : "返回")
                .accessibilityIdentifier("favorites.groups.back")
        } trailing: {
            Button { _ = confirmSelection() } label: { Image(systemName: "checkmark") }
                .buttonStyle(FeedHeaderButtonStyle()).foregroundStyle(Color.accentColor)
                .accessibilityLabel("确认")
                .accessibilityIdentifier(moving ? "favorites.confirm-move" : "favorites.confirm-add")
        }
        .task(id: attempt) {
            loadError = nil
            do {
                let groups = try await load()
                try Task.checkCancellation()
                guard !groups.isEmpty else { throw ViewerError.layoutChanged }
                choices = groups
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled { loadError = ErrorMessages.message(error) }
            }
        }
    }

    @discardableResult private func confirmSelection() -> Bool {
        guard let choice = choices.first(where: { $0.id == selected }) else { dismiss(); return true }
        do { try onConfirm(choice); dismiss(); return true }
        catch { confirmError = ErrorMessages.message(error); return false }
    }

    private func groupRow(_ choice: FavoriteGroupChoice) -> some View {
        let active = selected == choice.id
        return Button {
            selected = choice.id
            confirmError = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(choice.name).font(FeedChrome.labelFont)
                Spacer(minLength: 8)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(minHeight: FeedChrome.rowHeight)
            .background(active ? Color.accentColor.opacity(0.10) : .clear, in: AppShape.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("favorites.\(moving ? "move" : "add")-to.\(choice.id)")
    }
}

/// Center swipes leave management; edge swipes remain owned by section navigation.
enum MultiSelectionSwipePolicy {
    static func exits(startX: CGFloat, width: CGFloat, translation: CGSize) -> Bool {
        let edge = PageEdgeGestureMetrics.activationWidth
        return width > edge * 2 && startX > edge && startX < width - edge &&
            translation.width >= 48 && translation.width > abs(translation.height) * 1.5
    }
}

private struct MultiSelectionExitSwipe: ViewModifier {
    let selecting: Bool
    let action: () -> Void
    @State private var width: CGFloat = 0
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 18).onEnded { value in
                guard selecting, MultiSelectionSwipePolicy.exits(startX: value.startLocation.x, width: width,
                                                               translation: value.translation) else { return }
                action()
            }, including: selecting ? .all : .none)
    }
}

extension View {
    func exitMultiSelectionOnRightSwipe(_ selecting: Bool, action: @escaping () -> Void) -> some View {
        modifier(MultiSelectionExitSwipe(selecting: selecting, action: action))
    }
}
