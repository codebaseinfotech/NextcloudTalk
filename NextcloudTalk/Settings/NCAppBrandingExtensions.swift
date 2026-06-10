//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI

extension NCAppBranding {

    @objc
    static func elementColorBackground() -> UIColor {
        var lightColor: UIColor
        var darkColor: UIColor

        if #available(iOS 18.0, *) {
            lightColor = NCAppBranding.elementColor().withProminence(.quaternary)
            darkColor = NCAppBranding.elementColor().withProminence(.secondary)
        } else {
            lightColor = NCAppBranding.elementColor().withAlphaComponent(0.1)
            darkColor = NCAppBranding.elementColor().withAlphaComponent(0.2)
        }

        return NCAppBranding.getDynamicColor(lightColor, withDarkMode: darkColor)
    }

    // Use a fixed Nextcloud Talk compatible version for server API compatibility
    // This is separate from the app's marketing version (CFBundleShortVersionString)
    static let nextcloudTalkVersion = "20.0.0"

    @objc
    static func userAgent() -> String {
        return "Mozilla/5.0 (iOS) Nextcloud-Talk v\(nextcloudTalkVersion)"
    }

    @objc
    static func userAgentForLogin() -> String {
        let appDisplayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] ?? "Unknown app"
        let deviceName = UIDevice.current.name

        return "\(deviceName) (\(appDisplayName))"
    }

}
