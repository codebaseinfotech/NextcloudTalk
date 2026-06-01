//
// SPDX-FileCopyrightText: 2025 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import FirebaseRemoteConfig

@objcMembers
class RemoteConfigManager: NSObject {

    static let shared = RemoteConfigManager()

    private var remoteConfig: RemoteConfig

    // Remote Config Keys
    private let kIsIOSInReview = "is_ios_in_review"
    private let kReviewWebLoginURL = "review_weblogin_url"

    // Cached values
    private(set) var isIOSInReview: Bool = false
    private(set) var reviewWebLoginURL: String = ""

    private override init() {
        remoteConfig = RemoteConfig.remoteConfig()

        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = 0 // For development, set to 3600 (1 hour) for production
        remoteConfig.configSettings = settings

        // Set default values
        remoteConfig.setDefaults([
            kIsIOSInReview: false as NSObject,
            kReviewWebLoginURL: "" as NSObject
        ])

        super.init()
    }

    /// Fetch and activate remote config values
    func fetchRemoteConfig(completion: ((Bool) -> Void)? = nil) {
        print("📱 [RemoteConfig] ========== STARTING FETCH ==========")

        remoteConfig.fetchAndActivate { [weak self] status, error in
            guard let self = self else {
                print("📱 [RemoteConfig] ❌ Self is nil")
                completion?(false)
                return
            }

            print("📱 [RemoteConfig] Status: \(status.rawValue)")

            if let error = error {
                print("📱 [RemoteConfig] ❌ Error: \(error.localizedDescription)")
                completion?(false)
                return
            }

            // Get raw values for debugging
            let rawIsInReview = self.remoteConfig.configValue(forKey: self.kIsIOSInReview)
            let rawURL = self.remoteConfig.configValue(forKey: self.kReviewWebLoginURL)

            print("📱 [RemoteConfig] Raw is_ios_in_review: \(rawIsInReview.stringValue ?? "nil")")
            print("📱 [RemoteConfig] Raw review_weblogin_url: \(rawURL.stringValue ?? "nil")")
            print("📱 [RemoteConfig] Source is_ios_in_review: \(rawIsInReview.source.rawValue)")
            print("📱 [RemoteConfig] Source review_weblogin_url: \(rawURL.source.rawValue)")

            // Update cached values
            self.isIOSInReview = rawIsInReview.boolValue
            self.reviewWebLoginURL = rawURL.stringValue ?? ""

            print("📱 [RemoteConfig] ========== RESULT ==========")
            print("📱 [RemoteConfig] is_ios_in_review: \(self.isIOSInReview)")
            print("📱 [RemoteConfig] review_weblogin_url: \(self.reviewWebLoginURL)")
            print("📱 [RemoteConfig] ==============================")

            completion?(true)
        }
    }

    /// Check if app is in review mode and has a valid review URL
    var shouldUseReviewLogin: Bool {
        return isIOSInReview && !reviewWebLoginURL.isEmpty
    }
}
