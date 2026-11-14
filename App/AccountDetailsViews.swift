import SwiftUI
import ExViewerCore

private struct AccountExternalLinkRow: View {
    let title: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: FeedChrome.panelSpacing) {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.accentColor)
            .font(.footnote)
            .frame(minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct QuotaDetailsView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var loading = false
    @State private var failure: String?
    @State private var refreshRequest: UUID?

    private var usesIPRows: Bool {
        session.quota.tracking == .ip || session.quota.tracking == .restrictedIP
    }

    private func quotaRow(_ title: String, value: String) -> some View {
        CompactFormValueRow(value: value) { Text(title) }
    }

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                if let used = session.quota.used, let limit = session.quota.limit {
                    VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                        HStack { Text("已用 \(used)"); Spacer(); Text("上限 \(limit)") }
                        ProgressView(value: Double(used), total: Double(max(1, used, limit)))
                        Text("剩余 \(session.quota.remaining ?? 0)").font(.subheadline)
                        if let recovery = session.quota.recoveryPerMinute { Text("恢复速度：约 \(recovery.formatted())／分钟").font(.caption).foregroundStyle(.secondary) }
                        if let resetCost = session.quota.resetCost { Text("重置费用：\(resetCost)").font(.caption).foregroundStyle(.secondary) }
                    }
                } else if usesIPRows {
                    VStack(spacing: 0) {
                        quotaRow("计量方式", value: "按 IP")
                        Divider()
                        quotaRow("用量 / 上限", value: "暂不可读")
                        if let resetCost = session.quota.resetCost {
                            Divider()
                            quotaRow("重置费用", value: resetCost.formatted())
                        }
                        if session.quota.tracking == .restrictedIP {
                            Divider()
                            Text("高分辨率访问受限")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
                        }
                    }
                } else {
                    Text("额度暂不可读")
                        .foregroundStyle(.secondary)
                }
            }
            .accountPageCard(compactRows: usesIPRows && (session.quota.used == nil || session.quota.limit == nil))
            AccountExternalLinkRow(title: "站点额度设置", destination: URL(string: "https://e-hentai.org/home.php")!)
            .disabled(AppMode.qa)
            .accessibilityIdentifier("account.quota.settings")
            .accountPageCard(compactRows: true)
        }
        .appToast(message: $failure, identifier: "account.quota.error")
        .accountSubpageHeader("看图额度", identifier: "account.quota-page") {
            Button { refreshRequest = UUID() } label: {
                if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(FeedHeaderButtonStyle())
            .accessibilityLabel("刷新站点额度")
            .accessibilityIdentifier("account.quota-page.action")
            .disabled(loading || AppMode.qa)
        }
        .task(id: refreshRequest) {
            if !AppMode.qa, refreshRequest != nil || session.quota.used == nil { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            try await session.refreshQuota()
        } catch is CancellationError {
            return
        } catch {
            failure = ErrorMessages.message(error, fallback: "额度未能读取")
        }
    }
}

struct SponsorshipView: View {
    @EnvironmentObject private var session: SiteSession
    @State private var reading = AccountPageReading()
    @State private var loading = false
    @State private var failures: [String] = []

    private let homeURL = URL(string: "https://e-hentai.org/home.php")!
    private let donationURL = URL(string: "https://e-hentai.org/bitcoin.php")!
    private let perksURL = URL(string: "https://e-hentai.org/hathperks.php")!

    private var showsQAPreview: Bool {
        AppMode.qa && ProcessInfo.processInfo.arguments.contains("--qa-sponsorship-preview")
    }

    private var quotaTrackingMode: String? { showsQAPreview ? "测试数据" : reading.quotaTrackingMode }
    private var donationStatus: [String] { showsQAPreview ? ["测试赞助状态"] : reading.donationStatus }
    private var paymentInformation: [String] { showsQAPreview ? ["测试付款信息项目 A", "测试付款信息项目 B"] : reading.paymentInformation }
    private var perksInformation: [String] { showsQAPreview ? ["测试权益项目", "测试权益说明: 用于检查长内容换行与卡片留白，不代表实际账号权益。"] : reading.perksInformation }

    private func informationRow(_ title: String, content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FeedChrome.contentSpacing) {
            Text(title).foregroundStyle(.primary)
                .frame(width: 84, alignment: .leading)
            Text(content).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(FeedChrome.labelFont)
        .padding(.vertical, FeedChrome.panelSpacing)
        .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight, alignment: .leading)
    }

    var body: some View {
        List {
            informationRow("额度计算", content: quotaTrackingMode ?? "未读取")
                .accountPageCard(compactRows: true)
            informationRow("赞助状态", content: donationStatus.isEmpty ? "未读取" : donationStatus.joined(separator: "\n"))
                .accountPageCard(compactRows: true)
            informationRow("付款信息", content: paymentInformation.isEmpty ? "未读取" : paymentInformation.joined(separator: "\n"))
                .accountPageCard(compactRows: true)
            informationRow("权益信息", content: perksInformation.isEmpty ? "未读取" : perksInformation.joined(separator: "\n"))
                .accountPageCard(compactRows: true)
            AccountExternalLinkRow(title: "官方赞助页面", destination: donationURL)
                .accountPageCard(compactRows: true)
            AccountExternalLinkRow(title: "Hath Perks", destination: perksURL)
                .accountPageCard(compactRows: true)
        }
        .appToast(message: failures.first, identifier: "account.sponsorship.error")
        .accountSubpageHeader("赞助与权益", identifier: "account.sponsorship-page") {
            Button { Task { await load() } } label: {
                if loading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(FeedHeaderButtonStyle())
            .accessibilityLabel("刷新赞助与权益")
            .accessibilityIdentifier("account.sponsorship-page.action")
            .disabled(loading || AppMode.qa)
        }
        .task { if !AppMode.qa && !loading { await load() } }
    }

    @MainActor private func load() async {
        guard !AppMode.qa else { failures = ["测试模式未访问账号数据"]; return }
        loading = true; failures = []; reading = AccountPageReading()
        let revision = session.generation
        let owner = session.owner
        defer { if isCurrent(revision, owner) { loading = false } }

        do {
            let html = try await session.html(homeURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readHome(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append(ErrorMessages.message(error, fallback: "账号状态读取失败 请重试"))
        }
        do {
            let html = try await session.html(donationURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readDonation(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append(ErrorMessages.message(error, fallback: "赞助页面读取失败 请重试"))
        }
        do {
            let html = try await session.html(perksURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readPerks(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append(ErrorMessages.message(error, fallback: "Hath Perks 读取失败 请重试"))
        }
    }

    @MainActor private func isCurrent(_ revision: UUID, _ owner: String) -> Bool {
        revision == session.generation && owner == session.owner
    }
}
