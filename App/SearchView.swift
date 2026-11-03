import SwiftUI
import ExViewerCore

private struct FavoriteSearchDraft: Identifiable {
    let id = UUID()
    let query: SearchQuery
    let site: GallerySite
    let replacing: UUID?
    let name: String

    init(query: SearchQuery, site: GallerySite, existing: SavedSearch?) {
        self.query = query; self.site = site; replacing = existing?.id
        name = existing?.name ?? String((query.text.isEmpty ? SearchPresentation.summary(query, site: site) : query.text).prefix(80))
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
            VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    let details = SearchPresentation.conditions(query)
                    if details != displayTitle && !details.isEmpty {
                        Text(details).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Text(site == .ex ? "EX" : "EH")
                        if let date { Text(date, style: .relative).lineLimit(1) }
                        Spacer(minLength: 8)
                        if let selection {
                            Label(selection, systemImage: selection == "已修改" ? "pencil.circle" : "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon).foregroundStyle(Color.accentColor)
                                .fixedSize(horizontal: true, vertical: false)
                        } else {
                            Image(systemName: "arrow.up.left")
                        }
                    }.font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5).frame(minHeight: 44).contentShape(Rectangle())
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
        .listRowBackground(selection == nil ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: .tertiarySystemFill))
    }
}

private enum SearchPresetTab: Hashable { case recent, favorite }
private enum SearchComposerPage: Hashable { case filters, records }
enum SearchComposerStart: Equatable { case main, filters, favorites }

private struct TagMatchPicker: View {
    @Binding var selection: TagMatch
    let identifier: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(TagMatch.allCases.enumerated()), id: \.offset) { index, mode in
                Button { selection = mode } label: {
                    Text(mode.name)
                        .font(.footnote.weight(selection == mode ? .semibold : .regular))
                        .foregroundStyle(selection == mode ? Color.accentColor : Color.primary)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == mode ? Color.accentColor.opacity(0.12) : Color.clear)
                                .padding(.vertical, typeSize.isAccessibilitySize ? 3 : 8)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .accessibilityIdentifier("\(identifier).\(index)")
            }
        }
        .padding(.horizontal, 3)
        .appControlSurface(verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

private struct SearchTagRuleRow: View {
    let tag: GalleryTag
    @Binding var match: TagMatch
    let matchIdentifier: String
    let removeIdentifier: String
    let removeLabel: String
    let onRemove: () -> Void
    @ScaledMetric(relativeTo: .caption) private var matchWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("匹配方式", selection: $match) {
                    ForEach(TagMatch.allCases, id: \.self) { Text($0.name).tag($0) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(match.name).font(.caption.weight(.medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .frame(width: matchWidth)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("匹配方式：\(tag.label)")
            .accessibilityValue(match.name)
            .accessibilityIdentifier(matchIdentifier)

            Text(tag.label)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .layoutPriority(1)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .appControlSurface()
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeLabel)
            .accessibilityIdentifier(removeIdentifier)
        }
        .padding(.leading, 4)
        .appControlSurface(selected: match != .exclude, verticalInset: 6)
    }
}

private struct SearchPresetsView: View {
    @Binding var tab: SearchPresetTab
    var source: LoadedSearchSource?
    var sourceModified: Bool
    var onLoad: (LoadedSearchSource) -> Void
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var favorite: FavoriteSearchDraft?
    @State private var editingSaved: SavedSearch?
    @State private var reordering = false
    @State private var reorderingOwner: String?
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                Picker("记录类型", selection: $tab) {
                    Text("最近搜索").tag(SearchPresetTab.recent)
                    Text("常用组合").tag(SearchPresetTab.favorite)
                }.pickerStyle(.segmented).accessibilityIdentifier("compose.records-tabs")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            if tab == .recent {
                if let error = library.searchHistoryError {
                    Section { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    if library.recentSearches.isEmpty {
                        Text("暂无搜索记录").foregroundStyle(.secondary).accessibilityIdentifier("search-history.empty")
                    }
                    ForEach(library.recentSearches) { record in
                        HStack(spacing: 8) {
                            SearchPresetRow(title: SearchPresentation.conditions(record.query), query: record.query,
                                            site: record.site, date: record.date, selection: selection(.recent, record.id)) {
                                onLoad(LoadedSearchSource(record))
                            }.accessibilityIdentifier("search-history.load.\(record.id)")
                            Button {
                                favorite = FavoriteSearchDraft(query: record.query, site: record.site,
                                    existing: library.savedSearch(matching: record.query, site: record.site))
                            } label: { Image(systemName: "bookmark").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("将这组条件存为常用")
                            .accessibilityIdentifier("search-history.save.\(record.id)")
                        }
                        .listRowBackground(selection(.recent, record.id) == nil ? Color(uiColor: .secondarySystemGroupedBackground) : Color(uiColor: .tertiarySystemFill))
                        .swipeActions { Button("删除", role: .destructive) { library.deleteRecentSearch(record.id) } }
                    }
                } footer: { Text("点选记录载入编辑，返回后点击“搜索”执行。") }
            } else {
                if let error = library.error { Section { Text(error).font(.subheadline).foregroundStyle(.red) } }
                Section {
                    if library.snapshot.saved.isEmpty {
                        Text("暂无常用组合").foregroundStyle(.secondary).accessibilityIdentifier("search-favorites.empty")
                    }
                    ForEach(library.snapshot.saved) { saved in
                        SearchPresetRow(title: saved.name, query: saved.query, site: saved.site,
                                        selection: favoriteSelection(saved), onEdit: { editingSaved = saved }, reordering: reordering) {
                            onLoad(LoadedSearchSource(saved))
                        }.accessibilityIdentifier("search-favorites.load.\(saved.id)")
                            .swipeActions { Button("删除", role: .destructive) { library.deleteSearch(saved.id) } }
                            .moveDisabled(!reordering)
                    }
                    .onMove { offsets, destination in
                        guard let owner = reorderingOwner,
                              library.moveSavedSearches(from: offsets, to: destination, expectedOwner: owner) else {
                            reordering = false; return
                        }
                    }
                } footer: { Text(reordering ? "拖动右侧把手调整顺序，顺序即时保存。" : "轻点载入条件，长按编辑；点“编辑顺序”可拖动排列。") }
            }
        }
        .environment(\.editMode, .constant(reordering ? .active : .inactive))
        .navigationTitle("记录与常用").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
        .toolbar {
            if tab == .recent {
                AppToolbarItem(placement: .primaryAction) {
                    Button("清空") { clearing = true }
                        .disabled(library.recentSearches.isEmpty && library.searchHistoryError == nil)
                        .accessibilityIdentifier("search-history.clear")
                }
            } else {
                AppToolbarItem(placement: .primaryAction) {
                    Button(reordering ? "完成" : "编辑顺序") {
                        reorderingOwner = library.owner
                        reordering.toggle()
                    }
                    .disabled(library.snapshot.saved.count < 2)
                    .accessibilityIdentifier("search-favorites.reorder")
                }
            }
        }
        .onChange(of: tab) { _, _ in reordering = false; reorderingOwner = nil }
        .onChange(of: library.owner) { _, _ in
            reordering = false; reorderingOwner = nil; editingSaved = nil; favorite = nil
        }
        .confirmationDialog("清空当前账号的搜索记录？常用组合会保留。", isPresented: $clearing, titleVisibility: .visible) {
            Button("清空搜索记录", role: .destructive) { library.clearSearchHistory() }
        }
        .sheet(item: $favorite) { target in
            SaveSearchSheet(query: target.query, site: target.site, replacing: target.replacing,
                            initialName: target.name) { _ in }
        }
        .sheet(item: $editingSaved) { saved in
            DiscoveryComposerView(editing: saved)
                .environmentObject(library).environmentObject(session).dynamicTypeSize(typeSize)
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

struct SaveSearchSheet: View {
    var query: SearchQuery
    var site: GallerySite
    var replacing: UUID?
    var onSaved: (UUID) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var failure: String?
    init(query: SearchQuery, site: GallerySite, replacing: UUID?, initialName: String, onSaved: @escaping (UUID) -> Void) {
        self.query = query; self.site = site; self.replacing = replacing; self.onSaved = onSaved; _name = State(initialValue: initialName)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("组合名称", text: $name).accessibilityIdentifier("search.save.name") }
                Section("保存内容") {
                    LabeledContent("站点", value: site.name)
                    LabeledContent("条件数量", value: String(query.count))
                    Text((try? query.expression()) ?? "请先调整搜索条件").font(.caption).foregroundStyle(.secondary)
                    Text("关键词、标签、分类、评分与页数条件会一起保存。").font(.caption).foregroundStyle(.secondary)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
                if replacing != nil { Section { Button("另存为新组合") { save(replacing: nil) } } }
            }.navigationTitle(replacing == nil ? "保存搜索组合" : "编辑搜索组合").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
                .toolbar { AppToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; AppToolbarItem(placement: .confirmationAction, tone: .accent) { Button("保存") { save(replacing: replacing) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("search.save.confirm") } }
        }
    }
    private func save(replacing: UUID?) {
        do {
            _ = try query.url(site: site)
            guard let id = library.saveSearch(name: name, site: site, query: query, replacing: replacing), let saved = library.snapshot.saved.first(where: { $0.id == id }), saved.query == query, saved.site == site else { failure = library.error ?? "保存未完成，请检查名称或已保存组合数量。"; return }
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
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var categoryIconWidth: CGFloat = 18
    @State private var draftQuery: SearchQuery
    @State private var draftSite: GallerySite
    @State private var draftSavedID: UUID?
    @State private var inputText: String
    @State private var minimumPagesText: String
    @State private var maximumPagesText: String
    @State private var tagEntry = false
    @State private var failure: String?
    @State private var favorite: FavoriteSearchDraft?
    @State private var loadedSource: LoadedSearchSource?
    @State private var detailTagSource: DetailTagSearchDraft?
    @State private var clearedDraft = false
    @State private var savedFeedback = false
    @State private var path: [SearchComposerPage] = []
    @State private var recordsTab: SearchPresetTab = .recent
    @State private var savedName: String
    @State private var editorOwner: String?
    @FocusState private var inputFocused: Bool

    init(query: SearchQuery, site: GallerySite, savedID: UUID?, startAt: SearchComposerStart = .main, loadedPreset: SavedSearch? = nil,
         detailTagSource: DetailTagSearchDraft? = nil,
         onApply: @escaping (SearchQuery, GallerySite, UUID?) throws -> Void) {
        self.init(query: query, site: site, savedID: savedID, startAt: startAt, loadedPreset: loadedPreset, detailTagSource: detailTagSource, purpose: .search(onApply))
    }

    init(editing saved: SavedSearch) {
        self.init(query: saved.query, site: saved.site, savedID: saved.id, startAt: .main, loadedPreset: nil, detailTagSource: nil, purpose: .editSaved(saved))
    }

    private init(query: SearchQuery, site: GallerySite, savedID: UUID?, startAt: SearchComposerStart, loadedPreset: SavedSearch?, detailTagSource: DetailTagSearchDraft?, purpose: SearchComposerPurpose) {
        self.purpose = purpose
        if case let .editSaved(saved) = purpose { _savedName = State(initialValue: saved.name) }
        else { _savedName = State(initialValue: "") }
        _draftQuery = State(initialValue: query)
        _draftSite = State(initialValue: site)
        _draftSavedID = State(initialValue: savedID)
        _inputText = State(initialValue: Self.singleLineText(query.text))
        _minimumPagesText = State(initialValue: query.minPages.map(String.init) ?? "")
        _maximumPagesText = State(initialValue: query.maxPages.map(String.init) ?? "")
        _path = State(initialValue: startAt == .filters ? [.filters] : startAt == .favorites ? [.records] : [])
        _recordsTab = State(initialValue: startAt == .favorites ? .favorite : .recent)
        _loadedSource = State(initialValue: loadedPreset.map { LoadedSearchSource($0) })
        _detailTagSource = State(initialValue: detailTagSource)
    }

    var body: some View {
        NavigationStack(path: $path) {
            mainPage.navigationDestination(for: SearchComposerPage.self) { page in
                switch page {
                case .filters: filtersPage
                case .records:
                    SearchPresetsView(tab: $recordsTab, source: loadedSource, sourceModified: sourceModified) { source in
                        load(source); path.removeAll()
                    }
                }
            }
        }
        .onAppear { if isSavedEditor && editorOwner == nil { editorOwner = library.owner } }
        .onChange(of: library.owner) { _, owner in
            if isSavedEditor && editorOwner != owner { failure = "账号已切换，请重新打开常用组合编辑。" }
        }
        .onChange(of: path) { _, value in
            if !value.isEmpty { inputFocused = false; failure = nil }
        }
        .onChange(of: inputText) { _, _ in draftChanged() }
        .onChange(of: draftQuery) { _, _ in draftChanged() }
        .onChange(of: draftSite) { _, _ in draftChanged() }
        .onChange(of: minimumPagesText) { _, _ in draftChanged() }
        .onChange(of: maximumPagesText) { _, _ in draftChanged() }
        .onChange(of: savedName) { _, _ in draftChanged() }
        .sheet(isPresented: $tagEntry) {
            TagEntryView(editing: draftQuery.rules) { rules in draftQuery.rules = rules }
                .environmentObject(library).environmentObject(session)
        }
        .sheet(item: $favorite) { target in
            SaveSearchSheet(query: target.query, site: target.site, replacing: target.replacing,
                            initialName: target.name) { id in
                draftSavedID = id
                if let saved = library.snapshot.saved.first(where: { $0.id == id }) {
                    loadedSource = LoadedSearchSource(saved); savedFeedback = true
                    detailTagSource = nil
                }
            }
        }
    }

    private var mainPage: some View {
        Form {
            if isSavedEditor {
                Section("组合名称") {
                    TextField("名称", text: $savedName).accessibilityIdentifier("saved-editor.name")
                }
            }
            Section {
                TextField("关键词或标题", text: singleLineInput)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .submitLabel(.done).onSubmit { inputFocused = false }
                    .focused($inputFocused).accessibilityIdentifier("compose.text")
                    .accessibilityHint("也支持 title:、namespace:tag、~任一、-排除和 uploader: 条件。")
            } footer: {
                if clearedDraft {
                    Label(isSavedEditor ? "条件已清空，保存后更新此组合" : "已清空本次条件，点击“搜索”后生效", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("compose.cleared-state")
                } else if let source = detailTagSource {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(source.statusTitle, systemImage: source.origin == .newSearch ? "magnifyingglass" : "plus.magnifyingglass")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("compose.tag-source")
                        Text(source.origin == .newSearch ? "\(source.selectedCount) 个所选标签，尚未搜索" : "新增 \(source.addedCount) 个标签，原条件已保留，尚未搜索")
                        if let summary = source.sourceSummary {
                            Text("原搜索：\(summary)").lineLimit(2)
                                .accessibilityIdentifier("compose.tag-original")
                        }
                        if !tagSearchExclusions.isEmpty {
                            Text("原搜索已排除：\(tagSearchExclusions.map(\.label).joined(separator: "、"))。可在筛选条件中调整。")
                                .lineLimit(2).accessibilityIdentifier("compose.tag-exclusions")
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                } else if let source = loadedSource {
                    Label(loadedStatus, systemImage: sourceModified ? "pencil.circle" : "checkmark.circle")
                        .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("compose.loaded-state")
                        .accessibilityValue(sourceModified ? "已修改" : savedFeedback ? "已保存" : "已载入")
                        .accessibilityHint(source.title)
                }
            }
            Section {
                Button(action: openFilters) {
                    HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        if typeSize.isAccessibilitySize {
                            Label("筛选条件", systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
                            Text(filterCount).font(.subheadline).foregroundStyle(.secondary)
                        } else { HStack {
                            Label("筛选条件", systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon)
                            Spacer(minLength: 8)
                            Text(filterCount).font(.subheadline).foregroundStyle(.secondary)
                        } }
                        if !filterSummary.isEmpty {
                            Text(filterSummary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                .accessibilityIdentifier("compose.current-summary")
                        }
                    }.padding(.vertical, 3)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }.accessibilityIdentifier("compose.filters")
                    .accessibilityValue("\(filterCount) · \(filterSummary)")
                    .buttonStyle(.plain)
                if !isSavedEditor {
                    NavigationLink(value: SearchComposerPage.records) {
                        Label("记录与常用", systemImage: "clock.arrow.circlepath").labelStyle(.titleAndIcon)
                    }.accessibilityIdentifier("compose.records")
                }
            }
            Section {
                Button("清空本次条件") { clearDraft() }
                    .disabled(!hasDraftConditions)
                    .accessibilityIdentifier("compose.clear")
                    .accessibilityHint(isSavedEditor ? "保存后更新此组合" : "只修改待搜索的条件，点击搜索后才生效")
            }
            if let failure { Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("compose.error") } }
        }
        .navigationTitle(isSavedEditor ? "编辑常用组合" : detailTagSource?.navigationTitle ?? "组合搜索").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
        .toolbar {
            if path.isEmpty { AppToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier(isSavedEditor ? "saved-editor.cancel" : "compose.cancel")
            } }
            if path.last != .records { AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                Button(isSavedEditor ? "保存" : "搜索") { apply() }.fontWeight(.semibold)
                    .accessibilityIdentifier(isSavedEditor ? "saved-editor.save" : "compose.apply")
                    .disabled(submissionDisabled)
            } }
            if path.isEmpty && !isSavedEditor { AppToolbarItem(placement: .primaryAction) {
                Button { prepareFavorite() } label: { Image(systemName: "bookmark") }
                    .accessibilityLabel("保存当前条件为常用").accessibilityIdentifier("compose.save-favorite")
            } }
        }
    }

    private var filterCount: String {
        guard let query = try? proposedQuery() else { return "待检查" }
        let count = query.count - (query.text.isEmpty ? 0 : 1) + (query.titleOnly ? 1 : 0) + (query.matchPhrase ? 1 : 0)
        let scope = draftSite == .ex ? "EX" : "EH"
        return "\(scope) · \(count == 0 ? "不限" : "\(count) 项")"
    }

    private var filterSummary: String {
        guard var query = try? proposedQuery() else { return "请检查筛选条件" }
        query.text = ""
        return SearchPresentation.conditions(query)
    }

    private var loadedStatus: String {
        let origin = savedFeedback ? "已保存为常用" : loadedSource?.kind == .recent ? "从最近搜索载入" : "从常用组合载入"
        let count = (try? proposedQuery()).map { "\($0.count) 项设置" } ?? "设置待检查"
        return "\(origin) · \(count)\(sourceModified ? " · 已修改" : "")"
    }

    private var filtersPage: some View {
        Form {
                Section("搜索范围") {
                    Picker("站点", selection: $draftSite) { ForEach(GallerySite.allCases) { Text($0.name).tag($0) } }
                    Toggle("关键词只匹配标题", isOn: $draftQuery.titleOnly)
                    Toggle("关键词按完整短语匹配", isOn: $draftQuery.matchPhrase)
                    HStack(spacing: 8) {
                        Image(systemName: "person").foregroundStyle(.secondary)
                        TextField("作者 artist", text: Binding(get: { draftQuery.artist }, set: { draftQuery.replaceArtist($0) }))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("compose.artist")
                    }
                }

                Section("标签条件") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Button { tagEntry = true } label: {
                                Text("添加标签")
                            }
                            .buttonStyle(FeedHeaderButtonStyle())
                            .accessibilityLabel("添加标签")
                            .accessibilityHint("支持中文名和原名，可一次添加多个标签")
                            .accessibilityIdentifier("compose.add-tag")

                            Menu {
                                ForEach(library.snapshot.favoriteTags) { tag in
                                    let included = draftQuery.rules.contains { $0.id == tag.id }
                                    Button { addTag(tag) } label: {
                                        if included { Label(tag.label, systemImage: "checkmark") }
                                        else { Text(tag.label) }
                                    }
                                    .disabled(included)
                                    .accessibilityValue(included ? "已添加" : "添加为包含条件")
                                    .accessibilityIdentifier("compose.favorite-tag.\(tag.id)")
                                }
                            } label: {
                                Text("常用标签")
                            }
                            .buttonStyle(FeedHeaderButtonStyle())
                            .disabled(library.snapshot.favoriteTags.isEmpty)
                            .accessibilityLabel("常用标签")
                            .accessibilityIdentifier("compose.common-tags")
                        }
                        ForEach($draftQuery.rules) { $rule in
                            SearchTagRuleRow(tag: rule.tag, match: $rule.match,
                                             matchIdentifier: "compose.rule.match.\(rule.id)",
                                             removeIdentifier: "compose.rule.remove.\(rule.id)",
                                             removeLabel: "移除 \(rule.tag.label)") {
                                draftQuery.rules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }

                categorySection

                Section("评分、页数与上传者") {
                        Picker("最低评分", selection: Binding(get: { draftQuery.minRating ?? 0 }, set: { draftQuery.minRating = $0 == 0 ? nil : $0 })) {
                            Text("不限").tag(0); ForEach(2...5, id: \.self) { Text("\($0) 星").tag($0) }
                        }.accessibilityIdentifier("compose.min-rating")
                        LabeledContent("最少页数") {
                            TextField("不限", text: $minimumPagesText).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).accessibilityLabel("最少页数")
                                .accessibilityIdentifier("compose.min-pages")
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                        LabeledContent("最多页数") {
                            TextField("不限", text: $maximumPagesText).keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing).accessibilityLabel("最多页数")
                                .accessibilityIdentifier("compose.max-pages")
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
                        TextField("上传者 uploader（可选）", text: $draftQuery.uploader).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityIdentifier("compose.uploader")
                        Toggle("必须有 torrent", isOn: $draftQuery.requireTorrent)
                        if let warning = draftQuery.pageRangeWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
                }

        }
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
        .navigationTitle("筛选条件").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
        .toolbar {
            AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                Button(isSavedEditor ? "保存" : "搜索") { apply() }.fontWeight(.semibold)
                    .accessibilityIdentifier(isSavedEditor ? "saved-editor.save" : "compose.apply")
                    .disabled(submissionDisabled)
            }
        }
    }

    private var categoryIDs: Set<Int> { Set(GalleryCategory.all.map(\.id)) }

    private var selectedCategoryCount: Int {
        categoryIDs.subtracting(draftQuery.excludedCategories).count
    }

    private var categoryCountLabel: some View {
        Text("已选 \(selectedCategoryCount)/\(GalleryCategory.all.count)")
            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityIdentifier("compose.categories.count")
    }

    private var categoryActions: some View {
        HStack(spacing: 16) {
            Button { draftQuery.excludedCategories.removeAll() } label: {
                Text("全选").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(selectedCategoryCount == GalleryCategory.all.count)
            .accessibilityIdentifier("compose.categories.select-all")
            Button {
                draftQuery.excludedCategories = categoryIDs.subtracting(draftQuery.excludedCategories)
            } label: {
                Text("反选").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("compose.categories.invert")
        }
        .font(.subheadline).buttonStyle(FeedHeaderButtonStyle())
    }

    private var categorySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 0) {
                        categoryCountLabel
                        categoryActions
                    }
                } else {
                    HStack(spacing: 12) {
                        categoryCountLabel
                        Spacer(minLength: 8)
                        categoryActions
                    }
                }
                if selectedCategoryCount == 0 {
                    Text("请至少选择一个画廊分类。")
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("compose.categories.empty")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 8) {
                    ForEach(GalleryCategory.all) { category in
                        let excluded = draftQuery.excludedCategories.contains(category.id)
                        Button {
                            if excluded { draftQuery.excludedCategories.remove(category.id) }
                            else { draftQuery.excludedCategories.insert(category.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: excluded ? "circle" : "checkmark.circle.fill")
                                    .frame(width: categoryIconWidth).accessibilityHidden(true)
                                Text(category.name).lineLimit(1).minimumScaleFactor(0.85)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.subheadline)
                            .foregroundStyle(excluded ? Color.secondary : Color.accentColor)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .appControlSurface(selected: !excluded, verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(category.name)
                        .accessibilityIdentifier("compose.category.\(category.id)")
                        .accessibilityValue(excluded ? "未选择" : "已选择")
                        .accessibilityAddTraits(excluded ? [] : .isSelected)
                    }
                }
            }
        } header: {
            Text("画廊分类")
        } footer: {
            Text("选中的分类参与搜索。")
        }
    }

    private var sourceModified: Bool {
        guard let source = loadedSource else { return false }
        guard let current = try? proposedQuery(),
              let currentKey = try? RecentSearchRecord.requestKey(site: draftSite, query: current),
              let baselineKey = try? RecentSearchRecord.requestKey(site: source.site, query: source.query) else { return true }
        return currentKey != baselineKey
    }

    private var tagSearchExclusions: [GalleryTag] {
        guard let source = detailTagSource else { return [] }
        let query = (try? proposedQuery()) ?? draftQuery
        return query.rules.filter { source.originalExclusions.contains($0.id) && $0.match == .exclude }.map(\.tag)
    }

    private var isSavedEditor: Bool {
        if case .editSaved = purpose { return true }; return false
    }

    private var submissionDisabled: Bool {
        selectedCategoryCount == 0 || (isSavedEditor && (savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editorOwner != library.owner))
    }

    private static func singleLineText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private var singleLineInput: Binding<String> {
        Binding(get: { inputText }, set: { inputText = Self.singleLineText($0) })
    }

    private func load(_ source: LoadedSearchSource) {
        inputFocused = false
        draftQuery = source.query; draftSite = source.site
        draftSavedID = source.kind == .favorite ? source.id : nil
        inputText = Self.singleLineText(source.query.text)
        minimumPagesText = source.query.minPages.map(String.init) ?? ""
        maximumPagesText = source.query.maxPages.map(String.init) ?? ""
        loadedSource = source
        detailTagSource = nil
        failure = nil; clearedDraft = false; savedFeedback = false
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func prepareFavorite() {
        do {
            let query = try proposedQuery()
            guard query.hasSettings else { failure = "先输入关键词、标签或搜索设置，再存为常用。"; return }
            inputFocused = false
            let original = draftSavedID.flatMap { id in library.snapshot.saved.first(where: { $0.id == id }) }
            favorite = FavoriteSearchDraft(query: query, site: draftSite,
                                           existing: original ?? library.savedSearch(matching: query, site: draftSite))
        } catch { failure = (error as? LocalizedError)?.errorDescription ?? "搜索条件无效" }
    }

    private func addTag(_ tag: GalleryTag) {
        guard !draftQuery.rules.contains(where: { $0.id == tag.id }) else { return }
        draftQuery.rules.append(.init(tag: tag))
    }

    private func apply() {
        do {
            let query = try proposedQuery()
            switch purpose {
            case let .search(onApply):
                let matchingSavedID = library.savedSearch(matching: query, site: draftSite)?.id
                try onApply(query, draftSite, matchingSavedID)
            case let .editSaved(saved):
                guard let owner = editorOwner, owner == library.owner else { throw ViewerError.invalidQuery("账号已切换，请重新打开常用组合编辑。") }
                let name = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { throw ViewerError.invalidQuery("请输入组合名称。") }
                guard let id = library.saveSearch(name: name, site: draftSite, query: query, replacing: saved.id, expectedOwner: owner),
                      let stored = library.snapshot.saved.first(where: { $0.id == id }), stored.query == query, stored.site == draftSite else {
                    throw ViewerError.invalidQuery(library.error ?? "组合未能保存，请重新打开后重试。")
                }
            }
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? (error as? ViewerError)?.localizedDescription ?? "搜索条件无效"
        }
    }

    private var hasDraftConditions: Bool {
        var filters = draftQuery; filters.text = ""
        return !inputText.isEmpty || filters.hasSettings || filters.titleOnly || filters.matchPhrase ||
            !minimumPagesText.isEmpty || !maximumPagesText.isEmpty
    }

    private func draftChanged() {
        failure = nil
        if hasDraftConditions { clearedDraft = false }
    }

    private func clearDraft() {
        inputFocused = false; draftQuery = SearchQuery(); inputText = ""
        minimumPagesText = ""; maximumPagesText = ""; draftSavedID = nil
        detailTagSource = nil
        failure = nil; clearedDraft = true
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func openFilters() {
        do {
            let parsed = try SearchInputParser.parse(inputText, preserving: draftQuery)
            draftQuery = parsed.query; inputText = parsed.query.text
            path.append(.filters)
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "搜索条件无效"
        }
    }

    private func proposedQuery() throws -> SearchQuery {
        var proposed = draftQuery
        func page(_ text: String) throws -> Int? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return nil }
            guard let number = Int(value), number >= 0 else { throw ViewerError.invalidQuery("页数须为非负整数。") }
            return number
        }
        proposed.minPages = try page(minimumPagesText); proposed.maxPages = try page(maximumPagesText)
        proposed.artist = proposed.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        proposed.uploader = proposed.uploader.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try SearchInputParser.parse(inputText, preserving: proposed)
        _ = try parsed.query.url(site: draftSite)
        return parsed.query
    }
}

private struct PendingTagEntry: Identifiable {
    let tag: GalleryTag
    var match: TagMatch
    let origin: String
    var status: String
    var warning: String? = nil
    var id: String { tag.id }
}

struct TagEntryView: View {
    private var onCommit: ([TagRule]) -> Void
    private let allowsEmptyCommit: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var session: SiteSession
    @State private var text = ""
    @State private var namespace = "all"
    @State private var match: TagMatch = .all
    @StateObject private var suggestions = TagSuggestionModel()
    @State private var selected: TagSuggestion?
    @State private var verification: TagVerification = .unverified
    @State private var verificationTasks: [String: Task<Void, Never>] = [:]
    @State private var pending: [PendingTagEntry] = []
    @FocusState private var editingText: Bool
    private let namespaces = ["artist", "group", "parody", "character", "language", "cosplayer", "location", "female", "male", "mixed", "other", "reclass"]

    init(onSelect: @escaping (GalleryTag, TagMatch) -> Void) {
        onCommit = { rules in rules.forEach { onSelect($0.tag, $0.match) } }
        allowsEmptyCommit = false
    }

    init(editing rules: [TagRule], defaultMatch: TagMatch = .all, onCommit: @escaping ([TagRule]) -> Void) {
        self.onCommit = onCommit
        allowsEmptyCommit = !rules.isEmpty
        _match = State(initialValue: defaultMatch)
        _pending = State(initialValue: rules.map { PendingTagEntry(tag: $0.tag, match: $0.match, origin: "当前搜索", status: "已在本次搜索条件中") })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("标签条件") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            namespaceButton("all", title: "全部")
                            ForEach(namespaces, id: \.self) { value in namespaceButton(value, title: namespaceTitle(value)) }
                        }
                    }
                    .scrollClipDisabled()
                    .accessibilityIdentifier("tag.namespace-filter")
                    TextField("中文名或标签原名", text: $text)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("tag.name")
                        .focused($editingText).submitLabel(.done).onSubmit { editingText = false }
                        .accessibilityHint("标签查找忽略大小写，支持输入名称片段。中文在本地词库匹配；英文另请求站点前缀候选。")
                    TagMatchPicker(selection: $match, identifier: "tag.match")
                }

                if !pending.isEmpty {
                    Section("已选标签（\(pending.count)）") {
                        ForEach($pending) { $entry in
                            VStack(alignment: .leading, spacing: 0) {
                                SearchTagRuleRow(tag: entry.tag, match: $entry.match,
                                                 matchIdentifier: "tag.pending.match.\(entry.id)",
                                                 removeIdentifier: "tag.pending.remove.\(entry.id)",
                                                 removeLabel: "移除待添加标签 \(entry.tag.label)") {
                                    removePending(entry.id)
                                }
                                if let warning = entry.warning {
                                    Label(warning, systemImage: "exclamationmark.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 8).padding(.bottom, 4)
                                        .accessibilityIdentifier("tag.pending.warning.\(entry.id)")
                                }
                            }
                            .padding(.horizontal, 6)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .accessibilityElement(children: .contain)
                            .accessibilityValue(entry.status)
                            .accessibilityIdentifier("tag.pending.row.\(entry.id)")
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        }
                    }
                }

                Section("建议") {
                    if suggestions.catalog == nil {
                        Text("中文词库不可用，仍可按原名查询。")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag.dictionary-unavailable")
                    }
                    if suggestions.state == .loading {
                        HStack(spacing: 8) { ProgressView(); Text("正在查找标签建议…").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let message = suggestions.state.message {
                        Text(message).font(.caption).foregroundStyle(suggestions.state.isFailure ? Color.red : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("tag.suggestion-status")
                    }
                    ForEach(suggestions.items) { item in
                        let pendingEntry = pending.first(where: { $0.id == item.id })
                        Button { select(item) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let chinese = item.chineseName, !chinese.isEmpty {
                                        Text(chinese).font(.body.weight(.medium)).foregroundStyle(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Text(item.tag.name).font(.body).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("\(namespaceTitle(item.tag.namespace)) · \(item.tag.namespace)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(sourceLabel(item.source)).font(.caption).foregroundStyle(.secondary)
                                        if let master = item.relatedMaster {
                                            Text("master: \(master.label)").font(.caption).foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    if selected?.id == item.id {
                                        Text(verificationLabel)
                                            .font(.caption).foregroundStyle(verification == .verified ? Color.green : Color.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                if pendingEntry != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.source == .unsupported)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
                        .listRowBackground(pendingEntry == nil ? Color(uiColor: .secondarySystemGroupedBackground) : Color.accentColor.opacity(0.08))
                        .accessibilityHint(pendingEntry == nil ? "点按加入待添加标签" : "再次点按取消选择")
                        .accessibilityIdentifier("tag.suggestion.\(item.id)")
                        .accessibilityValue("\(sourceLabel(item.source)); \(pendingEntry.map { "已加入待添加；\($0.status)" } ?? verificationLabelFor(item))")
                        .accessibilityAddTraits(pendingEntry == nil ? [] : .isSelected)
                    }
                    if suggestions.items.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && suggestions.state != .loading {
                        Text(namespace == "all" ? "没有匹配项。选择命名空间后可明确使用未验证输入。" : "没有匹配项。可明确使用未验证输入。")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("tag.no-results")
                    }
                }

                if !library.snapshot.favoriteTags.isEmpty {
                    Section("本机常用标签") {
                        ForEach(library.snapshot.favoriteTags) { tag in
                            Button {
                                select(TagSuggestion(tag: tag, source: .saved, chineseName: suggestions.catalog?.translation(for: tag), relatedMaster: nil))
                            } label: {
                                HStack(spacing: 8) {
                                    Text(tag.namespace).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(tag.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: pending.contains(where: { $0.id == tag.id }) ? "checkmark.circle.fill" : "plus.circle")
                                        .foregroundStyle(pending.contains(where: { $0.id == tag.id }) ? Color.accentColor : Color.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tag.favorite.\(tag.id)")
                            .accessibilityValue(pending.contains(where: { $0.id == tag.id }) ? "本机常用；已加入待添加" : "本机常用；站点未验证")
                            .accessibilityHint(pending.contains(where: { $0.id == tag.id }) ? "再次点按取消选择" : "点按加入待添加标签")
                            .accessibilityAddTraits(pending.contains(where: { $0.id == tag.id }) ? .isSelected : [])
                        }
                    }
                }

                if let manualTag {
                    Section("未验证输入") {
                        LabeledContent("原名", value: manualTag.label)
                        Text("此输入未由站点确认。添加后仍会标为未验证。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("添加未验证标签") { stageManualTag() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("tag.stage")
                    }
                }
                if let catalog = suggestions.catalog {
                    Section {
                        DisclosureGroup {
                            Text(catalog.information).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("tag.dictionary-info")
                        } label: { Text("词库来源与覆盖").accessibilityIdentifier("tag.dictionary-disclosure") }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .listSectionSpacing(16)
            .navigationTitle("添加标签").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("tag.cancel")
                }
                AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                    Button("完成 \(pending.count)") {
                        onCommit(pending.map { TagRule(tag: $0.tag, match: $0.match) })
                        dismiss()
                    }
                    .disabled(pending.isEmpty && !allowsEmptyCommit)
                    .accessibilityLabel("完成，\(pending.count) 个标签")
                    .accessibilityIdentifier("tag.confirm")
                }
            }
            .onAppear { updateSuggestions() }
            .onChange(of: text) { _, _ in resetSelectionAndUpdate() }
            .onChange(of: namespace) { _, _ in resetSelectionAndUpdate() }
            .onChange(of: session.generation) { _, _ in
                verificationTasks.values.forEach { $0.cancel() }
                verificationTasks.removeAll()
                suggestions.sessionChanged()
                for index in pending.indices where pending[index].origin != "E-Hentai 站点候选" {
                    pending[index].status = "\(pending[index].origin)；会话已变化，未完成核验"
                }
                selected = nil; verification = .unverified
                updateSuggestions()
            }
            .onDisappear { verificationTasks.values.forEach { $0.cancel() }; suggestions.cancel() }
        }
    }

    private var manualTag: GalleryTag? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, namespace != "all" else { return nil }
        return GalleryTag(namespace: namespace, name: value)
    }

    private func stageManualTag() {
        guard let tag = manualTag, TagSuggestionRequest.isSelectable(tag) else { return }
        upsertPending(tag, origin: "手输标签，站点未验证", status: "未验证输入")
        clearInputForNextTag()
    }

    private var verificationLabel: String {
        if selected?.source == .qaFixture && verification == .verified {
            return "QA fixture模拟站点匹配；不代表真实站点响应"
        }
        let origin = selected.map { sourceLabel($0.source) } ?? "标签"
        switch verification {
        case .checking: return "\(origin)；正在向 E-Hentai 精确核验…"
        case .verified: return selected?.source == .site ? "站点候选" : "站点已匹配 · 来源：\(origin)"
        case .notFound: return "站点未匹配；\(origin)"
        case .failed(let reason): return "\(reason)；来源：\(origin)"
        case .unverified: return "\(origin)；站点未验证"
        }
    }

    private func verificationLabelFor(_ item: TagSuggestion) -> String {
        guard selected?.id == item.id else {
            switch item.source {
            case .site: return "站点候选"
            case .cached: return "站点缓存，未实时验证"
            case .dictionary: return "词库匹配，站点未验证"
            case .saved: return "本机常用，未核验"
            case .unsupported: return "站点返回未支持类型，不可提交"
            case .qaFixture: return "QA 样例，未核验"
            }
        }
        return verificationLabel
    }

    private func sourceLabel(_ source: TagSuggestion.Source) -> String {
        switch source {
        case .site: return "E-Hentai 站点候选"
        case .cached: return "站点缓存候选"
        case .dictionary: return "本地词库"
        case .saved: return "本机常用标签"
        case .unsupported: return "站点返回未支持类型，不可提交"
        case .qaFixture: return "QA 样例，不是站点匹配"
        }
    }

    private func namespaceTitle(_ value: String) -> String {
        ["artist": "作者", "group": "社团", "parody": "系列", "character": "角色", "language": "语言",
         "cosplayer": "扮演者", "location": "地点", "female": "女性", "male": "男性", "mixed": "混合",
         "other": "其他", "reclass": "重分类"][value] ?? value
    }

    private func namespaceButton(_ value: String, title: String) -> some View {
        let isSelected = namespace == value
        return Button { namespace = value } label: {
            Text(title).font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 10).frame(minHeight: 44)
                .appControlSurface(selected: isSelected, verticalInset: typeSize.isAccessibilitySize ? 0 : 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .accessibilityLabel("标签命名空间：\(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("tag.namespace.\(value)")
    }

    private func select(_ item: TagSuggestion) {
        guard item.source != .unsupported, TagSuggestionRequest.isSelectable(item.tag) else { return }
        if pending.contains(where: { $0.id == item.id }) {
            removePending(item.id)
            return
        }
        verificationTasks[item.id]?.cancel()
        selected = item
        switch item.source {
        case .site:
            verification = .verified
            upsertPending(item.tag, origin: sourceLabel(item.source), status: "站点候选")
        case .qaFixture:
            verification = .verified
            upsertPending(item.tag, origin: "QA 样例，非真实站点匹配", status: "QA 样例，非真实站点匹配")
        case .unsupported: return
        case .cached, .dictionary, .saved:
            suggestions.cancel()
            verification = .checking
            let id = item.id
            upsertPending(item.tag, origin: sourceLabel(item.source), status: "\(sourceLabel(item.source))；正在精确核验")
            let sessionGeneration = session.generation
            verificationTasks[id] = Task {
                let result = await suggestions.verify(item.tag, session: session, qa: AppMode.qa)
                guard !Task.isCancelled, sessionGeneration == session.generation,
                      let index = pending.firstIndex(where: { $0.id == id }) else { return }
                pending[index].status = verificationStatus(result, origin: pending[index].origin)
                switch result {
                case .notFound: pending[index].warning = "站点未匹配，可修改标签或保留当前输入。"
                case .failed(let reason): pending[index].warning = reason
                default: pending[index].warning = nil
                }
                verificationTasks[id] = nil
                if selected?.id == id { verification = result }
            }
        }
    }

    private func removePending(_ id: String) {
        verificationTasks[id]?.cancel()
        verificationTasks[id] = nil
        pending.removeAll { $0.id == id }
        if selected?.id == id { selected = nil; verification = .unverified }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func resetSelectionAndUpdate() {
        selected = nil; verification = .unverified
        updateSuggestions()
    }

    private func upsertPending(_ tag: GalleryTag, origin: String, status: String) {
        if let index = pending.firstIndex(where: { $0.id == tag.id }) {
            pending[index].match = match
        } else {
            pending.append(PendingTagEntry(tag: tag, match: match, origin: origin, status: status))
        }
    }

    private func clearInputForNextTag() {
        selected = nil
        verification = .unverified
        text = ""
        editingText = true
        updateSuggestions()
    }

    private func verificationStatus(_ result: TagVerification, origin: String) -> String {
        switch result {
        case .checking: return "\(origin)；正在核验"
        case .verified: return "站点已匹配 · 来源：\(origin)"
        case .notFound: return "站点未匹配；\(origin)"
        case .failed(let reason): return "\(reason)；来源：\(origin)"
        case .unverified: return "\(origin)；站点未验证"
        }
    }

    private func updateSuggestions() {
        suggestions.update(prefix: text, namespace: namespace, session: session, qa: AppMode.qa)
    }
}
