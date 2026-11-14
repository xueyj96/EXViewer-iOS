import SwiftUI
import ExViewerCore

private enum AccountRowMetrics {
    static let iconWidth: CGFloat = 20
    static let horizontalInset: CGFloat = 12
    static let iconSpacing = FeedChrome.controlSpacing
    static let separatorLeading = horizontalInset + iconWidth + iconSpacing
}

private struct AccountRowLabel<Title: View>: View {
    let systemImage: String
    let title: Title
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = AccountRowMetrics.iconWidth
    private let compact: Bool
    private var spacing: CGFloat { compact ? FeedChrome.panelSpacing : AccountRowMetrics.iconSpacing }

    init(systemImage: String, compact: Bool = false, @ViewBuilder title: () -> Title) {
        self.systemImage = systemImage
        self.compact = compact
        self.title = title()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: iconWidth, alignment: compact ? .leading : .center)
                .accessibilityHidden(true)
            title
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in iconWidth + spacing }
    }
}

private extension AccountRowLabel where Title == Text {
    init(_ title: String, systemImage: String) {
        self.init(systemImage: systemImage) { Text(title) }
    }
}

private func accountValueRow(_ title: String, systemImage: String, value: String) -> some View {
    CompactFormValueRow(value: value) {
        AccountRowLabel(title, systemImage: systemImage)
    }
}

struct AccountView: View {
    @Binding var site: GallerySite
    var onUseTag: (GalleryTag) -> Void
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @State private var web: WebDestination?
    @State private var loggingOut = false
    @State private var refreshingQuota = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FeedChrome.sectionSpacing) {
                accountSection("账号与站点") {
                    HStack(spacing: FeedChrome.controlSpacing) {
                        AccountRowLabel("站点账号", systemImage: "person.crop.circle")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if session.hasCredentials {
                            Text("会话已保存").foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            loginButton
                        }
                    }
                    .accountSettingsRow()
                    accountDivider
                    accountLink("登录管理", symbol: "person.badge.key", identifier: "account.login-management") {
                        AccountLoginManagement { loggingOut = true }
                    }
                    accountDivider
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: FeedChrome.controlSpacing) {
                            AccountRowLabel("默认浏览站点", systemImage: "globe").fixedSize()
                            Spacer(minLength: 0)
                            sitePicker
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            AccountRowLabel("默认浏览站点", systemImage: "globe")
                            sitePicker.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .accountSettingsRow()
                }

                accountSection("偏好与数据") {
                    accountLink("标签与屏蔽", symbol: "tag", identifier: "account.tags") { TagsView(use: onUseTag) }
                    accountDivider
                    accountLink("收藏设置", symbol: "folder", identifier: "account.favorite-settings") {
                        FavoriteSettingsView(site: site, session: session)
                    }
                    accountDivider
                    accountLink("收藏同步", symbol: "arrow.triangle.2.circlepath", identifier: "account.favorite-sync") {
                        FavoriteSyncStatusView(cache: session.favoriteStateCache)
                    }
                    accountDivider
                    accountLink("阅读与存储管理", symbol: "internaldrive", identifier: "account.storage") {
                        LocalDataManagementView(message: $message)
                    }
                }

                accountSection("站点服务") {
                    quotaStatus.accountSettingsRow()
                    accountDivider
                    Button {
                        refreshingQuota = true
                        Task {
                            defer { refreshingQuota = false }
                            do { try await session.refreshQuota() }
                            catch is CancellationError { return }
                            catch { message = ErrorMessages.message(error, fallback: "额度未能读取") }
                        }
                    } label: {
                        AccountRowLabel("读取站点额度", systemImage: "arrow.clockwise").accountSettingsRow()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(AppMode.qa || refreshingQuota)
                    accountDivider
                    accountLink("额度详情", symbol: "chart.bar", identifier: "account.quota") { QuotaDetailsView() }
                    accountDivider
                    accountLink("赞助与权益", symbol: "heart", identifier: "account.sponsorship") { SponsorshipView() }
                }

                Text("ExViewer · \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            .feedPageContent()
            .padding(.bottom, FeedChrome.sectionSpacing)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .font(.subheadline)
        .imageScale(.small)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            FloatingHeaderPanel(identifier: "account.header") {
                FloatingPageTitleRow(title: "我的", identifier: "account.title") { EmptyView() } trailing: { EmptyView() }
                    .environment(\.feedHeaderRow, .single)
            }
        }
        .officialWebPage(item: $web)
        .confirmationDialog("退出本机登录 离线资料保留", isPresented: $loggingOut, titleVisibility: .visible) {
            Button("退出", role: .destructive) {
                Task {
                    do { try await session.logout() }
                    catch { message = "退出未完成 请重试" }
                }
            }
        }
        .appToast(message: $message, identifier: "account.feedback")
        .appToast(message: session.error, identifier: "account.session-error")
    }

    private var loginButton: some View {
        Button { web = .login } label: { Text("登录") }
            .buttonStyle(AppActionButtonStyle(tone: .accent, labelFont: FeedChrome.labelFont))
    }

    private var sitePicker: some View {
        FeedScopePicker(selection: Binding(
            get: { site == .eh ? 0 : 1 },
            set: { site = $0 == 0 ? .eh : .ex }
        ), options: [.init(id: 0, title: "EH", symbol: "globe"), .init(id: 1, title: "EX", symbol: "lock.shield")],
           identifier: "account.browser-site", showsSymbols: false)
        .frame(width: 100)
    }

    @ViewBuilder private var quotaStatus: some View {
        if let used = session.quota.used, let limit = session.quota.limit {
            AccountRowLabel(systemImage: "gauge.with.dots.needle.50percent") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("已用 \(used)"); Spacer(); Text("上限 \(limit)") }
                    ProgressView(value: Double(used), total: Double(max(1, used, limit)))
                    Text("剩余 \(session.quota.remaining ?? 0)").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        } else if session.quota.tracking == .ip {
            AccountRowLabel("按 IP 动态计算额度", systemImage: "network").foregroundStyle(.secondary)
        } else if session.quota.tracking == .restrictedIP {
            AccountRowLabel("当前 IP 暂限低分辨率图片", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            AccountRowLabel("尚未取得当前额度", systemImage: "gauge.with.dots.needle.50percent").foregroundStyle(.secondary)
        }
    }

    private func accountSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader).padding(.horizontal, 12)
            VStack(spacing: 0, content: content)
                .formRowSurface()
        }
    }

    private func accountLink<Destination: View>(_ title: String, symbol: String, identifier: String,
                                                 @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: FeedChrome.controlSpacing) {
                AccountRowLabel(title, systemImage: symbol)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .accountSettingsRow()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private var accountDivider: some View {
        Divider().padding(.leading, AccountRowMetrics.separatorLeading).padding(.trailing, AccountRowMetrics.horizontalInset).accessibilityHidden(true)
    }
}

private extension View {
    func accountSettingsRow() -> some View {
        formRowLayout(.standard, horizontalInset: AccountRowMetrics.horizontalInset)
    }

}

private struct AccountLoginManagement: View {
    var onLogout: () -> Void
    @State private var web: WebDestination?
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore

    private func siteStatusRow(_ title: String, icon: String, status: String) -> some View {
        let states: Set<String> = ["未验证", "待验证", "连接中…", "需要登录", "连接失败", "EX 画廊可访问", "站点收藏可读取", "访客可访问"]
        let detail = states.contains(status) ? nil : status
        let value = status == ViewerError.challenge.localizedDescription ? "需要验证" :
                    status == ViewerError.authentication.localizedDescription ? "需要登录" :
                    detail == nil ? status : "验证未完成"
        return accountValueRow(title, systemImage: icon, value: value)
            .appToast(message: detail, identifier: "account.site-feedback.\(title)")
    }

    var body: some View {
        List {
            VStack(spacing: 0) {
                siteStatusRow("E-Hentai", icon: "globe", status: session.ehStatus)
                Divider()
                siteStatusRow("ExHentai", icon: "lock.shield", status: session.exStatus)
            }
            .accountPageCard(compactRows: true)

            if session.exStatus == ViewerError.challenge.localizedDescription {
                Button { web = .init(title: "EX 网页验证", url: GallerySite.ex.baseURL, login: true) } label: {
                    AccountRowLabel("处理 EX 网页验证", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("account.ex-web")
                .accountPageCard()
            }
            if session.hasCredentials {
                Button(role: .destructive, action: onLogout) {
                    AccountRowLabel("退出本机登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .tint(.red)
                .accountPageCard()
            }
        }
        .officialWebPage(item: $web)
        .appToast(message: session.error ?? library.error, identifier: "account.login.error")
        .accountSubpageHeader("登录管理", identifier: "account.login-page") {
            Button { web = .login } label: { Image(systemName: "person.badge.key") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel("重新登录")
                .accessibilityIdentifier("account.login-page.action")
        }
    }
}

private struct LocalDataManagementView: View {
    @Binding var message: String?
    @EnvironmentObject private var session: SiteSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    @AppStorage("reader.prefetchCount", store: ReaderPreferenceDefaults.store) private var prefetchCount = ReaderLoadPolicy.defaultPrefetchCount
    @AppStorage("reader.downloadConcurrency", store: ReaderPreferenceDefaults.store) private var readerConcurrency = ReaderLoadPolicy.defaultConcurrency
    @AppStorage("network.pageConcurrency", store: ReaderPreferenceDefaults.store) private var pageConcurrency = SiteRequestPolicy.defaultConcurrency
    @AppStorage(DownloadLoadPolicy.concurrencyKey, store: ReaderPreferenceDefaults.store) private var downloadConcurrency = DownloadLoadPolicy.defaultConcurrency
    @AppStorage(DownloadLoadPolicy.backgroundKey, store: ReaderPreferenceDefaults.store) private var backgroundDownloads = true
    @State private var editingPrefetch = false
    @State private var prefetchEntry = ""
    @State private var legacyReaderConcurrency: Int?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var readerConcurrencyChoices: [Int] {
        let choices = ReaderLoadPolicy.concurrencyChoices
        guard let legacyReaderConcurrency, !choices.contains(legacyReaderConcurrency) else { return choices }
        return (choices + [legacyReaderConcurrency]).sorted()
    }

    private func loadingControlCard(
        _ title: String, icon: String, identifier: String, unit: String,
        scale: LoadingValueSlider.Scale, value: Binding<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: FeedChrome.panelSpacing) {
            AccountRowLabel(systemImage: icon, compact: true) { Text(title) }
                .frame(maxWidth: .infinity, alignment: .leading)
            LoadingValueSlider(title: title, identifier: identifier, unit: unit, scale: scale, value: value)
                .frame(height: FeedChrome.rowHeight)
        }
        .accountPageCard()
    }

    var body: some View {
        List {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FeedChrome.panelSpacing),
                                     count: verticalSizeClass == .compact ? 2 : 1),
                      spacing: FeedChrome.panelSpacing) {
                loadingControlCard("后续图片预加载", icon: "photo.on.rectangle",
                                   identifier: "account.loading.prefetch", unit: "张",
                                   scale: .range(0...ReaderLoadPolicy.maxPrefetchCount), value: $prefetchCount)
                loadingControlCard("图片加载并发", icon: "square.stack",
                                   identifier: "account.loading.concurrency", unit: "路",
                                   scale: .choices(readerConcurrencyChoices), value: $readerConcurrency)
                loadingControlCard("站点页面并发", icon: "network",
                                   identifier: "account.loading.site-concurrency", unit: "路",
                                   scale: .choices(SiteRequestPolicy.concurrencyChoices), value: $pageConcurrency)
                    .onChange(of: pageConcurrency) { _, _ in session.updatePageConcurrency() }
                loadingControlCard("离线下载并发", icon: "arrow.down.circle",
                                   identifier: "account.loading.download-concurrency", unit: "路",
                                   scale: .range(DownloadLoadPolicy.concurrencyRange), value: $downloadConcurrency)
            }
            .accountPageListRow()

            Toggle(isOn: $backgroundDownloads) {
                AccountRowLabel("后台下载", systemImage: "arrow.down.circle")
            }
            .onChange(of: backgroundDownloads) { _, _ in downloads.updateBackgroundDownloadPreference() }
            .accessibilityIdentifier("account.download.background")
            .accountPageCard(compactRows: true)

            VStack(spacing: 0) {
                accountValueRow("浏览缓存上限", systemImage: "tray", value: "2 GB")
                Divider()
                accountValueRow("离线下载", systemImage: "arrow.down.circle", value: "\(library.snapshot.downloads.count) 项")
                Divider()
                accountValueRow("阅读历史", systemImage: "clock", value: "\(library.snapshot.history.count) 项")
                Divider()
                accountValueRow("稍后再读", systemImage: "text.badge.plus", value: "\(library.snapshot.bookmarks.count) 项")
            }
            .accountPageCard(compactRows: true)

            Button(role: .destructive) {
                Task { do { try await MediaRepository.shared.clear(owner: library.owner); message = "浏览缓存已清理" } catch { message = "缓存清理未完成 请重试" } }
            } label: {
                AccountRowLabel("清理浏览缓存", systemImage: "trash")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .tint(.red)
            .disabled(downloads.running != nil)
            .accessibilityHint("保留离线副本、标签和阅读记录")
            .accountPageCard()
        }
        .accountSubpageHeader("阅读与存储", identifier: "account.storage-page") {
            Button(action: openPrefetchEditor) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(FeedHeaderButtonStyle())
                .accessibilityLabel("精确设置预加载数量")
                .accessibilityIdentifier("account.storage-page.action")
        }
        .onAppear {
            ReaderLoadPolicy.migrate(defaults: ReaderPreferenceDefaults.store)
            prefetchCount = ReaderLoadPolicy.clampedPrefetchCount(prefetchCount)
            readerConcurrency = ReaderLoadPolicy.clampedConcurrency(readerConcurrency)
            legacyReaderConcurrency = readerConcurrency
            pageConcurrency = SiteRequestPolicy.clampedConcurrency(pageConcurrency)
            downloadConcurrency = DownloadLoadPolicy.configuredConcurrency(defaults: ReaderPreferenceDefaults.store)
        }
        .alert("预加载数量", isPresented: $editingPrefetch) {
            TextField("0–\(ReaderLoadPolicy.maxPrefetchCount)", text: $prefetchEntry).keyboardType(.numberPad)
            Button("取消", role: .cancel) { }
            Button("保存") {
                if let count = Int(prefetchEntry), (0...ReaderLoadPolicy.maxPrefetchCount).contains(count) {
                    prefetchCount = count
                }
            }
            .disabled(Int(prefetchEntry).map { !(0...ReaderLoadPolicy.maxPrefetchCount).contains($0) } ?? true)
        } message: {
            Text("0 表示关闭预加载")
        }
    }

    private func openPrefetchEditor() {
        prefetchEntry = String(prefetchCount)
        editingPrefetch = true
    }
}
