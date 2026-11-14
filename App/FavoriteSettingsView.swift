import SwiftUI
import ExViewerCore

struct FavoriteSettingsView: View {
    let site: GallerySite
    @ObservedObject private var preferences: FavoriteGroupPreferences
    @StateObject private var model: FavoriteSettingsModel
    @State private var editingGroup: Int?
    @State private var draftName = ""
    @FocusState private var focusedGroup: Int?

    init(site: GallerySite, session: SiteSession) {
        self.site = site; preferences = session.favoriteGroups
        _model = StateObject(wrappedValue: FavoriteSettingsModel(site: site, session: session))
    }

    var body: some View {
        List {
            FormValueMenuRow(title: "默认收藏分组", value: groupName(model.defaultGroup),
                             identifier: "favorite.settings.default", enabled: model.isCurrent && !model.saving && !model.loading) {
                ForEach(0...9, id: \.self) { group in
                    AppMenuItem(title: groupName(group), isSelected: group == model.defaultGroup) { model.setDefaultGroup(group) }
                    .accessibilityIdentifier("favorite.settings.default.group.\(group)")
                }
            }
            .accountPageCard(compactRows: true)

            ForEach(0...9, id: \.self) { group in
                Group {
                    if editingGroup == group {
                        FormGroup {
                            HStack(spacing: FeedChrome.panelSpacing) {
                            TextField("分组名称", text: $draftName)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.done).onSubmit { focusedGroup = nil }
                                .font(.footnote)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight,
                                       maxHeight: FeedChrome.compactFormRowHeight)
                                .formRowSurface(shape: AppShape.control)
                                .focused($focusedGroup, equals: group)
                                .disabled(model.saving || !model.isCurrent)
                                .accessibilityIdentifier("favorite.settings.name")

                            Button {
                                Task {
                                    if await model.rename(group, to: draftName) {
                                        focusedGroup = nil
                                        editingGroup = nil
                                    }
                                }
                            } label: {
                                Group {
                                    if model.saving { ProgressView().tint(.white) }
                                    else { Image(systemName: "checkmark") }
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: FeedChrome.compactFormRowHeight, height: FeedChrome.compactFormRowHeight)
                                .background(Color.accentColor, in: AppShape.control)
                                .overlay {
                                    AppShape.control
                                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 0.5)
                                        .allowsHitTesting(false)
                                }
                                .contentShape(AppShape.control)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.saving || !model.isCurrent || draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("保存")
                            .accessibilityIdentifier("favorite.settings.save")

                            Button {
                                focusedGroup = nil
                                editingGroup = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: FeedChrome.compactFormRowHeight, height: FeedChrome.compactFormRowHeight)
                                    .formRowSurface(shape: AppShape.control)
                                    .contentShape(AppShape.control)
                            }
                            .buttonStyle(.plain)
                            .disabled(model.saving)
                            .accessibilityLabel("取消")
                            .accessibilityIdentifier("favorite.settings.cancel")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("favorite.settings.editing.\(group)")
                        .accountPageListRow()
                    } else {
                        Button {
                            draftName = groupName(group)
                            editingGroup = group
                            focusedGroup = group
                        } label: {
                            HStack(spacing: FeedChrome.controlSpacing) {
                                Text(groupName(group)).lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 0)
                                Image(systemName: "pencil").foregroundStyle(.secondary)
                            }
                            .formRowLayout(.compact, horizontalInset: 0)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.loaded || !model.isCurrent || model.loading || model.saving || editingGroup != nil)
                        .accessibilityIdentifier("favorite.settings.group.\(group)")
                        .accountPageCard(compactRows: true)
                    }
                }
            }
            if model.loading { ProgressView().accountPageCard().accessibilityIdentifier("favorite.settings.loading") }
        }
        .appToast(message: model.error, identifier: "favorite.settings.error")
        .accountSubpageHeader("收藏设置", identifier: "favorite.settings") {
            Button { Task { await model.load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(FeedHeaderButtonStyle())
                .disabled(model.loading || model.saving)
                .accessibilityLabel("刷新收藏分组")
        }
        .task { await model.load() }
    }

    private func groupName(_ group: Int) -> String { model.groupName(group) }
}
