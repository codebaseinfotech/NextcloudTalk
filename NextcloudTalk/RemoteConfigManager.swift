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
    private let kNotiBaseURL = "noti_base_url"

    // Cached values
    private(set) var isIOSInReview: Bool = false
    private(set) var reviewWebLoginURL: String = ""
    private(set) var notiBaseURL: String = ""

    private override init() {
        remoteConfig = RemoteConfig.remoteConfig()

        let settings = RemoteConfigSettings()
        settings.minimumFetchInterval = 0 // For development, set to 3600 (1 hour) for production
        remoteConfig.configSettings = settings

        // Set default values
        remoteConfig.setDefaults([
            kIsIOSInReview: false as NSObject,
            kReviewWebLoginURL: "" as NSObject,
            kNotiBaseURL: "" as NSObject
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
            let rawNotiURL = self.remoteConfig.configValue(forKey: self.kNotiBaseURL)

            print("📱 [RemoteConfig] Raw is_ios_in_review: \(rawIsInReview.stringValue ?? "nil")")
            print("📱 [RemoteConfig] Raw review_weblogin_url: \(rawURL.stringValue ?? "nil")")
            print("📱 [RemoteConfig] Raw noti_base_url: \(rawNotiURL.stringValue ?? "nil")")
            print("📱 [RemoteConfig] Source is_ios_in_review: \(rawIsInReview.source.rawValue)")
            print("📱 [RemoteConfig] Source review_weblogin_url: \(rawURL.source.rawValue)")
            print("📱 [RemoteConfig] Source noti_base_url: \(rawNotiURL.source.rawValue)")

            // Update cached values
            self.isIOSInReview = rawIsInReview.boolValue
            self.reviewWebLoginURL = rawURL.stringValue ?? ""
            self.notiBaseURL = rawNotiURL.stringValue ?? ""

            // Store noti_base_url in UserDefau                                                                                                                                                                                                                                                            -                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   lts for access from extensions
            if !self.notiBaseURL.isEmpty {
                UserDefaults.standard.set(self.notiBaseURL, forKey: "remote_config_noti_base_url")
            }

            print("📱 [RemoteConfig] ========== RESULT ==========")
            print("📱 [RemoteConfig] is_ios_in_review: \(self.isIOSInReview)")
            print("📱 [RemoteConfig] review_weblogin_url: \(self.reviewWebLoginURL)")
            print("📱 [RemoteConfig] noti_base_url: \(self.notiBaseURL)")
            print("📱 [RemoteConfig] ==============================")

            completion?(true)
        }
    }

    /// Check if app is in review mode and has a valid review URL
    var shouldUseReviewLogin: Bool {
        return isIOSInReview && !reviewWebLoginURL.isEmpty
    }
}
