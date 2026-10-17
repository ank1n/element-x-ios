// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

/// Status groups and duplicate selection follow CallTaskStatus.ts at d84205c35c,
/// with timestamp parsing scoped to the backend's ISO 8601 contract.
/// Pass tasks from all recording sessions together so an issue is counted once.
struct CallTaskStatistics {
    struct Counts: Equatable {
        var total = 0
        var backlog = 0
        var started = 0
        var completed = 0
        var cancelled = 0
        var unknown = 0
    }

    let counts: Counts
    /// First-seen issue order, with newer snapshots replacing their original slot.
    let uniqueTasks: [CreatedTask]

    var total: Int {
        counts.total
    }

    var backlog: Int {
        counts.backlog
    }

    var started: Int {
        counts.started
    }

    var completed: Int {
        counts.completed
    }

    var cancelled: Int {
        counts.cancelled
    }

    var unknown: Int {
        counts.unknown
    }

    init(tasks: [CreatedTask]) {
        struct IssueKey: Hashable {
            let projectID: String?
            let issueID: String
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nonFractional = ISO8601DateFormatter()
        nonFractional.formatOptions = [.withInternetDateTime]
        func timestamp(_ value: String?) -> Double {
            guard let value else { return .nan }
            // The API supplies RFC 3339 UTC timestamps or explicit offsets.
            // Exclude legacy JS date strings and partial formatter matches.
            let fullRange = NSRange(value.startIndex..., in: value)
            guard Self.timestampPattern?.firstMatch(in: value, range: fullRange)?.range == fullRange else { return .nan }
            var normalized = value
            if let dot = normalized.firstIndex(of: ".") {
                let start = normalized.index(after: dot)
                let end = normalized[start...].firstIndex { !$0.isNumber } ?? normalized.endIndex
                // Truncate before parsing: .1239 must tie with .123, not .124.
                if normalized.distance(from: start, to: end) > 3 {
                    normalized.removeSubrange(normalized.index(start, offsetBy: 3)..<end)
                }
            }
            guard let date = (normalized.contains(".") ? fractional : nonFractional).date(from: normalized) else { return .nan }
            // Foundation dates use floating point seconds. Round the already
            // truncated millisecond value to avoid tiny binary representation ties.
            return (date.timeIntervalSince1970 * 1000).rounded()
        }

        var positions: [IssueKey: Int] = [:]
        var selected: [CreatedTask] = []
        var selectedTimestamps: [Double] = []
        for task in tasks {
            // Match JS truthiness: whitespace is an ID; only nil/empty is absent.
            guard let issueID = task.trackitIssueId, !issueID.isEmpty else { continue }
            let key = IssueKey(projectID: task.trackitProjectId, issueID: issueID)
            if let index = positions[key] {
                // In particular, a valid candidate does not replace an invalid
                // first timestamp: both operands must parse and be strictly newer.
                let candidateTimestamp = timestamp(task.statusSyncedAt)
                if candidateTimestamp > selectedTimestamps[index] {
                    selected[index] = task
                    selectedTimestamps[index] = candidateTimestamp
                }
            } else {
                positions[key] = selected.count
                selected.append(task)
                selectedTimestamps.append(timestamp(task.statusSyncedAt))
            }
        }

        var result = Counts()
        result.total = selected.count
        for task in selected {
            // Never derive a group from the localized/project-specific state name.
            switch task.trackitStateGroup?.lowercased() {
            case "backlog", "unstarted": result.backlog += 1
            case "started": result.started += 1
            case "completed": result.completed += 1
            case "cancelled": result.cancelled += 1
            default: result.unknown += 1
            }
        }
        counts = result
        uniqueTasks = selected
    }

    private static let timestampPattern = try? NSRegularExpression(pattern: #"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})"#)
}

/// Presentational only: fetching, refresh errors and visibility belong to the caller.
struct CallTaskStatusSummary: View {
    let statistics: CallTaskStatistics
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(NSLocalizedString("stalk_call_tasks_summary_title", tableName: "Localizable", value: "Linked tasks", comment: "Call task status summary heading"))
            } icon: {
                Image(systemName: "checkmark.circle")
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                count(NSLocalizedString("stalk_call_tasks_total", tableName: "Localizable", value: "Total: %ld", comment: "Total linked task count"),
                      value: statistics.total, symbol: "number.circle", color: .primary, emphasized: true)
                count(NSLocalizedString("stalk_call_tasks_backlog", tableName: "Localizable", value: "Backlog: %ld", comment: "Backlog and unstarted task count"),
                      value: statistics.backlog, symbol: "tray", color: .secondary)
                count(NSLocalizedString("stalk_call_tasks_started", tableName: "Localizable", value: "In progress: %ld", comment: "Started task count"),
                      value: statistics.started, symbol: "circle.lefthalf.filled", color: .orange)
                count(NSLocalizedString("stalk_call_tasks_completed", tableName: "Localizable", value: "Completed: %ld", comment: "Completed task count"),
                      value: statistics.completed, symbol: "checkmark.circle.fill", color: .green)
                if statistics.cancelled > 0 {
                    count(NSLocalizedString("stalk_call_tasks_cancelled", tableName: "Localizable", value: "Cancelled: %ld", comment: "Cancelled task count"),
                          value: statistics.cancelled, symbol: "xmark.circle", color: .secondary)
                }
                if statistics.unknown > 0 {
                    count(NSLocalizedString("stalk_call_tasks_unknown", tableName: "Localizable", value: "Unknown status: %ld", comment: "Task count with an unknown status group"),
                          value: statistics.unknown, symbol: "questionmark.circle", color: .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var columns: [GridItem] {
        if dynamicTypeSize >= .xxxLarge {
            return [GridItem(.flexible(), alignment: .leading)]
        }
        return [GridItem(.adaptive(minimum: 150), alignment: .leading)]
    }

    private func count(_ format: String, value: Int, symbol: String, color: Color, emphasized: Bool = false) -> some View {
        let label = String(format: format, locale: Locale.current, value)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .foregroundColor(color)
                .accessibilityHidden(true)
            Text(label)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline.weight(emphasized ? .semibold : .regular))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }
}
