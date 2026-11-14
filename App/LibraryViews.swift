import SwiftUI
import ExViewerCore

enum LibrarySelectionPolicy {
    static func filtered(_ galleries: [Gallery], blocked: Set<String>) -> (visible: [Gallery], unknown: Int) {
        var visible: [Gallery] = []; var unknown = 0
        for gallery in galleries {
            switch TagFilter.decision(tags: gallery.tags, blocked: blocked, complete: gallery.tagsComplete) {
            case .visible: visible.append(gallery)
            case .unknown: unknown += 1
            case .blocked: break
            }
        }
        return (visible, unknown)
    }

    static func toggled(_ id: String, in current: Set<String>) -> Set<String> {
        var next = current
        if !next.insert(id).inserted { next.remove(id) }
        return next
    }

    static func selectAllOrClear(_ ids: [String], current: Set<String>) -> Set<String> {
        let target = Set(ids)
        return target.isSubset(of: current) ? current.subtracting(target) : current.union(target)
    }

    static func allSelected(_ ids: [String], current: Set<String>) -> Bool {
        Set(ids).isSubset(of: current)
    }
}

struct TagsView: View {
    var use: (GalleryTag) -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @State private var scope = 0
    private struct SearchDraft: Equatable {
        var query = ""
        var namespace = "all"
    }
    @State private var searchDrafts = [SearchDraft(), SearchDraft()]
    private var addQuery: String {
        get { searchDrafts[scope].query }
        nonmutating set { searchDrafts[scope].query = newValue }
    }
    private var addNamespace: String {
        get { searchDrafts[scope].namespace }
        nonmutating set { searchDrafts[scope].namespace = newValue }
    }
    private func queryBinding(_ index: Int) -> Binding<String> { Binding(get: { searchDrafts[index].query }, set: { searchDrafts[index].query = $0 }) }
    @State private var searchesToResume = Set<Int>()
    @StateObject private var commonSuggestions = TagSuggestionModel()
    @StateObject private var blockedSuggestions = TagSuggestionModel()
    private var suggestions: TagSuggestionModel { scope == 0 ? commonSuggestions : blockedSuggestions }
    @FocusState private var searchFocused: Int?
    @State private var addFailure: String?
    @State private var undone: GalleryTag?
    @State private var selectedSuggestions: [GalleryTag] = []
    @State private var selectedSavedIDs = Set<String>()
    private var tags: [GalleryTag] { scope == 0 ? library.snapshot.favoriteTags : library.snapshot.blockedTags }
    private var hasQuery: Bool { !addQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var scopeBinding: Binding<Int> {
        Binding(get: { scope }, set: { next in
            guard next != scope else { return }
            searchFocused = nil
            clearSelection()
            scope = next
        })
    }

    var body: some View {
        HeaderSectionPages(selection: scope) { paneScope, active in
            tagPane(paneScope, active: active)
        }
        .scrollDismissesKeyboard(.interactively)
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .headerSectionGestureLocked(searchFocused != nil)
        .headerSectionWillChange { clearSelection() }
        .headerSectionPaging(selection: scopeBinding, count: 2, identifier: "tags.scope",
                             identity: session.generation)
        .onChange(of: searchDrafts) { old, new in
            clearSelection(); addFailure = nil
            for index in new.indices where old[index] != new[index] {
                let model = index == 0 ? commonSuggestions : blockedSuggestions
                model.update(prefix: new[index].query, namespace: new[index].namespace, session: session, qa: AppMode.qa)
            }
        }
        .onChange(of: tags.map(\.id)) { _, ids in selectedSavedIDs.formIntersection(ids) }
        .onChange(of: searchFocused) { _, focused in
            if focused != nil { selectedSavedIDs = [] }
        }
        .onChange(of: session.generation) { _, _ in
            clearSelection(); searchesToResume = []; searchDrafts = [SearchDraft(), SearchDraft()]
            commonSuggestions.sessionChanged(); blockedSuggestions.sessionChanged()
            commonSuggestions.update(prefix: "", namespace: "all", session: session, qa: AppMode.qa)
            blockedSuggestions.update(prefix: "", namespace: "all", session: session, qa: AppMode.qa)
        }
        .onAppear {
            for index in searchesToResume {
                let draft = searchDrafts[index]
                let model = index == 0 ? commonSuggestions : blockedSuggestions
                model.update(prefix: draft.query, namespace: draft.namespace, session: session, qa: AppMode.qa)
            }
            searchesToResume = []
        }
        .onDisappear {
            let models = [commonSuggestions, blockedSuggestions]
            searchesToResume = Set(models.indices.filter { models[$0].state == .loading })
            models.forEach { $0.cancel() }
        }
    }

    private func tagPane(_ paneScope: Int, active: Bool) -> some View {
        let savedTags = paneScope == 0 ? library.snapshot.favoriteTags : library.snapshot.blockedTags
        return
        List {
            searchCard(paneScope)
            if !searchDrafts[paneScope].query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TagManagementGroup(title: "搜索结果", symbol: "magnifyingglass", isSearch: true) { addResults(paneScope) }
                    .accessibilityElement(children: .contain).accessibilityIdentifier("tags.results")
                    .accountPageListRow()
            }
            if let undone {
                HStack {
                    Text("已屏蔽 \(undone.name)").font(.caption)
                    Spacer()
                    Button("撤销") { library.unblock(undone); self.undone = nil }
                }.accountPageCard(compactRows: true)
            }
            if !savedTags.isEmpty {
                TagManagementGroup(title: paneScope == 0 ? "已有常用" : "已有屏蔽", symbol: paneScope == 0 ? "bookmark" : "eye.slash") {
                    VStack(spacing: FeedChrome.panelSpacing) {
                        ForEach(savedTags) { tag in
                            TagListRowLabel(tag: tag, symbol: (active && selectedSavedIDs.contains(tag.id)) ? "checkmark.circle.fill" : "circle",
                                            emphasized: (active && selectedSavedIDs.contains(tag.id)), allowsMultiline: true)
                                .formRowLayout()
                                .contentShape(Rectangle())
                                .formRowSurface(shape: AppShape.control)
                                .background((active && selectedSavedIDs.contains(tag.id)) ? Color.accentColor.opacity(0.12) : Color.clear,
                                            in: AppShape.control)
                                .overlay {
                                    if (active && selectedSavedIDs.contains(tag.id)) {
                                        AppShape.control.strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1)
                                    }
                                }
                                .onTapGesture {
                                    selectedSuggestions = []
                                    if !selectedSavedIDs.insert(tag.id).inserted { selectedSavedIDs.remove(tag.id) }
                                }
                                .accessibilityIdentifier("tags.saved.\(tag.id)")
                                .accessibilityValue((active && selectedSavedIDs.contains(tag.id)) ? "已选中" : "未选中")
                                .appContextMenu {
                                    AppMenuItem(title: TagMenuTitle.addToSearch) { use(tag) }
                                    if scope == 0 {
                                        AppMenuItem(title: TagMenuTitle.block, role: .destructive) { library.block(tag); undone = tag }
                                        AppMenuItem(title: TagMenuTitle.unfavorite, role: .destructive) { library.unpin(tag) }
                                    } else {
                                        AppMenuItem(title: TagMenuTitle.unblock) { library.unblock(tag) }
                                        AppMenuItem(title: TagMenuTitle.favorite) { library.pin(tag) }
                                    }
                                }
                            }
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("tags.saved")
                .accountPageListRow()
            }
        }
        .appToast(message: active ? addFailure ?? library.error : nil, identifier: "tags.operation-error")
        .appToast(message: active && (paneScope == 0 ? commonSuggestions : blockedSuggestions).state.isFailure
                    ? (paneScope == 0 ? commonSuggestions : blockedSuggestions).state.message : nil,
                  identifier: "tags.lookup-error")
        .accountSubpageContent()
    }

    private var header: some View {
        FloatingHeaderPanel(identifier: "account.tags-page.header") {
            HStack(spacing: FeedChrome.panelSpacing) {
                Button { dismiss() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(FeedHeaderButtonStyle()).environment(\.pageHeaderAction, true)
                    .accessibilityLabel("返回").accessibilityIdentifier("BackButton")
                FeedScopePicker(selection: scopeBinding, options: [
                    .init(id: 0, title: "常用标签", symbol: "tag"),
                    .init(id: 1, title: "屏蔽标签", symbol: "eye.slash")
                ], identifier: "tags.scope", showsSymbols: false, onSelection: { searchFocused = nil })
                Button(action: applySelection) {
                    Image(systemName: selectedSavedIDs.isEmpty ? "plus" : "minus")
                }
                .buttonStyle(FeedHeaderButtonStyle()).environment(\.pageHeaderAction, true)
                .foregroundStyle(selectedSavedIDs.isEmpty ? Color.accentColor : Color.red)
                .disabled(selectedSuggestions.isEmpty && selectedSavedIDs.isEmpty)
                .accessibilityLabel(selectedSavedIDs.isEmpty ? "添加所选标签" : "移除所选标签")
                .accessibilityIdentifier("tags.add")
            }
            .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight)
            .environment(\.feedHeaderRow, .single)
        }
    }

    private func searchCard(_ paneScope: Int) -> some View {
        let draft = searchDrafts[paneScope]
        let hasQuery = !draft.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return FormGroup {
            HStack(spacing: FeedChrome.panelSpacing) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).padding(.leading, FeedChrome.contentSpacing).accessibilityHidden(true)
                TextField("中文名或标签原名", text: queryBinding(paneScope),
                          prompt: Text("中文名或标签原名").foregroundStyle(Palette.inputPrompt))
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .focused($searchFocused, equals: paneScope).submitLabel(.done).onSubmit { searchFocused = nil }
                    .accessibilityIdentifier("tags.search")
                if hasQuery { namespaceMenu(paneScope) }
                Button { searchDrafts[paneScope].query = "" } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                        .frame(width: FeedChrome.compactFormRowHeight, height: FeedChrome.compactFormRowHeight)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("清空搜索").accessibilityIdentifier("tags.search.clear")
            }
            .font(.footnote).frame(minHeight: FeedChrome.compactFormRowHeight)
        }
        .accountPageListRow()
        .accessibilityElement(children: .contain).accessibilityIdentifier("tags.search-card")
    }

    private func namespaceMenu(_ paneScope: Int) -> some View {
        AppMenu(onOpen: { searchFocused = nil }) {
            ForEach(["all"] + TagNamespaceDisplay.namespaces, id: \.self) { namespace in
                AppMenuItem(title: namespace == "all" ? "全部分类" : TagNamespaceDisplay.title(namespace),
                            isSelected: searchDrafts[paneScope].namespace == namespace) { searchDrafts[paneScope].namespace = namespace }
                    .accessibilityIdentifier(namespace == "all" ? "tags.add.namespace.all" : "tags.add.namespace.\(namespace)")
            }
        } label: { namespaceLabel(searchDrafts[paneScope].namespace) }
        .buttonStyle(.plain)
        .accessibilityLabel("标签分类").accessibilityValue(searchDrafts[paneScope].namespace)
        .accessibilityIdentifier("tags.add.namespace")
    }

    private func namespaceLabel(_ namespace: String) -> some View {
        AppMenuValueLabel(title: namespace == "all" ? "全部分类" : TagNamespaceDisplay.title(namespace))
    }

    private func addResults(_ paneScope: Int) -> some View {
        resultRows(query: searchDrafts[paneScope].query, namespace: searchDrafts[paneScope].namespace,
                   model: paneScope == 0 ? commonSuggestions : blockedSuggestions) { tag, identifier in
            addButton(tag, paneScope: paneScope, identifier: identifier)
        }
    }

    @ViewBuilder private func resultRows<Row: View>(query: String, namespace: String, model: TagSuggestionModel,
                                                    @ViewBuilder row: @escaping (GalleryTag, String) -> Row) -> some View {
        if model.state == .loading {
            ProgressView().controlSize(.mini).frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
                .formRowSurface(shape: AppShape.control)
        }
        ForEach(model.items) { item in
            row(item.tag, "tag.suggestion.\(item.id)")
        }
        if namespace == "all", model.items.isEmpty, model.state == .ready {
            Text("无匹配标签").foregroundStyle(.secondary)
                .formRowLayout().formRowSurface(shape: AppShape.control)
                .accessibilityIdentifier("tags.results.empty")
        }
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.items.contains(where: {
            TagSuggestionRequest.matchRank(original: $0.tag.name, chinese: $0.chineseName,
                                           normalizedPrefix: TagSuggestionRequest.normalized(name)) == 0
        }) {
            if namespace != "all" {
                if TagInputValidation.error(name, namespace: namespace) == nil {
                    row(.init(namespace: namespace, name: name), "tag.stage")
                        .accessibilityHint("原名输入，尚未经站点核验")
                }
            }
        }
    }

    private func addButton(_ tag: GalleryTag, paneScope: Int, identifier: String) -> some View {
        let exists = (paneScope == 0 ? library.snapshot.favoriteTags : library.snapshot.blockedTags).contains { $0.id == tag.id }
        return Button {
            selectedSavedIDs = []
            if let index = selectedSuggestions.firstIndex(where: { $0.id == tag.id }) {
                selectedSuggestions.remove(at: index)
            } else { selectedSuggestions.append(tag) }
        } label: {
            TagListRowLabel(tag: tag,
                            symbol: exists || (paneScope == scope && selectedSuggestions.contains(where: { $0.id == tag.id })) ? "checkmark.circle.fill" : "circle",
                            emphasized: exists || (paneScope == scope && selectedSuggestions.contains(where: { $0.id == tag.id })))
                .formRowLayout()
                .formRowSurface(shape: AppShape.control)
        }
        .buttonStyle(.plain).disabled(exists || !TagSuggestionRequest.isSelectable(tag))
        .accessibilityIdentifier(identifier)
        .accessibilityValue(exists ? "已添加" : (paneScope == scope && selectedSuggestions.contains(where: { $0.id == tag.id })) ? "已选中" : "未选中")
    }

    private func clearSelection() {
        selectedSuggestions = []
        selectedSavedIDs = []
    }

    private func applySelection() {
        let saved: Bool
        if !selectedSavedIDs.isEmpty {
            let removing = tags.filter { selectedSavedIDs.contains($0.id) }
            saved = scope == 0 ? library.unpin(removing) : library.unblock(removing)
        } else {
            guard !selectedSuggestions.isEmpty else { return }
            saved = scope == 0 ? library.pin(selectedSuggestions) : library.block(selectedSuggestions)
        }
        if saved { clearSelection(); addFailure = nil }
        else { addFailure = library.error ?? "标签保存失败 请重试" }
    }


}

/// Short, useful section identity shares the same row and inset rules as its contents.
private struct TagManagementGroup<Content: View>: View {
    let title: String
    let symbol: String
    var isSearch = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        FormGroup {
            HStack(spacing: FeedChrome.iconLabelSpacing) {
                Image(systemName: symbol).accessibilityHidden(true)
                Text(title).fontWeight(.medium)
            }
            .foregroundStyle(isSearch ? Color.accentColor : Color.secondary)
            .formRowLayout()
            content()
        }
    }
}

private enum DownloadFilter: String, CaseIterable {
    case all, active, needsAttention, complete

    var title: String {
        switch self {
        case .all: "全部下载"
        case .active: "进行中"
        case .needsAttention: "暂停或失败"
        case .complete: "已下载"
        }
    }

    func includes(_ status: DownloadRecord.Status) -> Bool {
        switch self {
        case .all: true
        case .active: status == .waiting || status == .downloading
        case .needsAttention: status == .paused || status == .failed
        case .complete: status == .complete
        }
    }
}

private enum ReadLaterFilter: String, CaseIterable {
    case all, unread, started

    var title: String {
        switch self {
        case .all: "全部作品"
        case .unread: "尚未阅读"
        case .started: "有阅读记录"
        }
    }
}

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.galleryDetailPresentation) private var presentation
    @Environment(\.edgeTouchGate) private var edgeTouches
    @Binding var site: GallerySite
    var isActive = true
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var scope = 0
    @State private var downloadFilter: DownloadFilter = .all
    @State private var readLaterFilter: ReadLaterFilter = .all
    @State private var sortOrders: [LibrarySortSection: LibrarySortOrder] = [:]
    @StateObject private var localSelection = LibrarySelectionStore()
    @State private var selectingLocal = false
    @State private var confirmingLocalRemoval = false
    @State private var removingDownloads = false
    private var matchingReadLater: [Gallery] {
        let saved = library.snapshot.readLater
        guard readLaterFilter != .all else { return saved }
        let started = Set(library.snapshot.history.map(\.id))
        return saved.filter { started.contains($0.id) == (readLaterFilter == .started) }
    }
    private var readLaterVisible: [Gallery] {
        LibrarySelectionPolicy.filtered(matchingReadLater, blocked: library.blockedIDs).visible
    }
    private var sortPreferences: LibrarySortPreferences {
        .init(owner: library.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var visibleDownloads: [DownloadRecord] {
        library.snapshot.downloads.filter { downloadFilter.includes($0.status) }
    }
    private var localIDs: Set<String> {
        scope == 3 ? Set(visibleDownloads.map(\.id)) : Set(readLaterVisible.map(\.id))
    }
    private var localSource: LibraryBatchSource { scope == 3 ? .downloads : .readLater }

    var body: some View {
        HeaderSectionPages(selection: scope, topInset: FeedChrome.headerClearance(twoRows: true)) { paneScope, active in
            if paneScope == 1 { CloudFavoritesView(site: $site, scope: $scope, isActive: isActive && active) }
            else if paneScope == 2 { ReadingHistoryView(placement: .library($scope)) }
            else { localLibrary(paneScope) }
        }
        .headerSectionLocked(removingDownloads || confirmingLocalRemoval)
        .exitMultiSelectionOnRightSwipe(selectingLocal, action: endLocalSelection)
        .headerSectionWillChange { endLocalSelection() }
        .headerSectionPaging(selection: $scope, count: 4, identifier: "library.scope", enabled: isActive,
                             identity: site.rawValue)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { sortOrders = sortPreferences.load() }
        .onChange(of: library.owner) { _, _ in sortOrders = sortPreferences.load() }
        .onChange(of: scope) { _, _ in endLocalSelection() }
        .onChange(of: library.owner) { _, _ in
            downloadFilter = .all
            readLaterFilter = .all
            endLocalSelection()
        }
        .onChange(of: isActive) { _, active in if !active { endLocalSelection() } }
        .onChange(of: localIDs) { _, ids in localSelection.updateLoadedIDs(ids) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selectingLocal && isActive {
                LibraryBatchToolbar(source: localSource, summary: localSelection.summary, busy: removingDownloads,
                                    galleries: { readLaterVisible.filter { localSelection.selectedIDs.contains($0.id) } },
                                    onRemove: { confirmingLocalRemoval = true })
            }
        }
        .confirmationDialog(scope == 3 ? "移除所选离线副本？" : "从稍后再读移除所选作品？",
                            isPresented: $confirmingLocalRemoval, titleVisibility: .visible) {
            Button(scope == 3 ? "移除本机副本" : "移出所选作品", role: .destructive) {
                let ids = localSelection.selectedIDs
                if scope == 3 {
                    removingDownloads = true
                    Task {
                        let removed = await downloads.remove(ids)
                        removingDownloads = false
                        if removed, scope == 3 { endLocalSelection() }
                    }
                } else if library.removeReadLater(ids) {
                    endLocalSelection()
                }
            }
        } message: {
            Text(scope == 3 ? "将删除所选的本机下载文件" : "保留站点收藏 下载文件和阅读进度")
        }
    }

    private func localLibrary(_ paneScope: Int) -> some View {
        FloatingFeedLayout(twoRows: true) { headerHeight in
            GeometryReader { geometry in
                let viewport = GalleryFeedViewport(space: "local-library-feed", height: geometry.size.height,
                                                   topOcclusion: headerHeight)
                ScrollViewReader { proxy in
                 ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if library.error != nil {
                            Button("重试加载") { library.load(owner: library.owner) }
                                .buttonStyle(AppActionButtonStyle(tone: .accent))
                                .appToast(message: library.error, identifier: "library.load-error")
                        }
                        if paneScope == 3 { downloadsSection }
                        else { bookmarksSection(viewport: viewport) }
                    }
                    .padding(.top, headerHeight).padding(.bottom, FeedChrome.sectionSpacing)
                    .id("library.local.section-top")
                 }
                 .onHeaderReselection {
                     guard !selectingLocal else { return }
                     withAnimation(reduceMotion ? nil : ChromeMotion.control) { proxy.scrollTo("library.local.section-top", anchor: .top) }
                 }
                }
                .coordinateSpace(name: viewport.space)
                .contentMargins(.top, headerHeight, for: .scrollIndicators)
                .overlay {
                    if library.error == nil && (paneScope == 3 ? visibleDownloads.isEmpty : matchingReadLater.isEmpty) {
                        GalleryEmptyState()
                            .accessibilityIdentifier(paneScope == 3 ? "downloads.empty" : "read-later.empty")
                            .padding(.top, headerHeight)
                    }
                }
                .accessibilityIdentifier("library.local")
            }
        } header: {
            LibraryFloatingHeader(selection: $scope, identifier: "library.header.floating", isSelecting: selectingLocal) {
                if selectingLocal {
                    LibraryBatchSelectionHeader(source: paneScope == 3 ? .downloads : .readLater, store: localSelection, summary: localSelection.summary,
                                                busy: removingDownloads, onExit: endLocalSelection)
                } else {
                    if typeSize.isAccessibilitySize {
                        AccessibilityHeaderActions { localLeading(paneScope) } trailing: {
                            HStack(spacing: FeedChrome.panelSpacing) { localSort(paneScope); localAction(paneScope) }
                        }
                    } else {
                        FeedHeaderGrid(spans: [1, 1, 1]) {
                            localLeading(paneScope)
                            localSort(paneScope)
                            localAction(paneScope)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func localLeading(_ paneScope: Int) -> some View {
        if paneScope == 3 {
            LibraryFilterMenu(selection: $downloadFilter, options: DownloadFilter.allCases, title: \.title,
                              label: "下载状态筛选", identifier: "downloads.filter", symbol: "line.3.horizontal.decrease")
        } else {
            LibraryFilterMenu(selection: $readLaterFilter, options: ReadLaterFilter.allCases, title: \.title,
                              label: "阅读状态筛选", identifier: "read-later.filter", symbol: "line.3.horizontal.decrease")
        }
    }

    private func localSort(_ paneScope: Int) -> some View {
        sortMenu(paneScope == 3 ? .downloads : .bookmarks)
    }

    private func localAction(_ paneScope: Int) -> some View {
        LibraryBatchEntryButton(identifier: paneScope == 3 ? "downloads.select" : "read-later.select") {
            localSelection.clear()
            localSelection.updateLoadedIDs(localIDs)
            selectingLocal = true
        }
        .disabled(localIDs.isEmpty || removingDownloads)
    }

    private var downloadsSection: some View {
        LazyVStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
            if !visibleDownloads.isEmpty {
                let records = LibrarySorting.downloads(visibleDownloads, order: sortOrders[.downloads] ?? .original,
                                                       history: library.snapshot.history)
                LibraryCardRows(items: records, cover: { record in
                    record.coverSource(in: library)
                }) { record in
                    downloadRow(record)
                        .accessibilityIdentifier("library.download.item.\(record.gallery.ref.gid)")
                }
            }
        }.padding(.horizontal, FeedChrome.contentInset)
            .padding(.top, FeedChrome.contentTopGap)
            .accessibilityElement(children: .contain).accessibilityIdentifier("library.downloads")
    }

    @ViewBuilder private func downloadRow(_ record: DownloadRecord) -> some View {
        if selectingLocal {
            SelectableDownloadRow(record: record, store: localSelection, entry: localSelection.entry(for: record.id))
        } else {
            Group {
                if record.status == .complete {
                    Button {
                        guard edgeTouches?.blocksGalleryActions != true else { return }
                        presentation?.readOffline(record.gallery)
                    } label: {
                        DownloadRowLabel(record: record)
                    }
                } else {
                    Button {
                        guard edgeTouches?.blocksGalleryActions != true else { return }
                        if record.canPause { downloads.pause(record.id) }
                        else { downloads.enqueue(record.gallery) }
                    } label: { DownloadRowLabel(record: record) }
                }
            }
            .buttonStyle(.plain)
            .highPriorityGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in
                guard edgeTouches?.blocksGalleryActions != true else { return }
                beginLocalSelection(record.id)
            })
            .accessibilityValue(record.accessibleDownloadStatus)
            .accessibilityHint(record.status == .complete ? "轻点打开离线阅读，长按选择" :
                                record.requiresRetry ? [record.error, "轻点重试，长按选择"].compactMap { $0 }.joined(separator: "。") :
                                record.canPause ? "轻点暂停，长按选择" : "轻点继续，长按选择")
            .accessibilityAction(named: Text("选择并管理")) { beginLocalSelection(record.id) }
            .disabled(removingDownloads)
            .allowsHitTesting(edgeTouches?.blocksGalleryActions != true)
        }
    }

    private func bookmarksSection(viewport: GalleryFeedViewport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !matchingReadLater.isEmpty {
                GalleryRows(galleries: LibrarySorting.galleries(matchingReadLater, order: sortOrders[.bookmarks] ?? .original, history: library.snapshot.history),
                            sourceIdentity: library.owner + ":read-later",
                            selectionStore: localSelection, isSelecting: selectingLocal, openIdentifier: "favorites.gallery",
                            onLongPressSelect: { beginLocalSelection($0.id) }, viewport: viewport)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("library.bookmarks")
    }

    private func beginLocalSelection(_ id: String) {
        localSelection.updateLoadedIDs(localIDs)
        selectingLocal = localSelection.beginSelecting(id)
    }

    private func endLocalSelection() {
        selectingLocal = false
        confirmingLocalRemoval = false
        localSelection.clear()
    }

    private func sortMenu(_ section: LibrarySortSection) -> some View {
        AppMenu {
            ForEach(section.options) { option in
                AppMenuItem(title: option.title, isSelected: option == (sortOrders[section] ?? section.defaultOrder)) {
                    sortPreferences.set(option, for: section)
                    sortOrders[section] = option
                }.accessibilityIdentifier("library.sort.\(section.rawValue).\(option.rawValue)")
            }
        } label: {
            LibrarySortControlLabel(title: (sortOrders[section] ?? section.defaultOrder).title)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("\(section.title)排序")
        .accessibilityValue((sortOrders[section] ?? section.defaultOrder).title)
        .accessibilityIdentifier("library.sort.\(section.rawValue)")
    }

}

private extension DownloadRecord {
    var canPause: Bool { status == .waiting || status == .downloading }
    var accessibleDownloadStatus: String {
        guard status != .complete else { return downloadStatus }
        if let pageCount, pageCount > 0 {
            return "\(downloadStatus) 已保存 \(completed.count)/\(pageCount) 页"
        }
        return completed.isEmpty ? downloadStatus : "\(downloadStatus) 已保存 \(completed.count) 页"
    }

    @MainActor func coverSource(in library: LibraryStore) -> LibraryCardCover? {
        guard TagFilter.decision(tags: gallery.tags, blocked: library.blockedIDs,
                                 complete: gallery.tagsComplete) == .visible else { return nil }
        return LibraryCardCover(gallery: gallery, localFile: library.downloadedPage(1, in: self)?.url)
    }

    var pageCount: Int? { total ?? gallery.pages }

    var downloadStatus: String {
        if requiresRetry { return "下载失败" }
        return switch status {
        case .waiting: "等待中"
        case .downloading: "下载中"
        case .paused: "已暂停"
        case .complete: "已下载"
        case .failed: "下载失败"
        }
    }
}

private struct DownloadRowLabel: View {
    let record: DownloadRecord
    var selected: Bool? = nil
    @EnvironmentObject private var library: LibraryStore

    private var symbol: String {
        if record.status == .complete { return "chevron.right" }
        if record.requiresRetry { return "arrow.clockwise" }
        return record.canPause ? "pause.fill" : "play.fill"
    }

    private var progress: CGFloat {
        if record.status == .complete { return 1 }
        guard let pageCount = record.pageCount, pageCount > 0 else { return 0 }
        return min(1, CGFloat(record.completed.count) / CGFloat(pageCount))
    }

    var body: some View {
        LibraryGalleryCard(gallery: record.gallery, pageCount: record.pageCount,
                           context: "画廊 #\(record.gallery.ref.gid)", selected: selected,
                           actionSymbol: symbol, progress: progress) {
            cover
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var coverPlaceholder: some View {
        Image(systemName: "book.closed")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
    }

    private var cover: some View {
        Group {
            if let source = record.coverSource(in: library) {
                if let file = source.localFile {
                    ZStack {
                        coverPlaceholder
                        StaticCover(file: file, contextIdentity: library.owner, requestIdentity: record.id,
                                    contentMode: .fill, fitsExtremeAspects: true)
                    }
                } else {
                    CoverView(gallery: source.gallery, contentMode: .fill, showsLoadingIndicator: false,
                              showsRetryButton: false, fitsExtremeAspects: true)
                }
            } else {
                coverPlaceholder
            }
        }
    }
}

private struct SelectableDownloadRow: View {
    let record: DownloadRecord
    let store: LibrarySelectionStore
    @ObservedObject var entry: LibrarySelectionEntry

    var body: some View {
        Button { store.toggle(record.id) } label: { DownloadRowLabel(record: record, selected: entry.isSelected) }
            .buttonStyle(.plain)
            .accessibilityValue(entry.isSelected ? "已选中" : "未选中")
            .accessibilityAddTraits(entry.isSelected ? .isSelected : [])
    }
}

struct CloudFavoritesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var site: GallerySite
    @Binding var scope: Int
    var isActive = true
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var pager = GalleryPager()
    @StateObject private var pullRefresh = FeedPullRefresh()
    @StateObject private var selectionStore = LibrarySelectionStore()
    @StateObject private var submission = FavoriteBatchSubmission()
    @State private var web: WebDestination?
    @State private var category = "all"
    @State private var selecting = false
    @State private var initialLayoutReady = false
    @State private var seenRemovals: [String: UUID] = [:]
    @State private var visibleGalleryID: String?
    @State private var anchorAfterRemoval: String?
    @State private var confirmingRemoval = false
    @State private var moveSelection: MoveSelection?
    @State private var qaFavoriteAttemptCount = 0
    private struct MoveSelection: Hashable {
        let references: [GalleryRef]
        let category: String
        let owner: String
        let generation: UUID
    }
    private struct RequestedSource: Equatable {
        let url: URL
        let generation: UUID
        let owner: String
        let favoritesRevision: UUID
    }
    @State private var requestedSource: RequestedSource?
    private var displayedItems: [Gallery] {
        AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-library-large-selection")
            ? LibrarySelectionQA.galleries : pager.items
    }
    @State private var preparedVisible: [Gallery]?
    private var visible: [Gallery] { preparedVisible ?? filteredItems() }
    private var selectedGalleries: [Gallery] { visible.filter { selectionStore.selectedIDs.contains($0.id) } }
    private var sortPreferences: LibrarySortPreferences {
        .init(owner: session.owner, defaults: AppMode.qa ? UserDefaults(suiteName: LibrarySortPreferences.qaSuite)! : .standard)
    }
    private var sortOrder: SiteFavoriteOrder { sortPreferences.favoriteOrder(for: site) }
    private var working: Bool { submission.workingCount != nil }
    var body: some View {
        FloatingFeedLayout(twoRows: true) { headerHeight in
        VStack(spacing: 0) {
            if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-library-large-selection") {
                Text("QA").font(.system(size: 1)).foregroundStyle(.clear).frame(width: 1, height: 1)
                    .accessibilityIdentifier("library.qa.workload")
                    .accessibilityValue("galleries=\(displayedItems.count);blocked=\(library.snapshot.blockedTags.count)")
                    .allowsHitTesting(false)
            }
            if (!session.hasCredentials && !AppMode.qa) || (AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-login-required")) {
                ContentUnavailableView {
                    Label("登录后读取站点收藏", systemImage: "heart")
                } description: {
                    Text("请登录站点账号查看收藏")
                } actions: {
                    Button("打开官方登录页") { web = .login }.buttonStyle(AppActionButtonStyle(tone: .accent))
                }
                .padding(.top, headerHeight)
            } else {
                favoritesFeed(headerHeight: headerHeight)
            }
          }
        } header: {
            favoritesFloatingHeader
        }
        .headerSectionLocked(working || confirmingRemoval || moveSelection != nil)
        .exitMultiSelectionOnRightSwipe(selecting && !working, action: endSelection)
        .headerSectionWillChange { endSelection() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting && isActive {
                LibraryBatchToolbar(source: .favorites, summary: selectionStore.summary, busy: working,
                                    galleries: { selectedGalleries }, onMove: beginMove,
                                    onRemove: { confirmingRemoval = true })
                    .overlay(alignment: .top) {
                        if let count = submission.workingCount {
                            ProgressView("正在处理 \(count) 项…")
                                .font(FeedChrome.labelFont)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(FloatingChrome.background, in: AppShape.control)
                                .alignmentGuide(.top) { $0[.bottom] + 6 }
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        .navigationDestination(item: $moveSelection) { move in
            FavoriteGroupPicker(count: move.references.count, moving: true, load: {
                (0...9).map { FavoriteGroupChoice(id: $0, name: categoryName($0)) }
            }) { group in
                try confirmMove(move, to: group.id)
            }
        }
        .appConfirmationDialog("取消收藏", message: "取消所选 \(selectionStore.selectedIDs.count) 部作品的收藏",
                               isPresented: $confirmingRemoval, identifier: "favorites.remove") {
            perform(.remove, references: selectedGalleries.map(\.ref))
        }
        .officialWebPage(item: $web)
        .task {
            prepareVisible()
            if isActive && !selecting { reload(force: false) }
            else if let url = sortOrder.url(site: site, category: category) {
                await pager.prepareCached(url: url, session: session, qa: AppMode.qa)
            }
        }
        .onChange(of: pager.items) { _, _ in prepareVisible() }
        .onChange(of: pager.loading) { _, loading in
            if !loading { submission.finishListRefresh(succeeded: pager.failure == nil && !pager.interrupted) }
        }
        .onChange(of: library.blockedIDs) { _, _ in selectionStore.clear(); selecting = false; prepareVisible() }
        .onChange(of: category) { _, _ in selectionStore.clear(); selecting = false; reload(force: false) }
        .onChange(of: site) { _, _ in submission.cancel(); submission.dismissNotice(); selectionStore.clear(); selecting = false; category = "all"; reload(force: false) }
        .onChange(of: session.hasCredentials) { _, _ in reload(force: false) }
        .onChange(of: session.favoritesRevision) { _, _ in reload(force: false) }
        .onReceive(session.favoriteStateCache.$confirmedRemovals, perform: applyConfirmedRemovals)
        .onChange(of: session.generation) { _, _ in accountChanged() }
        .onChange(of: session.owner) { _, _ in accountChanged() }
        .onChange(of: isActive) { _, active in
            if active { reload(force: false) }
            else { initialLayoutReady = false; submission.cancel(); pager.cancel(); selectionStore.clear(); selecting = false }
        }
        .onDisappear {
            guard moveSelection == nil else { return }
            initialLayoutReady = false; submission.cancel(); pager.cancel(); selectionStore.clear(); selecting = false
        }
    }

    private func favoritesFeed(headerHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            let viewport = GalleryFeedViewport(space: "favorites-feed", height: geometry.size.height, topOcclusion: headerHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        GalleryRows(galleries: displayedItems,
                                    sourceIdentity: "\(site.rawValue):\(category):\(sortOrder.rawValue)",
                                    selectionStore: selectionStore, isSelecting: selecting, isLoading: pager.loading, loadFailure: pager.failure,
                                    openIdentifier: "favorites.gallery",
                                    onLongPressSelect: beginSelection(at:),
                                    onNearEnd: {
                                        if isActive && initialLayoutReady && !selecting && anchorAfterRemoval == nil && pager.failure == nil {
                                            pager.more(session: session, prefetch: true)
                                        }
                                    }, viewport: viewport, onVisibleAnchor: {
                                        if anchorAfterRemoval == nil { visibleGalleryID = $0 }
                                    })
                        if !selecting && !pager.items.isEmpty { GalleryContinuationFooter(pager: pager) }
                    }
                    .padding(.top, headerHeight)
                    .padding(.bottom, FeedChrome.sectionSpacing)
                    .id("favorites.section-top")
                    .feedRefreshProbe(pullRefresh, enabled: !working && isActive)
                }
                .overlay {
                    if !selecting { GalleryFeedStatus(pager: pager).padding(.top, headerHeight) }
                }
                .coordinateSpace(name: viewport.space)
                .feedPullRefresh(pullRefresh, topInset: headerHeight, enabled: !working && isActive) {
                    if !working {
                        selectionStore.clear()
                        selecting = false
                        reload()
                        await pager.waitForLoad()
                    }
                }
                .onHeaderReselection {
                    guard isActive, !working, !selecting else { return }
                    withAnimation(reduceMotion ? nil : ChromeMotion.control) { proxy.scrollTo("favorites.section-top", anchor: .top) }
                    await pullRefresh.refresh(enabled: isActive) {
                        reload()
                        await pager.waitForLoad()
                    }
                }
                .contentMargins(.top, headerHeight, for: .scrollIndicators)
                .task(id: isActive ? headerHeight : -1) {
                    initialLayoutReady = false
                    guard isActive, headerHeight > 0 else { return }
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled, isActive else { return }
                    initialLayoutReady = true
                }
                .task(id: anchorAfterRemoval) {
                    guard let anchor = anchorAfterRemoval else { return }
                    await Task.yield()
                    guard !Task.isCancelled, anchorAfterRemoval == anchor else { return }
                    proxy.scrollTo(GalleryFeedViewport.restorationID(for: anchor), anchor: viewport.restorationAlignment)
                    visibleGalleryID = anchor
                    anchorAfterRemoval = nil
                }
            }
        }
    }

    private func applyConfirmedRemovals(_ revisions: [String: UUID]) {
        guard let requestedSource, requestedSource.owner == session.owner,
              requestedSource.generation == session.generation, requestedSource.url.host == site.host,
              revisions != seenRemovals else { return }
        let ids = Set(revisions.filter { id, revision in
            id.hasPrefix("\(site.rawValue):") && seenRemovals[id] != revision
        }.keys)
        seenRemovals = revisions
        guard !ids.isEmpty else { return }
        let rows = filteredItems()
        if let anchor = anchorAfterRemoval ?? visibleGalleryID,
           let index = rows.firstIndex(where: { $0.id == anchor }),
           rows[...index].contains(where: { ids.contains($0.id) }) {
            anchorAfterRemoval = rows[index...].first { !ids.contains($0.id) }?.id
                ?? rows[..<index].last { !ids.contains($0.id) }?.id
        }
        pager.removeConfirmedFavorites(ids)
    }

    private var favoritesFloatingHeader: some View {
        LibraryFloatingHeader(selection: $scope, scopeEnabled: !working, identifier: "favorites.header.floating", isSelecting: selecting) {
            VStack(spacing: 0) {
                if session.hasCredentials || AppMode.qa {
                    if selecting {
                        LibraryBatchSelectionHeader(source: .favorites, store: selectionStore, summary: selectionStore.summary,
                                                    busy: working) {
                            selecting = false
                            selectionStore.clear()
                            if pager.interrupted { pager.retry(session: session) }
                        }
                    } else {
                        if typeSize.isAccessibilitySize {
                            AccessibilityHeaderActions { groupMenu } trailing: {
                                HStack(spacing: FeedChrome.panelSpacing) { favoriteSortMenu; favoriteSelectButton }
                            }
                        } else {
                            FeedHeaderGrid(spans: [1, 1, 1]) {
                                groupMenu
                                favoriteSortMenu
                                favoriteSelectButton
                            }
                        }
                    }
                }
                if FeedCacheQA.isEnabled { FeedCacheQAStatus(pager: pager, lane: "favorites") }
                if library.error != nil {
                    Button("重试加载") { library.load(owner: library.owner) }
                        .buttonStyle(AppActionButtonStyle(tone: .accent))
                        .appToast(message: library.error, identifier: "favorites.library-error")
                }
                if let notice = submissionNotice {
                    Group {
                        if notice.needsVerification {
                            Button("刷新核实") { submission.dismissNotice(); reload() }
                                .buttonStyle(AppActionButtonStyle(tone: .accent))
                                .accessibilityIdentifier("favorites.verify-refresh")
                        } else { Color.clear.frame(height: 0) }
                    }
                    .appToast(message: notice.text, identifier: "favorites.operation-feedback")
                }
                if AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-unknown-response") {
                    Text("QA 模拟提交次数：\(qaFavoriteAttemptCount)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("favorites.qa-attempt-count")
                }
            }
        }
    }

    private var submissionNotice: (text: String, needsVerification: Bool)? {
        switch submission.state {
        case .idle, .submitting:
            return nil
        case .refreshingList, .listRefreshed:
            return nil
        case .listRefreshFailed:
            return ("操作已发送 请刷新列表", false)
        case .preview:
            return ("测试模式 未修改站点收藏", false)
        case .interrupted(let submitted, let count, let reason):
            let progress = submitted > 0 ? "已发送 \(submitted) 项 " : ""
            switch reason {
            case .needsVerification:
                return (progress + "本批 \(count) 项结果待确认 后续已暂停", true)
            case .notSent:
                return (progress + "本批 \(count) 项尚未发送 后续已暂停", false)
            }
        }
    }
    private var groupMenu: some View {
        AppMenu {
            AppMenuItem(title: "全部分组", isSelected: category == "all") { category = "all" }
            ForEach(0...9, id: \.self) { index in
                AppMenuItem(title: categoryName(index), isSelected: category == String(index)) {
                    category = String(index)
                }
            }
        } label: {
            LibraryMenuLabel(title: selectedGroupName, symbol: "folder")
                .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize)).foregroundStyle(.primary)
        .accessibilityLabel("收藏分组").accessibilityValue(selectedGroupName)
        .accessibilityHint("选择要查看的站点收藏分组")
        .accessibilityIdentifier("favorites.group-filter")
        .disabled(working)
    }
    private var favoriteSelectButton: some View {
        LibraryBatchEntryButton(identifier: "favorites.select", action: beginSelection)
            .disabled(working || visible.isEmpty)
    }

    private var favoriteSortMenu: some View {
        AppMenu {
            ForEach(SiteFavoriteOrder.allCases) { order in
                AppMenuItem(title: order.title, isSelected: order == sortOrder) {
                    sortPreferences.set(order, for: site)
                    reload(force: false)
                }
                .accessibilityIdentifier("favorites.sort.\(order.rawValue)")
            }
        } label: {
            LibrarySortControlLabel(title: sortOrder == .siteDefault ? "排序" : sortOrder.title)
        }
        .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true, expandsHorizontally: !typeSize.isAccessibilitySize))
        .accessibilityLabel("站点收藏排序").accessibilityValue(sortOrder.title)
        .accessibilityIdentifier("favorites.sort")
        .disabled(working)
    }
    private func filteredItems() -> [Gallery] {
        LibrarySelectionPolicy.filtered(displayedItems, blocked: library.blockedIDs).visible
    }
    private func prepareVisible() {
        let items = filteredItems()
        preparedVisible = items
        selectionStore.updateLoadedIDs(Set(items.map(\.id)))
    }
    private var selectedGroupName: String {
        category == "all" ? "全部分组" : categoryName(Int(category) ?? 0)
    }
    private func categoryName(_ index: Int) -> String { pager.categories[String(index)] ?? "分组 \(index + 1)" }
    private func beginSelection() {
        guard !working, !selecting, !visible.isEmpty else { return }
        selectionStore.clear()
        selectionStore.updateLoadedIDs(Set(visible.map(\.id)))
        pager.pauseForSelection()
        selecting = true
    }
    private func beginSelection(at gallery: Gallery) {
        guard !working, !selecting else { return }
        SelectionPerformanceProbe.markAction(id: gallery.id)
        guard selectionStore.beginSelecting(gallery.id) else { return }
        pager.pauseForSelection()
        SelectionPerformanceProbe.markStateSet(id: gallery.id, count: selectionStore.selectedIDs.count)
        selecting = true
    }
    private func endSelection() {
        guard selecting, !working else { return }
        selecting = false; selectionStore.clear()
        if pager.interrupted { pager.retry(session: session) }
    }
    private func accountChanged() {
        submission.cancel(); submission.dismissNotice(); selectionStore.clear(); selecting = false
        reload(force: false)
    }
    private func beginMove() {
        let references = selectedGalleries.map(\.ref)
        guard !working, !references.isEmpty else { return }
        moveSelection = MoveSelection(references: references, category: category, owner: session.owner, generation: session.generation)
    }
    private func confirmMove(_ move: MoveSelection, to group: Int) throws {
        guard !working, isActive, selecting, move.owner == session.owner, move.generation == session.generation,
              move.category == category, move.references.allSatisfy({ $0.site == site }),
              Set(move.references) == Set(selectedGalleries.map(\.ref)) else {
            throw ViewerError.invalidQuery("所选收藏已变化 请重新选择")
        }
        perform(.move(group), references: move.references)
    }
    private func perform(_ action: FavoriteAction, references: [GalleryRef]) {
        guard !references.isEmpty, !working else { return }
        let simulateUnknown = AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-favorites-unknown-response")
        if AppMode.qa && !simulateUnknown {
            selectionStore.clear()
            selecting = false
            submission.showPreview()
            return
        }
        let generation = session.generation, owner = session.owner, sourceSite = site
        let isCurrent = { generation == session.generation && owner == session.owner && sourceSite == site }
        submission.start(references, isCurrent: isCurrent, invalidateCache: {
            await pager.invalidateFavoriteCache(owner: owner)
        }, submit: { batch in
            if simulateUnknown {
                try await Task.sleep(nanoseconds: 150_000_000)
                guard isCurrent() else { throw ViewerError.stale }
                qaFavoriteAttemptCount += 1
                throw FavoriteMutationFailure(requestMayHaveBeenSent: true,
                                              underlying: NSError(domain: "ExViewer.QA", code: 1,
                                                                  userInfo: [NSLocalizedDescriptionKey: "QA 模拟：服务器响应丢失，结果未知。"]))
            }
            try await session.changeFavorites(batch, site: sourceSite, action: action)
        }, onSubmitted: { batch in
            selectionStore.remove(batch.map(\.id))
        }, onComplete: {
            selecting = false
            selectionStore.clear()
            reload()
        })
    }
    private func reload(force: Bool = true) {
        guard isActive, AppMode.qa || session.hasCredentials, let url = sortOrder.url(site: site, category: category) else { return }
        let source = RequestedSource(url: url, generation: session.generation, owner: session.owner, favoritesRevision: session.favoritesRevision)
        if !force, requestedSource == source {
            applyConfirmedRemovals(session.favoriteStateCache.confirmedRemovals)
            if pager.interrupted { pager.retry(session: session) }
            return
        }
        let replaceInFlight = requestedSource.map { $0.favoritesRevision != source.favoritesRevision } ?? false
        if requestedSource?.url != source.url || requestedSource?.generation != source.generation {
            visibleGalleryID = nil
            anchorAfterRemoval = nil
        }
        requestedSource = source
        seenRemovals = session.favoriteStateCache.confirmedRemovals
        pager.reset(url: url, session: session, qa: AppMode.qa, replaceInFlight: replaceInFlight)
    }
}
