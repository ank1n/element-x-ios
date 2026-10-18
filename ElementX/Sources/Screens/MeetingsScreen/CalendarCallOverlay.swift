// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A local overlay, never persisted as a meeting or used to create reminders/invitations.
struct CalendarAgendaEntry: Identifiable {
    let id: String
    let meeting: Meeting?
    let calls: [CallHistoryItem]
    var startTime: Date { meeting?.startTime ?? calls[0].timestamp }
    var taskCount: Int { calls.reduce(0) { $0 + max(0, $1.createdTaskCount ?? 0) } }

    static func make(meetings: [Meeting], calls: [CallHistoryItem], showUnplanned: Bool) -> [Self] {
        var entries = meetings.filter { $0.status != .cancelled }.map { Self(id: "meeting:\($0.id)", meeting: $0, calls: []) }
        var seen = Set<String>()
        for call in CallHistoryItem.mergingTaskMetadata(in: calls).sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = call.contactId + ":" + (call.callId ?? call.id)
            guard seen.insert(key).inserted else { continue }
            let end = call.timestamp.addingTimeInterval(max(1, call.duration ?? 0))
            if let index = entries.firstIndex(where: { entry in
                guard let meeting = entry.meeting else { return false }
                let meetingEnd = meeting.endTime > meeting.startTime ? meeting.endTime : meeting.startTime.addingTimeInterval(3600)
                return meeting.matrixRoomId == call.contactId && call.timestamp < meetingEnd && end > meeting.startTime
            }) {
                let entry = entries[index]
                entries[index] = Self(id: entry.id, meeting: entry.meeting, calls: entry.calls + [call])
            } else if showUnplanned {
                entries.append(Self(id: "call:" + key, meeting: nil, calls: [call]))
            }
        }
        return entries.sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
    }
}

struct CalendarCallHistorySnapshot: Equatable {
    let calls: [CallHistoryItem]
    let unavailable: Bool
    let loading: Bool
}
