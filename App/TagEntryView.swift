import SwiftUI
import ExViewerCore

enum TagNamespaceDisplay {
    static func title(_ value: String) -> String {
        ["artist": "作者", "group": "社团", "parody": "系列", "character": "角色", "language": "语言",
         "cosplayer": "扮演者", "location": "地点", "female": "女性", "male": "男性", "mixed": "混合",
         "other": "其他", "reclass": "重分类"][value] ?? value
    }
}

struct TagListRowLabel: View {
    let tag: GalleryTag
    let symbol: String
    var emphasized = false
    var allowsMultiline = false

    var body: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            Text(TagNamespaceDisplay.title(tag.namespace))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            Text(tag.name)
                .foregroundStyle(.primary)
                .lineLimit(allowsMultiline ? nil : 1)
                .fixedSize(horizontal: false, vertical: allowsMultiline)
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
        .font(.footnote)
    }
}

struct SearchTagRuleRow: View {
    let tag: GalleryTag
    @Binding var match: TagMatch
    let matchIdentifier: String
    let removeIdentifier: String
    let removeLabel: String
    var isNew = false
    var showsMatch = true
    let onRemove: () -> Void
    @ScaledMetric(relativeTo: .caption) private var matchWidth: CGFloat = 56

    var body: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            if showsMatch {
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
                    .frame(minHeight: FeedChrome.compactFormRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("匹配方式：\(tag.label)")
                .accessibilityValue(match.name)
                .accessibilityIdentifier(matchIdentifier)
            }

            HStack(spacing: 6) {
                Text(tag.label)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if isNew {
                    Text("新增")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FeedChrome.panelSpacing)
            .layoutPriority(1)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeLabel)
            .accessibilityIdentifier(removeIdentifier)
        }
        .padding(.leading, showsMatch ? FeedChrome.panelSpacing : FeedChrome.contentSpacing)
        .frame(minHeight: FeedChrome.compactFormRowHeight)
        .formRowSurface(shape: AppShape.control)
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
    private let editsSearchRules: Bool
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
    @State private var dictionaryExpanded = false
    @FocusState private var editingText: Bool
    private let namespaces = ["artist", "group", "parody", "character", "language", "cosplayer", "location", "female", "male", "mixed", "other", "reclass"]

    init(onSelect: @escaping (GalleryTag, TagMatch) -> Void) {
        onCommit = { rules in rules.forEach { onSelect($0.tag, $0.match) } }
        allowsEmptyCommit = false
        editsSearchRules = false
    }

    init(editing rules: [TagRule], defaultMatch: TagMatch = .all, onCommit: @escaping ([TagRule]) -> Void) {
        self.onCommit = onCommit
        allowsEmptyCommit = !rules.isEmpty
        editsSearchRules = true
        _match = State(initialValue: defaultMatch)
        _pending = State(initialValue: rules.map { PendingTagEntry(tag: $0.tag, match: $0.match, origin: "当前搜索", status: "已在本次搜索条件中") })
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                lookupCard
                if !pending.isEmpty { pendingSection }
                if suggestions.catalog == nil || suggestions.state.message != nil ||
                    !suggestions.items.isEmpty || manualTagName != nil {
                    suggestionsSection
                }
                if !library.snapshot.favoriteTags.isEmpty { favoriteSection }
                if let catalog = suggestions.catalog {
                    dictionarySection(catalog.information)
                }
            }
            .feedPageContent()
            .padding(.bottom, FeedChrome.sectionSpacing)
        }
        .background(Color(uiColor: .systemBackground))
        .scrollDismissesKeyboard(.interactively)
        .appNavigationChrome(backButton: true, showsToolbarBackButton: false)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            FloatingHeaderPanel(identifier: "tag.header") {
                FloatingPageTitleRow(title: "添加标签", identifier: "tag.title") {
                    Button { dismiss() } label: { Label("取消", systemImage: "xmark") }
                        .buttonStyle(FeedHeaderButtonStyle())
                        .accessibilityIdentifier("tag.cancel")
                } trailing: {
                    Button {
                        onCommit(pending.map { TagRule(tag: $0.tag, match: $0.match) })
                        dismiss()
                    } label: {
                        Label("完成", systemImage: "checkmark")
                    }
                    .buttonStyle(FeedHeaderButtonStyle())
                    .foregroundStyle(Color.accentColor)
                    .disabled(pending.isEmpty && !allowsEmptyCommit)
                    .accessibilityIdentifier("tag.confirm")
                }
                .environment(\.feedHeaderRow, .single)
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

    private var lookupCard: some View {
        let fields = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: FeedChrome.panelSpacing))
            : AnyLayout(HStackLayout(spacing: FeedChrome.panelSpacing))
        return VStack(spacing: FeedChrome.panelSpacing) {
            fields {
                TextField("中文名或标签原名", text: $text,
                          prompt: Text("中文名或标签原名").foregroundStyle(Palette.inputPrompt))
                    .font(.footnote)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("tag.name")
                    .focused($editingText).submitLabel(.done).onSubmit { editingText = false }
                    .accessibilityHint("忽略大小写，支持输入名称片段。")
                    .padding(.horizontal, FeedChrome.contentSpacing)
                    .frame(minHeight: FeedChrome.compactFormRowHeight)
                    .formRowSurface(shape: AppShape.control)
                Menu {
                    ForEach(["all"] + namespaces, id: \.self) { value in
                        Button { namespace = value } label: {
                            if namespace == value {
                                Label(namespaceTitle(value), systemImage: "checkmark")
                            } else {
                                Text(namespaceTitle(value))
                            }
                        }
                        .accessibilityIdentifier("tag.namespace.\(value)")
                    }
                } label: {
                    HStack(spacing: FeedChrome.panelSpacing) {
                        Text(namespaceTitle(namespace))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                        .font(.footnote)
                        .padding(.horizontal, FeedChrome.contentSpacing)
                        .frame(minWidth: 44, minHeight: FeedChrome.compactFormRowHeight)
                        .formRowSurface(shape: AppShape.control)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("标签分类")
                .accessibilityValue(namespaceTitle(namespace))
                .accessibilityIdentifier("tag.namespace-filter")
            }
            if editsSearchRules {
                CompactFormSegmentPicker(selection: $match, options: TagMatch.allCases, title: { $0.name },
                                         accessibilityLabel: "标签匹配方式", identifier: "tag.match")
            }
        }
        .padding(FeedChrome.panelSpacing)
        .formRowSurface(outer: true)
    }

    private func dictionarySection(_ information: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                dictionaryExpanded.toggle()
            } label: {
                HStack(spacing: FeedChrome.panelSpacing) {
                    Text("词库来源与覆盖")
                        .font(.footnote)
                    Spacer(minLength: 0)
                    Image(systemName: dictionaryExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, FeedChrome.contentSpacing)
                .frame(minHeight: FeedChrome.compactFormRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(dictionaryExpanded ? "已展开" : "已收起")
            .accessibilityIdentifier("tag.dictionary-disclosure")

            if dictionaryExpanded {
                Text(information)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, FeedChrome.contentSpacing)
                    .padding(.bottom, FeedChrome.contentSpacing)
                    .accessibilityIdentifier("tag.dictionary-info")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .formRowSurface()
    }

    private var pendingSection: some View {
        tagSection("已选标签（\(pending.count)）") {
            ForEach($pending) { $entry in
                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                    SearchTagRuleRow(tag: entry.tag, match: $entry.match,
                                     matchIdentifier: "tag.pending.match.\(entry.id)",
                                     removeIdentifier: "tag.pending.remove.\(entry.id)",
                                     removeLabel: "移除待添加标签 \(entry.tag.label)",
                                     showsMatch: editsSearchRules) {
                        removePending(entry.id)
                    }
                    if let warning = entry.warning {
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, FeedChrome.contentSpacing)
                            .padding(.bottom, FeedChrome.panelSpacing)
                            .accessibilityIdentifier("tag.pending.warning.\(entry.id)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityValue(entry.status)
                .accessibilityIdentifier("tag.pending.row.\(entry.id)")
            }
        }
    }

    private var suggestionsSection: some View {
        tagSection(suggestions.items.isEmpty ? nil : "建议") {
            if suggestions.catalog == nil {
                Text("中文词库不可用，仍可按原名查询。")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("tag.dictionary-unavailable")
            }
            if suggestions.state == .loading {
                HStack(spacing: FeedChrome.contentSpacing) {
                    ProgressView()
                    Text("正在查找标签建议…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(FeedChrome.panelSpacing)
            } else if let message = suggestions.state.message {
                Text(message).font(.caption).foregroundStyle(suggestions.state.isFailure ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(FeedChrome.panelSpacing)
                    .accessibilityIdentifier("tag.suggestion-status")
            }
            ForEach(suggestions.items) { suggestionCard($0) }
            if let manualName = manualTagName {
                if let error = manualTagError(manualName, namespace: namespace == "all" ? "other" : namespace) {
                    Text(error)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(FeedChrome.panelSpacing)
                        .accessibilityIdentifier("tag.manual-validation")
                } else {
                    manualTagCard(manualName)
                }
            }
        }
    }

    private var favoriteSection: some View {
        tagSection("常用标签") {
            ForEach(library.snapshot.favoriteTags) { tag in
                let isSelected = pending.contains { $0.id == tag.id }
                Button {
                    select(TagSuggestion(tag: tag, source: .saved, chineseName: suggestions.catalog?.translation(for: tag), matchedAlias: nil))
                } label: {
                    TagListRowLabel(tag: tag, symbol: isSelected ? "checkmark.circle.fill" : "plus.circle",
                                    emphasized: isSelected)
                        .padding(.horizontal, FeedChrome.contentSpacing)
                        .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
                    .formRowSurface(shape: AppShape.control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tag.favorite.\(tag.id)")
                .accessibilityValue(isSelected ? "本机常用；已加入待添加" : "本机常用；站点未验证")
                .accessibilityHint(isSelected ? "再次点按取消选择" : "点按加入待添加标签")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private func tagSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, FeedChrome.contentSpacing)
                    .padding(.vertical, FeedChrome.panelSpacing)
            }
            content()
        }
        .padding(FeedChrome.panelSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .formRowSurface(outer: true)
    }

    private func namespaceTitle(_ value: String) -> String {
        value == "all" ? "全部分类" : TagNamespaceDisplay.title(value)
    }

    private func suggestionCard(_ item: TagSuggestion) -> some View {
        let pendingEntry = pending.first { $0.id == item.id }
        let isSelected = pendingEntry != nil
        let chineseName = item.chineseName.flatMap { $0.isEmpty ? nil : $0 }
        let status = selected?.id == item.id ? verificationLabel : sourceLabel(item.source)
        let subtitle = [TagNamespaceDisplay.title(item.tag.namespace), item.matchedAlias.map { "别名 \($0.name)" }, status]
            .compactMap { $0 }.joined(separator: " · ")

        return Button { select(item) } label: {
            tagCardLabel(chineseName ?? item.tag.name, original: chineseName == nil ? nil : item.tag.name,
                         subtitle: subtitle, icon: isSelected ? "checkmark.circle.fill" : nil, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isSelected ? "再次点按取消选择" : "点按加入待添加标签")
        .accessibilityIdentifier("tag.suggestion.\(item.id)")
        .accessibilityValue("\(sourceLabel(item.source)); \(pendingEntry.map { "已加入待添加；\($0.status)" } ?? verificationLabelFor(item))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func tagCardLabel(_ title: String, original: String? = nil, subtitle: String,
                              icon: String?, isSelected: Bool = false) -> some View {
        let card = AppShape.control
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                if let original { Text(original).font(.footnote).foregroundStyle(.secondary) }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: icon ?? "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor).opacity(icon == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, FeedChrome.contentSpacing)
        .padding(.vertical, FeedChrome.panelSpacing)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background {
            card.fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay { card.fill(Color.accentColor.opacity(isSelected ? 0.10 : 0)) }
        }
        .overlay {
            card.strokeBorder(isSelected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .contentShape(card)
    }

    private var manualTagName: String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let query = TagSuggestionRequest.normalized(value)
        let hasExactSuggestion = suggestions.items.contains { item in
            TagSuggestionRequest.matchRank(original: item.tag.name, chinese: item.chineseName, normalizedPrefix: query) == 0 ||
                item.matchedAlias.map { TagSuggestionRequest.normalized($0.name) } == query
        }
        return hasExactSuggestion ? nil : value
    }

    private func manualTagCard(_ name: String) -> some View {
        Group {
            if namespace == "all" {
                Menu {
                    ForEach(namespaces, id: \.self) { scope in
                        Button(TagNamespaceDisplay.title(scope)) { stageManualTag(name, namespace: scope) }
                            .accessibilityIdentifier("tag.stage.namespace.\(scope)")
                    }
                } label: {
                    tagCardLabel("添加「\(name)」", subtitle: "未验证 · 选择标签分类", icon: "chevron.down")
                }
            } else {
                Button { stageManualTag(name, namespace: namespace) } label: {
                    tagCardLabel("添加「\(name)」", subtitle: "未验证 · \(TagNamespaceDisplay.title(namespace))", icon: "plus")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tag.stage")
    }

    private func stageManualTag(_ name: String, namespace: String) {
        let tag = GalleryTag(namespace: namespace, name: name)
        guard TagSuggestionRequest.isSelectable(tag), manualTagError(name, namespace: namespace) == nil else { return }
        upsertPending(tag, origin: "手输标签，站点未验证", status: "未验证输入")
        clearInputForNextTag()
    }

    private func manualTagError(_ name: String, namespace: String) -> String? {
        var query = SearchQuery()
        query.rules = [TagRule(tag: GalleryTag(namespace: namespace, name: name), match: match)]
        do {
            _ = try query.expression()
            return nil
        } catch {
            return error.localizedDescription
        }
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
        case .qaFixture: return "QA 样例，不是站点匹配"
        }
    }

    private func select(_ item: TagSuggestion) {
        guard TagSuggestionRequest.isSelectable(item.tag) else { return }
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
