// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct MeetingVenuePickerView: View {
    @ObservedObject var context: MeetingEditViewModelType.Context
    var body: some View {
        if context.viewState.venuesAvailable || context.viewState.venuesLoading || context.viewState.venueError != nil {
            LazyVStack(alignment: .leading, spacing: 12) {
                if context.viewState.venuesAvailable {
                    Toggle(MeetingVenueStrings.text("reserve"), isOn: $context.venueWanted)
                    if context.viewState.bindings.venueWanted {
                        if context.viewState.bindings.isIndefinite {
                            Text(MeetingVenueStrings.text("needs_end")).foregroundStyle(.red)
                        } else {
                            if !context.viewState.bindings.venueName.isEmpty {
                                Label(context.viewState.bindings.venueName, systemImage: "door.left.hand.open")
                            }
                            TextField(MeetingVenueStrings.text("search"), text: $context.venueQuery)
                            Toggle(MeetingVenueStrings.text("recent"), isOn: $context.venueRecent)
                            if !context.viewState.bindings.venueRecent {
                                Picker(MeetingVenueStrings.text("office"), selection: $context.venueOfficeID) {
                                    Text(MeetingVenueStrings.text("all_offices")).tag(Int?.none)
                                    ForEach(context.viewState.venueOffices) { Text($0.name).tag(Optional($0.id)) }
                                }
                            }
                            ForEach(context.viewState.venueRooms) { room in
                                let conflicts = room.conflicts(excluding: context.viewState.meetingId)
                                Button {
                                    context.venueID = room.id; context.venueName = room.name
                                } label: {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            MeetingVenuePhoto(source: room.photo_mxc, name: room.name, mediaProvider: context.mediaProvider, height: 100)
                                            Text(room.name)
                                            Text([room.office_name, room.floor.map { String(format: MeetingVenueStrings.text("floor"), $0) }, room.capacity.map { String(format: MeetingVenueStrings.text("capacity"), $0) }].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                                            if let equipment = room.equipment, !equipment.isEmpty { Text(equipment.joined(separator: ", ")).font(.caption) }
                                            if !room.can_book { Text(MeetingVenueStrings.text("forbidden")).font(.caption) }
                                            ForEach(Array(conflicts.enumerated()), id: \.offset) { _, busy in
                                                Text(MeetingVenueStrings.text("busy") + " " + MeetingVenueStrings.interval(start: busy.start, end: busy.end)).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if context.viewState.bindings.venueID == room.id { Image(systemName: "checkmark") }
                                    }
                                }.disabled(!room.can_book || !conflicts.isEmpty)
                            }
                        }
                    }
                }
                if context.viewState.venuesLoading { ProgressView() }
                if let error = context.viewState.venueError {
                    Text(error).foregroundStyle(.secondary)
                    Button(L10n.actionRetry) { context.send(viewAction: .loadVenues) }
                }
            }.padding(16).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
