//
// SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import OneSignalFramework

@objcMembers
public class NCChatNotificationHelper: NSObject {

    /// Sends an external notification for a chat message
    /// This method handles fetching participants and calling the notification API asynchronously
    public static func sendNotification(
        forRoom room: NCRoom,
        account: TalkAccount,
        message: String,
        referenceId: String?,
        replyTo: Int,
        silently: Bool
    ) {
        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else { return }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string
        let conversationType = conversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Extract mention IDs from the message
        var mentionIds: [String] = []
        var mentionTitle = ""
        var mentionBody = ""

        // Check for direct @mentions pattern
        // Matches both @username and @"username" (with optional quotes)
        if let atMentionRegex = try? NSRegularExpression(pattern: "@\\\"?([\\w]+)\\\"?", options: []) {
            let matches = atMentionRegex.matches(in: message, options: [], range: NSRange(location: 0, length: message.utf16.count))
            for match in matches {
                if match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: message) {
                    let mentionId = String(message[range])
                    if !mentionIds.contains(mentionId) {
                        mentionIds.append(mentionId)
                    }
                }
            }
        }

        let isMentions = !mentionIds.isEmpty

        // Clean message by removing quotes from mentions: @"username" -> @username
        var cleanedMessage = message
        if let cleanRegex = try? NSRegularExpression(pattern: "@\\\"([\\w]+)\\\"", options: []) {
            cleanedMessage = cleanRegex.stringByReplacingMatches(
                in: message,
                options: [],
                range: NSRange(location: 0, length: message.utf16.count),
                withTemplate: "@$1"
            )
        }

        if isMentions && !isOneToOne {
            mentionTitle = "You were mentioned in \(conversationName)"
            mentionBody = "\(senderName): \(cleanedMessage)"
        }

        // Build title and body based on room type
        var title = ""
        var body = ""

        if isOneToOne {
            // 1:1 chat: title = sender's name, body = just the message
            title = senderName
            body = cleanedMessage
        } else {
            // Group/Public chat: title = room name, body = "senderName: message"
            title = conversationName
            body = "\(senderName): \(cleanedMessage)"
        }

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests), exclude the sender, and exclude mentioned users
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId,
                       !mentionIds.contains(actorId) {
                        participantUserIds.append(actorId)
                        // OneSignal external ID is the same as user ID
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for notification: \(error.localizedDescription)")
                // Continue with empty participant list
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendChatNotification(
                event: "send_chat_message",
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                message: message,
                referenceId: referenceId ?? "",
                replyToMessageId: replyTo,
                silent: silently,
                isMentions: isMentions,
                mentionIds: mentionIds,
                mentionTitle: mentionTitle,
                mentionBody: mentionBody,
                title: title,
                body: body
            )
        }
    }

    /// Sends an external notification for an edited message
    public static func sendEditNotification(
        forRoom room: NCRoom,
        account: TalkAccount,
        newMessage: String
    ) {
        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else { return }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string
        let conversationType = conversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Build title and body based on room type
        var title = ""
        var body = ""

        if isOneToOne {
            title = senderName
            body = "\(senderName) edited a message: \(newMessage)"
        } else {
            title = conversationName
            body = "\(senderName) edited a message: \(newMessage)"
        }

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests) and exclude the sender
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId {
                        participantUserIds.append(actorId)
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for edit notification: \(error.localizedDescription)")
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendEditMessageNotification(
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                newMessage: newMessage,
                title: title,
                body: body
            )
        }
    }

    /// Sends an external notification for a reaction
    public static func sendReactionNotification(
        forRoom room: NCRoom,
        account: TalkAccount,
        emoji: String
    ) {
        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else { return }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string
        let conversationType = conversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Build title and body
        let title = senderName
        let body = "Reacted \(emoji) to your message"

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests) and exclude the sender
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId {
                        participantUserIds.append(actorId)
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for reaction notification: \(error.localizedDescription)")
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendReactionNotification(
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                emoji: emoji,
                title: title,
                body: body
            )
        }
    }

    /// Sends an external notification for a shared file
    public static func sendShareFileNotification(
        forRoom room: NCRoom,
        account: TalkAccount,
        fileUri: String,
        fileName: String
    ) {
        NSLog("sendShareFileNotification: Called with room token: \(room.token ?? "nil"), fileName: \(fileName)")

        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else {
            NSLog("sendShareFileNotification: Skipping NoteToSelf room")
            return
        }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string
        let conversationType = conversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Build title and body
        var title = ""
        var body = ""

        if isOneToOne {
            title = senderName
            body = "\(senderName) shared a file: \(fileName)"
        } else {
            title = conversationName
            body = "\(senderName) shared a file: \(fileName)"
        }

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests) and exclude the sender
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId {
                        participantUserIds.append(actorId)
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for share file notification: \(error.localizedDescription)")
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendShareFileNotification(
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                fileUri: fileUri,
                fileName: fileName,
                mimeType: nil,
                sizeBytes: nil,
                title: title,
                body: body
            )
        }
    }

    /// Sends an external notification for a shared location
    public static func sendShareLocationNotification(
        forRoom room: NCRoom,
        account: TalkAccount,
        latitude: Double,
        longitude: Double,
        locationName: String
    ) {
        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else { return }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string
        let conversationType = conversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Build title and body
        var title = ""
        var body = ""

        if isOneToOne {
            title = senderName
            body = "\(senderName) shared a location: \(locationName)"
        } else {
            title = conversationName
            body = "\(senderName) shared a location: \(locationName)"
        }

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests) and exclude the sender
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId {
                        participantUserIds.append(actorId)
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for share location notification: \(error.localizedDescription)")
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendShareLocationNotification(
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                latitude: latitude,
                longitude: longitude,
                locationName: locationName,
                title: title,
                body: body
            )
        }
    }

    /// Sends an external notification for starting a call
    public static func sendStartCallNotification(
        forRoom room: NCRoom,
        account: TalkAccount,
        withVideo: Bool,
        withAudio: Bool,
        silent: Bool
    ) {
        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else { return }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string for calls
        let conversationType = callConversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Build title and body based on room type
        var title = ""
        var body = ""

        if isOneToOne {
            title = "Incoming call"
            body = "\(senderName) is calling you..."
        } else {
            title = "Incoming group call"
            body = "\(senderName) started a call in \(conversationName)"
        }

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests) and exclude the sender
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId {
                        participantUserIds.append(actorId)
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for start call notification: \(error.localizedDescription)")
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendStartCallNotification(
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                withVideo: withVideo,
                withAudio: withAudio,
                silent: silent,
                title: title,
                body: body
            )
        }
    }

    /// Sends an external notification for a deleted message
    public static func sendDeleteMessageNotification(
        forRoom room: NCRoom,
        account: TalkAccount
    ) {
        // Skip for NoteToSelf rooms
        guard room.type != .noteToSelf else { return }

        let conversationToken = room.token ?? ""
        let conversationName = room.displayName ?? ""
        let roomType = room.type

        // Determine room type flags
        let isOneToOne = (roomType == .oneToOne)
        let isGroup = (roomType == .group)
        let isPublic = (roomType == .public)
        let isNoteToSelf = (roomType == .noteToSelf)

        // Get conversation type string
        let conversationType = conversationTypeString(for: roomType)

        // Get sender information
        let senderId = account.userId ?? ""
        let senderName = account.userDisplayName ?? ""
        let senderActorType = "users"
        // Get OneSignal external ID (falls back to userId if not set)
        let senderExternalId = OneSignal.User.externalId ?? senderId

        // Build title and body based on room type
        var title = ""
        var body = ""

        if isOneToOne {
            title = senderName
            body = "\(senderName) deleted a message"
        } else {
            title = conversationName
            body = "\(senderName) deleted a message"
        }

        // Fetch participants asynchronously and then send notification
        Task { @MainActor in
            var participantUserIds: [String] = []
            var participantExternalIds: [String] = []

            do {
                let participants = try await NCAPIController.sharedInstance().getParticipants(forRoom: conversationToken, forAccount: account)

                // Filter to only users (not guests) and exclude the sender
                for participant in participants {
                    if participant.actorType == .user,
                       let actorId = participant.actorId,
                       actorId != senderId {
                        participantUserIds.append(actorId)
                        participantExternalIds.append(actorId)
                    }
                }
            } catch {
                NCLog.log("Failed to get participants for delete message notification: \(error.localizedDescription)")
            }

            // Call the notification API
            NCAPIController.sharedInstance().sendDeleteMessageNotification(
                senderId: senderId,
                senderName: senderName,
                senderActorType: senderActorType,
                senderExternalId: senderExternalId,
                conversationToken: conversationToken,
                conversationType: conversationType,
                conversationName: conversationName,
                isOneToOne: isOneToOne,
                isGroup: isGroup,
                isPublic: isPublic,
                isNoteToSelf: isNoteToSelf,
                participantUserIds: participantUserIds,
                participantExternalIds: participantExternalIds,
                title: title,
                body: body
            )
        }
    }

    private static func conversationTypeString(for roomType: NCRoomType) -> String {
        switch roomType {
        case .oneToOne:
            return "ROOM_TYPE_ONE_TO_ONE"
        case .group:
            return "ROOM_GROUP_CALL"
        case .public:
            return "ROOM_PUBLIC_CALL"
        case .changelog:
            return "ROOM_CHANGELOG"
        case .formerOneToOne:
            return "ROOM_FORMER_ONE_TO_ONE"
        case .noteToSelf:
            return "ROOM_NOTE_TO_SELF"
        @unknown default:
            return "UNKNOWN"
        }
    }

    private static func callConversationTypeString(for roomType: NCRoomType) -> String {
        switch roomType {
        case .oneToOne:
            return "ROOM_TYPE_ONE_TO_ONE_CALL"
        case .group:
            return "ROOM_GROUP_CALL"
        case .public:
            return "ROOM_PUBLIC_CALL"
        case .changelog:
            return "ROOM_CHANGELOG"
        case .formerOneToOne:
            return "ROOM_FORMER_ONE_TO_ONE"
        case .noteToSelf:
            return "ROOM_NOTE_TO_SELF"
        @unknown default:
            return "UNKNOWN"
        }
    }
}
