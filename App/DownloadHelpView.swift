import SwiftUI

struct DownloadHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("优先保存已有看图缓存，缺少的图片再下载。")
                Text("普通图片使用看图额度；App 不购买 GP 归档、不自动重置额度。")
                Text("切到后台会暂停，返回下载页可继续。")
                Text("清理浏览缓存会保留已保存的离线副本。")
            }
            .font(.subheadline)
            .navigationTitle("下载说明").navigationBarTitleDisplayMode(.inline).appNavigationChrome()
            .toolbar { AppToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
