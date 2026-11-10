import SwiftUI

struct DownloadHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("优先保存已有看图缓存，缺少的图片再下载。")
                    .accountPageCard()
                Text("普通图片使用看图额度；App 不购买 GP 归档、不自动重置额度。")
                    .accountPageCard()
                Text("在 iOS 26 及以上，点按保存或继续可让当前作品在后台接着下载。系统可提前结束任务，已保存的页会保留。")
                    .accountPageCard()
                Text("清理浏览缓存会保留已保存的离线副本。")
                    .accountPageCard()
            }
            .accountSubpageContent()
            .floatingPageHeader("下载说明", identifier: "downloads.help-page") {
                EmptyView()
            } trailing: {
                Button("完成") { dismiss() }.buttonStyle(FeedHeaderButtonStyle())
                    .accessibilityIdentifier("downloads.help-page.close")
            }
        }.presentationDetents([.medium, .large])
    }
}
