//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

@testable import ReadiumNavigator
import ReadiumShared
import Testing
import UIKit

/// Custom editing actions must respect the same delegate gating as the native
/// ones: the host app can suppress the whole menu through
/// `shouldShowMenuForSelection` and disable individual actions through
/// `canPerformAction(_:for:)`. These tests guard against the custom-action menu
/// bypassing that gating (see PR #822).
@MainActor
@Suite("EditingActionsController custom action gating")
struct EditingActionsControllerTests {
    private final class FakeDelegate: EditingActionsControllerDelegate {
        var showsMenu = true
        /// Actions the host app disables through `canPerformAction(_:for:)`.
        var disabledActions: Set<EditingAction> = []

        func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {}

        func editingActions(_ editingActions: EditingActionsController, shouldShowMenuForSelection selection: Selection) -> Bool {
            showsMenu
        }

        func editingActions(_ editingActions: EditingActionsController, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
            !disabledActions.contains(action)
        }
    }

    private let highlight = EditingAction(title: "Highlight", action: Selector("highlight:"))

    private let selection = Selection(
        locator: Locator(href: AnyURL(string: "chapter1.html")!, mediaType: .html),
        frame: nil
    )

    private func makeController(_ delegate: FakeDelegate) -> EditingActionsController {
        let publication = Publication(manifest: Manifest(metadata: Metadata(title: "Test"), links: [], readingOrder: []))
        let controller = EditingActionsController(actions: [highlight, .copy], publication: publication)
        controller.delegate = delegate
        return controller
    }

    @Test("available when the menu is shown and the action is enabled")
    func enabled() {
        let delegate = FakeDelegate()
        let controller = makeController(delegate)
        controller.selection = selection

        #expect(controller.canPerformAction(highlight))
    }

    @Test("suppressed when shouldShowMenuForSelection returns false")
    func suppressedByMenu() {
        let delegate = FakeDelegate()
        delegate.showsMenu = false
        let controller = makeController(delegate)
        controller.selection = selection

        #expect(!controller.canPerformAction(highlight))
    }

    @Test("disabled when the delegate denies canPerformAction")
    func disabledByDelegate() {
        let delegate = FakeDelegate()
        delegate.disabledActions = [highlight]
        let controller = makeController(delegate)
        controller.selection = selection

        #expect(!controller.canPerformAction(highlight))
    }

    @Test("unavailable without a selection")
    func requiresSelection() {
        let delegate = FakeDelegate()
        let controller = makeController(delegate)
        // No selection set.

        #expect(!controller.canPerformAction(highlight))
    }
}
