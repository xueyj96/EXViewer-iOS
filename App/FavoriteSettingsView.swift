import SwiftUI
import ExViewerCore

struct FavoriteSettingsView: View {
    let site: GallerySite
    @ObservedObject private var preferences: FavoriteGroupPreferences
    @StateObject private var model: FavoriteSettingsModel

    init(site: GallerySite, session: SiteSession) {
        self.site = site; preferences = session.favoriteGroups
        _model = StateObject(wrappedValue: FavoriteSettingsModel(site: site, session: session))
    }

    var body: some View {
        List {
            Menu {
                ForEach(0...9, id: \.self) { group in
                    Button { model.setDefaultGroup(group) } label: {
                        if group == model.defaultGroup { Label(groupName(group), systemImage: "checkmark") }
                        else { Text(groupName(group)) }
                    }
                }
            } label: {
                HStack(spacing: FeedChrome.panelSpacing) {
                    Text("默认收藏分组").foregroundStyle(.primary).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: FeedChrome.controlSpacing)
                    Text(groupName(model.defaultGroup)).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.isCurrent)
            .accessibilityLabel("默认收藏分组")
            .accessibilityValue(groupName(model.defaultGroup))
            .accessibilityIdentifier("favorite.settings.default")
            .accountPageCard(compactRows: true)

            ForEach(0...9, id: \.self) { group in
                NavigationLink {
                    FavoriteGroupRenameView(group: group, model: model, name: groupName(group))
                } label: {
                    HStack(spacing: FeedChrome.controlSpacing) {
                        Text(groupName(group)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.loaded || !model.isCurrent)
                .accessibilityIdentifier("favorite.settings.group.\(group)")
                .accountPageCard(compactRows: true)
            }
            if model.loading { ProgressView().accountPageCard().accessibilityIdentifier("favorite.settings.loading") }
            if let error = model.error { Text(error).foregroundStyle(.red).accountPageCard() }
        }
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

private struct FavoriteGroupRenameView: View {
    let group: Int
    @ObservedObject var model: FavoriteSettingsModel
    @State var name: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            TextField("分组名称", text: $name)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done)
                .disabled(model.saving)
                .accessibilityIdentifier("favorite.settings.name")
                .accountPageCard(compactRows: true)
            if let error = model.error { Text(error).foregroundStyle(.red).accountPageCard() }
        }
        .accountSubpageHeader("分组改名", identifier: "favorite.settings.rename") {
            Button {
                Task { if await model.rename(group, to: name) { dismiss() } }
            } label: {
                if model.saving { ProgressView() } else { Label("保存", systemImage: "checkmark") }
            }
            .buttonStyle(FeedHeaderButtonStyle())
            .disabled(model.saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("favorite.settings.save")
        }
    }
}
