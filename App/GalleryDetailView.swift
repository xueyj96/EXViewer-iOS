import SwiftUI
import ExViewerCore

struct GalleryDetailView: View {

    let gallery: Gallery
    private let onResumeReading: (() -> Void)?
    private let searchTarget: DetailSearchTarget?
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.galleryDetailPresentation) private var presentation
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .footnote) private var actionHeight = FeedChrome.rowSurfaceHeight
    @State private var loadedDetail: ReaderOpeningDetail?
    @State private var loadedScope: PageReadScope?
    @State private var failure: String?
    @State private var loadToken = UUID()
    @State private var web: WebDestination?
    @State private var downloadOptions = false
    @State private var lastBlockedTags: [GalleryTag] = []
    @State private var selectedTagIDs = Set<String>()
    @State private var originatingSearch: DetailSearchTarget?
    @State private var tagFeedback: String?
    @State private var tagFailure: String?
    @State private var favoriteEditing = false
    @State private var favoriteFailure: String?
    @State private var pendingOfflineUpdate: GalleryOfflineUpdate?
    @StateObject private var favoriteObservation = GalleryFavoriteObservation()
    @StateObject private var downloadVersions = GalleryDownloadVersions()

    init(gallery: Gallery, onResumeReading: (() -> Void)? = nil, searchTarget: DetailSearchTarget? = nil) {
        self.gallery = gallery
        self.onResumeReading = onResumeReading
        self.searchTarget = searchTarget
        _originatingSearch = State(initialValue: searchTarget?.origin == .currentSearch ? searchTarget : nil)
    }

    private var activeSearchTarget: DetailSearchTarget? {
        let target = originatingSearch ?? (searchTarget?.origin == .discoverSearch ? searchTarget : nil)
        return target?.isCurrent == true ? target : nil
    }

    private var openingDetail: ReaderOpeningDetail? {
        if loadedScope == session.pageReadScope, let loadedDetail, loadedDetail.detail.gallery.ref == gallery.ref {
            return loadedDetail
        }
        return session.cachedGalleryDetail(for: gallery.ref)
    }

    private var detail: GalleryDetail? { openingDetail?.detail }

    private var current: Gallery {
        guard var resolved = detail?.gallery else { return gallery }
        if resolved.cover == nil { resolved.cover = gallery.cover }
        if resolved.title.isEmpty { resolved.title = gallery.title }
        if resolved.category.isEmpty { resolved.category = gallery.category }
        if resolved.uploader.isEmpty { resolved.uploader = gallery.uploader }
        if resolved.pages == nil { resolved.pages = gallery.pages }
        if resolved.rating == nil { resolved.rating = gallery.rating }
        if resolved.tags.isEmpty && !gallery.tags.isEmpty { resolved.tags = gallery.tags; resolved.tagsComplete = gallery.tagsComplete }
        return resolved
    }
    private var favoriteState: GalleryFavoriteState { favoriteObservation.state }
    private var downloadQuery: GalleryDownloadVersions.Query? {
        GalleryDownloadVersions.query(for: current.ref, library: library, session: session)
    }
    private var downloadState: GalleryDownloadState {
        downloadVersions.downloadState(for: current.ref, library: library, session: session)
    }
    private var canShowDownloadOptions: Bool {
        switch downloadState {
        case .downloading, .retry, .saved, .update: return true
        case .ready: return detail != nil || library.download(for: current.ref) != nil
        }
    }
    private var selectedTags: [GalleryTag] { current.tags.filter { selectedTagIDs.contains($0.id) } }
    private var favoriteTitle: String {
        switch favoriteState {
        case .unknown: return "站点收藏"
        case .notFavorited: return "添加收藏"
        case .favorited: return "收藏完成"
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                infoCard
                if let failure { StatusMessage(title: failure) { Task { await load(refresh: true) } } }
                if !current.tags.isEmpty || (!current.tagsComplete && failure == nil) {
                    tagsCard
                }
                VStack(spacing: FeedChrome.panelSpacing) {
                    detailLink(title: "站点原页", icon: "safari", identifier: "detail.site-page") {
                        web = .init(title: "画廊原网页", url: current.ref.url)
                    }
                    detailLink(title: "本地下载", icon: "arrow.down.to.line", identifier: "detail.download") {
                        downloadOptions = true
                    }.disabled(!canShowDownloadOptions)
                }
                .padding(FeedChrome.panelSpacing)
                .galleryDetailCard("detail.site-card", containsInsetCards: true)
            }
                .feedPageContent()
                .padding(.bottom, 22)
                .padding(.bottom, onResumeReading == nil ? 64 : 0)
        }
            .accessibilityIdentifier("detail.scroll")
            .appNavigationChrome(backButton: true, showsToolbarBackButton: false)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { detailHeader }
            .task(id: session.pageReadScope) { await load() }
            .task(id: downloadQuery) { await downloadVersions.refresh(current, query: downloadQuery, session: session) }
            .onDisappear { favoriteObservation.cancel() }
            .onAppear(perform: bindFavoriteState)
            .onChange(of: GalleryFavoriteScope(gallery, session)) { _, _ in bindFavoriteState() }
            .onReceive(session.favoriteStateCache.$revision) { _ in favoriteObservation.syncFromCache() }
            .onChange(of: gallery.id) { _, _ in clearTagSelection() }
            .onChange(of: current.tags) { _, tags in selectedTagIDs.formIntersection(Set(tags.map(\.id))) }
            .sheet(item: $web, onDismiss: { Task { await load(refresh: true) } }) { OfficialWebView(destination: $0) }
            .sheet(isPresented: $downloadOptions) { GalleryDownloadsView(gallery: current, versions: downloadVersions) }
            .navigationDestination(isPresented: $favoriteEditing) {
                GalleryFavoriteEditorView(gallery: current, session: session, preparation: favoriteObservation.preparation(favoriteClient(for: current, session: session), reference: current.ref)) { favoriteObservation.accept($0, form: $1) }
            }
            .alert("收藏未能加入", isPresented: Binding(get: { favoriteFailure != nil }, set: { if !$0 { favoriteFailure = nil } })) {
                Button("好") { favoriteFailure = nil }
            } message: { Text(favoriteFailure ?? "") }
            .alert("标签操作未完成", isPresented: Binding(get: { tagFailure != nil }, set: { if !$0 { tagFailure = nil } })) {
                Button("好") { tagFailure = nil }
            } message: { Text(tagFailure ?? "") }
            .confirmOfflineUpdate($pendingOfflineUpdate) { downloads.enqueueUpdate($0, from: current) }
    }

    private var infoCard: some View {
        let inset = FeedChrome.DetailCard.inset
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: inset))
            : AnyLayout(HStackLayout(alignment: .center, spacing: inset))
        let coverWidth = verticalSizeClass == .compact ? FeedChrome.DetailCard.compactCoverWidth : FeedChrome.DetailCard.coverWidth
        return VStack(alignment: .leading, spacing: inset) {
            layout {
                CoverView(gallery: current, fitsExtremeAspects: true)
                    .frame(width: coverWidth, height: coverWidth * FeedChrome.DetailCard.coverHeightRatio)
                    .clipShape(AppShape.control)

                VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                    Text(current.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    galleryCredits
                    galleryFacts
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The button face sits inside a taller hit area. Measure the visible gap.
            detailActions
                .padding(.vertical, -FeedChrome.verticalHitInset(for: actionHeight))
        }
        .padding(inset)
        .galleryDetailCard("detail.info-card")
    }

    private var galleryCredits: some View {
        let artists = current.tags.filter { $0.namespace == "artist" }.map(\.name).joined(separator: "、")
        return Grid(alignment: .leading, horizontalSpacing: FeedChrome.panelSpacing, verticalSpacing: FeedChrome.panelSpacing) {
            creditRow("作者：", value: artists)
            creditRow("上传：", value: current.uploader)
        }
        .font(FeedChrome.DetailCard.metadataFont)
    }

    private func creditRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "N/A" : value)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var galleryFacts: some View {
        let facts = GalleryFact.items(for: current)
        if !facts.isEmpty {
            TagWrapLayout(spacing: FeedChrome.DetailCard.inset, rowSpacing: FeedChrome.panelSpacing) {
                ForEach(facts) { fact in
                    factChip(fact.label, value: fact.value)
                        .accessibilityIdentifier("detail.info.\(fact.id)")
                }
            }
        }
    }

    private func factChip(_ label: String, value: String) -> some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
        .font(FeedChrome.DetailCard.metadataFont)
        .lineLimit(1)
        .padding(.horizontal, FeedChrome.DetailCard.inset)
        .padding(.vertical, 2)
        .frame(minHeight: 22)
        .overlay {
            AppShape.control.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }

    private var tagsCard: some View {
        let tagsByGroup = Dictionary(grouping: current.tags, by: \.namespace)
        return VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            if let message = tagFeedback ?? (tagsByGroup.isEmpty ? "正在读取标签…" : nil) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("detail.tags.feedback")
            }
            if !lastBlockedTags.isEmpty {
                HStack {
                    Text("已屏蔽 \(lastBlockedTags.count) 个标签")
                    Spacer()
                    Button("撤销") {
                        if library.unblock(lastBlockedTags) { lastBlockedTags = []; tagFeedback = "已撤销屏蔽" }
                        else { tagFailure = library.error ?? "标签未能保存，请重试。" }
                    }
                }.font(.footnote)
            }
            ForEach(tagsByGroup.keys.sorted(), id: \.self) { namespace in
                tagGroupCard(namespace, tags: tagsByGroup[namespace, default: []])
            }
        }
        .padding(FeedChrome.DetailCard.tagGroupInset)
        .galleryDetailCard("detail.tags-card", containsInsetCards: true)
    }

    private func tagGroupCard(_ namespace: String, tags: [GalleryTag]) -> some View {
        TagWrapLayout(spacing: FeedChrome.panelSpacing, keepsFirstPairTogether: true) {
            Text("\(TagNamespaceDisplay.title(namespace))：")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.primary)
                .tagChipFaceLayout()
                .background(Color.accentColor.opacity(0.12), in: AppShape.control)
                .tagChipTargetLayout()
                .accessibilityAddTraits(.isHeader)
            ForEach(tags) { tag in
                let selected = selectedTagIDs.contains(tag.id)
                Button { toggleTagSelection(tag) } label: { Text(tag.name) }
                    .buttonStyle(TagChipButtonStyle(selected: selected, allowsMultiline: true))
                    .accessibilityLabel(tag.name).accessibilityIdentifier("detail.tag.\(tag.id)")
                    .accessibilityValue(selected ? "已选中" : "未选中")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("加入常用标签") { pinTags([tag]) }
                        Button("屏蔽标签", role: .destructive) { blockTags([tag]) }
                        if library.blockedIDs.contains(tag.id) { Button("解除屏蔽") { library.unblock(tag) } }
                    }
            }
        }
        .padding(.horizontal, FeedChrome.DetailCard.tagGroupInset)
        .padding(.vertical, FeedChrome.DetailCard.tagGroupInset - TagChipMetrics.verticalOverhang)
        .frame(maxWidth: .infinity, alignment: .leading)
        .galleryDetailInsetSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.tags.group.\(namespace)")
    }

    private var detailHeader: some View {
        FloatingHeaderPanel(identifier: "detail.header.floating") {
            FloatingPageTitleRow(title: selectedTags.isEmpty ? "画廊详情" : "已选 \(selectedTags.count) 个",
                                 identifier: "detail.title", balancesActions: selectedTags.isEmpty) {
                if selectedTags.isEmpty {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(FeedHeaderButtonStyle())
                        .accessibilityLabel("返回").accessibilityIdentifier("BackButton")
                } else {
                    Button(action: clearTagSelection) { Image(systemName: "xmark") }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .accessibilityLabel("取消标签选择").accessibilityIdentifier("detail.tags.cancel")
                }
            } trailing: {
                if selectedTags.isEmpty {
                    galleryMoreMenu
                } else {
                    tagActionsMenu
                    tagSearchMenu
                }
            }
            .environment(\.feedHeaderRow, .single)
        }
    }

    private func favoriteTapped() {
        if favoriteObservation.needsManagement {
            favoriteEditing = true
        } else {
            do {
                _ = try session.addToDefaultFavorites([current])
                favoriteObservation.syncFromCache()
            } catch { favoriteFailure = ErrorMessages.message(error) }
        }
    }

    private var detailActions: some View {
        let hasLocalPages = library.readableDownload(for: current) != nil
        let readingTitle = onResumeReading != nil ? "返回阅读" :
            (library.snapshot.history.contains(where: { $0.id == gallery.id }) ? "继续阅读" : hasLocalPages ? "开始阅读" : "在线阅读")
        let state = downloadState
        return HStack(spacing: FeedChrome.panelSpacing) {
            Button {
                if let onResumeReading { onResumeReading() }
                else { presentation?.read(current, activeSearchTarget, openingDetail) }
            } label: { actionLabel(readingTitle, symbol: "book") }
                .buttonStyle(AppActionButtonStyle(tone: .accent))
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityLabel(readingTitle).accessibilityValue(hasLocalPages ? "优先读本机副本" : "")
                .accessibilityIdentifier("detail.read")
                .disabled(onResumeReading == nil && presentation == nil)
            Button(action: favoriteTapped) {
                actionLabel(favoriteActionTitle,
                            symbol: { if case .favorited = favoriteState { return "star.fill" }; return "star" }())
            }
                .buttonStyle(AppActionButtonStyle())
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityIdentifier("detail.site-favorite")
                .accessibilityLabel(favoriteAccessibilityLabel)
                .accessibilityValue(favoriteObservation.phase?.label ?? "")
            Button {
                switch downloadState {
                case .ready: downloads.enqueue(current)
                case .retry(let record): downloads.enqueue(record.gallery)
                case .downloading, .saved: downloadOptions = true
                case .update(let update): pendingOfflineUpdate = update
                }
            } label: { actionLabel(state.title, symbol: state.symbol) }
                .buttonStyle(AppActionButtonStyle())
                .frame(minWidth: 0, maxWidth: .infinity)
                .accessibilityLabel(state.title).accessibilityValue(state.progress)
                .accessibilityIdentifier("detail.download-action")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.actions")
    }

    private var galleryMoreMenu: some View {
        Menu {
            Button { web = .init(title: "画廊原网页", url: current.ref.url) } label: { Label("站点原网页", systemImage: "safari") }
                .accessibilityIdentifier("detail.more.site-page")
            Button { downloadOptions = true } label: { Label("下载", systemImage: "arrow.down") }
                .disabled(!canShowDownloadOptions)
                .accessibilityIdentifier("detail.more.download")
            Button { library.toggleReadLater(current) } label: {
                Label(library.containsReadLater(current) ? "移出稍后再读" : "加入稍后再读", systemImage: "text.badge.plus")
            }.accessibilityIdentifier("detail.local-bookmark")
        } label: { detailMenuLabel }
            .buttonStyle(.plain)
            .accessibilityLabel("更多操作").accessibilityIdentifier("detail.more")
    }

    private var tagActionsMenu: some View {
        Menu {
            Button("加入常用标签") { pinTags(selectedTags) }
                .accessibilityIdentifier("detail.tags.pin")
            Button("屏蔽所选标签", role: .destructive) { blockTags(selectedTags) }
                .accessibilityIdentifier("detail.tags.block")
        } label: { detailMenuLabel }
            .buttonStyle(.plain)
            .accessibilityLabel("所选标签操作").accessibilityIdentifier("detail.tags.more")
    }

    private var tagSearchMenu: some View {
        Menu {
            Button {
                let draft = DetailTagSearchDraft.newSearch(tags: selectedTags, site: current.ref.site)
                presentation?.search(.init(draft: draft, generation: session.generation))
            } label: {
                Label("新建搜索", systemImage: "plus.magnifyingglass")
                Text("仅使用 \(selectedTags.count) 个所选标签")
            }.accessibilityIdentifier("detail.tags.new-search")
            if let target = activeSearchTarget {
                Button {
                    let draft = DetailTagSearchDraft.adding(tags: selectedTags, to: target.search, origin: target.origin)
                    presentation?.search(.init(draft: draft, generation: session.generation, target: target))
                } label: {
                    Label(target.menuTitle, systemImage: "text.badge.plus")
                    Text(target.search.summary)
                }.accessibilityIdentifier("detail.tags.add-to-search")
                    .accessibilityHint(target.search.summary)
            }
        } label: {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.accentColor)
                .feedHeaderControl(typeSize: typeSize)
        }
        .buttonStyle(.plain)
        .disabled(presentation == nil)
        .accessibilityLabel("标签搜索方式").accessibilityIdentifier("detail.tags.search-menu")
    }

    private var detailMenuLabel: some View {
        Image(systemName: "ellipsis").foregroundStyle(.primary)
            .feedHeaderControl(typeSize: typeSize)
    }

    private func toggleTagSelection(_ tag: GalleryTag) {
        if selectedTagIDs.contains(tag.id) { selectedTagIDs.remove(tag.id) }
        else { selectedTagIDs.insert(tag.id) }
        tagFeedback = nil
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func clearTagSelection() { selectedTagIDs.removeAll(); tagFeedback = nil }

    private func pinTags(_ tags: [GalleryTag]) {
        let existing = Set(library.snapshot.favoriteTags.map(\.id))
        let count = tags.filter { !existing.contains($0.id) }.count
        if library.pin(tags) { tagFeedback = count == 0 ? "所选标签已在常用中" : "已加入 \(count) 个常用标签" }
        else { tagFailure = library.error ?? "标签未能保存，请重试。" }
    }

    private func blockTags(_ tags: [GalleryTag]) {
        let additions = tags.filter { !library.blockedIDs.contains($0.id) }
        if library.block(tags) { lastBlockedTags = additions; clearTagSelection() }
        else { tagFailure = library.error ?? "标签未能保存，请重试。" }
    }
    private var favoriteActionTitle: String {
        switch favoriteObservation.phase {
        case .queued: "等待同步"
        case .sending, .checking: "正在同步"
        case .uncertain: "等待确认"
        case .failed, .login, nil: favoriteObservation.phase?.label ?? favoriteTitle
        }
    }

    private var favoriteAccessibilityLabel: String {
        let title = favoriteObservation.phase == nil ? favoriteTitle : "站点收藏"
        if case let .favorited(group) = favoriteState { return "\(title)，\(group)" }
        return title
    }
    private func bindFavoriteState() {
        favoriteObservation.bind(favoriteClient(for: gallery, session: session), reference: gallery.ref,
                                 cache: session.favoriteStateCache, scope: GalleryFavoriteScope(gallery, session))
    }
    private func actionLabel(_ title: String, symbol: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol).fixedSize(horizontal: true, vertical: false)
            Text(title).minimumScaleFactor(0.5)
        }
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .frame(height: actionHeight)
    }
    private func detailLink(title: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.body).foregroundStyle(.secondary).frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(FeedChrome.panelSpacing)
            .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight, alignment: .leading)
            .galleryDetailInsetSurface()
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
    private func load(refresh: Bool = false) async {
        let scope = session.pageReadScope
        let token = UUID()
        loadToken = token
        failure = nil
        do {
            let value: ReaderOpeningDetail
            if AppMode.qa {
                if ProcessInfo.processInfo.arguments.contains("--qa-detail-failure") {
                    throw ViewerError.network
                }
                if ProcessInfo.processInfo.arguments.contains("--qa-detail-delay") {
                    try await Task.sleep(for: .seconds(8))
                }
                value = .init(detail: QASamples.detail(gallery), generation: scope.generation, owner: scope.owner)
                let favoriteScope = GalleryFavoriteScope(gallery, session)
                let favoriteVersion = session.favoriteStateCache.entry(favoriteScope)?.version
                session.favoriteStateCache.put(NativeFavoritesQA.detailState(reference: gallery.ref), scope: favoriteScope,
                                               expectedVersion: favoriteVersion, conditional: true)
            } else {
                value = try await session.galleryDetail(for: gallery.ref, refresh: refresh)
            }
            guard !Task.isCancelled, token == loadToken, scope == session.pageReadScope else { return }
            loadedDetail = value
            loadedScope = scope
        } catch is CancellationError {
        } catch {
            guard token == loadToken, scope == session.pageReadScope else { return }
            failure = ErrorMessages.message(error, fallback: ViewerError.network.localizedDescription)
        }
    }
}

private extension View {
    func galleryDetailInsetSurface() -> some View {
        formRowSurface(shape: AppShape.control)
    }

    func galleryDetailCard(_ identifier: String, containsInsetCards: Bool = false) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .formRowSurface(outer: containsInsetCards)
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}
