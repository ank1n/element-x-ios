// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct MeetingFreeNowView: View {
    let service: MeetingsService
    let mediaProvider: MediaProviderProtocol?
    let changed: () -> Void
    let open: (Meeting) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var duration = 30
    @State private var office: Int?
    @State private var offices: [MeetingVenueOffice] = []
    @State private var rooms: [MeetingFreeNow.Room] = []
    @State private var busy = false
    @State private var booking = false
    @State private var error: String?
    @State private var booked: Meeting?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(MeetingVenueStrings.text("duration"), selection: $duration) {
                        ForEach([15, 30, 60], id: \.self) { Text(String(format: MeetingVenueStrings.text("minutes"), $0)).tag($0) }
                    }.pickerStyle(.segmented).disabled(busy || booked != nil)
                    Picker(MeetingVenueStrings.text("office"), selection: $office) {
                        Text(MeetingVenueStrings.text("all_offices")).tag(Int?.none)
                        ForEach(offices) { Text($0.name).tag(Optional($0.id)) }
                    }.disabled(busy)
                }
                if let booked {
                    Section {
                        Label(MeetingVenueStrings.text(booked.room?.status == "pending" ? "pending_hint" : booked.room?.checkin?.checked_in_at != nil || booked.room?.checked_in_at != nil ? "checked_in" : "reserved_now"), systemImage: booked.room?.status == "pending" ? "clock" : "checkmark.circle")
                        Button(MeetingVenueStrings.text("open_meeting")) { open(booked) }
                    }
                }
                if busy { ProgressView() }
                if let error {
                    Text(error).foregroundStyle(.red)
                    Button(L10n.actionRetry) { Task { await load() } }.disabled(busy)
                }
                if rooms.isEmpty, !busy, error == nil { Text(MeetingVenueStrings.text("none_free")) }
                ForEach(rooms) { room in
                    VStack(alignment: .leading, spacing: 8) {
                        MeetingVenuePhoto(source: room.photo_mxc, name: room.name, mediaProvider: mediaProvider)
                        Text(room.name).font(.headline)
                        Text([room.office_name, room.floor, room.capacity.map { String(format: MeetingVenueStrings.text("capacity"), $0) }].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                        if let until = room.free_until, let date = MeetingVenueStrings.date(until) {
                            Text(MeetingVenueStrings.text("free_until") + " " + date.formatted(date: .omitted, time: .shortened)).font(.caption)
                        }
                        Button(MeetingVenueStrings.text("take_room")) { Task { await take(room) } }
                            .disabled(busy || booked != nil || error != nil)
                    }
                }
            }
            .navigationTitle(MeetingVenueStrings.text("free_now"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.actionClose) { dismiss() }.disabled(booking) } }
            .interactiveDismissDisabled(booking)
            .task(id: "\(duration)-\(office ?? -1)") { await load() }
        }
    }

    private func load() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if offices.isEmpty { offices = try await service.venueOffices() }
            let data = try await service.freeNow(duration: duration, officeID: office)
            guard !Task.isCancelled else { return }
            rooms = data.rooms; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func take(_ room: MeetingFreeNow.Room) async {
        guard !busy, booked == nil else { return }; busy = true; booking = true; error = nil
        do {
            let fresh = try await service.freeNow(duration: duration, officeID: office)
            guard fresh.rooms.contains(where: { $0.id == room.id }) else { throw MeetingVenueError(status: 409, code: "room_busy") }
            guard let start = MeetingVenueStrings.date(fresh.start), let end = MeetingVenueStrings.date(fresh.end), end > start else { throw URLError(.badServerResponse) }
            let request = MeetingRequest(title: String(format: MeetingVenueStrings.text("quick_title"), room.name), startTime: start,
                                         endTime: end, roomID: room.id)
            let meeting = try await service.createMeeting(request)
            booked = meeting // Persist the successful creation before attempting check-in.
            changed()
            if meeting.room?.status == "confirmed" {
                do {
                    let result = try await service.venueAction(meetingID: meeting.id, action: "checkin")
                    booked?.room = result.room; booked?.roomReleased = result.room_released
                } catch { self.error = MeetingVenueStrings.text("created_checkin_pending") + " " + error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
        booking = false
        // Read-only refresh after either success or a 409/network error; never resend POST.
        if let data = try? await service.freeNow(duration: duration, officeID: office) { rooms = data.rooms }
        busy = false
    }
}
