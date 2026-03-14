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

struct MeetingsScreenViewState: BindableState {
    var meetings: [Meeting] = []
    var holidays: Set<String> = [] // "YYYY-MM-DD"
    var selectedDate: Date = .now
    var isLoading = true
    var errorMessage: String?
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
    var currentUserId: String = ""
    var homeserverURL: String = ""
    var isLoading = false
    var linkCopied = false
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

struct MeetingDetailViewStateBindings { }

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

    var isEditing: Bool { meetingId != nil }
    var navigationTitle: String { isEditing ? SL10n.meetingEdit : SL10n.meetingNew }
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
