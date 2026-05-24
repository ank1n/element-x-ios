//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// Models are defined in Services/Meetings/MeetingsService.swift

// MARK: - View State

enum MeetingsScreenViewAction {
    case selectDate(Date)
    case selectMeeting(Meeting)
    case createMeeting
    case refresh
    case back
}

enum MeetingsScreenViewModelAction {
    case openMeetingDetail(Meeting)
    case openCreateMeeting
    case dismiss
}

/// Resolved participant info for display (name + avatar URL)
struct ResolvedParticipant: Equatable {
    let displayName: String
    let avatarURL: URL?
}

struct MeetingsScreenViewState: BindableState {
    var meetings: [Meeting] = []
    var holidays: Set<String> = [] // "YYYY-MM-DD"
    var selectedDate: Date = .now
    var isLoading = true
    var errorMessage: String?
    /// userId → resolved display name + avatar URL
    var participantProfiles: [String: ResolvedParticipant] = [:]
    /// Media provider for loading avatar images
    var mediaProvider: MediaProviderProtocol?
    var bindings = MeetingsScreenViewStateBindings()

    /// Meetings for the selected date
    var meetingsForSelectedDate: [Meeting] {
        let calendar = Calendar.current
        return meetings.filter { meeting in
            calendar.isDate(meeting.startTime, inSameDayAs: selectedDate)
        }
    }

    /// Dates that have meetings (for calendar dots)
    var datesWithMeetings: Set<String> {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return Set(meetings.map { formatter.string(from: $0.startTime) })
    }
}

struct MeetingsScreenViewStateBindings {
    var searchQuery = ""
}

// MARK: - Detail

enum MeetingDetailViewAction {
    case rsvp(RSVPStatus)
    case joinCall
    case edit
    case delete
    case back
    case copyLink
}

enum MeetingDetailViewModelAction {
    case editMeeting(Meeting)
    case deleted
    case dismiss
    case joinCall(roomId: String)
}

struct MeetingDetailViewState: BindableState {
    var meeting: Meeting
    var currentUserId = ""
    var homeserverURL = ""
    var isLoading = false
    var linkCopied = false
    var participantProfiles: [String: ResolvedParticipant] = [:]
    var mediaProvider: MediaProviderProtocol?
    var bindings = MeetingDetailViewStateBindings()

    var isCreator: Bool {
        meeting.creatorId == currentUserId
    }

    var myRSVP: RSVPStatus? {
        meeting.participants.first(where: { $0.userId == currentUserId })?.rsvp
    }

    var meetingLink: String? {
        guard let code = meeting.meetingCode, !code.isEmpty, !homeserverURL.isEmpty else { return nil }
        return "\(homeserverURL)/meet/s/\(code)"
    }
}

struct MeetingDetailViewStateBindings {
    /// STMOB-151 build 174: показывается как alert в MeetingDetailScreen.
    /// Раньше ensureRoom error swallowed без feedback в UI — кнопка
    /// "Начать звонок" могла выглядеть мёртвой.
    var alertInfo: AlertInfo<UUID>?
}

// MARK: - Edit/Create

enum MeetingEditViewAction {
    case save
    case cancel
    case searchParticipants(String)
    case addParticipant(UserProfileProxy)
    case removeParticipant(UserProfileProxy)
}

enum MeetingEditViewModelAction {
    case saved(Meeting)
    case cancelled
}

struct MeetingEditViewState: BindableState {
    var meetingId: Int? // nil = create
    var bindings: MeetingEditViewStateBindings
    var isLoading = false
    var errorMessage: String?
    var searchResults: [UserProfileProxy] = []
    var isSearching = false

    var isEditing: Bool {
        meetingId != nil
    }

    var navigationTitle: String {
        isEditing ? SL10n.meetingEdit : SL10n.meetingNew
    }
}

struct MeetingEditViewStateBindings {
    var title = ""
    var description = ""
    var startDate = Date()
    var endDate = Date().addingTimeInterval(3600)
    var location = ""
    var isIndefinite = false
    var allowGuests = false
    var participants: [UserProfileProxy] = []
    var participantSearchQuery = ""
}
