import SwiftUI
import ExViewerCore

struct GalleryFavoriteEditorView: View {
    let gallery: Gallery
    let onState: (GalleryFavoriteState, GalleryFavoriteForm?) -> Void
    let requestRemoval: Bool
    private let preparation: GalleryFavoritePreparation?
    private let scope: GalleryFavoriteScope
    private let initialPendingNote: String
    @ObservedObject private var syncCache: SiteFavoriteCache
    @StateObject private var model: GalleryFavoriteEditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var removing = false
    @State private var mutation: Task<Void, Never>?
    @State private var checkingResult = false

    init(gallery: Gallery, session: SiteSession, requestRemoval: Bool = false,
         preparation: GalleryFavoritePreparation? = nil, onState: @escaping (GalleryFavoriteState, GalleryFavoriteForm?) -> Void) {
        self.gallery = gallery; self.onState = onState; self.requestRemoval = requestRemoval
        self.preparation = preparation; syncCache = session.favoriteStateCache; scope = GalleryFavoriteScope(gallery, session)
        let client = preparation?.client ?? favoriteClient(for: gallery, session: session)
        let initial = preparation?.initialForm.flatMap { $0.reference == gallery.ref ? $0 : nil }
        initialPendingNote = preparation?.pendingNote ?? initial?.note ?? ""
        let value = GalleryFavoriteEditorModel(client: client, initialForm: initial)
        if let preparation { value.useCachedState(preparation.initialState, pending: preparation.pending, group: preparation.pendingGroup, note: preparation.pendingNote) }
        _model = StateObject(wrappedValue: value)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(gallery.title).font(.subheadline).lineLimit(2)
                    LabeledContent("站点", value: gallery.ref.site.name)
                    LabeledContent("当前状态", value: status)
                        .accessibilityIdentifier("favorite.editor.status")
                }
                if model.loading && model.form == nil {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView().accessibilityIdentifier("favorite.editor.loading-spinner")
                            Text("正在读取收藏…").font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("favorite.editor.loading-label")
                        }
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("favorite.editor.loading")
                    }
                }
                if let change = syncCache.changes.first(where: { $0.id == gallery.id }) {
                    Section {
                        Text(change.phase.label).font(.subheadline).accessibilityIdentifier("favorite.sync.status")
                        if let message = change.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        if change.phase == .uncertain {
                            Button("检查结果") { checkingResult = true; syncCache.check(change.id) }.accessibilityIdentifier("favorite.sync.check")
                        } else if change.phase == .failed || change.phase == .login || (change.phase == .queued && change.message != nil) {
                            Button("重试") { syncCache.retry(change.id) }.accessibilityIdentifier("favorite.sync.retry")
                        }
                    }
                }
                if let error = model.error {
                    Section {
                        Text(error).font(.subheadline).foregroundStyle(.red)
                            .accessibilityIdentifier("favorite.editor.error")
                        if model.needsVerification || model.form == nil {
                            Button(model.needsVerification ? "检查结果" : "重试") {
                                mutation = Task {
                                    let confirmed = await model.reload(preserveDraft: model.form != nil)
                                    publishState()
                                    if confirmed { dismiss() }
                                }
                            }.disabled(model.working).accessibilityIdentifier("favorite.editor.refresh")
                        }
                    }
                }
                if requestRemoval, model.form != nil {
                    Section {
                        if model.canRemove {
                            Text("取消这部作品的站点收藏？")
                            Button("确认取消收藏", role: .destructive) { save(remove: true) }
                                .accessibilityIdentifier("favorite.editor.confirm-remove")
                        } else if model.observedState == .notFavorited {
                            Text(syncCache.entry(scope)?.phase == nil ? "这部作品已不在站点收藏中。" : "取消收藏的结果尚未确认。")
                        }
                    } footer: { Text("稍后再读、下载文件和阅读进度会保留。") }
                }
                if let form = model.form, !requestRemoval {
                    Section {
                        ForEach(form.groups) { group in
                            Button { model.selection = group.id } label: {
                                HStack(spacing: 12) {
                                    Text(group.name).foregroundStyle(.primary)
                                    Spacer(minLength: 12)
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        .opacity(model.selection == group.id ? 1 : 0)
                                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.saving || model.needsVerification)
                                .accessibilityIdentifier("favorite.editor.group.\(group.id)")
                                .accessibilityValue(model.selection == group.id ? "已选择" : "未选择")
                                .accessibilityAddTraits(model.selection == group.id ? .isSelected : [])
                        }
                    } header: { Text("收藏分组") }
                    footer: { if model.selection == nil { Text("选择一个分组，再保存到站点账号。") } }
                    Section {
                        TextField("添加备注", text: $model.note, axis: .vertical)
                            .lineLimit(3...5).disabled(model.saving || model.needsVerification)
                            .accessibilityIdentifier("favorite.editor.note")
                    } header: { Text("备注（可选）") }
                    footer: {
                        Text(model.noteBytes <= 200 ? "中文通常约 66 字，英文约 200 字。" :
                                (GalleryFavoriteForm.normalizedNote(model.note) == form.note ? "已保留原有备注；新备注请控制长度。" : "备注过长，请删减后保存。"))
                            .foregroundStyle(model.noteBytes > 200 && GalleryFavoriteForm.normalizedNote(model.note) != form.note ? Color.red : .secondary)
                    }
                    if case .favorited = model.observedState {
                        Section {
                            Button("取消收藏", role: .destructive) { removing = true }
                                .disabled(!model.canRemove).accessibilityIdentifier("favorite.editor.remove")
                        }
                    }
                }
                if AppMode.qa {
                    Text("reads=\(model.reads);posts=\(model.posts)").font(.system(size: 1)).foregroundStyle(.clear)
                        .accessibilityIdentifier("favorite.editor.qa-counts")
                }
                if model.form != nil && model.error == nil {
                    Section {
                        Button("刷新站点状态") {
                            mutation = Task {
                                let confirmed = await model.reload(preserveDraft: true)
                                publishState()
                                if confirmed { dismiss() }
                            }
                        }.disabled(model.working).accessibilityIdentifier("favorite.editor.reload")
                    }
                }
            }
            .navigationTitle("站点收藏").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar {
                AppToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(model.saving)
                        .accessibilityIdentifier("favorite.editor.cancel")
                }
                AppToolbarItem(placement: .confirmationAction, tone: .accent) {
                    Button { save() } label: {
                        if model.saving { ProgressView().accessibilityLabel("保存中") } else { Text("保存") }
                    }.disabled(!model.canSave || syncCache.entry(scope)?.phase == .uncertain ||
                               (preparation?.pending == true && model.selection == preparation?.pendingGroup && model.note == initialPendingNote))
                        .accessibilityIdentifier("favorite.editor.save")
                }
            }
            .confirmationDialog("取消这部作品的站点收藏？", isPresented: $removing, titleVisibility: .visible) {
                Button("取消收藏", role: .destructive) { save(remove: true) }
                    .accessibilityIdentifier("favorite.editor.confirm-remove")
            }
        }
        .presentationDetents(requestRemoval ? [.medium, .large] : [.large])
        .interactiveDismissDisabled(model.saving)
        .task {
            if syncCache.entry(scope)?.phase != .uncertain && (model.form == nil || preparation?.requiresRefresh == true) {
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
    private var status: String {
        switch model.observedState {
        case .unknown: return model.needsVerification ? "结果待确认" : model.loading ? "正在读取收藏…" : "尚未读取"
        case .notFavorited: return "未收藏"
        case .favorited(let group): return "已收藏 · \(group)"
        }
    }
    private func save(remove: Bool = false) {
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
            if let failure = cache.readFailure { Text(failure).foregroundStyle(.red) }
            else if cache.changes.isEmpty { Text("没有待处理的收藏更改").foregroundStyle(.secondary) }
            ForEach(cache.changes) { change in
                Section {
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
            }
        }.navigationTitle("收藏同步").navigationBarTitleDisplayMode(.inline).appNavigationChrome(backButton: true)
    }
}
