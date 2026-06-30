//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!

    private static let reflowableScript = loadScript(named: "readium-reflowable")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        super.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [
                WKUserScript(source: Self.reflowableScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            ],
            animatedLoad: animatedLoad
        )
    }

    override func clear() {
        super.clear()

        // Clean up go to continuations.
        for continuation in goToContinuations {
            continuation.resume()
        }
        goToContinuations.removeAll()

        scrollDidEnd()
    }

    override func setupWebView() {
        super.setupWebView()

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        // Own the column paging natively instead of relying on
        // `UIScrollView.isPagingEnabled`. A paging scroll view keeps its own
        // notion of the current page and re-snaps `contentOffset` to it on
        // layout changes — including when iOS restores the view on a
        // background→foreground transition. Because the page position here is
        // driven by JavaScript (`window.scrollBy`), not UIKit, that re-snap can
        // land one column off. With paging disabled we snap manually in
        // `scrollViewWillEndDragging`.
        scrollView.isPagingEnabled = false
        scrollView.decelerationRate = viewModel.scroll ? .normal : .fast

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Re-pin the column on foreground. `didBecomeActive` fires while iOS is
        // still showing the app snapshot, before the live web view is revealed,
        // so correcting the offset here lands *before* the reveal — no visible
        // one-column flash. This is the trigger that actually fires on a plain
        // background→foreground (no relayout), unlike `layoutSubviews`.
        // Observer removed by the base class `deinit` (`removeObserver(self)`).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reassertColumnAfterForeground),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.readingOrderIndices.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let url = viewModel.url(to: spread.first.link)
        webView.load(URLRequest(url: url.url))
    }

    override func applySettings() {
        super.applySettings()

        // Native column paging (see `setupWebView`): keep UIScrollView paging
        // off and snap manually.
        scrollView.isPagingEnabled = false
        scrollView.decelerationRate = viewModel.scroll ? .normal : .fast

        updateContentInset()
    }

    private func updateContentInset() {
        let contentInset = delegate?.spreadViewContentInset(self) ?? .zero

        if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.constant = 0
            scrollView.contentInset = contentInset

        } else {
            topConstraint.constant = contentInset.top
            bottomConstraint.constant = -contentInset.bottom
            scrollView.contentInset = .zero
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            if scrollView.contentOffset.x < 0 {
                point.x += abs(scrollView.contentOffset.x)
            }
            if scrollView.contentOffset.y < 0 {
                point.y += abs(scrollView.contentOffset.y)
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    override func progression(in index: ReadingOrder.Index) -> ClosedRange<Double> {
        guard
            spread.first.index == index,
            let progression = progression
        else {
            return 0 ... 0
        }
        return progression
    }

    override func spreadDidLoad() async {
        let link = spread.first.link
        if let linkJSON = try? link.jsonString() {
            await evaluateScript("readium.link = \(linkJSON);")
        }

        // TODO: Better solution for delaying scrolling to pending location
        // This delay is used to wait for the web view pagination to settle and give the CSS and webview time to layout
        // correctly before attempting to scroll to the target progression, otherwise we might end up at the wrong spot.
        // 0.2 seconds seems like a good value for it to work on an iPhone 5s.
        try? await Task.sleep(seconds: 0.2)

        let location = pendingLocation
        await go(to: location.location, animated: location.animated)

        // The rendering is sometimes very slow. So in case we don't show the first page of the resource, we add
        // a generous delay before showing the spread again.
        let delayed = !location.location.isStart
        try? await Task.sleep(seconds: delayed ? 0.3 : 0)
    }

    override func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        let factor: CGFloat = {
            switch direction {
            case .left:
                return -1
            case .right:
                return 1
            }
        }()

        guard scrollView.bounds.width > 0 else { return false }
        let offsetX = scrollView.bounds.width * factor
        let targetX = round((scrollView.contentOffset.x + offsetX) / offsetX) * offsetX
        guard 0 ..< scrollView.contentSize.width ~= targetX else {
            return false
        }

        // The column index is the source of truth; update it for this turn up
        // front so a concurrent `layoutSubviews` re-assert can't revert the
        // JS-driven scroll before it settles.
        currentColumn = Int((targetX / scrollView.bounds.width).rounded())

        // We use JavaScript instead of `UIScrollView.setContentOffset()` to
        // prevent glitches when turning pages without animation.
        // See https://github.com/readium/swift-toolkit/issues/737#issuecomment-4090386881
        //
        // `scrollBy` is used instead of `scrollTo` because RTL content uses
        // negative `window.scrollX` values in WKWebView, whereas UIKit's
        // `contentOffset.x` is always non-negative. A relative displacement
        // (`offsetX`) is coordinate-system agnostic and works for both LTR and
        // RTL.
        let behavior = options.animated ? "smooth" : "instant"
        await evaluateScript("window.scrollBy({ left: \(offsetX), behavior: '\(behavior)' });")

        if options.animated {
            // Waits for the scroll animation to finish.
            await withCheckedContinuation { continuation in
                let request = ScrollAnimationRequest(continuation)
                pendingScrollAnimation?.resume()
                pendingScrollAnimation = request

                // Safety net in case `scrollDidEnd` never fires. The identity
                // check on `request` ensures a stale timeout from a previous
                // request does not resume a newer one.
                Task { @MainActor in
                    try? await Task.sleep(seconds: 0.8)
                    scrollDidEnd(for: request)
                }
            }
        }

        return true
    }

    private struct PendingLocation {
        var location: PageLocation
        var animated: Bool
    }

    /// Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PendingLocation = .init(location: .start, animated: false)

    override func go(to location: PageLocation, animated: Bool) async {
        guard isSpreadLoaded else {
            // Delays moving to the location until the document is loaded.
            pendingLocation = PendingLocation(location: location, animated: animated)

            await waitGoToCompletion()
            return
        }

        switch location {
        case let .locator(locator):
            await go(to: locator, animated: animated)
        case .start:
            await scroll(toProgression: 0, animated: animated)
        case .end:
            await scroll(toProgression: 1, animated: animated)
        }

        // Programmatic move settled (resume, ToC jump, scrub, start/end) —
        // adopt the landed column as the source of truth.
        captureCurrentColumn()
        didCompleteGoTo()
    }

    private func waitGoToCompletion() async {
        await withCheckedContinuation { continuation in
            goToContinuations.append(continuation)
        }
    }

    private func didCompleteGoTo() {
        for cont in goToContinuations {
            cont.resume()
        }
        goToContinuations.removeAll()
    }

    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    private var pendingScrollAnimation: ScrollAnimationRequest?

    /// Represents an in-flight animated page turn, waiting for the scroll
    /// animation to settle before completing.
    private class ScrollAnimationRequest {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        /// Resumes the continuation. Safe to call multiple times; only the
        /// first call has any effect.
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func scrollDidEnd(for request: ScrollAnimationRequest? = nil) {
        guard request == nil || pendingScrollAnimation === request else {
            return
        }
        pendingScrollAnimation?.resume()
        pendingScrollAnimation = nil
    }

    @discardableResult
    private func go(to locator: Locator, animated: Bool) async -> Bool {
        if !["", "#"].contains(locator.href.string) {
            guard
                let index = viewModel.readingOrder.firstIndexWithHREF(locator.href),
                spread.contains(index: index)
            else {
                log(.warning, "The locator's href is not in the spread")
                return false
            }
        }

        if locator.text.highlight != nil {
            return await scroll(toLocator: locator, animated: animated)
            // TODO: find the first fragment matching a tag ID (need a regex)
        } else if let id = locator.locations.fragments.first, !id.isEmpty {
            return await scroll(toTagID: id, animated: animated)
        } else {
            let progression = locator.locations.progression ?? 0
            return await scroll(toProgression: progression, animated: animated)
        }
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double, animated: Bool) async -> Bool {
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if viewModel.scroll, !viewModel.verticalText, [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            return true
        } else {
            let dir = viewModel.readingProgression.rawValue
            await evaluateScript("readium.scrollToPosition(\'\(progression)\', \'\(dir)\', \(animated))")
            return true
        }
    }

    /// Scrolls at the tag with ID `tagID`.
    @discardableResult
    private func scroll(toTagID tagID: String, animated: Bool) async -> Bool {
        let result = await evaluateScript("readium.scrollToId(\'\(tagID)\', \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    /// Scrolls at the snippet matching the given text context.
    @discardableResult
    private func scroll(toLocator locator: Locator, animated: Bool) async -> Bool {
        guard let json = try? locator.jsonString() else {
            return false
        }
        let result = await evaluateScript("readium.scrollToLocator(\(json), \(animated));")
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    // MARK: - Progression

    /// Current progression range in the page.
    private var progression: ClosedRange<Double>?
    /// To check if a progression change was cancelled or not.
    private var previousProgression: ClosedRange<Double>?

    /// Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard
            isSpreadLoaded,
            let body = body as? [String: Any],
            var firstProgression = body["first"] as? Double,
            var lastProgression = body["last"] as? Double
        else {
            return
        }
        precondition(firstProgression <= lastProgression)
        firstProgression = min(max(firstProgression, 0.0), 1.0)
        lastProgression = min(max(lastProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = firstProgression ... lastProgression

        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil

        scrollDidEnd()
        delegate?.spreadViewPagesDidChange(self)
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
    }

    // MARK: - Native column paging

    /// Width of a single paginated column (one page). Zero in scroll mode or
    /// before the first layout.
    private var pageWidth: CGFloat {
        viewModel.scroll ? 0 : scrollView.bounds.width
    }

    /// Snaps a free-scrolling drag to the nearest column boundary, with a clear
    /// fling advancing at least one column in its direction. Replaces the
    /// snapping `UIScrollView.isPagingEnabled` used to provide now that we own
    /// the column paging (see `setupWebView`). Operates purely on the
    /// non-negative UIKit `contentOffset`, where columns sit at multiples of the
    /// page width, so it is correct for both reading directions.
    private func snapTargetToColumn(
        velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        let page = pageWidth
        guard page > 0 else { return }
        let current = (scrollView.contentOffset.x / page).rounded()
        var target = (targetContentOffset.pointee.x / page).rounded()
        if velocity.x > 0.1 {
            target = max(target, current + 1)
        } else if velocity.x < -0.1 {
            target = min(target, current - 1)
        }
        let maxColumn = max(0, ((scrollView.contentSize.width - page) / page).rounded())
        target = min(max(target, 0), maxColumn)
        targetContentOffset.pointee.x = target * page
    }

    /// Column index currently snapped to the leading edge — the source of truth
    /// for the horizontal position in paginated mode. The scroll offset is a
    /// derived value re-asserted from this after a same-width relayout (see
    /// `layoutSubviews`), so an external re-snap (e.g. iOS restoring the
    /// paginated scroll view on foreground) can't silently leave the reader one
    /// column off. Tracked in non-negative UIKit column space → reading-
    /// direction agnostic.
    private var currentColumn = 0
    /// Page width the column index was last reconciled against. Tells a reflow
    /// (width changed → index meaningless, the navigator re-pins to the saved
    /// locator) from a re-snap (width unchanged → re-assert the column).
    private var lastReconciledWidth: CGFloat = 0
    /// Guards the re-assert from being mistaken for a user/JS scroll.
    private var isReassertingColumn = false

    /// Records the column under the leading edge as the source of truth. Called
    /// when a scroll settles from genuine intent (user drag end, programmatic
    /// `go`), never from a passive scroll report — so a stray re-snap can't
    /// overwrite the truth before `layoutSubviews` corrects it.
    private func captureCurrentColumn() {
        let page = pageWidth
        guard page > 0, !isReassertingColumn else { return }
        currentColumn = Int((scrollView.contentOffset.x / page).rounded())
        // Tie the captured column to the grid width it was captured against, so
        // a later re-assert (foreground / same-width relayout) recognises an
        // unchanged grid. Without this, `lastReconciledWidth` could stay 0 on a
        // spread that loaded, scrolled to position and then sat idle (its
        // `layoutSubviews` width-set branch never ran), blocking the re-assert.
        lastReconciledWidth = scrollView.bounds.width
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard
            !viewModel.scroll, isSpreadLoaded, pageWidth > 0,
            !scrollView.isDragging, !scrollView.isDecelerating,
            pendingScrollAnimation == nil
        else { return }

        guard scrollView.bounds.width == lastReconciledWidth else {
            // Column width changed (rotation / font size / Split View): the
            // index no longer maps to the same content and the navigator
            // re-pins to the saved locator. Re-baseline against the new grid.
            lastReconciledWidth = scrollView.bounds.width
            captureCurrentColumn()
            return
        }

        reassertColumnIfDrifted()
    }

    /// Re-pin `contentOffset.x` to the source-of-truth column when it has
    /// drifted off it with no user/JS input on an unchanged column grid — e.g.
    /// iOS/WebKit re-clamping the scroll offset one column back after a
    /// background→foreground content-process purge. Idempotent and safe to call
    /// from any trigger (`layoutSubviews`, `didBecomeActive`).
    private func reassertColumnIfDrifted() {
        guard
            !viewModel.scroll, isSpreadLoaded, pageWidth > 0,
            !scrollView.isDragging, !scrollView.isDecelerating,
            pendingScrollAnimation == nil,
            scrollView.bounds.width == lastReconciledWidth
        else { return }

        let expectedX = CGFloat(currentColumn) * pageWidth
        guard abs(scrollView.contentOffset.x - expectedX) > 0.5 else { return }
        isReassertingColumn = true
        scrollView.contentOffset.x = expectedX
        isReassertingColumn = false
    }

    @objc private func reassertColumnAfterForeground() {
        reassertColumnIfDrifted()
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        setNeedsNotifyPagesDidChange()
    }

    override func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard !viewModel.scroll else { return }
        snapTargetToColumn(velocity: velocity, targetContentOffset: targetContentOffset)
    }

    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { captureCurrentColumn() }
    }

    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        captureCurrentColumn()
    }
}
