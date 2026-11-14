import SwiftUI

struct GalleryContinuationFooter: View {
    @ObservedObject var pager: GalleryPager
    @EnvironmentObject private var session: SiteSession
    private var hasContent: Bool {
        if pager.loading { return pager.loadingPresentation != .hidden }
        return pager.interrupted || pager.failure != nil || pager.next != nil
    }
    var body: some View {
        Group {
            if pager.loading {
                if pager.loadingPresentation != .hidden {
                    GalleryLoadingIndicator(label: pager.loadingPresentation == .initial ? "正在载入" : "正在加载更多")
                        .frame(maxWidth: .infinity, minHeight: FeedChrome.rowSurfaceHeight)
                }
            } else if pager.interrupted || pager.failure != nil {
                continuationButton(pager.failure == nil ? "继续加载" : "重试加载") { pager.retry(session: session) }
            } else if pager.next != nil {
                continuationButton("继续加载") { pager.more(session: session) }
            }
        }
        .padding(.top, !pager.items.isEmpty && hasContent ? FeedChrome.contentSpacing : 0)
        .appToast(message: pager.failure, identifier: "gallery.load-error")
    }

    private func continuationButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(FeedChrome.labelFont)
                .frame(maxWidth: .infinity, minHeight: FeedChrome.compactFormRowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .appControlSurface()
        .padding(.horizontal, FeedChrome.contentInset)
        .accessibilityIdentifier("gallery.continue")
    }
}

/// Shared quiet feedback for a cold feed, unknown-tag rows and continuation.
struct GalleryLoadingIndicator: View {
    let label: String
    @State private var visible = false
    var body: some View {
        Group {
            if visible {
                ProgressView().controlSize(.mini).tint(.secondary)
                    .accessibilityLabel(label).accessibilityIdentifier("gallery.loading-indicator")
            } else { Color.clear.accessibilityHidden(true) }
        }
        .frame(minHeight: FeedChrome.rowSurfaceHeight)
        .task {
            visible = false
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            visible = true
        }
    }
}

/// Cold loading and failures share the same content-area anchor as the empty state.
/// Continuation feedback remains next to the existing results.
struct GalleryFeedStatus: View {
    @ObservedObject var pager: GalleryPager
    var body: some View {
        Group {
            if pager.items.isEmpty && !pager.interrupted {
                if pager.loading || pager.failure != nil {
                    GalleryContinuationFooter(pager: pager)
                } else {
                    GalleryEmptyState().accessibilityIdentifier("gallery.empty")
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
