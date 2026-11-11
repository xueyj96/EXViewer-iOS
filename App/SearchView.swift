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
    }

    private var presetList: some View {
        List {
            if list == .recent {
                if let error = library.searchHistoryError {
                    Text(error).foregroundStyle(.secondary).accountPageCard()
                }
                if let error = library.error { Text(error).foregroundStyle(.red).accountPageCard() }
                Group {
                    if library.recentSearches.isEmpty {
                        Text("暂无搜索记录").foregroundStyle(.secondary).accountPageCard(compactRows: true).accessibilityIdentifier("search-history.empty")
                    }
                    ForEach(library.recentSearches) { record in
                        let saved = library.savedSearch(matching: record.query, site: record.site)
                        HStack(spacing: 8) {
                            SearchPresetRow(title: SearchPresentation.conditions(record.query), query: record.query,
                                            site: record.site, date: record.date, selection: selection(.recent, record.id)) {
                                onLoad(LoadedSearchSource(record))
                                dismiss()
                            }.accessibilityIdentifier("search-history.load.\(record.id)")
                            Button {
                                favorite = FavoriteSearchDraft(query: record.query, site: record.site, owner: library.owner)
                            } label: {
                                Image(systemName: saved == nil ? "bookmark" : "bookmark.fill").frame(width: FeedChrome.rowHeight, height: FeedChrome.rowHeight)
                            }
                            .buttonStyle(.borderless)
                            .disabled(saved != nil)
                            .accessibilityLabel(saved == nil ? "将这组条件存为常用" : "已存常用")
                            .accessibilityIdentifier("search-history.save.\(record.id)")
                        }
                        .accountPageCard(compactRows: true)
                        .swipeActions { Button("删除", role: .destructive) { library.deleteRecentSearch(record.id) } }
                    }
                }
            } else {
                if let error = library.error {
                    Text(error).font(.footnote).foregroundStyle(.red).accountPageCard()
                }
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
        .appNavigationChrome(backButton: list == .recent, showsToolbarBackButton: false)
        .floatingPageHeader(list.title, identifier: "search-presets", pinned: true) {
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: { Image(systemName: list == .recent ? "chevron.left" : "xmark") }
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
        .confirmationDialog("清空当前账号的搜索记录？常用组合会保留。", isPresented: $clearing, titleVisibility: .visible) {
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
            if let failure { Text(failure).foregroundStyle(.red).accountPageCard() }
        }
        .accountSubpageContent()
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
        guard owner == library.owner else { failure = "账号已切换，请重新打开保存窗口。"; return }
        do {
            _ = try query.url(site: site)
            guard let id = library.saveSearch(name: name, site: site, query: query, expectedOwner: owner), let saved = library.snapshot.saved.first(where: { $0.id == id }), saved.query == query, saved.site == site else { failure = library.error ?? "保存未完成，请检查名称或已保存组合数量。"; return }
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
    @State private var tagEntry = false
    @State private var commonTagsExpanded = false
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
            tagEntry = false; confirmingPresetRemoval = false
            if isSavedEditor && editorOwner != owner { failure = "账号已切换，请重新打开常用组合编辑。" }
        }
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
                load(source); startsWithFavorites = false
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
                    SearchPresetsView(list: .recent, source: loadedSource, sourceModified: sourceModified) { source in
                        load(source)
                    }
                    .dynamicTypeSize(typeSize)
                }
                .navigationDestination(isPresented: $tagEntry) {
                    TagEntryView(editing: draft.query.rules) { rules in draft.query.rules = rules }
                        .dynamicTypeSize(typeSize)
                }
        }
    }

    private var mainPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? FeedChrome.contentSpacing : 0) {
                composerRows
            }
            .feedPageContent(topGap: typeSize.isAccessibilitySize ? FeedChrome.contentTopGap : 0)
            .padding(.bottom, FeedChrome.sectionSpacing)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let failure {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                    Text(failure).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("compose.error")
                }
                .font(.subheadline).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .appNavigationChrome(backButton: usesParentNavigation, showsToolbarBackButton: false)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) { composerHeader }
    }

    @ViewBuilder
    private var composerRows: some View {
        if isSavedEditor {
            filterGroup {
                LabeledContent("组合名称") {
                    TextField("输入名称", text: $savedName)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("saved-editor.name")
                }
                .searchFilterRow()
            }
        }
        keywordCard
        if clearedDraft || !tagSearchExclusions.isEmpty || composerStatusSource != nil {
            composerStatus.searchComposerCardSurface(allowsMultiline: true)
        }
        if !isSavedEditor { favoriteDraftCard }
        filterCard
        if filtersExpanded { filterSections }
        if showsRecentSearches {
            Text("最近搜索")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 12)
                .padding(.vertical, FeedChrome.panelSpacing)
            recentSearchCards
        }
        clearCard
        if isSavedEditor {
            Button(role: .destructive) { confirmingPresetRemoval = true } label: {
                Text("删除组合").searchComposerCardSurface()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(editorOwner != library.owner)
            .accessibilityIdentifier("saved-editor.delete")
        }
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
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: FeedChrome.rowHeight, height: FeedChrome.rowHeight)
                        .contentShape(Rectangle())
                        .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 8)
                }
                    .buttonStyle(.plain)
                    .accessibilityLabel("搜索记录").accessibilityIdentifier("compose.records")
            }
        }
        .searchComposerCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose.keyword-card")
    }

    @ViewBuilder
    private var composerStatus: some View {
        if clearedDraft {
            Label(isSavedEditor ? "条件已清空，保存后更新此组合" : "已清空本次条件，点击“\(visibleConfirmationTitle)”后生效",
                  systemImage: "checkmark.circle")
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("compose.cleared-state")
        } else if !tagSearchExclusions.isEmpty {
            Text("原搜索已排除：\(tagSearchExclusions.map(\.label).joined(separator: "、"))。可在筛选条件中调整。")
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
        Button(action: openFilters) {
            HStack(spacing: FeedChrome.controlSpacing) {
                Text("筛选条件")
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("compose.filters.title")
                Spacer(minLength: 0)
                filterCardDetail
                Image(systemName: filtersExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .searchComposerCardSurface()
        }.accessibilityIdentifier("compose.filters")
            .accessibilityValue("\(filtersExpanded ? "已展开" : "已收起") · \(filterCount) · \(fullFilterSummary)")
            .accessibilityHint(filtersExpanded ? "收起筛选条件" : "展开查看全部筛选条件")
            .buttonStyle(.plain)
    }

    private var filterCardDetail: some View {
        ViewThatFits(in: .horizontal) {
            if !filtersExpanded, let query = try? draft.validatedQuery(),
               SearchPresentation.conditionCount(query) > 0 {
                let preview = SearchPresentation.presetPreview(query, includeText: false)
                HStack(spacing: FeedChrome.panelSpacing) {
                    if !preview.conditions.isEmpty {
                        Text(preview.conditions).truncationMode(.tail)
                            .accessibilityIdentifier("compose.filters.preview")
                    }
                    if !preview.limits.isEmpty {
                        Text(preview.limits).monospacedDigit().fixedSize()
                            .accessibilityIdentifier("compose.filters.limits")
                    }
                }
            }
            Text(filterCount).accessibilityIdentifier("compose.filters.count")
        }
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }

    private var favoriteDraftCard: some View {
        let saved = matchingFavorite != nil
        let label = saved ? "已存常用" : "存为常用"
        return Button(action: prepareFavorite) {
            HStack(spacing: FeedChrome.contentSpacing) {
                Image(systemName: saved ? "bookmark.fill" : "bookmark").accessibilityHidden(true)
                Text(label)
                Spacer(minLength: 0)
            }
            .searchComposerCardSurface()
        }
        .buttonStyle(.plain)
        .foregroundStyle(draft.hasConditions && !saved ? Color.accentColor : Color.secondary)
        .disabled(saved || !draft.hasConditions)
        .accessibilityValue(saved ? "已保存" : "未保存")
        .accessibilityIdentifier("compose.save-favorite")
    }

    private var clearCard: some View {
        Button { clearDraft() } label: {
            Text("清空本次条件").searchComposerCardSurface()
        }
            .buttonStyle(.plain)
            .disabled(!draft.hasConditions)
            .accessibilityIdentifier("compose.clear")
            .accessibilityHint(isSavedEditor ? "保存后更新此组合" : "只修改待搜索的条件，点击搜索后才生效")
    }

    private var composerHeader: some View {
        FloatingHeaderPanel(identifier: "compose.header") {
            FloatingPageTitleRow(title: isSavedEditor ? "编辑常用组合" : detailNavigationTitle ?? "搜索",
                                 identifier: "compose.title") {
                Button {
                    if let onCancel { onCancel() } else { dismiss() }
                } label: { Label("取消", systemImage: "xmark") }
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

    private var showsRecentSearches: Bool {
        !isSavedEditor && !filtersExpanded && !draft.hasConditions && !library.recentSearches.isEmpty
    }

    private var recentSearchCards: some View {
        ForEach(library.recentSearches.prefix(4)) { record in
            Button { load(LoadedSearchSource(record)) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(SearchPresentation.recordTitle(record.query)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    Spacer(minLength: 0)
                    Text(record.site == .ex ? "EX" : "EH").font(.caption).foregroundStyle(.secondary)
                }
                .searchComposerCardSurface()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search-history.recent.\(record.id)")
            .accessibilityHint("载入条件编辑")
        }
    }

    private var filterCount: String {
        guard let query = try? draft.validatedQuery() else { return "待检查" }
        let count = SearchPresentation.conditionCount(query)
        let scope = draft.site == .ex ? "EX" : "EH"
        return "\(scope) · \(count == 0 ? "不限" : "\(count) 项条件")"
    }

    private var fullFilterSummary: String {
        guard let query = try? draft.validatedQuery() else { return "请检查筛选条件" }
        return SearchPresentation.conditions(query, includeText: false)
    }

    private var composerStatusSource: LoadedSearchSource? {
        guard let loadedSource, loadedSource.kind == .recent else { return nil }
        return loadedSource
    }

    private var loadedStatus: String {
        return sourceModified ? "从最近搜索载入 · 已修改" : "从最近搜索载入"
    }

    @ViewBuilder private var filterSections: some View {
        filterGroup {
            LabeledContent {
                Picker("站点", selection: $draft.site) {
                    ForEach(GallerySite.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .searchPickerTypography()
                .accessibilityIdentifier("compose.site")
            } label: {
                Text("搜索范围").accessibilityAddTraits(.isHeader)
            }
            .searchFilterRow()
            Toggle("仅搜标题", isOn: $draft.query.titleOnly)
                .controlSize(.small)
                .searchFilterRow()
            Toggle("匹配完整短语", isOn: $draft.query.matchPhrase)
                .controlSize(.small)
                .searchFilterRow()
            LabeledContent("作者") {
                TextField("不限", text: Binding(get: { draft.query.artist }, set: { draft.query.replaceArtist($0) }), prompt: unlimitedPrompt)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing).accessibilityLabel("作者")
                    .accessibilityIdentifier("compose.artist")
            }
            .searchFilterRow()
        }

        filterGroup {
            tagConditionActions
            if commonTagsExpanded {
                ForEach(library.snapshot.favoriteTags) { tag in
                    let included = draft.query.rules.contains { $0.id == tag.id }
                    Button { addTag(tag) } label: {
                        TagListRowLabel(tag: tag, symbol: included ? "checkmark.circle.fill" : "plus.circle",
                                        emphasized: included)
                            .searchFilterRow()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(included)
                    .accessibilityValue(included ? "已添加" : "添加为包含条件")
                    .accessibilityIdentifier("compose.favorite-tag.\(tag.id)")
                }
            }
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

        categorySection

        filterGroup {
            LabeledContent("最低评分") {
                Picker("最低评分", selection: Binding(get: { draft.query.minRating ?? 0 }, set: { draft.query.minRating = $0 == 0 ? nil : $0 })) {
                    Text("不限").tag(0)
                    ForEach(2...5, id: \.self) { Text("\($0) 星").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .searchPickerTypography()
                .accessibilityIdentifier("compose.min-rating")
            }
            .searchFilterRow()
            LabeledContent("最少页数") {
                TextField("不限", text: $draft.minimumPagesText, prompt: unlimitedPrompt).keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing).accessibilityLabel("最少页数")
                    .accessibilityIdentifier("compose.min-pages")
            }
            .searchFilterRow()
            LabeledContent("最多页数") {
                TextField("不限", text: $draft.maximumPagesText, prompt: unlimitedPrompt).keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing).accessibilityLabel("最多页数")
                    .accessibilityIdentifier("compose.max-pages")
            }
            .searchFilterRow()
            LabeledContent("上传者") {
                TextField("不限", text: $draft.query.uploader, prompt: unlimitedPrompt)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .multilineTextAlignment(.trailing).accessibilityLabel("上传者")
                    .accessibilityIdentifier("compose.uploader")
            }
            .searchFilterRow()
            Toggle("必须有 torrent", isOn: $draft.query.requireTorrent).searchFilterRow()
            if let warning = (try? draft.queryWithPageRange())?.pageRangeWarning {
                Text(warning).font(.caption).foregroundStyle(.secondary).searchFilterRow()
                    .accessibilityIdentifier("compose.page-range-warning")
            }
        }
    }

    private var tagConditionActions: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            Button {
                inputFocused = false
                commonTagsExpanded = false
                tagEntry = true
            } label: {
                Text("添加标签").lineLimit(1).minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SearchFilterActionStyle())
            .accessibilityLabel("添加标签")
            .accessibilityHint("支持中文名和原名，可一次添加多个标签")
            .accessibilityIdentifier("compose.add-tag")

            Button {
                inputFocused = false
                commonTagsExpanded.toggle()
            } label: {
                HStack(spacing: FeedChrome.panelSpacing) {
                    Text("常用标签").lineLimit(1).minimumScaleFactor(0.8)
                    Image(systemName: commonTagsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SearchFilterActionStyle())
            .disabled(library.snapshot.favoriteTags.isEmpty)
            .accessibilityLabel("常用标签")
            .accessibilityValue(commonTagsExpanded ? "已展开" : "已收起")
            .accessibilityIdentifier("compose.common-tags")
        }
    }

    private func filterGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing, content: content)
            .padding(FeedChrome.panelSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .formRowSurface(outer: true)
            .padding(.vertical, FeedChrome.panelSpacing / 2)
    }

    private var categoryIDs: Set<Int> { Set(GalleryCategory.all.map(\.id)) }

    private var selectedCategoryCount: Int {
        categoryIDs.subtracting(draft.query.excludedCategories).count
    }

    private var categoryActions: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            Button { draft.query.excludedCategories.removeAll() } label: {
                Text("全选").frame(maxWidth: .infinity)
            }
            .buttonStyle(SearchFilterActionStyle(highlighted: true))
            .disabled(selectedCategoryCount == GalleryCategory.all.count)
            .accessibilityIdentifier("compose.categories.select-all")
            Button {
                draft.query.excludedCategories = categoryIDs.subtracting(draft.query.excludedCategories)
            } label: {
                Text("反选").frame(maxWidth: .infinity)
            }
            .buttonStyle(SearchFilterActionStyle())
            .accessibilityIdentifier("compose.categories.invert")
        }
    }

    private var categorySection: some View {
        filterGroup {
            categoryActions
            if selectedCategoryCount == 0 {
                Text("请至少选择一个画廊分类。")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("compose.categories.empty")
            }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("画廊分类")
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
        selectedCategoryCount == 0 || (isSavedEditor && (savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editorOwner != library.owner))
    }

    private var confirmationTitle: String {
        if isSavedEditor { return "保存" }
        return updatesResults ? "更新结果" : "搜索"
    }

    private var visibleConfirmationTitle: String {
        updatesResults && !isSavedEditor ? "更新" : confirmationTitle
    }

    private func load(_ source: LoadedSearchSource) {
        inputFocused = false
        draft = SearchDraft(query: source.query, site: source.site)
        loadedSource = source
        detailTagSource = nil
        failure = nil; clearedDraft = false
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func prepareFavorite() {
        do {
            let query = try draft.validatedQuery()
            guard query.hasSettings else { failure = "先输入关键词、标签或搜索设置，再存为常用。"; return }
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
            failure = library.error ?? "未能删除常用组合，请重试。"
            return
        }
        dismiss()
    }

    private func apply() {
        do {
            let query = try draft.validatedQuery()
            switch purpose {
            case let .search(onApply):
                let matchingSavedID = library.savedSearch(matching: query, site: draft.site)?.id
                inputFocused = false
                try onApply(query, draft.site, matchingSavedID)
            case let .editSaved(saved):
                guard let owner = editorOwner, owner == library.owner else { throw ViewerError.invalidQuery("账号已切换，请重新打开常用组合编辑。") }
                let name = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ViewerError.invalidQuery("请输入组合名称。") }
                guard let id = library.saveSearch(name: name, site: draft.site, query: query, replacing: saved.id, expectedOwner: owner),
                      let stored = library.snapshot.saved.first(where: { $0.id == id }), stored.query == query, stored.site == draft.site else {
                    throw ViewerError.invalidQuery(library.error ?? "组合未能保存，请重新打开后重试。")
                }
            }
            if dismissesOnApply { dismiss() }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? (error as? ViewerError)?.localizedDescription ?? "搜索条件无效"
        }
    }

    private func draftChanged() {
        failure = nil
        if draft.hasConditions { clearedDraft = false }
    }

    private func clearDraft() {
        inputFocused = false
        draft.clear()
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

private extension View {
    func searchPickerTypography() -> some View {
        // A menu Picker draws its summary at the native control size rather than the row font.
        scaleEffect(0.82, anchor: .trailing)
    }

    func searchComposerCardSurface(allowsMultiline: Bool = false) -> some View {
        modifier(SearchComposerCardSurface(allowsMultiline: allowsMultiline))
    }

    func searchFilterRow() -> some View {
        font(.footnote)
            .padding(.horizontal, FeedChrome.contentSpacing)
            .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
            .formRowSurface(shape: AppShape.control)
    }
}

private struct SearchFilterActionStyle: ButtonStyle {
    var highlighted = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let accented = highlighted && enabled
        configuration.label
            .font(FeedChrome.labelFont)
            .foregroundStyle(accented ? Color.accentColor : Color.primary)
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
                Color.clear.formRowSurface()
                    .padding(.vertical, inset)
            }
            .contentShape(Rectangle())
    }
}
