import Foundation
import CoreGraphics

/// Pure geometry policy. A successful rectangle still requires a fresh AX hit-test.
public enum MessageViewport {
    public enum Kind {
        case namedMessages
        case anonymousScrollArea
    }

    /// Fixed diagnostic codes only; no accessibility labels or user text are retained.
    public enum Rejection: String, Error {
        case invalidBounds
        case composerNotVisible
        case outsidePaneOrWindow
        case tooNarrow
        case tooShort
        case partlyOutsideViewport
        case extendsIntoComposer
        case notAligned
        case noAreaAboveComposer
        case insufficientHitArea
    }

    public static func resolve(area: CGRect, pane: CGRect, window: CGRect,
                               composer: CGRect, kind: Kind) -> Result<CGRect, Rejection> {
        guard [area, pane, window, composer].allSatisfy(isUsable) else {
            return .failure(.invalidBounds)
        }
        let visiblePane = pane.intersection(window)
        guard isUsable(visiblePane) else { return .failure(.outsidePaneOrWindow) }
        guard isUsable(composer.intersection(visiblePane)) else {
            return .failure(.composerNotVisible)
        }
        let visibleArea = area.intersection(visiblePane)
        guard isUsable(visibleArea) else { return .failure(.outsidePaneOrWindow) }

        switch kind {
        case .namedMessages:
            // Chat messages may expose short content or the full offscreen transcript bounds.
            // Its verified semantic identity, pane membership and live hit-test do the selection.
            break
        case .anonymousScrollArea:
            guard area.width >= max(300, composer.width * 0.65) else { return .failure(.tooNarrow) }
            guard area.height >= 160 else { return .failure(.tooShort) }
            guard visibleArea.width >= area.width * 0.95,
                  visibleArea.height >= area.height * 0.95 else {
                return .failure(.partlyOutsideViewport)
            }
            guard area.maxY <= composer.minY + 40 else { return .failure(.extendsIntoComposer) }
            guard horizontalOverlap(area, composer) >= min(area.width, composer.width) * 0.8,
                  area.minX <= composer.midX, area.maxX >= composer.midX else {
                return .failure(.notAligned)
            }
        }

        let bottom = min(visibleArea.maxY, composer.minY - 8)
        guard bottom > visibleArea.minY else { return .failure(.noAreaAboveComposer) }
        let aboveComposer = CGRect(x: visibleArea.minX, y: visibleArea.minY,
                                   width: visibleArea.width, height: bottom - visibleArea.minY)
        // Check before insetBy: a CGRect with a negative size must never become a usable region.
        guard aboveComposer.width > 40, aboveComposer.height > 40 else {
            return .failure(.insufficientHitArea)
        }
        let hitRect = aboveComposer.insetBy(dx: 10, dy: 10)
        guard isUsable(hitRect), hitRect.width > 20, hitRect.height > 20 else {
            return .failure(.insufficientHitArea)
        }
        guard horizontalOverlap(hitRect, composer) > 0 else { return .failure(.notAligned) }
        return .success(hitRect)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.size.width > 0 && rect.size.height > 0
            && [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                rect.maxX, rect.maxY].allSatisfy { $0.isFinite }
    }

    private static func horizontalOverlap(_ first: CGRect, _ second: CGRect) -> CGFloat {
        max(0, min(first.maxX, second.maxX) - max(first.minX, second.minX))
    }
}
