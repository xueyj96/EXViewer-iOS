import SwiftUI
import UIKit

/// Fixed-size reader status typography shared by SwiftUI and the UIKit decoder.
enum ReaderStatusAppearance {
    static let uiFont = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize, weight: .medium)
    static let font = Font(uiFont)
    static let actionBackground = UIColor.white.withAlphaComponent(0.10)
    static let actionBorder = UIColor.white.withAlphaComponent(0.16)
}

struct ReaderFailureMessage: View {
    let message: String
    var retry: (() -> Void)?
    var retryIdentifier: String? = nil
    var body: some View {
        VStack(spacing: FeedChrome.contentSpacing) {
            if let retry {
                Button(action: retry) {
                    Text("重试")
                        .foregroundStyle(.white)
                        .padding(.horizontal, FeedChrome.contentSpacing * 2)
                        .frame(minWidth: FeedChrome.rowHeight * 2, minHeight: FeedChrome.rowHeight)
                        .background(Color(ReaderStatusAppearance.actionBackground), in: AppShape.control)
                        .overlay { AppShape.control.strokeBorder(Color(ReaderStatusAppearance.actionBorder), lineWidth: 0.5) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(retryIdentifier ?? "reader.metadata.retry")
            }
        }
        .appToast(message: message, identifier: "reader.error")
        .font(ReaderStatusAppearance.font)
        .foregroundStyle(.white.opacity(0.7))
    }
}

struct ReaderLoadingPage: View {
    let index: Int
    var progress: MediaLoadProgress? = nil
    var metadata = false
    var failure: String? = nil
    var retry: (() -> Void)? = nil
    var interactions = CanvasInteractions()

    private var contentGestures: some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .onEnded { _ in interactions.longPress?() }
            .exclusively(before:
                SpatialTapGesture(coordinateSpace: .global)
                    .onEnded { interactions.singleTap?($0.location) })
    }

    private var phaseText: String {
        if metadata { return "正在读取页面信息" }
        switch progress?.phase ?? .resolvingPage {
        case .resolvingPage: return "正在读取图片地址"
        case .queued: return "等待下载"
        case .connecting: return "正在连接图片源"
        case .transferring: return "正在下载"
        case .ready: return "正在显示图片"
        }
    }

    private var byteText: String? {
        guard let progress, progress.phase == .transferring else { return nil }
        let received = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        if let total = progress.totalBytes {
            return received + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }
        return progress.completedBytes > 0 ? received : nil
    }

    var body: some View {
        ZStack {
            Color.black
                .contentShape(Rectangle())
                .gesture(contentGestures)
            VStack(spacing: 10) {
                Text("第 \(index) 页").monospacedDigit()
                if let failure {
                    ReaderFailureMessage(message: failure, retry: retry,
                                         retryIdentifier: "reader.page.retry.\(index)")
                } else {
                    if let fraction = progress?.fraction {
                        ProgressView(value: fraction).frame(width: 112).tint(.white)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    } else { ProgressView().tint(.white) }
                    Text(phaseText)
                    if let byteText { Text(byteText).monospacedDigit() }
                }
            }
            .font(ReaderStatusAppearance.font)
            .foregroundStyle(.white.opacity(0.7))
            .padding(24)
            .allowsHitTesting(failure != nil && retry != nil)
            .gesture(contentGestures)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.page.loading.\(index)")
        .accessibilityValue(failure ?? phaseText)
    }
}
