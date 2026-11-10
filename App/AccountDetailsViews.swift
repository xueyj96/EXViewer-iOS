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
                } else if failure == nil {
                    Text("额度暂不可读")
                        .foregroundStyle(.secondary)
                }
                if let failure {
                    Text(failure)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(.bottom, usesIPRows ? FeedChrome.contentSpacing : 0)
                }
            }
            .accountPageCard(compactRows: usesIPRows && (session.quota.used == nil || session.quota.limit == nil))
            AccountExternalLinkRow(title: "站点额度设置", destination: URL(string: "https://e-hentai.org/home.php")!)
            .disabled(AppMode.qa)
            .accessibilityIdentifier("account.quota.settings")
            .accountPageCard(compactRows: true)
        }
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

    var body: some View {
        List {
            VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                LabeledContent("额度计算方式", value: reading.quotaTrackingMode ?? "未从站点页面识别")
                if reading.donationStatus.isEmpty {
                    Text("未读取到可确认的捐赠或服务器赞助状态。") .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reading.donationStatus.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline) }
                }
            }
            .accountPageCard()
            VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                Text("站点提供的付款信息").font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if reading.paymentInformation.isEmpty {
                    Text("未从站点页面识别付款方式信息。") .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reading.paymentInformation.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline).textSelection(.enabled) }
                }
                AccountExternalLinkRow(title: "打开官方赞助页面", destination: donationURL)
            }
            .accountPageCard()
            VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                Text("Hath Perks").font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if reading.perksInformation.isEmpty {
                    Text("未从站点页面识别权益或价格信息。") .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(reading.perksInformation.enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline) }
                }
                AccountExternalLinkRow(title: "打开官方 Hath Perks 页面", destination: perksURL)
            }
            .accountPageCard()
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: FeedChrome.contentSpacing) {
                    ForEach(Array(failures.enumerated()), id: \.offset) { _, error in
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .accountPageCard()
            }
            Text("此页只展示站点当前返回并能识别的内容。不会代替你操作付款，也不会推断未显示的权益、金额或付款地址。")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, FeedChrome.contentSpacing)
                .accountPageListRow()
        }
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
        guard !AppMode.qa else { failures = ["测试模式未访问账号数据。"]; return }
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
            failures.append("额度与账号状态读取失败：\(error.localizedDescription)")
        }
        do {
            let html = try await session.html(donationURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readDonation(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append("赞助页面读取失败：\(error.localizedDescription)")
        }
        do {
            let html = try await session.html(perksURL)
            guard isCurrent(revision, owner) else { return }
            reading = reading.merging(try AccountPages.readPerks(html))
        } catch {
            guard isCurrent(revision, owner) else { return }
            failures.append("Hath Perks 页面读取失败：\(error.localizedDescription)")
        }
    }

    @MainActor private func isCurrent(_ revision: UUID, _ owner: String) -> Bool {
        revision == session.generation && owner == session.owner
    }
}
