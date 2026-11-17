import SwiftUI
import UIKit
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class ComposerHitTestingTests: XCTestCase {
    func testHomeComposerAcceptsTouchesAcrossEmptyInput() throws {
        try withHomeComposer(text: "") { input, window in
            // The editable area must cover the full 44pt touch target, including its lower half.
            try assertEditableTouches(input: input, window: window, offsets: [-20, -10, 0, 10, 20])
        }
    }

    func testHomeComposerAcceptsTouchesInPaddingWithExistingText() throws {
        try withHomeComposer(text: "First line\nSecond line") { input, window in
            try assertEditableTouches(input: input, window: window, offsets: [-31, 0, 31])
        }
    }

    func testHomeComposerKeepsFiveLineHeightLimitWithEditablePadding() throws {
        try withHomeComposer(text: "One\nTwo\nThree\nFour\nFive\nSix\nSeven") { input, window in
            XCTAssertEqual(input.bounds.height, 129, accuracy: 1)
            try assertEditableTouches(input: input, window: window, offsets: [-62, 0, 62])

            let frame = input.convert(input.bounds, to: window)
            // Input expansion must not cover the attachment and send button hit targets.
            for x in [frame.minX - 20, frame.maxX + 20] {
                let point = CGPoint(x: x, y: frame.maxY - 22)
                let hit = try XCTUnwrap(window.hitTest(point, with: nil))
                XCTAssertFalse(hit === input || hit.isDescendant(of: input))
            }
        }
    }

    private func assertEditableTouches(input: ChipTextView, window: UIWindow, offsets: [CGFloat]) throws {
        XCTAssertGreaterThan(input.bounds.width, 100)
        for fraction in [0.1, 0.5, 0.75, 0.95] {
            for offset in offsets {
                let point = input.convert(
                    CGPoint(x: input.bounds.width * fraction, y: input.bounds.midY + offset),
                    to: window
                )
                let hit = try XCTUnwrap(window.hitTest(point, with: nil))
                XCTAssertTrue(
                    hit === input || hit.isDescendant(of: input),
                    "Composer touch at (\(fraction), \(offset)) must reach the editable input: \(hit)"
                )
            }
        }
    }

    private func withHomeComposer(text: String, check: (ChipTextView, UIWindow) throws -> Void) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: TestHost(draft: ComposerDraft(text: text)))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.layoutIfNeeded()

        func descendants(of view: UIView) -> [UIView] {
            view.subviews + view.subviews.flatMap(descendants(of:))
        }
        let input = try XCTUnwrap(descendants(of: window).compactMap { $0 as? ChipTextView }.first)
        try check(input, window)
    }

    private struct TestHost: View {
        @State var draft: ComposerDraft

        var body: some View {
            NavigationStack {
                ScrollView {
                    Color.blue.frame(height: 1600)
                }
                .safeAreaInset(edge: .bottom) {
                    ComposerBar(draft: $draft, placeholder: L10n.Composer.askPlaceholder)
                        .padding(.horizontal, 38)
                        .padding(.bottom, 4)
                }
            }
        }
    }
}
