import AppKit
import SwiftUI

/// 三处高度测量结果：滚动内容的理想高度、滚动视口、根视图总高。
struct WindowHeights: Equatable {
    var ideal: CGFloat = 0
    var viewport: CGFloat = 0
    var root: CGFloat = 0
}

private struct WindowHeightsKey: PreferenceKey {
    static let defaultValue = WindowHeights()

    static func reduce(value: inout WindowHeights, nextValue: () -> WindowHeights) {
        let next = nextValue()
        if next.ideal > 0 { value.ideal = next.ideal }
        if next.viewport > 0 { value.viewport = next.viewport }
        if next.root > 0 { value.root = next.root }
    }
}

/// 高度预算：窗口最高只能长到屏幕可用高度减去边距，滚动区至少留这么高。
enum WindowHeightBudget {
    static let screenMargin: CGFloat = 70
    static let minimumWindowHeight: CGFloat = 320
    static let minimumViewportHeight: CGFloat = 240

    static var screenCap: CGFloat {
        max(minimumWindowHeight, (NSScreen.main?.visibleFrame.height ?? 900) - screenMargin)
    }
}

extension WindowHeights {
    /// 不随内容变化的那部分窗口高度（标题、介质卡片、底部按钮、内边距）。
    var chromeHeight: CGFloat { max(0, root - viewport) }

    /// 滚动区应当钉住的高度：内容理想高度，但不超过屏幕留给它的那部分。
    var pinnedScrollHeight: CGFloat? {
        guard ideal > 0 else { return nil }
        let available = max(WindowHeightBudget.minimumViewportHeight, WindowHeightBudget.screenCap - chromeHeight)
        return min(ideal, available)
    }

    /// 窗口内容高度：外框 + 钉住的滚动区。全部由内容决定，与窗口当前尺寸无关，因此幂等。
    var targetContentHeight: CGFloat {
        guard let pinned = pinnedScrollHeight else { return 0 }
        return chromeHeight + pinned
    }
}

extension View {
    /// 按理想高度布局并上报内容高度，避免"内容高度跟着视口长"形成反馈。
    func reportIdealScrollHeight() -> some View {
        fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: WindowHeightsKey.self, value: WindowHeights(ideal: proxy.size.height))
            })
    }

    func reportViewportHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: WindowHeightsKey.self, value: WindowHeights(viewport: proxy.size.height))
        })
    }

    func reportRootHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: WindowHeightsKey.self, value: WindowHeights(root: proxy.size.height))
        })
    }

    /// 汇总三处高度测量结果。
    func collectWindowHeights(_ handler: @escaping (WindowHeights) -> Void) -> some View {
        onPreferenceChange(WindowHeightsKey.self, perform: handler)
    }
}

/// 把窗口内容高度设为测量值；纯绝对值、幂等，不做增量追踪。
struct AutoHeightWindow: ViewModifier {
    let targetContentHeight: CGFloat

    func body(content: Content) -> some View {
        content.background(WindowFitting(targetContentHeight: targetContentHeight))
    }

    private struct WindowFitting: NSViewRepresentable {
        let targetContentHeight: CGFloat

        final class Coordinator {
            var hasFitted = false
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

        func updateNSView(_ view: NSView, context: Context) {
            guard let window = view.window, targetContentHeight > 0 else { return }
            let cap = window.screen?.visibleFrame.height ?? WindowHeightBudget.screenCap
            let target = min(max(targetContentHeight, WindowHeightBudget.minimumWindowHeight), cap)
            let current = window.contentLayoutRect.height
            guard abs(target - current) > 1 else { return }
            let titlebar = window.frame.height - current
            // 布局回调里改窗口尺寸会重入，交给下一个主循环。
            DispatchQueue.main.async {
                var frame = window.frame
                frame.size.height = target + titlebar
                guard context.coordinator.hasFitted else {
                    // 首次贴合直接定尺寸并居中，别把窗口从初始位置往下推。
                    context.coordinator.hasFitted = true
                    window.setFrame(frame, display: true)
                    window.center()
                    return
                }
                frame.origin.y = window.frame.maxY - frame.size.height
                window.setFrame(frame, display: true, animate: true)
            }
        }
    }
}

extension View {
    func autoHeightWindow(targetContentHeight: CGFloat) -> some View {
        modifier(AutoHeightWindow(targetContentHeight: targetContentHeight))
    }
}
