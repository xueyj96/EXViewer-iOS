import SwiftUI
import ExViewerCore

private struct FavoriteSearchDraft: Identifiable {
    let id = UUID()
    let query: SearchQuery
    let site: GallerySite
    let name: String
    let owner: String

    init(query: SearchQuery, site: GallerySite, owner: String) {
        self.query = query; self.site = site
        self.owner = owner
        name = String((query.text.isEmpty ? SearchPresentation.summary(query, site: site) : query.text).prefix(80))
    }
}

private struct LoadedSearchSource {
    enum Kind { case favorite, recent }
    let kind: Kind
    let id: UUID
    let title: String
    let query: SearchQuery
    let site: GallerySite

    init(_ saved: SavedSearch) {
        kind = .favorite; id = saved.id; title = saved.name; query = saved.query; site = saved.site
    }
    init(_ recent: RecentSearchRecord) {
        kind = .recent; id = recent.id; title = SearchPresentation.recordTitle(recent.query)
        query = recent.query; site = recent.site
    }
}

private struct SearchPresetRow: View {
    var title: String
    var query: SearchQuery
    var site: GallerySite
    var date: Date? = nil
    var selection: String? = nil
    var onEdit: (() -> Void)? = nil
    var reordering = false
    var action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var displayTitle: String {
        let summary = SearchPresentation.conditions(query)
        let generated = [query.text, summary, SearchPresentation.summary(query, site: site)]
        return generated.contains(where: { String($0.prefix(80)) == title }) ? (summary.isEmpty ? "全部画廊" : summary) : title
    }

    private var savedPresetContent: some View {
        let preview = SearchPresentation.presetPreview(query)
        let fullConditions = SearchPresentation.conditions(query)
        return VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            HStack(spacing: FeedChrome.contentSpacing) {
                Text(title).font(FeedChrome.labelFont)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(site == .ex ? "EX" : "EH")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, FeedChrome.panelSpacing * 2)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: AppShape.control)
                    .fixedSize()
                if let selection {
                    Image(systemName: selection == "已修改" ? "pencil.circle" : "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
            }
            HStack(spacing: FeedChrome.contentSpacing) {
                if !preview.conditions.isEmpty {
                    Text(preview.conditions)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !preview.limits.isEmpty {
                    Text(preview.limits).monospacedDigit().layoutPriority(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(fullConditions.isEmpty ? "全部画廊" : fullConditions))
        }
    }

    private var loadOrEdit: some Gesture {
        LongPressGesture(minimumDuration: 0.55).exclusively(before: TapGesture())
            .onEnded { result in
                guard !reordering else { return }
                switch result {
                case .first: onEdit?()
                case .second: action()
                }
            }
    }

    var body: some View {
        Button { if !reordering { action() } } label: {
            Group {
                if let date {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayTitle).font(FeedChrome.labelFont).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        HStack(spacing: 8) {
                            Text(site == .ex ? "EX" : "EH")
                            Text(date, style: .relative).lineLimit(1)
                            Spacer(minLength: 8)
                            if let selection {
                                Image(systemName: selection == "已修改" ? "pencil.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "arrow.up.left")
                            }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    savedPresetContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FeedChrome.panelSpacing)
            .frame(minHeight: FeedChrome.rowHeight + FeedChrome.contentSpacing)
            .padding(.horizontal, date == nil ? FeedChrome.contentSpacing : 0)
            .background {
                if date == nil {
                    Color.clear.formRowSurface()
                        .overlay {
                            if selection != nil { AppShape.card.fill(Color.accentColor.opacity(0.07)).allowsHitTesting(false) }
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(loadOrEdit,
                             including: onEdit != nil && !reordering ? .all : .none)
        .accessibilityValue(selection ?? "载入条件编辑，尚未执行搜索")
        .accessibilityHint(onEdit == nil ? "轻点载入条件" : reordering ? "拖动重新排序控件调整位置" : "轻点载入条件，长按编辑已保存的组合")
        .accessibilityActions {
            if let onEdit, !reordering { Button("编辑组合", action: onEdit) }
        }
        .accessibilityAddTraits(selection == nil ? [] : .isSelected)
    }
}

private enum SearchPresetList: Hashable, Identifiable {
    case recent, favorite
    var id: Self { self }
    var title: String { self == .recent ? "搜索记录" : "常用组合" }
}
enum SearchComposerStart: Hashable, Identifiable {
    case main, filters, favorites
    var id: Self { self }
}

private struct SearchPresetsView: View {
    let list: SearchPresetList
    var source: LoadedSearchSource?
    var sourceModified: Bool
    var onClose: (() -> Void)? = nil
    var onLoad: (LoadedSearchSource) -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var favorite: FavoriteSearchDraft?
    @State private var editingSaved: SavedSearch?
    @State private var reordering = false
    @State private var reorderingOwner: String?
    @State private var clearing = false

    @ViewBuilder
    private var listPage: some View {
        presetList.accountSubpageContent()
            .appToast(message: library.searchHistoryError ?? library.error, identifier: "search-presets.error")
    }

    private var presetList: some View {
        List {
            if list == .recent {
                Group {
                    if library.recentSearches.isEmpty {
                        Text("暂无搜索记录").foregroundStyle(.secondary).accountPageCard(compactRows: true).accessibilityIdentifier("search-history.empty")
                    }
                    ForEach(library.recentSearches) { record in
                        let saved = library.savedSearch(matching: record.query, site: record.site)
                        HStack(spacing: FeedChrome.panelSpacing) {
                            Button {
                                onLoad(LoadedSearchSource(record))
                                if let onClose { onClose() } else { dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                                    let preview = SearchPresentation.presetPreview(record.query)
                                    Text(SearchPresentation.recordTitle(record.query))
                                        .font(FeedChrome.labelFont).lineLimit(1).truncationMode(.tail)
                                    HStack(spacing: FeedChrome.controlSpacing) {
                                        Text(record.site == .ex ? "EX" : "EH")
                                        Text(record.date, style: .relative).lineLimit(1)
                                        if !preview.limits.isEmpty { Text(preview.limits).lineLimit(1).truncationMode(.tail) }
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight + FeedChrome.contentSpacing, alignment: .leading)
                                .accessibilityElement(children: .combine)
                                .accessibilityValue(SearchPresentation.conditions(record.query))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("search-history.load.\(record.id)")
                            .accessibilityHint("使用此搜索条件直接搜索")
                            Button {
                                favorite = FavoriteSearchDraft(query: record.query, site: record.site, owner: library.owner)
                            } label: { Image(systemName: saved == nil ? "bookmark" : "bookmark.fill") }
                                .buttonStyle(FeedHeaderButtonStyle())
                                .environment(\.pageHeaderAction, true)
                                .frame(width: FeedChrome.pageActionWidth)
                                .disabled(saved != nil)
                                .accessibilityLabel(saved == nil ? "加入常用搜索组合" : "已加入常用搜索组合")
                                .accessibilityIdentifier("search-history.save.\(record.id)")
                        }
                        .frame(minHeight: FeedChrome.rowHeight + FeedChrome.contentSpacing)
                        .accountPageCard(compactRows: true)
                        .swipeActions { Button("删除", role: .destructive) { library.deleteRecentSearch(record.id) } }
                    }
                }
            } else {
                if library.snapshot.saved.isEmpty {
                    Text("暂无常用组合").font(.footnote).foregroundStyle(.secondary)
                        .accountPageCard(compactRows: true)
                        .accessibilityIdentifier("search-favorites.empty")
                }
                Section {
                    ForEach(library.snapshot.saved) { saved in
                        SearchPresetRow(title: saved.name, query: saved.query, site: saved.site,
                                        selection: favoriteSelection(saved), onEdit: { editingSaved = saved }, reordering: reordering) {
                            onLoad(LoadedSearchSource(saved))
                        }.accessibilityIdentifier("search-favorites.load.\(saved.id)")
                            .accountPageListRow()
                            .moveDisabled(!reordering)
                    }
                    .onMove { offsets, destination in
                        guard let owner = reorderingOwner,
                              library.moveSavedSearches(from: offsets, to: destination, expectedOwner: owner) else {
                            reordering = false; return
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        listPage
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
        .detailEdgeBack(action: close)
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false, customEdgeBack: true)
        .floatingPageHeader(list.title, identifier: "search-presets", pinned: true) {
            Button(action: close) { Image(systemName: "chevron.left") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel(list == .recent ? "返回" : "关闭")
                .accessibilityIdentifier("search-presets.close")
        } trailing: {
            if list == .recent {
                Button { clearing = true } label: { Label("清空", systemImage: "trash") }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .disabled(library.recentSearches.isEmpty && library.searchHistoryError == nil)
                    .accessibilityIdentifier("search-history.clear")
            } else {
                Button {
                    reorderingOwner = library.owner
                    reordering.toggle()
                } label: {
                    Image(systemName: reordering ? "checkmark" : "arrow.up.arrow.down")
                }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel(reordering ? "完成" : "编辑顺序")
                .disabled(!reordering && library.snapshot.saved.count < 2)
                .accessibilityIdentifier("search-favorites.reorder")
            }
        }
        .onChange(of: library.owner) { _, _ in
            reordering = false; reorderingOwner = nil; editingSaved = nil; favorite = nil; clearing = false
        }
        .confirmationDialog("清空搜索记录 常用组合保留", isPresented: $clearing, titleVisibility: .visible) {
            Button("清空搜索记录", role: .destructive) { library.clearSearchHistory() }
        }
        .navigationDestination(isPresented: Binding(get: { favorite != nil }, set: { if !$0 { favorite = nil } })) {
            if let target = favorite {
                SaveSearchPage(query: target.query, site: target.site,
                               initialName: target.name, owner: target.owner) { _ in }
                    .dynamicTypeSize(typeSize)
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { editingSaved != nil },
            set: { if !$0 { editingSaved = nil } }
        )) {
            if let saved = editingSaved {
                DiscoveryComposerView(editing: saved, usesParentNavigation: true)
                    .dynamicTypeSize(typeSize)
            }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func favoriteSelection(_ saved: SavedSearch) -> String? {
        guard source?.query == saved.query, source?.site == saved.site else { return nil }
        return selection(.favorite, saved.id)
    }

    private func selection(_ kind: LoadedSearchSource.Kind, _ id: UUID) -> String? {
        guard source?.kind == kind, source?.id == id else { return nil }
        return sourceModified ? "已修改" : "已载入"
    }
}

struct SaveSearchPage: View {
    var query: SearchQuery
    var site: GallerySite
    let owner: String
    var onSaved: (UUID) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    init(query: SearchQuery, site: GallerySite, initialName: String, owner: String, onSaved: @escaping (UUID) -> Void) {
        self.query = query; self.site = site; self.onSaved = onSaved; _name = State(initialValue: initialName)
        self.owner = owner
    }
    var body: some View {
        List {
            TextField("组合名称", text: $name).accessibilityIdentifier("search.save.name")
                .accountPageCard(compactRows: true)
            LabeledContent("站点", value: site.name).accountPageCard(compactRows: true)
            Text(SearchPresentation.conditions(query)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.secondary).accountPageCard(compactRows: true)
        }
        .accountSubpageContent()
        .appToast(message: $failure, identifier: "search.save.error")
        .floatingPageHeader("保存搜索组合",
                             identifier: "search.save", pinned: true) {
            Button { dismiss() } label: { Label("取消", systemImage: "xmark") }
                .buttonStyle(FeedHeaderButtonStyle()).accessibilityIdentifier("search.save.cancel")
        } trailing: {
            Button(action: save) { Label("保存", systemImage: "checkmark") }
                .buttonStyle(FeedHeaderButtonStyle()).foregroundStyle(Color.accentColor)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("search.save.confirm")
        }
    }
    private func save() {
        guard owner == library.owner else { failure = "账号已切换 请重新保存"; return }
        do {
            _ = try query.url(site: site)
            guard let id = library.saveSearch(name: name, site: site, query: query, expectedOwner: owner), let saved = library.snapshot.saved.first(where: { $0.id == id }), saved.query == query, saved.site == site else { failure = library.error ?? "保存失败 请检查名称和组合数量"; return }
            onSaved(id); dismiss()
        } catch { failure = (error as? ViewerError)?.localizedDescription ?? "条件无法保存" }
    }
}

private enum SearchComposerPurpose {
    case search((SearchQuery, GallerySite, UUID?) throws -> Void)
    case editSaved(SavedSearch)
}

struct DiscoveryComposerView: View {
    private let purpose: SearchComposerPurpose
    private let dismissesOnApply: Bool
    private let usesParentNavigation: Bool
    private let updatesResults: Bool
    private let onCancel: (() -> Void)?
    private let detailNavigationTitle: String?
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var categoryIconWidth: CGFloat = 18
    private var unlimitedPrompt: Text { Text("不限").foregroundStyle(Palette.inputPrompt) }
    @State private var draft: SearchDraft
    @State private var tagLookup = TagLookupDraft()
    @State private var tagsExpanded = false
    @State private var tagSource: SearchTagSource = .add
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var categoriesExpanded = true
    @State private var matchingExpanded = true
    @State private var workConditionsExpanded = true
    @State private var failure: String?
    @State private var favorite: FavoriteSearchDraft?
    @State private var loadedSource: LoadedSearchSource?
    @State private var detailTagSource: DetailTagSearchDraft?
    @State private var clearedDraft = false
    @State private var filtersExpanded: Bool
    @State private var startsWithFavorites: Bool
    @State private var showsSearchHistory = false
    @State private var savedName: String
    @State private var editorOwner: String?
    @State private var confirmingPresetRemoval = false
    @FocusState private var inputFocused: Bool

    init(query: SearchQuery, site: GallerySite, startAt: SearchComposerStart = .main, loadedPreset: SavedSearch? = nil,
         detailTagSource: DetailTagSearchDraft? = nil, dismissesOnApply: Bool = true, updatesResults: Bool = false,
         usesParentNavigation: Bool = false, onCancel: (() -> Void)? = nil, onApply: @escaping (SearchQuery, GallerySite, UUID?) throws -> Void) {
        self.init(query: query, site: site, startAt: startAt, loadedPreset: loadedPreset,
                  detailTagSource: detailTagSource, purpose: .search(onApply),
                  dismissesOnApply: dismissesOnApply, updatesResults: updatesResults,
                  usesParentNavigation: usesParentNavigation, onCancel: onCancel)
    }

    init(editing saved: SavedSearch, usesParentNavigation: Bool = false) {
        self.init(query: saved.query, site: saved.site, startAt: .main, loadedPreset: nil,
                  detailTagSource: nil, purpose: .editSaved(saved), usesParentNavigation: usesParentNavigation)
    }

    private init(query: SearchQuery, site: GallerySite, startAt: SearchComposerStart, loadedPreset: SavedSearch?,
                 detailTagSource: DetailTagSearchDraft?, purpose: SearchComposerPurpose,
                 dismissesOnApply: Bool = true, updatesResults: Bool = false,
                 usesParentNavigation: Bool = false, onCancel: (() -> Void)? = nil) {
        self.purpose = purpose
        self.dismissesOnApply = dismissesOnApply
        self.usesParentNavigation = usesParentNavigation
        self.updatesResults = updatesResults
        self.onCancel = onCancel
        detailNavigationTitle = detailTagSource?.navigationTitle
        if case let .editSaved(saved) = purpose { _savedName = State(initialValue: saved.name) }
        else { _savedName = State(initialValue: "") }
        _draft = State(initialValue: SearchDraft(query: query, site: site))
        _tagsExpanded = State(initialValue: !query.rules.isEmpty)
        _filtersExpanded = State(initialValue: startAt != .main)
        _startsWithFavorites = State(initialValue: startAt == .favorites)
        _loadedSource = State(initialValue: loadedPreset.map { LoadedSearchSource($0) })
        _detailTagSource = State(initialValue: detailTagSource)
    }

    var body: some View {
        Group {
            if usesParentNavigation {
                page
            } else {
                NavigationStack { page }
            }
        }
        .onAppear { if isSavedEditor && editorOwner == nil { editorOwner = library.owner } }
        .onChange(of: library.owner) { _, owner in
            favorite = nil; showsSearchHistory = false
            tagsExpanded = false; tagSource = .add; confirmingPresetRemoval = false
            if isSavedEditor && editorOwner != owner { failure = "账号已切换 请重新编辑常用组合" }
        }
        .onChange(of: tagSource) { _, _ in inputFocused = false }
        .onChange(of: draft) { _, _ in draftChanged() }
        .onChange(of: savedName) { _, _ in draftChanged() }
        .confirmationDialog("删除这个常用组合？", isPresented: $confirmingPresetRemoval, titleVisibility: .visible) {
            Button("删除组合", role: .destructive, action: removeEditedPreset)
                .accessibilityIdentifier("saved-editor.confirm-delete")
        }
    }
    @ViewBuilder private var page: some View {
        if startsWithFavorites {
            SearchPresetsView(list: .favorite, source: loadedSource, sourceModified: sourceModified, onClose: onCancel) { source in
                loadAndSearch(source)
            }
        } else {
            mainPage
                .navigationDestination(isPresented: Binding(get: { favorite != nil }, set: { if !$0 { favorite = nil } })) {
                    if let target = favorite {
                        SaveSearchPage(query: target.query, site: target.site, initialName: target.name, owner: target.owner) { id in
                            if let saved = library.snapshot.saved.first(where: { $0.id == id }) {
                                loadedSource = LoadedSearchSource(saved); detailTagSource = nil
                            }
                        }
                        .dynamicTypeSize(typeSize)
                    }
                }
                .navigationDestination(isPresented: $showsSearchHistory) {
                    SearchPresetsView(list: .recent, source: loadedSource, sourceModified: sourceModified, onClose: { showsSearchHistory = false }) { source in
                        loadAndSearch(source)
                    }
                    .dynamicTypeSize(typeSize)
                }

        }
    }

    private var mainPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? FeedChrome.contentSpacing : 0) {
                composerRows
            }
            .feedPageContent(topGap: typeSize.isAccessibilitySize ? FeedChrome.contentTopGap : 0)
            .padding(.bottom, FeedChrome.sectionSpacing)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .appToast(message: $failure, identifier: "compose.error")
        .detailEdgeBack(commitAllowed: isSavedEditor || !draft.hasConditions || (try? draft.validatedQuery()) != nil, committing: {
            if isSavedEditor || !draft.hasConditions { cancel(); return true }
            return apply()
        }, onBlockedCommit: {
            // Validation failed before dragging; report through the same path as Search.
            _ = apply()
        })
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false, customEdgeBack: true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { composerHeader }
    }

    @ViewBuilder
    private var composerRows: some View {
        if isSavedEditor {
            filterGroup {
                SearchLabeledInputRow(title: "名称") {
                    TextField("名称", text: $savedName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .multilineTextAlignment(.leading)
                        .accessibilityLabel("组合名称")
                        .accessibilityIdentifier("saved-editor.name")
                        .searchInputSurface()
                }
            }
        }
        keywordCard
        if clearedDraft || !tagSearchExclusions.isEmpty || composerStatusSource != nil {
            composerStatus.searchComposerCardSurface(allowsMultiline: true)
        }
        filterCard
        filterGroup {
            HStack(spacing: FeedChrome.panelSpacing) {
                clearCard
                if isSavedEditor { deletePresetCard }
                else { favoriteDraftCard }
            }
        }
        .padding(.vertical, FeedChrome.panelSpacing)
    }

    private var deletePresetCard: some View {
        Button(role: .destructive) { confirmingPresetRemoval = true } label: {
            Text("删除").lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(SearchFilterActionStyle(destructive: true))
        .disabled(editorOwner != library.owner)
        .accessibilityLabel("删除组合")
        .accessibilityIdentifier("saved-editor.delete")
    }

    private var keywordCard: some View {
        HStack(spacing: 8) {
            TextField("关键词、标题或标签", text: $draft.inputText,
                          prompt: Text("关键词、标题或标签").foregroundStyle(Palette.inputPrompt))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .submitLabel(.done).onSubmit { inputFocused = false }
                .focused($inputFocused)
                .frame(minHeight: FeedChrome.rowHeight)
                .accessibilityIdentifier(isSavedEditor ? "saved-editor.text" : "compose.text")
                .accessibilityHint("也支持 title:、namespace:tag、~任一、-排除和 uploader: 条件。")
            if !isSavedEditor {
                Button {
                    inputFocused = false
                    showsSearchHistory = true
                } label: {
                    Label("搜索记录", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .environment(\.pageHeaderAction, true)
                    .environment(\.feedHeaderRow, .single)
                    .accessibilityLabel("搜索记录").accessibilityIdentifier("compose.records")
            }
        }
        .font(FeedChrome.labelFont)
        .padding(.leading, FeedChrome.contentSpacing)
        .padding(.trailing, FeedChrome.panelSpacing)
        .formRowSurface(shape: AppShape.control)
        .padding(.vertical, FeedChrome.panelSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.keyword-card")
    }

    @ViewBuilder
    private var composerStatus: some View {
        if clearedDraft {
            Label(isSavedEditor ? "条件已清空 保存后生效" : "条件已清空 点击\(visibleConfirmationTitle)后生效",
                  systemImage: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("compose.cleared-state")
        } else if !tagSearchExclusions.isEmpty {
            Text("已排除 \(tagSearchExclusions.map(\.label).joined(separator: " "))")
                .font(FeedChrome.labelFont).foregroundStyle(.secondary)
                .lineLimit(2).accessibilityIdentifier("compose.tag-exclusions")
        } else if let source = composerStatusSource {
            Label(loadedStatus, systemImage: sourceModified ? "pencil.circle" : "checkmark.circle")
                .labelStyle(.titleAndIcon).foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("compose.loaded-state")
                .accessibilityValue(sourceModified ? "已修改" : "已载入")
                .accessibilityHint(source.title)
        }
    }

    private var filterCard: some View {
        VStack(spacing: 0) {
            AppDisclosureHeader(title: "筛选", expanded: filtersExpanded,
                                   identifier: "compose.filters", action: openFilters)
                .padding(FeedChrome.panelSpacing)
            AnimatedDisclosureContent(isExpanded: filtersExpanded, identifier: "compose.disclosure.advanced") {
                VStack(spacing: FeedChrome.panelSpacing) { filterSections }
                    .padding([.horizontal, .bottom], FeedChrome.panelSpacing)
            }
        }
        .background {
            Color.clear.formRowSurface(shape: AppShape.aligned(with: filtersExpanded ? AppShape.card : AppShape.control,
                                                              offset: FeedChrome.panelSpacing), outer: true)
                .animation(reduceMotion ? nil : ChromeMotion.resize, value: filtersExpanded)
        }
        .padding(.vertical, FeedChrome.panelSpacing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.advanced-group")
    }

    private var favoriteDraftCard: some View {
        let saved = matchingFavorite != nil
        let label = saved ? "已保存" : "存常用"
        return Button(action: prepareFavorite) {
            Text(label).lineLimit(1).frame(maxWidth: .infinity)
        }
        .buttonStyle(SearchFilterActionStyle(highlighted: true))
        .disabled(saved || !draft.hasConditions)
        .accessibilityValue(saved ? "已保存" : "未保存")
        .accessibilityLabel(saved ? "已加入常用组合" : "加入常用组合")
        .accessibilityIdentifier("compose.save-favorite")
    }

    private var clearCard: some View {
        Button { clearDraft() } label: {
            Text("清空").lineLimit(1).frame(maxWidth: .infinity)
        }
            .buttonStyle(SearchFilterActionStyle())
            .disabled(!draft.hasConditions)
            .accessibilityLabel("清空条件")
            .accessibilityIdentifier("compose.clear")
            .accessibilityHint(isSavedEditor ? "保存后更新此组合" : "只修改待搜索的条件，点击搜索后才生效")
    }

    private var composerHeader: some View {
        FloatingHeaderPanel(identifier: "compose.header") {
            FloatingPageTitleRow(title: isSavedEditor ? "编辑常用组合" : detailNavigationTitle ?? "搜索",
                                 identifier: "compose.title") {
                Button(action: cancel) { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .accessibilityIdentifier(isSavedEditor ? "saved-editor.cancel" : "compose.cancel")
            } trailing: {
                Button { apply() } label: {
                    Label(visibleConfirmationTitle, systemImage: isSavedEditor ? "checkmark" : "magnifyingglass")
                }
                .buttonStyle(FeedHeaderButtonStyle(truncatesLabel: true))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(confirmationTitle)
                .accessibilityIdentifier(isSavedEditor ? "saved-editor.save" : "compose.apply")
                .disabled(submissionDisabled)
            }
            .environment(\.feedHeaderRow, .single)
        }
    }

    private var composerStatusSource: LoadedSearchSource? {
        guard let loadedSource, loadedSource.kind == .recent else { return nil }
        return loadedSource
    }

    private var loadedStatus: String {
        return sourceModified ? "从最近搜索载入 · 已修改" : "从最近搜索载入"
    }

    @ViewBuilder private var tagSections: some View {
        filterGroup {
            VStack(alignment: .leading, spacing: 0) {
                tagConditionActions
                AnimatedDisclosureContent(isExpanded: tagsExpanded, identifier: "compose.disclosure.tag-group") {
                    VStack(alignment: .leading, spacing: 0) {
                        Group {
                            switch tagSource {
                            case .add:
                                InlineTagSearch(draft: $tagLookup, rules: $draft.query.rules)
                            case .common:
                                commonTagRows
                            }
                        }
                        .transition(.opacity)

                        if !draft.query.rules.isEmpty {
                            VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                                ForEach($draft.query.rules) { $rule in
                                    SearchTagRuleRow(tag: rule.tag, match: $rule.match,
                                                     matchIdentifier: "compose.rule.match.\(rule.id)",
                                                     removeIdentifier: "compose.rule.remove.\(rule.id)",
                                                     removeLabel: "移除 \(rule.tag.label)",
                                                     isNew: detailTagSource?.origin != .newSearch && detailTagSource?.addedTagIDs.contains(rule.id) == true) {
                                        draft.query.rules.removeAll { $0.id == rule.id }
                                    }
                                }
                            }
                            .padding(.top, FeedChrome.panelSpacing)
                        }
                    }
                    .padding(.top, FeedChrome.panelSpacing)
                    .animation(reduceMotion ? nil : ChromeMotion.replace, value: tagSource)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.tags-group")
    }

    @ViewBuilder private var filterSections: some View {
        tagSections
        filterGroup {
            VStack(spacing: 0) {
                AppDisclosureHeader(title: "作品", expanded: workConditionsExpanded, identifier: "compose.work.disclosure") {
                    workConditionsExpanded.toggle()
                }
                AnimatedDisclosureContent(isExpanded: workConditionsExpanded, identifier: "compose.disclosure.work") {
                    VStack(spacing: FeedChrome.panelSpacing) {
                        SearchLabeledInputRow(title: "作者") {
                            TextField("不限", text: Binding(get: { draft.query.artist }, set: { draft.query.replaceArtist($0) }), prompt: unlimitedPrompt)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .multilineTextAlignment(.leading).accessibilityLabel("作者")
                                .accessibilityIdentifier("compose.artist")
                                .searchInputSurface()
                        }
                        SearchLabeledInputRow(title: "上传者") {
                            TextField("不限", text: $draft.query.uploader, prompt: unlimitedPrompt)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .multilineTextAlignment(.leading).accessibilityLabel("上传者")
                                .accessibilityIdentifier("compose.uploader")
                                .searchInputSurface()
                        }
                        SearchLabeledInputRow(title: "页数") {
                            HStack(spacing: FeedChrome.panelSpacing) {
                                TextField("0", text: $draft.minimumPagesText, prompt: Text("0").foregroundStyle(Palette.inputPrompt))
                                    .keyboardType(.numberPad).multilineTextAlignment(.leading)
                                    .accessibilityLabel("最少页数").accessibilityIdentifier("compose.min-pages")
                                    .monospacedDigit()
                                    .searchInputSurface()
                                Text("–").foregroundStyle(.secondary)
                                TextField("∞", text: $draft.maximumPagesText, prompt: Text("∞").foregroundStyle(Palette.inputPrompt))
                                    .keyboardType(.numberPad).multilineTextAlignment(.leading)
                                    .accessibilityLabel("最多页数").accessibilityIdentifier("compose.max-pages")
                                    .monospacedDigit()
                                    .searchInputSurface()
                            }
                            .frame(maxWidth: .infinity)
                        }
                        FormValueMenuRow(title: "最低分", value: draft.query.minRating.map { "\($0) 星" } ?? "不限",
                                         identifier: "compose.min-rating") {
                            ForEach([0] + Array(2...5), id: \.self) { rating in
                                AppMenuItem(title: rating == 0 ? "不限" : "\(rating) 星", isSelected: (draft.query.minRating ?? 0) == rating) {
                                    draft.query.minRating = rating == 0 ? nil : rating
                                }
                            }
                        }
                        .searchFilterRow()
                        if let warning = (try? draft.queryWithPageRange())?.pageRangeWarning {
                            Text(warning).font(.caption).foregroundStyle(.secondary).searchFilterRow()
                                .accessibilityIdentifier("compose.page-range-warning")
                        }
                    }
                    .padding(.top, FeedChrome.panelSpacing)
                }
            }
        }

        categorySection

        filterGroup {
            VStack(spacing: 0) {
                AppDisclosureHeader(title: "匹配", expanded: matchingExpanded, identifier: "compose.matching.disclosure") {
                    matchingExpanded.toggle()
                }
                AnimatedDisclosureContent(isExpanded: matchingExpanded, identifier: "compose.disclosure.matching") {
                    VStack(spacing: FeedChrome.panelSpacing) {
                        Toggle("仅标题", isOn: $draft.query.titleOnly).accessibilityLabel("仅搜索标题")
                            .controlSize(.small).searchFilterRow()
                        Toggle("整句搜", isOn: $draft.query.matchPhrase).accessibilityLabel("匹配完整短语")
                            .controlSize(.small).searchFilterRow()
                        Toggle("有种子", isOn: $draft.query.requireTorrent).accessibilityLabel("必须有 BT 种子")
                            .searchFilterRow()
                    }
                    .padding(.top, FeedChrome.panelSpacing)
                }
            }
        }
    }

    private var tagConditionActions: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            if tagsExpanded {
                CompactFormSegmentPicker(selection: $tagSource, options: SearchTagSource.allCases,
                                         title: { $0.title }, accessibilityLabel: "标签来源",
                                         identifier: "compose.tag-source")
                    .transition(.opacity)
                AppDisclosureButton(title: "标签", expanded: tagsExpanded, identifier: "compose.tags.disclosure") {
                    inputFocused = false
                    tagsExpanded.toggle()
                }
            } else {
                AppDisclosureHeader(title: "标签", expanded: tagsExpanded, identifier: "compose.tags.disclosure") {
                    inputFocused = false
                    tagsExpanded.toggle()
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : ChromeMotion.replace, value: tagsExpanded)
    }

    private var commonTagRows: some View {
        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            if library.snapshot.favoriteTags.isEmpty {
                Text("暂无常用标签").foregroundStyle(.secondary).searchFilterRow()
            }
            ForEach(library.snapshot.favoriteTags) { tag in
                let included = draft.query.rules.contains { $0.id == tag.id }
                Button {
                    if included { draft.query.rules.removeAll { $0.id == tag.id } }
                    else { addTag(tag) }
                } label: {
                    TagListRowLabel(tag: tag, symbol: included ? "checkmark.circle.fill" : "plus.circle",
                                    emphasized: included)
                        .searchFilterRow().contentShape(Rectangle())
                }
                .buttonStyle(TagShortcutButtonStyle())
                .tagLibraryActions(tag)
                .accessibilityValue(included ? "已添加" : "添加为包含条件")
                .accessibilityIdentifier("compose.favorite-tag.\(tag.id)")
            }
        }
    }

    private func filterGroup<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        FormGroup(content: content)
    }

    private var categoryIDs: Set<Int> { Set(GalleryCategory.all.map(\.id)) }

    private var selectedCategoryCount: Int {
        categoryIDs.subtracting(draft.query.excludedCategories).count
    }

    private var categoryActions: some View {
        HStack(spacing: 0) {
            Button { draft.query.excludedCategories.removeAll() } label: {
                Text("全选")
                    .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
                    .contentShape(Rectangle())
            }
            .disabled(selectedCategoryCount == GalleryCategory.all.count)
            .accessibilityIdentifier("compose.categories.select-all")
            Button {
                draft.query.excludedCategories = categoryIDs.subtracting(draft.query.excludedCategories)
            } label: {
                Text("反选")
                    .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("compose.categories.invert")
        }
        .font(FeedChrome.labelFont)
        .foregroundStyle(Color.accentColor)
        .buttonStyle(.plain)
        .appControlSurface()
        .overlay {
            Divider().frame(height: FeedChrome.compactFormRowHeight / 2).allowsHitTesting(false)
        }
    }

    private var categorySection: some View {
        filterGroup {
            VStack(spacing: 0) {
                HStack(spacing: FeedChrome.panelSpacing) {
                    Button { categoriesExpanded.toggle() } label: {
                        AppDisclosureTitle(title: "分类", identifier: "compose.categories.disclosure.title")
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("画廊分类")
                    .accessibilityValue(categoriesExpanded ? "已展开" : "已收起")
                    .accessibilityIdentifier("compose.categories.disclosure.heading")
                    if categoriesExpanded {
                        categoryActions.transition(.opacity)
                    }
                    AppDisclosureButton(title: "分类", expanded: categoriesExpanded, identifier: "compose.categories.disclosure") {
                        categoriesExpanded.toggle()
                    }
                }
                .animation(reduceMotion ? nil : ChromeMotion.resize, value: categoriesExpanded)
                AnimatedDisclosureContent(isExpanded: categoriesExpanded, identifier: "compose.disclosure.categories") {
                    categoryContent.padding(.top, FeedChrome.panelSpacing)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("画廊分类")
    }

    private var categoryContent: some View {
        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            let column = GridItem(.flexible(), spacing: FeedChrome.panelSpacing, alignment: .leading)
            LazyVGrid(columns: Array(repeating: column, count: typeSize.isAccessibilitySize ? 1 : 2),
                      alignment: .leading, spacing: FeedChrome.panelSpacing) {
                ForEach(GalleryCategory.all) { category in
                    let excluded = draft.query.excludedCategories.contains(category.id)
                    Button {
                        if excluded { draft.query.excludedCategories.remove(category.id) }
                        else { draft.query.excludedCategories.insert(category.id) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: excluded ? "circle" : "checkmark.circle.fill")
                                .frame(width: categoryIconWidth)
                                .foregroundStyle(excluded ? Color.secondary : Color.accentColor)
                                .accessibilityHidden(true)
                            Text(category.name).lineLimit(1).minimumScaleFactor(0.85)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(excluded ? Color.secondary : Color.primary)
                        .searchFilterRow()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.name)
                    .accessibilityIdentifier("compose.category.\(category.id)")
                    .accessibilityValue(excluded ? "未选择" : "已选择")
                    .accessibilityAddTraits(excluded ? [] : .isSelected)
                }
            }
        }
    }

    private var sourceModified: Bool {
        guard let source = loadedSource else { return false }
        guard let current = try? draft.validatedQuery(),
              let currentKey = try? RecentSearchRecord.requestKey(site: draft.site, query: current),
              let baselineKey = try? RecentSearchRecord.requestKey(site: source.site, query: source.query) else { return true }
        return currentKey != baselineKey
    }

    private var tagSearchExclusions: [GalleryTag] {
        guard let source = detailTagSource else { return [] }
        let query = (try? draft.validatedQuery()) ?? draft.query
        return query.rules.filter { source.originalExclusions.contains($0.id) && $0.match == .exclude }.map(\.tag)
    }

    private var isSavedEditor: Bool {
        if case .editSaved = purpose { return true }; return false
    }

    private var submissionDisabled: Bool {
        isSavedEditor && editorOwner != library.owner
    }

    private var confirmationTitle: String {
        if isSavedEditor { return "保存" }
        return updatesResults ? "更新结果" : "搜索"
    }

    private var visibleConfirmationTitle: String {
        updatesResults && !isSavedEditor ? "更新" : confirmationTitle
    }

    private func cancel() {
        if let onCancel { onCancel() } else { dismiss() }
    }

    private func load(_ source: LoadedSearchSource) {
        inputFocused = false
        draft = SearchDraft(query: source.query, site: source.site)
        loadedSource = source
        detailTagSource = nil
        failure = nil; clearedDraft = false
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func loadAndSearch(_ source: LoadedSearchSource) {
        load(source)
        startsWithFavorites = false
        showsSearchHistory = false
        if !isSavedEditor { apply() }
    }

    private func prepareFavorite() {
        do {
            let query = try draft.validatedQuery()
            guard query.hasSettings else { failure = "请先输入搜索条件"; return }
            inputFocused = false
            guard library.savedSearch(matching: query, site: draft.site) == nil else { return }
            favorite = FavoriteSearchDraft(query: query, site: draft.site, owner: library.owner)
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "搜索条件无效" }
    }

    private var matchingFavorite: SavedSearch? {
        guard let query = try? draft.validatedQuery(), query.hasSettings else { return nil }
        return library.savedSearch(matching: query, site: draft.site)
    }

    private func addTag(_ tag: GalleryTag) {
        guard !draft.query.rules.contains(where: { $0.id == tag.id }) else { return }
        draft.query.rules.append(.init(tag: tag))
    }

    private func removeEditedPreset() {
        guard case let .editSaved(saved) = purpose, editorOwner == library.owner else { return }
        guard library.deleteSearch(saved.id) else {
            failure = library.error ?? "常用组合删除失败 请重试"
            return
        }
        dismiss()
    }

    @discardableResult private func apply(reportErrors: Bool = true) -> Bool {
        do {
            let query = try draft.validatedQuery()
            switch purpose {
            case let .search(onApply):
                let selectedSaved = loadedSource.flatMap { source in
                    source.kind == .favorite ? library.snapshot.saved.first { $0.id == source.id && $0.query == query && $0.site == draft.site } : nil
                }
                let matchingSavedID = selectedSaved?.id ?? library.savedSearch(matching: query, site: draft.site)?.id
                inputFocused = false
                try onApply(query, draft.site, matchingSavedID)
            case let .editSaved(saved):
                guard let owner = editorOwner, owner == library.owner else { throw ViewerError.invalidQuery("账号已切换 请重新编辑常用组合") }
                let name = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ViewerError.invalidQuery("请输入组合名称") }
                guard let id = library.saveSearch(name: name, site: draft.site, query: query, replacing: saved.id, expectedOwner: owner),
                      let stored = library.snapshot.saved.first(where: { $0.id == id }), stored.query == query, stored.site == draft.site else {
                    throw ViewerError.invalidQuery(library.error ?? "常用组合保存失败 请重试")
                }
            }
            if dismissesOnApply { dismiss() }
            return true
        } catch {
            if reportErrors {
                failure = (error as? LocalizedError)?.errorDescription ?? (error as? ViewerError)?.localizedDescription ?? "搜索条件无效"
            }
            return false
        }
    }

    private func draftChanged() {
        failure = nil
        if draft.hasConditions { clearedDraft = false }
    }

    private func clearDraft() {
        inputFocused = false
        draft.clear()
        tagLookup = TagLookupDraft()
        detailTagSource = nil
        failure = nil; clearedDraft = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func openFilters() {
        inputFocused = false
        if filtersExpanded { filtersExpanded = false; return }
        do {
            try draft.parseInlineFilters()
            failure = nil; filtersExpanded = true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "搜索条件无效"
        }
    }
}

private enum SearchTagSource: String, CaseIterable {
    case add, common
    var title: String { self == .add ? "添加" : "常用" }
}

/// The label column and input surfaces share dimensions across all search inputs.
private struct SearchLabeledInputRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: FormLayoutMetrics.labelToFieldGap) {
            Text(title).lineLimit(1)
                .frame(width: FormLayoutMetrics.fieldLabelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity)
        }
        .formRowLayout(.compact)
        .formRowSurface(shape: AppShape.control)
    }
}

private extension View {
    func searchInputSurface() -> some View {
        font(FeedChrome.labelFont)
            .padding(.horizontal, FormLayoutMetrics.textInset)
            .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
            .appControlSurface(verticalInset: FeedChrome.panelSpacing)
    }

    func searchComposerCardSurface(allowsMultiline: Bool = false) -> some View {
        modifier(SearchComposerCardSurface(allowsMultiline: allowsMultiline))
    }

    func searchFilterRow() -> some View {
        formRowLayout(.compact)
            .formRowSurface(shape: AppShape.control)
    }
}

private struct SearchFilterActionStyle: ButtonStyle {
    var highlighted = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let accented = highlighted && enabled
        configuration.label
            .font(FeedChrome.labelFont)
            .foregroundStyle(destructive ? Color.red : accented ? Color.accentColor : Color.primary)
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.38)
            .frame(minHeight: FeedChrome.compactFormRowHeight)
            .contentShape(Rectangle())
            .appControlSurface(selected: accented)
    }
}

private struct SearchComposerCardSurface: ViewModifier {
    let allowsMultiline: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        let inset = typeSize.isAccessibilitySize ? 0 : FeedChrome.panelSpacing
        let contentInset = allowsMultiline || typeSize.isAccessibilitySize ? inset + FeedChrome.panelSpacing : 0
        content
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, contentInset)
            .frame(maxWidth: .infinity, minHeight: FeedChrome.rowHeight, alignment: .leading)
            .background {
                Color.clear.formRowSurface(shape: AppShape.control)
                    .padding(.vertical, inset)
            }
            .contentShape(Rectangle())
    }
}

/// Disabled common tags keep readable text; the checkmark communicates membership.
private struct TagShortcutButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
