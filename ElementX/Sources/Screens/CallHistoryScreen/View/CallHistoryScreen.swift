//
// Copyright 2025 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
//

import Compound
import SwiftUI

struct CallHistoryScreen: View {
    @ObservedObject var context: CallHistoryScreenViewModel.Context

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Filter chips
                filterChips

                // Recordings list
                if context.viewState.isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if context.viewState.filteredRecordings.isEmpty {
                    emptyState
                } else {
                    recordingsList
                }
            }
            .padding()
        }
        .navigationTitle("История звонков")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: Binding(
            get: { context.viewState.searchQuery },
            set: { context.send(viewAction: .search($0)) }
        ), prompt: "Поиск звонков")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    context.send(viewAction: .refresh)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            context.send(viewAction: .appeared)
        }
        .alert(item: $context.bindings.alertInfo)
    }

    // MARK: - Private Views

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(CallHistoryFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.displayName,
                        isSelected: context.viewState.selectedFilter == filter
                    ) {
                        context.send(viewAction: .selectFilter(filter))
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var recordingsList: some View {
        ForEach(context.viewState.filteredRecordings) { recording in
            CallHistoryCell(recording: recording) {
                context.send(viewAction: .playRecording(recording))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.badge.waveform")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
                .padding(.top, 60)

            Text("Нет записей звонков")
                .font(.title2)
                .foregroundColor(.primary)

            Text("Записи ваших звонков будут отображаться здесь")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(.systemGray5))
                .cornerRadius(20)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        CallHistoryScreen(
            context: CallHistoryScreenViewModel(
                callHistoryService: CallHistoryServiceMock()
            ).context
        )
    }
}
