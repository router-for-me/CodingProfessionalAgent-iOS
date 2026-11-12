import SwiftUI
import UIKit
import XCTest
@testable import CodingProfessionalAgent

@MainActor
final class ThemeTests: XCTestCase {
    func testSelectedHostHasDarkBackgroundAndReadableLabelInDarkAppearance() throws {
        let background = try luminance(of: Theme.chipBackground, style: .dark)
        let label = try luminance(of: Color.primary, style: .dark)

        XCTAssertLessThan(background, 0.15, "The selected host must not retain a pale background in dark mode")
        XCTAssertGreaterThanOrEqual(contrast(label, background), 4.5)
    }

    func testUserBubbleHasDarkBackgroundAndReadableTextInDarkAppearance() throws {
        let background = try luminance(of: Theme.userBubble, style: .dark)
        let text = try luminance(of: Theme.userBubbleText, style: .dark)

        XCTAssertLessThan(background, 0.15, "Sent messages must use a dark surface in dark mode")
        XCTAssertGreaterThanOrEqual(contrast(text, background), 4.5)
    }

    func testLightAppearanceKeepsBrightBackgroundsAndReadableText() throws {
        let chip = try luminance(of: Theme.chipBackground, style: .light)
        let label = try luminance(of: Color.primary, style: .light)
        let bubble = try luminance(of: Theme.userBubble, style: .light)
        let text = try luminance(of: Theme.userBubbleText, style: .light)

        XCTAssertGreaterThan(chip, 0.8)
        XCTAssertGreaterThan(bubble, 0.8)
        XCTAssertGreaterThanOrEqual(contrast(label, chip), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(text, bubble), 4.5)
    }

    private func luminance(of color: Color, style: UIUserInterfaceStyle) throws -> Double {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let resolved = UIColor(color).resolvedColor(with: traits)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let rgb = try XCTUnwrap(resolved.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil))
        let components = try XCTUnwrap(rgb.components)
        XCTAssertEqual(components.count, 4)
        let linear = components.prefix(3).map { component -> Double in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    private func contrast(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
