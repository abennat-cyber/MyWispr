import EventKit
import Foundation
import MyWisprCore

enum LocalCalendarError: Error, LocalizedError {
    case denied
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Grant Apple Calendar access in Settings to autofill meeting title and participants."
        case .lookupFailed(let details):
            return details
        }
    }
}

actor LocalCalendarAccessService {
    private let eventStore = EKEventStore()

    func accessState() -> CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .granted
        case .denied, .restricted, .writeOnly:
            return .denied("Grant full Calendar access in System Settings to read upcoming meetings.")
        @unknown default:
            return .denied("Calendar access is unavailable on this Mac.")
        }
    }

    func requestAccess() async -> CalendarAccessState {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess {
            return .granted
        }

        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, _ in
                if granted {
                    continuation.resume(returning: .granted)
                } else {
                    continuation.resume(returning: .denied("Grant full Calendar access in System Settings to read upcoming meetings."))
                }
            }
        }
    }

    func fetchSuggestion(at date: Date) async throws -> MeetingContextSuggestion? {
        try await fetchSuggestion(at: date, selectedCalendarIdentifier: "")
    }

    func availableCalendars() async -> [CalendarSelection] {
        guard accessState() == .granted else { return [] }
        return eventStore.calendars(for: .event)
            .sorted {
                let left = "\($0.source.title) \($0.title)"
                let right = "\($1.source.title) \($1.title)"
                return left.localizedStandardCompare(right) == .orderedAscending
            }
            .map {
                CalendarSelection(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
    }

    func fetchSuggestion(at date: Date, selectedCalendarIdentifier: String) async throws -> MeetingContextSuggestion? {
        let state = accessState()
        guard state == .granted else {
            throw LocalCalendarError.denied
        }

        let startWindow = date.addingTimeInterval(-4 * 60 * 60)
        let endWindow = date.addingTimeInterval(15 * 60)
        let allCalendars = eventStore.calendars(for: .event)
        let calendars: [EKCalendar]
        if selectedCalendarIdentifier.isEmpty {
            calendars = allCalendars
        } else {
            calendars = allCalendars.filter { $0.calendarIdentifier == selectedCalendarIdentifier }
        }
        guard !calendars.isEmpty else {
            throw LocalCalendarError.lookupFailed("The selected calendar is no longer available. Choose another calendar in Settings.")
        }

        let predicate = eventStore.predicateForEvents(withStart: startWindow, end: endWindow, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        let candidates: [(MeetingEventCandidate, String)] = events.compactMap { event in
            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let participants = MeetingAutofillSupport.filteredParticipants(
                from: (event.attendees ?? []).map { attendee in
                    MeetingParticipantCandidate(
                        displayName: Self.displayName(for: attendee),
                        email: Self.extractEmail(from: attendee.url),
                        isResource: Self.isResource(attendee.participantType),
                        isOrganizer: attendee.participantRole == .chair,
                        isCurrentUser: attendee.isCurrentUser,
                        responseStatus: Self.responseStatusString(attendee.participantStatus)
                    )
                }
            )

            let candidate = MeetingEventCandidate(
                title: title,
                startDate: event.startDate,
                endDate: event.endDate,
                participants: participants
            )
            return (candidate, event.calendar.title)
        }

        guard let best = MeetingAutofillSupport.bestMatchingEvent(
            from: candidates.map(\.0),
            now: date,
            upcomingGracePeriod: 15 * 60
        ) else {
            return nil
        }

        let matchedCalendar = candidates.first(where: { candidate, _ in
            candidate.title == best.title
                && candidate.startDate == best.startDate
                && candidate.endDate == best.endDate
        })?.1

        return MeetingContextSuggestion(
            suggestedTitle: best.title,
            participants: best.participants,
            calendarName: matchedCalendar,
            eventStart: best.startDate,
            eventEnd: best.endDate
        )
    }

    private static func responseStatusString(_ status: EKParticipantStatus) -> String? {
        switch status {
        case .unknown:
            return "unknown"
        case .pending:
            return "pending"
        case .accepted:
            return "accepted"
        case .tentative:
            return "tentative"
        case .declined:
            return "declined"
        case .delegated:
            return "delegated"
        case .completed:
            return "completed"
        case .inProcess:
            return "in_process"
        default:
            return nil
        }
    }

    private static func displayName(for attendee: EKParticipant) -> String {
        let trimmedName = attendee.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        if let email = extractEmail(from: attendee.url) {
            return email
        }

        return attendee.url.absoluteString
    }

    private static func isResource(_ participantType: EKParticipantType) -> Bool {
        switch participantType {
        case .room, .resource:
            return true
        default:
            return false
        }
    }

    private static func extractEmail(from url: URL) -> String? {
        let absoluteString = url.absoluteString
        if absoluteString.hasPrefix("mailto:") {
            return String(absoluteString.dropFirst("mailto:".count))
        }
        return nil
    }
}

struct LocalCalendarMeetingContextProvider: MeetingContextProvider, Sendable {
    let accessService: LocalCalendarAccessService
    let selectedCalendarIdentifier: @Sendable () async -> String

    func fetchContext(for draft: MeetingSessionDraft, during date: Date) async -> MeetingContextLookupState {
        switch await accessService.accessState() {
        case .notDetermined:
            let requestState = await accessService.requestAccess()
            guard requestState == .granted else {
                return .unavailable(requestState.message ?? requestState.title)
            }
        case .granted:
            break
        case .requesting:
            break
        case .denied(let message):
            return .unavailable(message)
        }

        do {
            let selectedCalendarIdentifier = await selectedCalendarIdentifier()
            guard let suggestion = try await accessService.fetchSuggestion(
                at: date,
                selectedCalendarIdentifier: selectedCalendarIdentifier
            ) else {
                return .unavailable("No Apple Calendar event is in progress or starting within the next 15 minutes.")
            }
            return .suggested(suggestion)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
