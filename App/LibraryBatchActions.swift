import SwiftUI
import ExViewerCore

enum LibraryBatchSource: String {
    case discover, history = "reading-history", readLater = "read-later", favorites, downloads
}

private enum LibraryBatchAction: String, Identifiable {
    case readLater = "add-read-later", favorite, download, manage, back, move, remove

    var id: Self { self }

    func title(in source: LibraryBatchSource) -> String {
        switch self {
        case .readLater: "稍后再读"
        case .favorite: "站点收藏"
        case .download: "下载"
        case .manage: "管理"
        case .back: "返回"
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
        case .manage: "ellipsis"
        case .back: "chevron.left"
        case .move: "folder"
        case .remove: "trash"
        }
    }

    var tone: AppActionButtonStyle.Tone {
        switch self {
        case .favorite, .manage, .move: .accent
        case .remove: .destructive
        default: .neutral
        }
    }
}

struct LibraryBatchSelectionHeader: View {
    let source: LibraryBatchSource
    let store: LibrarySelectionStore
    @ObservedObject var summary: LibrarySelectionSummary
    var busy = false
    var compact = false
    let onExit: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if compact {
            HStack(spacing: FeedChrome.panelSpacing) {
                selectionCount
                Spacer(minLength: 0)
                selectAllButton
                exitButton
            }
        } else if typeSize.isAccessibilitySize {
            LibraryHeaderActions { selectionCount } trailing: {
                HStack(spacing: FeedChrome.panelSpacing) {
                    selectAllButton
                    exitButton
                }
            }
        } else {
            FeedHeaderGrid(spans: [2, 1, 1]) {
                selectionCount
                selectAllButton
                exitButton
            }
        }
    }

    private var selectionCount: some View {
        Text("已选 \(summary.value.count) 项")
            .monospacedDigit().lineLimit(1)
            .frame(maxWidth: compact || typeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .feedHeaderControl(typeSize: typeSize)
            .accessibilityIdentifier("\(source.rawValue).selection-count")
    }

    private var selectAllButton: some View {
        let all = summary.value.allLoadedSelected
        let title = all ? "取消全选" : "全选已加载"
        let symbol = all ? "minus.square" : "checkmark.square"
        return Button { store.toggleAllLoaded() } label: {
            ViewThatFits(in: .horizontal) {
                if !compact && !typeSize.isAccessibilitySize { Label(title, systemImage: symbol).fixedSize() }
                Image(systemName: symbol)
            }
            .frame(maxWidth: compact || typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !compact && !typeSize.isAccessibilitySize))
        .disabled(busy)
        .accessibilityLabel(title)
        .accessibilityIdentifier("\(source.rawValue).select-all")
    }

    private var exitButton: some View {
        Button(action: onExit) {
            ViewThatFits(in: .horizontal) {
                if !compact { Label("退出", systemImage: "xmark").fixedSize() }
                Image(systemName: "xmark")
            }
            .frame(maxWidth: compact || typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !compact && !typeSize.isAccessibilitySize))
        .foregroundStyle(Color.accentColor)
        .disabled(busy)
        .accessibilityLabel("退出多选")
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
    @State private var managing = false
    @State private var favoriteBatch: FavoriteBatch?
    @State private var notice: Notice?

    private struct Notice: Identifiable {
        let id = UUID()
        let text: String
    }

    private struct FavoriteBatch: Hashable {
        let galleries: [Gallery]
        let owner: String
        let generation: UUID
    }

    private var actions: [LibraryBatchAction] {
        switch source {
        case .discover, .history: [.readLater, .favorite, .download]
        case .readLater: [.favorite, .download, .remove]
        case .favorites: managing ? [.move, .remove, .back] : [.readLater, .download, .manage]
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
                            HStack(spacing: 5) {
                                Image(systemName: symbol).imageScale(.small)
                                if !typeSize.isAccessibilitySize || source == .downloads {
                                    Text(title).lineLimit(1).minimumScaleFactor(0.80)
                                }
                            }
                            .id(action)
                            .transition(.opacity)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AppActionButtonStyle(tone: action.tone, minSurfaceHeight: FeedChrome.rowSurfaceHeight))
                    .accessibilityLabel(accessibilityTitle(action, title: title))
                    .accessibilityIdentifier("\(source.rawValue).\(action.rawValue)")
                    .disabled(busy || (summary.value.count == 0 && action != .back))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: managing)
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice.text)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: AppShape.control)
                        .overlay(AppShape.control.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                        .padding(.horizontal, FeedChrome.contentInset)
                        .alignmentGuide(.top) { $0[.bottom] + 6 }
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("\(source.rawValue).feedback")
                        .task(id: notice.id) {
                            try? await Task.sleep(for: .seconds(3))
                            if !Task.isCancelled { self.notice = nil }
                        }
                }
            }
        }
        .navigationDestination(item: $favoriteBatch) { batch in
            FavoriteGroupPicker(count: batch.galleries.count, moving: false, load: { try await loadGroups(for: batch) }) { choice in
                try queueFavorites(batch, choice: choice)
            }
        }
    }

    private func accessibilityTitle(_ action: LibraryBatchAction, title: String) -> String {
        if action == .readLater { return "加入稍后再读" }
        if action == .remove, source == .readLater { return "移出稍后再读" }
        return title
    }

    private func perform(_ action: LibraryBatchAction) {
        switch action {
        case .manage: managing = true
        case .back: managing = false
        case .move: onMove()
        case .remove: onRemove()
        case .readLater:
            guard library.owner == session.owner else { show("账号已切换，请重新选择作品。"); return }
            let selected = galleries()
            let count = library.addReadLater(selected)
            show(count.map { resultText("已加入稍后再读", $0, of: selected.count, skipped: "已有") } ?? "稍后再读未能保存，请重试。")
        case .download:
            let selected = galleries()
            let count = downloads.enqueueNew(selected)
            show(count.map { resultText("已加入下载队列", $0, of: selected.count, skipped: "已有记录") } ?? "下载队列未能保存，请重试。")
        case .favorite:
            guard session.hasCredentials || AppMode.qa else { show("登录站点账号后可批量收藏。"); return }
            let selected = galleries()
            guard !selected.isEmpty else { return }
            favoriteBatch = FavoriteBatch(galleries: selected, owner: session.owner, generation: session.generation)
        }
    }

    private func checkScope(_ batch: FavoriteBatch) throws {
        guard batch.owner == session.owner, batch.generation == session.generation, batch.owner == library.owner else {
            throw ViewerError.stale
        }
    }

    private func loadGroups(for batch: FavoriteBatch) async throws -> [FavoriteGroupChoice] {
        try checkScope(batch)
        var groups: [Int: [GallerySite: String]] = [:]
        for site in GallerySite.allCases {
            guard let gallery = batch.galleries.first(where: { $0.ref.site == site }) else { continue }
            let form = try await favoriteClient(for: gallery, session: session).read()
            try Task.checkCancellation()
            try checkScope(batch)
            guard form.reference == gallery.ref else { throw ViewerError.restricted }
            for group in form.groups { groups[group.id, default: [:]][site] = group.name }
        }
        return groups.keys.sorted().map { index in
            let names = groups[index, default: [:]]
            let label: String
            if let first = names.values.first, names.values.allSatisfy({ $0 == first }) { label = first }
            else {
                label = GallerySite.allCases.compactMap { site in
                    names[site].map { "\(site.name) · \($0)" }
                }.joined(separator: "\n")
            }
            return FavoriteGroupChoice(id: index, name: label, siteNames: names)
        }
    }

    private func queueFavorites(_ batch: FavoriteBatch, choice: FavoriteGroupChoice) throws {
        try checkScope(batch)
        let additions = try batch.galleries.map { gallery in
            guard let name = choice.siteNames[gallery.ref.site] else { throw ViewerError.stale }
            return SiteFavoriteCache.BatchAddition(scope: .init(gallery, session), client: favoriteClient(for: gallery, session: session),
                                                   title: gallery.title, groupName: name)
        }
        let count = try session.favoriteStateCache.enqueueAdditions(additions, group: choice.id)
        show(resultText("已加入收藏同步队列", count, of: batch.galleries.count, skipped: "已有待处理操作"))
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
                if let loadError {
                    StatusMessage(title: loadError) { attempt += 1 }
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
                if let confirmError { Text(confirmError).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, FeedChrome.contentInset)
            .padding(.top, FeedChrome.contentTopGap).padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PinnedBottomSlot(id: "favorites.groups.actions") {
                Button {
                    guard let choice = choices.first(where: { $0.id == selected }) else { return }
                    do { try onConfirm(choice); dismiss() }
                    catch { confirmError = ErrorMessages.message(error) }
                } label: {
                    Label(moving ? "移动 \(count) 项" : "收藏 \(count) 项", systemImage: moving ? "folder" : "heart")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: FeedChrome.rowSurfaceHeight)
                        .foregroundStyle(.white)
                        .background(Color.accentColor.opacity(selected == nil ? 0.38 : 1), in: AppShape.control)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selected == nil)
                .accessibilityIdentifier(moving ? "favorites.confirm-move" : "favorites.confirm-add")
            }
        }
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false)
        .floatingPageHeader(moving ? "移到分组" : "加入站点收藏", identifier: "favorites.groups", pinned: true) {
            Button { dismiss() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel(moving ? "管理" : "返回")
                .accessibilityIdentifier("favorites.groups.back")
        } trailing: {
            EmptyView()
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

    private func groupRow(_ choice: FavoriteGroupChoice) -> some View {
        let active = selected == choice.id
        return Button {
            selected = choice.id
            confirmError = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(active ? Color.accentColor : Color.secondary)
                Text(choice.name).font(.subheadline.weight(active ? .semibold : .regular))
                Spacer(minLength: 8)
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(minHeight: 44)
            .background(active ? Color.accentColor.opacity(0.10) : .clear, in: AppShape.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("favorites.\(moving ? "move" : "add")-to.\(choice.id)")
    }
}
