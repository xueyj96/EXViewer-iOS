import SwiftUI
import ExViewerCore

struct GalleryFavoriteEditorView: View {
    let gallery: Gallery
    let onState: (GalleryFavoriteState, GalleryFavoriteForm?) -> Void
    private let preparation: GalleryFavoritePreparation?
    private let scope: GalleryFavoriteScope
    private let initialPendingNote: String
    @ObservedObject private var syncCache: SiteFavoriteCache
    @StateObject private var model: GalleryFavoriteEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var mutation: Task<Void, Never>?
    @State private var checkingResult = false

    init(gallery: Gallery, session: SiteSession,
         preparation: GalleryFavoritePreparation? = nil, onState: @escaping (GalleryFavoriteState, GalleryFavoriteForm?) -> Void) {
        self.gallery = gallery; self.onState = onState
        self.preparation = preparation; syncCache = session.favoriteStateCache; scope = GalleryFavoriteScope(gallery, session)
        let client = preparation?.client ?? favoriteClient(for: gallery, session: session)
        let initial = preparation?.initialForm.flatMap { $0.reference == gallery.ref ? $0 : nil }
        initialPendingNote = preparation?.pendingNote ?? initial?.note ?? ""
        let value = GalleryFavoriteEditorModel(client: client, initialForm: initial)
        if let preparation { value.useCachedState(preparation.initialState, pending: preparation.pending, group: preparation.pendingGroup, note: preparation.pendingNote) }
        _model = StateObject(wrappedValue: value)
    }
    var body: some View {
        List {
            VStack(spacing: 0) {
                Text(gallery.title).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
                Divider()
                CompactFormValueRow(value: gallery.ref.site.name) { Text("站点") }
                Divider()
                CompactFormValueRow(value: status) { Text("当前状态") }
                    .accessibilityIdentifier("favorite.editor.status")
            }
            .accountPageCard(compactRows: true)

            if model.loading && model.form == nil {
                VStack(spacing: FeedChrome.panelSpacing) {
                    ProgressView().accessibilityIdentifier("favorite.editor.loading-spinner")
                    Text("正在读取收藏").foregroundStyle(.secondary)
                        .accessibilityIdentifier("favorite.editor.loading-label")
                }
                .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight * 2)
                .accessibilityElement(children: .contain).accessibilityIdentifier("favorite.editor.loading")
                .accountPageCard(compactRows: true)
            }
            if let change = syncCache.changes.first(where: { $0.id == gallery.id }) {
                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                    Text(change.phase.label).accessibilityIdentifier("favorite.sync.status")
                    Color.clear.frame(height: 0).appToast(message: change.message, identifier: "favorite.editor.sync-error")
                    if change.phase == .uncertain {
                        Button("检查结果") { checkingResult = true; syncCache.check(change.id) }
                            .accessibilityIdentifier("favorite.sync.check")
                    } else if change.phase == .failed || change.phase == .login || (change.phase == .queued && change.message != nil) {
                        Button("重试") { syncCache.retry(change.id) }.accessibilityIdentifier("favorite.sync.retry")
                    }
                }
                .accountPageCard()
            }
            if model.error != nil && (model.needsVerification || model.form == nil) {
                Button(model.needsVerification ? "检查结果" : "重试") { reload() }
                    .disabled(model.working).accessibilityIdentifier("favorite.editor.refresh")
                    .accountPageCard()
            }
            if let form = model.form {
                let groupName = form.groups.first { $0.id == model.selection }?.name ?? "选择分组"
                let unavailable = model.working || model.needsVerification || syncCache.entry(scope)?.phase == .uncertain
                FormValueMenuRow(title: "收藏分组", value: groupName, identifier: "favorite.editor.group-picker",
                                 titleIdentifier: "favorite.editor.group-title", enabled: !unavailable) {
                    ForEach(form.groups) { group in
                        AppMenuItem(title: group.name, isSelected: model.selection == group.id) { model.selection = group.id }
                        .accessibilityIdentifier("favorite.editor.group.\(group.id)")
                        .accessibilityValue(model.selection == group.id ? "已选择" : "未选择")
                    }
                }
                .accountPageCard(compactRows: true)
            }
            if model.canRemove {
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Text("取消收藏").foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.red).disabled(syncCache.entry(scope)?.phase == .uncertain)
                .accessibilityIdentifier("favorite.editor.remove")
                .accountPageCard(compactRows: true)
            }
            if model.form != nil && model.error == nil {
                Button { reload() } label: {
                    Text("刷新站点状态").frame(maxWidth: .infinity, alignment: .leading)
                }
                    .disabled(model.working).accessibilityIdentifier("favorite.editor.reload")
                    .accountPageCard(compactRows: true)
            }
            if AppMode.qa {
                Text("reads=\(model.reads);posts=\(model.posts)").font(.system(size: 1)).foregroundStyle(.clear)
                    .accessibilityIdentifier("favorite.editor.qa-counts").accountPageListRow()
            }
        }
        .accountSubpageContent()
        .appToast(message: model.error, identifier: "favorite.editor.error")
        .floatingPageHeader("站点收藏", identifier: "favorite.editor", pinned: true) {
            Button { dismiss() } label: { Label("返回", systemImage: "chevron.left") }
                .buttonStyle(FeedHeaderButtonStyle()).disabled(model.saving)
                .accessibilityIdentifier("favorite.editor.cancel")
        } trailing: {
            Button { save() } label: {
                if model.saving { ProgressView().accessibilityLabel("保存中") }
                else { Label("保存分组", systemImage: "checkmark") }
            }
            .buttonStyle(FeedHeaderButtonStyle()).foregroundStyle(Color.accentColor)
            .disabled(!canSaveGroup || syncCache.entry(scope)?.phase == .uncertain ||
                       (preparation?.pending == true && model.selection == preparation?.pendingGroup && model.note == initialPendingNote))
            .accessibilityIdentifier("favorite.editor.save")
        }
        .appConfirmationDialog("取消收藏", message: "取消这部作品的站点收藏", isPresented: $confirmingRemoval,
                               identifier: "favorite.editor.remove") { save(remove: true) }
        .interactiveDismissDisabled(model.saving)
        .task {
            if syncCache.entry(scope)?.phase != .uncertain &&
                (model.form == nil || preparation?.requiresRefresh == true) {
                await model.reload(preservingEdits: model.form != nil); publishState()
            }
        }
        .onChange(of: model.observedState) { _, _ in publishState() }
        .onReceive(syncCache.$revision) { _ in
            if let value = syncCache.entry(scope) {
                if let form = value.form, !model.loading { model.useCachedForm(form) }
                model.useCachedState(value.state, pending: false, group: nil, note: nil)
                if checkingResult && value.phase == nil { dismiss() }
            }
        }
        .onDisappear { mutation?.cancel(); model.cancel() }
    }
    private func reload() {
        mutation = Task {
            let confirmed = await model.reload(preservingEdits: true)
            publishState()
            if confirmed { dismiss() }
        }
    }
    private var status: String {
        switch model.observedState {
        case .unknown: return model.needsVerification ? "结果待确认" : model.loading ? "正在读取收藏" : "尚未读取"
        case .notFavorited: return "未收藏"
        case .favorited(let group): return "已收藏 · \(group)"
        }
    }
    private var canSaveGroup: Bool {
        guard model.canSave, let form = model.form, let selection = model.selection else { return false }
        return selection != form.selectedGroup
    }
    private func save(remove: Bool = false) {
        if !remove, let form = model.form {
            // Notes are no longer editable here. Preserve a legacy explicit
            // pending note; otherwise only change category, never hidden text.
            model.note = syncCache.entry(scope)?.pendingNote ?? form.note
        }
        if let enqueue = preparation?.enqueue {
            if model.enqueue(enqueue, title: gallery.title, remove: remove) { dismiss() }
            return
        }
        mutation = Task {
            let confirmed = await model.save(remove: remove)
            publishState()
            if confirmed { dismiss() }
        }
    }
    private func publishState() {
        if preparation?.enqueue != nil { return }
        if model.observedState == .unknown {
            if model.saving || model.needsVerification { onState(.unknown, nil) }
        } else if model.lastReadSucceeded {
            onState(model.observedState, model.form)
        }
    }
}

struct FavoriteSyncStatusView: View {
    @ObservedObject var cache: SiteFavoriteCache
    var body: some View {
        List {
            if cache.readFailure == nil && cache.changes.isEmpty {
                Text("没有待处理的收藏更改").foregroundStyle(.secondary).accountPageCard()
            }
            ForEach(cache.changes) { change in
                VStack(alignment: .leading, spacing: 0) {
                    Text(change.title).lineLimit(1).truncationMode(.tail)
                        .formRowLayout(.compact, horizontalInset: 0).font(.footnote.weight(.medium))
                    Divider()
                    HStack(spacing: FeedChrome.contentSpacing) {
                        Text(change.actionText)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: FeedChrome.controlSpacing)
                        Text(change.phase.label).foregroundStyle(.secondary)
                    }.formRowLayout(.compact, horizontalInset: 0)
                    Color.clear.frame(height: 0)
                        .appToast(message: change.informativeMessage, identifier: "favorite.sync.feedback.\(change.id)")
                    if change.canCheck && change.phase == .uncertain {
                        Divider()
                        Button { cache.check(change.id) } label: {
                            Text("检查站点收藏").formRowLayout(.compact, horizontalInset: 0).contentShape(Rectangle())
                        }
                        .font(.footnote).foregroundStyle(Color.accentColor).buttonStyle(.plain)
                            .accessibilityIdentifier("favorite.sync.check")
                    } else if change.canCheck && (change.phase == .failed || change.phase == .login || (change.phase == .queued && change.message != nil)) {
                        Divider()
                        Button { cache.retry(change.id) } label: {
                            Text("重试同步").formRowLayout(.compact, horizontalInset: 0).contentShape(Rectangle())
                        }
                        .font(.footnote).foregroundStyle(Color.accentColor).buttonStyle(.plain)
                            .accessibilityIdentifier("favorite.sync.retry")
                    } else if !change.canCheck {
                        Divider()
                        Text("重新打开作品后继续同步").font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
                    }
                }
                .accountPageCard(compactRows: true)
            }
        }
        .appToast(message: cache.readFailure, identifier: "favorite.sync.error")
        .accountSubpageHeader("收藏同步", identifier: "account.favorite-sync-page") {
            Button { cache.refreshActive() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel("刷新收藏同步")
                .accessibilityIdentifier("account.favorite-sync-page.action")
                .disabled(cache.changes.isEmpty)
        }
    }
}

private extension SiteFavoriteCache.Change {
    var actionText: String {
        guard let groupName, !groupName.isEmpty else { return action }
        return "\(action) · \(groupName)"
    }

    var informativeMessage: String? {
        guard let message, !message.isEmpty else { return nil }
        // Include legacy persisted copy so an update does not repeat phase feedback.
        let phaseMessages: Set<String> = [
            "收藏结果待确认 请检查结果", "同步未完成 本次更改已保留",
            "请登录站点后继续同步", "暂时无法连接 请稍后重试",
            "暂时无法确认是否已生效，请检查结果。", "未能同步，已保留本次更改。",
            "站点要求登录，请登录后继续同步。", "暂时无法连接，请稍后重试。"
        ]
        if phaseMessages.contains(message) { return nil }
        return message
    }
}
