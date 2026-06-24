import Foundation

public struct MeetingEventCandidate: Equatable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var participants: [MeetingParticipant]

    public init(title: String, startDate: Date, endDate: Date, participants: [MeetingParticipant]) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.participants = participants
    }
}

public struct MeetingParticipantCandidate: Equatable, Sendable {
    public var displayName: String
    public var email: String?
    public var isResource: Bool
    public var isOrganizer: Bool
    public var isCurrentUser: Bool
    public var responseStatus: String?

    public init(
        displayName: String,
        email: String? = nil,
        isResource: Bool = false,
        isOrganizer: Bool = false,
        isCurrentUser: Bool = false,
        responseStatus: String? = nil
    ) {
        self.displayName = displayName
        self.email = email
        self.isResource = isResource
        self.isOrganizer = isOrganizer
        self.isCurrentUser = isCurrentUser
        self.responseStatus = responseStatus
    }
}

public enum MeetingAutofillSupport {
    public static func bestMatchingEvent(
        from candidates: [MeetingEventCandidate],
        now: Date,
        upcomingGracePeriod: TimeInterval = 15 * 60
    ) -> MeetingEventCandidate? {
        let ongoing = candidates
            .filter { $0.startDate <= now && now < $0.endDate }
            .sorted {
                if $0.startDate == $1.startDate {
                    return $0.endDate < $1.endDate
                }
                return $0.startDate > $1.startDate
            }
            .first

        if let ongoing {
            return ongoing
        }

        let latestUpcomingDate = now.addingTimeInterval(upcomingGracePeriod)
        return candidates
            .filter { $0.startDate >= now && $0.startDate <= latestUpcomingDate }
            .sorted {
                if $0.startDate == $1.startDate {
                    return $0.endDate < $1.endDate
                }
                return $0.startDate < $1.startDate
            }
            .first
    }

    public static func filteredParticipants(from candidates: [MeetingParticipantCandidate]) -> [MeetingParticipant] {
        let eligibleCandidates = candidates.filter { candidate in
            guard !candidate.isResource else { return false }

            let trimmedStatus = candidate.responseStatus?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return trimmedStatus != "declined"
        }

        let visibleCandidates = eligibleCandidates.filter { !$0.isCurrentUser }
        let invitees = visibleCandidates.filter { !$0.isOrganizer }
        let candidatesToRender = invitees.isEmpty ? visibleCandidates : invitees
        var seen = Set<String>()

        return candidatesToRender.compactMap { candidate in
            let trimmedName = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedEmail = candidate.email?.trimmingCharacters(in: .whitespacesAndNewlines)

            let displayName: String
            if trimmedName.isEmpty || trimmedName.lowercased().hasPrefix("mailto:") {
                if let trimmedEmail, !trimmedEmail.isEmpty {
                    displayName = trimmedEmail
                } else {
                    displayName = trimmedName
                }
            } else {
                displayName = trimmedName
            }

            let normalizedEmail = trimmedEmail?.isEmpty == true ? nil : trimmedEmail
            let dedupeKey = (normalizedEmail ?? displayName).lowercased()
            guard !displayName.isEmpty, !seen.contains(dedupeKey) else { return nil }
            seen.insert(dedupeKey)

            return MeetingParticipant(
                displayName: displayName,
                email: normalizedEmail
            )
        }
    }
}
