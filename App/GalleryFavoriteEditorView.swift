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
                    Text("正在读取收藏…").foregroundStyle(.secondary)
                        .accessibilityIdentifier("favorite.editor.loading-label")
                }
                .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight * 2)
                .accessibilityElement(children: .contain).accessibilityIdentifier("favorite.editor.loading")
                .accountPageCard(compactRows: true)
            }
            if let change = syncCache.changes.first(where: { $0.id == gallery.id }) {
                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                    Text(change.phase.label).accessibilityIdentifier("favorite.sync.status")
                    if let message = change.message { Text(message).foregroundStyle(.secondary) }
                    if change.phase == .uncertain {
                        Button("检查结果") { checkingResult = true; syncCache.check(change.id) }
                            .accessibilityIdentifier("favorite.sync.check")
                    } else if change.phase == .failed || change.phase == .login || (change.phase == .queued && change.message != nil) {
                        Button("重试") { syncCache.retry(change.id) }.accessibilityIdentifier("favorite.sync.retry")
                    }
                }
                .accountPageCard()
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("favorite.editor.error")
                    if model.needsVerification || model.form == nil {
                        Button(model.needsVerification ? "检查结果" : "重试") { reload() }
                            .disabled(model.working).accessibilityIdentifier("favorite.editor.refresh")
                    }
                }
                .accountPageCard()
            }
            if let form = model.form {
                Menu {
                    ForEach(form.groups) { group in
                        Button { model.selection = group.id } label: {
                            if model.selection == group.id { Label(group.name, systemImage: "checkmark") }
                            else { Text(group.name) }
                        }
                        .accessibilityIdentifier("favorite.editor.group.\(group.id)")
                        .accessibilityValue(model.selection == group.id ? "已选择" : "未选择")
                    }
                } label: {
                    HStack(spacing: FeedChrome.panelSpacing) {
                        Text("收藏分组").foregroundStyle(.primary).fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: FeedChrome.controlSpacing)
                        Text(form.groups.first { $0.id == model.selection }?.name ?? "选择分组")
                            .lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    }.font(.subheadline).contentShape(Rectangle())
                }
                .disabled(model.working || model.needsVerification || syncCache.entry(scope)?.phase == .uncertain)
                .accessibilityIdentifier("favorite.editor.group-picker")
                .accountPageCard(compactRows: true)
            }
            if model.canRemove {
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Label("取消收藏", systemImage: "star.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(.red).disabled(syncCache.entry(scope)?.phase == .uncertain)
                .accessibilityIdentifier("favorite.editor.remove")
                .accountPageCard(compactRows: true)
            }
            if model.form != nil && model.error == nil {
                Button { reload() } label: { Label("刷新站点状态", systemImage: "arrow.clockwise") }
                    .disabled(model.working).accessibilityIdentifier("favorite.editor.reload")
                    .accountPageCard(compactRows: true)
            }
            if AppMode.qa {
                Text("reads=\(model.reads);posts=\(model.posts)").font(.system(size: 1)).foregroundStyle(.clear)
                    .accessibilityIdentifier("favorite.editor.qa-counts").accountPageListRow()
            }
        }
        .accountSubpageContent()
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
        .alert("取消站点收藏？", isPresented: $confirmingRemoval) {
            Button("保留收藏", role: .cancel) { }
            Button("取消收藏", role: .destructive) { save(remove: true) }
                .accessibilityIdentifier("favorite.editor.confirm-remove")
        }
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
        case .unknown: return model.needsVerification ? "结果待确认" : model.loading ? "正在读取收藏…" : "尚未读取"
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
            if let failure = cache.readFailure {
                Text(failure).foregroundStyle(.red).accountPageCard()
            } else if cache.changes.isEmpty {
                Text("没有待处理的收藏更改").foregroundStyle(.secondary).accountPageCard()
            }
            ForEach(cache.changes) { change in
                VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                    Text(change.title).font(.subheadline).lineLimit(2)
                    LabeledContent("状态", value: change.phase.label)
                    if let message = change.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if change.canCheck {
                        if change.phase == .failed || change.phase == .login || (change.phase == .queued && change.message != nil) {
                            Button("重试") { cache.retry(change.id) }
                        } else if change.phase == .uncertain {
                            Button("检查结果") { cache.check(change.id) }
                        }
                    } else { Text("打开这部作品后继续同步。").font(.caption).foregroundStyle(.secondary) }
                }
                .accountPageCard()
            }
        }
        .accountSubpageHeader("收藏同步", identifier: "account.favorite-sync-page") {
            Button { cache.refreshActive() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel("刷新收藏同步")
                .accessibilityIdentifier("account.favorite-sync-page.action")
                .disabled(cache.changes.isEmpty)
        }
    }
}
