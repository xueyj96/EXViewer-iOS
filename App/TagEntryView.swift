import SwiftUI
import ExViewerCore

enum TagNamespaceDisplay {
    static let namespaces = ["artist", "group", "parody", "character", "language", "cosplayer", "location", "female", "male", "mixed", "other", "reclass"]
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
    var displayName: String? = nil

    var body: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            TagNamespaceChip(namespace: tag.namespace)
            Text(displayName ?? tag.name)
                .foregroundStyle(.primary)
                .lineLimit(allowsMultiline ? nil : 1)
                .fixedSize(horizontal: false, vertical: allowsMultiline)
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
                .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
                .tagRowAccessorySurface()
                .accessibilityHidden(true)
        }
        .font(.footnote)
    }
}

private extension View {
    func tagRowAccessorySurface() -> some View {
        appControlSurface(insets: EdgeInsets(top: FormMenuMetrics.valueFaceInset, leading: 0,
                                            bottom: FormMenuMetrics.valueFaceInset, trailing: 0))
    }
}

/// Read-only category identity is shared by suggestions, saved tags and selected rules.
private struct TagNamespaceChip: View {
    let namespace: String
    var body: some View {
        Text(TagNamespaceDisplay.title(namespace))
            .font(.footnote).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
            .tagRowAccessorySurface()
            .accessibilityIdentifier("tag.category.\(namespace)")
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
    private let matchWidth = FeedChrome.rowHeight
    private func symbol(_ match: TagMatch) -> String {
        switch match { case .all: return "plus"; case .any: return "arrow.triangle.branch"; case .exclude: return "minus" }
    }

    var body: some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            if showsMatch {
                AppMenu {
                    ForEach(TagMatch.allCases, id: \.self) { option in
                        AppMenuItem(title: option.name, systemImage: symbol(option), isSelected: match == option) { match = option }
                    }
                } label: {
                    AppMenuValueLabel(title: match.name, width: matchWidth, systemImage: symbol(match))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityLabel("匹配方式：\(tag.label)")
                .accessibilityValue(match.name)
                .accessibilityIdentifier(matchIdentifier)
            }

            HStack(spacing: FeedChrome.panelSpacing) {
                TagNamespaceChip(namespace: tag.namespace)
                Text(tag.name)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, FeedChrome.panelSpacing)
                if isNew {
                    Text("新增")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "xmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
                    .tagRowAccessorySurface()
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(removeLabel)
            .accessibilityIdentifier(removeIdentifier)
            .padding(.trailing, FeedChrome.contentSpacing)
        }
        .padding(.leading, FeedChrome.contentSpacing)
        .frame(minHeight: FeedChrome.compactFormRowHeight)
        .appControlSurface(selected: true)
        .tagLibraryActions(tag)
    }
}

/// Lookup input belongs to the search draft, so collapsing it cannot discard typing.
struct TagLookupDraft: Equatable {
    var text = ""
    var namespace = "all"
    var originalNamespace = ""
}

/// Embedded lookup edits the same rule collection as the selected-tag rows.
/// Suggestions are candidates; selection never waits for an extra verification request.
struct InlineTagSearch: View {
    @Binding var draft: TagLookupDraft
    @Binding var rules: [TagRule]
    @EnvironmentObject private var session: SiteSession
    @StateObject private var suggestions = TagSuggestionModel()
    @FocusState private var editingText: Bool
    private var hasInput: Bool { !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                HStack(spacing: FeedChrome.panelSpacing) {
                    TextField("中文名或标签原名", text: Binding(get: { draft.text }, set: {
                        draft.text = $0.split(whereSeparator: \.isNewline).joined(separator: " ")
                    }), prompt: Text("中文名或标签原名").foregroundStyle(Palette.inputPrompt))
                        .font(.footnote).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($editingText).submitLabel(.done).onSubmit { editingText = false }
                        .accessibilityIdentifier("tag.name")
                    AppMenu {
                        ForEach(["all"] + TagNamespaceDisplay.namespaces, id: \.self) { value in
                            AppMenuItem(title: title(value), isSelected: draft.namespace == value) { draft.namespace = value }
                                .accessibilityIdentifier("tag.namespace.\(value)")
                        }
                    } label: { AppMenuValueLabel(title: title(draft.namespace)) }
                    .buttonStyle(.plain).foregroundStyle(.primary)
                    .accessibilityLabel("标签分类").accessibilityIdentifier("tag.namespace-filter")
                    Button { draft.text = "" } label: {
                        Image(systemName: "xmark")
                            .frame(width: FeedChrome.compactFormRowHeight, height: FeedChrome.compactFormRowHeight)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("清空标签搜索").accessibilityIdentifier("tag.clear")
                }
                .padding(.horizontal, FeedChrome.contentSpacing)
                .frame(minHeight: FeedChrome.compactFormRowHeight)
                .formRowSurface(shape: AppShape.control)
            }
            if hasInput {
                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                    if suggestions.state == .loading && suggestions.items.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
                            .accessibilityLabel("正在查找标签")
                    }
                    ForEach(suggestions.items) { item in
                        let included = rules.contains { $0.id == item.id }
                        Button { toggle(item.tag) } label: {
                            TagListRowLabel(tag: item.tag, symbol: included ? "checkmark.circle.fill" : "plus.circle",
                                            emphasized: included, displayName: displayName(item))
                                .padding(.horizontal, FeedChrome.contentSpacing)
                                .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
                                .formRowSurface(shape: AppShape.control)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tagLibraryActions(item.tag)
                        .accessibilityIdentifier("tag.suggestion.\(item.id)")
                        .accessibilityValue(included ? "已添加" : "添加标签")
                        .accessibilityHint(included ? "再次点击取消选择 长按管理标签" : "点击添加 长按管理标签")
                    }
                    if let name = manualTagName {
                        manualTag(name)
                    }
                }
            }
        }
        .appToast(message: suggestions.state.isFailure ? suggestions.state.message : nil, identifier: "tag.lookup.error")
        .onAppear { updateSuggestions() }
        .onChange(of: draft.text) { _, _ in updateSuggestions() }
        .onChange(of: draft.namespace) { _, _ in updateSuggestions() }
        .onChange(of: session.generation) { _, _ in suggestions.sessionChanged(); updateSuggestions() }
        .onDisappear { suggestions.cancel() }
    }

    private func title(_ namespace: String) -> String {
        namespace == "all" ? "全部分类" : TagNamespaceDisplay.title(namespace)
    }
    private func displayName(_ item: TagSuggestion) -> String {
        guard let chinese = item.chineseName, !chinese.isEmpty else { return item.tag.name }
        return "\(chinese) · \(item.tag.name)"
    }
    private var manualTagName: String? {
        let name = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestions.hasNoResults(prefix: name, namespace: draft.namespace) else { return nil }
        return name
    }
    private var originalNamespace: String {
        if !draft.originalNamespace.isEmpty { return draft.originalNamespace }
        return draft.namespace == "all" ? "" : draft.namespace
    }
    private func manualTag(_ name: String) -> some View {
        HStack(spacing: FeedChrome.panelSpacing) {
            AppMenu {
                ForEach(TagNamespaceDisplay.namespaces, id: \.self) { namespace in
                    AppMenuItem(title: title(namespace), isSelected: originalNamespace == namespace) {
                        draft.originalNamespace = namespace
                    }
                    .accessibilityIdentifier("tag.stage.namespace.\(namespace)")
                }
            } label: {
                AppMenuValueLabel(title: originalNamespace.isEmpty ? "分类" : title(originalNamespace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("原名标签分类")
            .accessibilityValue(originalNamespace.isEmpty ? "未选择" : title(originalNamespace))
            .accessibilityIdentifier("tag.stage.namespace")
            Text("按原名添加: \(name)").font(.footnote).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { addOriginal(name, namespace: originalNamespace) } label: {
                Image(systemName: "plus.circle")
                    .frame(width: FeedChrome.rowHeight, height: FeedChrome.compactFormRowHeight)
                    .tagRowAccessorySurface()
            }
            .buttonStyle(.plain)
            .disabled(originalNamespace.isEmpty || TagInputValidation.error(name, namespace: originalNamespace, match: .all) != nil)
            .accessibilityLabel("按原名添加 \(name)")
            .accessibilityIdentifier("tag.stage.add")
        }
        .padding(.horizontal, FeedChrome.contentSpacing)
        .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
        .formRowSurface(shape: AppShape.control)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tag.stage")
    }
    private func addOriginal(_ name: String, namespace: String) {
        guard TagInputValidation.error(name, namespace: namespace, match: .all) == nil else { return }
        add(GalleryTag(namespace: namespace, name: name))
    }
    private func toggle(_ tag: GalleryTag) {
        if rules.contains(where: { $0.id == tag.id }) { rules.removeAll { $0.id == tag.id } }
        else { add(tag) }
    }
    private func add(_ tag: GalleryTag) {
        guard TagSuggestionRequest.isSelectable(tag), !rules.contains(where: { $0.id == tag.id }) else { return }
        rules.append(TagRule(tag: tag, match: .all))
    }
    private func updateSuggestions() {
        suggestions.update(prefix: draft.text, namespace: draft.namespace, session: session, qa: AppMode.qa)
    }
}

/// Shared validation for explicit original-name input in search and tag management.
enum TagInputValidation {
    static func error(_ name: String, namespace: String, match: TagMatch = .all) -> String? {
        var query = SearchQuery()
        query.rules = [TagRule(tag: GalleryTag(namespace: namespace, name: name), match: match)]
        do { _ = try query.expression(); return nil }
        catch { return error.localizedDescription }
    }
}

/// Search conditions and embedded tag lookup share the same section spacing and headings.
struct TagSectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content
    var body: some View {
        FormGroup {
            if let title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("tag.section.title.\(title)")
                    .padding(.horizontal, FeedChrome.contentSpacing)
                    .padding(.vertical, FeedChrome.panelSpacing)
            }
            content()
        }
    }
}

/// The same saved/block actions serve search candidates and selected rules.
private struct TagLibraryActions: ViewModifier {
    let tag: GalleryTag
    @EnvironmentObject private var library: LibraryStore
    @State private var feedback: String?

    func body(content: Content) -> some View {
        content.appContextMenu {
            let saved = library.snapshot.favoriteTags.contains { $0.id == tag.id }
            AppMenuItem(title: saved ? TagMenuTitle.unfavorite : TagMenuTitle.favorite) {
                let success = saved ? library.unpin([tag]) : library.pin([tag])
                feedback = success ? (saved ? "已移出常用标签" : "已加入常用标签") : library.error ?? "标签保存失败 请重试"
            }
            .accessibilityIdentifier("tag.library.favorite")
            let blocked = library.blockedIDs.contains(tag.id)
            AppMenuItem(title: blocked ? TagMenuTitle.unblock : TagMenuTitle.block,
                        role: blocked ? nil : .destructive) {
                let success = blocked ? library.unblock([tag]) : library.block([tag])
                feedback = success ? (blocked ? "已解除屏蔽" : "已屏蔽标签") : library.error ?? "标签保存失败 请重试"
            }
            .accessibilityIdentifier("tag.library.block")
        }
        .appToast(message: $feedback, identifier: "tag.library.feedback")
    }
}

extension View {
    func tagLibraryActions(_ tag: GalleryTag) -> some View {
        modifier(TagLibraryActions(tag: tag))
    }
}
