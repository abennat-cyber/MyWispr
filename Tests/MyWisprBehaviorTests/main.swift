import Foundation
import MyWisprCore

@main
struct MyWisprBehaviorTests {
    static func main() {
        testHebrewOnlyWithoutVocabularyHasNoLocalPrompt()
        testHebrewOnlyWithVocabularyUsesHebrewPromptFrame()
        testEnglishOnlyKeepsEnglishVocabularyPromptFrame()
        testMultiLanguagePromptRemainsEnglishLanguageHint()
        testHebrewTextIsAcceptedForHebrewOnlySettings()
        testEnglishOnlyTextRetriesForHebrewOnlySettings()
        testMixedHebrewAndEnglishTextIsAcceptedForHebrewOnlySettings()
        testMeetingBundleFormatterKeepsStructuredFieldsSeparate()
        testMeetingBundleJSONUsesPriorityContract()
        testMeetingAutofillPrefersOngoingEvent()
        testMeetingAutofillFallsBackToUpcomingWindow()
        testMeetingParticipantFilterExcludesDeclinedAndResources()
        testMeetingParticipantFilterKeepsPendingInviteesAndDropsOwner()
        testMeetingParticipantFilterDoesNotReturnCurrentUserOnly()
        testDictationRecordingFormatSelection()
        testLocalWhisperConversionPolicy()
        testRecordingRetentionPurgesExpiredAudioFormats()
        testRecordingRetentionUsesModificationDateForLegacyAudio()
        testRecordingRetentionPurgesTimestampedMeetingSidecars()
        testRecordingRetentionKeepsUnrelatedTextFiles()
        testActivationWaitPolicy()
        testSilentTranscriptFilter()
        testAudioSilencePolicy()
        testMeetingLiveTranscriptionChunkPolicy()
        testMeetingLiveTranscriptionAppendPolicy()
        testInsertionTextFormatterAddsSpaceAndLowercasesInSentence()
        testInsertionTextFormatterAddsSpaceBeforeNextWord()
    }

    private static func testHebrewOnlyWithoutVocabularyHasNoLocalPrompt() {
        let prompt = TranscriptionPromptBuilder.localPrompt(
            languageNames: ["Hebrew"],
            languageScripts: [.hebrew],
            vocabulary: []
        )

        expect(prompt == nil, "Hebrew-only local prompt should be nil without vocabulary.")
    }

    private static func testHebrewOnlyWithVocabularyUsesHebrewPromptFrame() {
        let prompt = TranscriptionPromptBuilder.localPrompt(
            languageNames: ["Hebrew"],
            languageScripts: [.hebrew],
            vocabulary: ["MyWispr", " Assaf "]
        )

        expect(prompt == "מילים חשובות: MyWispr, Assaf.", "Hebrew vocabulary prompt should use Hebrew framing.")
        expect(prompt?.contains("Custom vocabulary") == false, "Hebrew local prompt should not use English framing.")
    }

    private static func testEnglishOnlyKeepsEnglishVocabularyPromptFrame() {
        let prompt = TranscriptionPromptBuilder.localPrompt(
            languageNames: ["English"],
            languageScripts: [.latin],
            vocabulary: ["MyWispr"]
        )

        expect(prompt == "Custom vocabulary: MyWispr.", "English vocabulary prompt should keep English framing.")
    }

    private static func testMultiLanguagePromptRemainsEnglishLanguageHint() {
        let prompt = TranscriptionPromptBuilder.localPrompt(
            languageNames: ["English", "Hebrew"],
            languageScripts: [.latin, .hebrew],
            vocabulary: []
        )

        expect(
            prompt == "The audio may be in any of these languages: English, Hebrew.",
            "Multi-language prompt should remain unchanged."
        )
    }

    private static func testHebrewTextIsAcceptedForHebrewOnlySettings() {
        expect(TranscriptScriptValidator.containsExpectedScript("שלום עולם", expectedScript: .hebrew), "Hebrew text should match Hebrew settings.")
        expect(!TranscriptScriptValidator.shouldRetryWithoutPrompt("שלום עולם", expectedScript: .hebrew), "Hebrew text should not retry.")
    }

    private static func testEnglishOnlyTextRetriesForHebrewOnlySettings() {
        expect(!TranscriptScriptValidator.containsExpectedScript("Hello world", expectedScript: .hebrew), "English text should not match Hebrew settings.")
        expect(TranscriptScriptValidator.shouldRetryWithoutPrompt("Hello world", expectedScript: .hebrew), "English text should retry for Hebrew settings.")
    }

    private static func testMixedHebrewAndEnglishTextIsAcceptedForHebrewOnlySettings() {
        expect(TranscriptScriptValidator.containsExpectedScript("שלום MyWispr", expectedScript: .hebrew), "Mixed text containing Hebrew should match Hebrew settings.")
        expect(!TranscriptScriptValidator.shouldRetryWithoutPrompt("שלום MyWispr", expectedScript: .hebrew), "Mixed text containing Hebrew should not retry.")
    }

    private static func testMeetingBundleFormatterKeepsStructuredFieldsSeparate() {
        let bundle = sampleMeetingBundle()
        let summary = MeetingBundleFormatter.humanReadableSummary(for: bundle)

        expect(summary.contains("Title: Weekly sync"), "Summary should include the title field.")
        expect(summary.contains("Participants: Ada Lovelace <ada@example.com>"), "Summary should include participants separately.")
        expect(summary.contains("Personal notes:\nDecision already made offline."), "Summary should keep personal notes in a dedicated section.")
        expect(summary.contains("Transcript:\nWe discussed launch timing."), "Summary should keep transcript in a dedicated section.")
    }

    private static func testMeetingBundleJSONUsesPriorityContract() {
        let bundle = sampleMeetingBundle()
        let json = tryValue {
            try MeetingBundleFormatter.prettyJSONString(for: bundle)
        }

        expect(json.contains("\"personalNotesPriority\" : \"higher_than_transcript_when_conflict_exists\""), "JSON should encode the notes priority contract.")
        expect(json.contains("\"title\" : \"Weekly sync\""), "JSON should encode the meeting title.")
    }

    private static func testMeetingAutofillPrefersOngoingEvent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ongoing = MeetingEventCandidate(
            title: "Ongoing sync",
            startDate: now.addingTimeInterval(-300),
            endDate: now.addingTimeInterval(900),
            participants: []
        )
        let upcoming = MeetingEventCandidate(
            title: "Upcoming review",
            startDate: now.addingTimeInterval(600),
            endDate: now.addingTimeInterval(1_200),
            participants: []
        )

        let selected = MeetingAutofillSupport.bestMatchingEvent(from: [upcoming, ongoing], now: now)
        expect(selected?.title == "Ongoing sync", "Autofill should prefer a currently ongoing event.")
    }

    private static func testMeetingAutofillFallsBackToUpcomingWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let nearUpcoming = MeetingEventCandidate(
            title: "Starts soon",
            startDate: now.addingTimeInterval(10 * 60),
            endDate: now.addingTimeInterval(40 * 60),
            participants: []
        )
        let farUpcoming = MeetingEventCandidate(
            title: "Too far away",
            startDate: now.addingTimeInterval(40 * 60),
            endDate: now.addingTimeInterval(70 * 60),
            participants: []
        )

        let selected = MeetingAutofillSupport.bestMatchingEvent(from: [farUpcoming, nearUpcoming], now: now)
        expect(selected?.title == "Starts soon", "Autofill should fall back to the next meeting within the grace period.")
    }

    private static func testMeetingParticipantFilterExcludesDeclinedAndResources() {
        let participants = MeetingAutofillSupport.filteredParticipants(from: [
            MeetingParticipantCandidate(displayName: "Ada", email: "ada@example.com", isResource: false, responseStatus: "accepted"),
            MeetingParticipantCandidate(displayName: "Room 12", email: "room12@example.com", isResource: true, responseStatus: "accepted"),
            MeetingParticipantCandidate(displayName: "Grace", email: "grace@example.com", isResource: false, responseStatus: "declined"),
            MeetingParticipantCandidate(displayName: "Linus", email: "linus@example.com", isResource: false, responseStatus: "tentative"),
        ])

        expect(participants.map(\.displayName) == ["Ada", "Linus"], "Participant filtering should exclude declined guests and resources.")
    }

    private static func testMeetingParticipantFilterKeepsPendingInviteesAndDropsOwner() {
        let participants = MeetingAutofillSupport.filteredParticipants(from: [
            MeetingParticipantCandidate(
                displayName: "Owner",
                email: "owner@example.com",
                isOrganizer: true,
                isCurrentUser: true,
                responseStatus: "accepted"
            ),
            MeetingParticipantCandidate(displayName: "Pending Guest", email: "pending@example.com", responseStatus: "pending"),
            MeetingParticipantCandidate(displayName: "", email: "unknown@example.com", responseStatus: "unknown"),
        ])

        expect(
            participants == [
                MeetingParticipant(displayName: "Pending Guest", email: "pending@example.com"),
                MeetingParticipant(displayName: "unknown@example.com", email: "unknown@example.com"),
            ],
            "Participant filtering should keep non-declined invitees and avoid returning only the current account owner."
        )
    }

    private static func testMeetingParticipantFilterDoesNotReturnCurrentUserOnly() {
        let participants = MeetingAutofillSupport.filteredParticipants(from: [
            MeetingParticipantCandidate(
                displayName: "Owner",
                email: "owner@example.com",
                isOrganizer: true,
                isCurrentUser: true,
                responseStatus: "accepted"
            ),
        ])

        expect(participants.isEmpty, "Participant filtering should not autofill the current user as the only participant.")
    }

    private static func testDictationRecordingFormatSelection() {
        expect(
            DictationRecordingFormatSelector.recordingFormat(forEngineRawValue: "localWhisper") == .wav,
            "Local Whisper dictation should record directly as WAV."
        )
        expect(
            DictationRecordingFormatSelector.recordingFormat(forEngineRawValue: "whisperAPI") == .m4a,
            "Whisper API dictation should keep compressed M4A recording."
        )
        expect(
            DictationRecordingFormatSelector.recordingFormat(forEngineRawValue: "customCommand") == .m4a,
            "Custom command dictation should keep the previous M4A default."
        )
    }

    private static func testLocalWhisperConversionPolicy() {
        expect(
            !LocalWhisperConversionPolicy.requiresConversion(fileExtension: "wav"),
            "Local Whisper should skip conversion for WAV input."
        )
        expect(
            !LocalWhisperConversionPolicy.requiresConversion(fileExtension: " WAV "),
            "Local Whisper conversion policy should normalize WAV extensions."
        )
        expect(
            LocalWhisperConversionPolicy.requiresConversion(fileExtension: "m4a"),
            "Local Whisper should still convert non-WAV input."
        )
    }

    private static func testRecordingRetentionPurgesExpiredAudioFormats() {
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!
        let old = now.addingTimeInterval(-90_000)

        expect(
            RecordingRetentionPolicy.shouldPurge(
                fileName: "2026-06-23T08-00-00Z.wav",
                creationDate: old,
                contentModificationDate: old,
                now: now,
                maxAge: 86_400
            ),
            "Expired WAV recordings should be purgeable."
        )
        expect(
            RecordingRetentionPolicy.shouldPurge(
                fileName: "2026-06-23T08-00-00Z.m4a",
                creationDate: old,
                contentModificationDate: old,
                now: now,
                maxAge: 86_400
            ),
            "Expired M4A recordings should remain purgeable."
        )
    }

    private static func testRecordingRetentionUsesModificationDateForLegacyAudio() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-90_000)
        let recent = now.addingTimeInterval(-60)

        expect(
            RecordingRetentionPolicy.shouldPurge(
                fileName: "legacy-recording.wav",
                creationDate: recent,
                contentModificationDate: old,
                now: now,
                maxAge: 86_400
            ),
            "Legacy audio without a filename timestamp should expire by modification date."
        )
        expect(
            !RecordingRetentionPolicy.shouldPurge(
                fileName: "legacy-recording.m4a",
                creationDate: old,
                contentModificationDate: recent,
                now: now,
                maxAge: 86_400
            ),
            "Recently modified legacy audio should not be purged only because creation date is old."
        )
    }

    private static func testRecordingRetentionPurgesTimestampedMeetingSidecars() {
        let now = ISO8601DateFormatter().date(from: "2026-06-24T12:00:00Z")!

        expect(
            RecordingRetentionPolicy.shouldPurge(
                fileName: "Meeting-2026-06-23T08-00-00Z.json",
                creationDate: now,
                contentModificationDate: now,
                now: now,
                maxAge: 86_400
            ),
            "Expired meeting JSON sidecars should be purged using the filename timestamp."
        )
        expect(
            RecordingRetentionPolicy.shouldPurge(
                fileName: "Meeting-2026-06-23T08-00-00Z.txt",
                creationDate: now,
                contentModificationDate: now,
                now: now,
                maxAge: 86_400
            ),
            "Expired meeting text sidecars should be purged using the filename timestamp."
        )
    }

    private static func testRecordingRetentionKeepsUnrelatedTextFiles() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-90_000)

        expect(
            !RecordingRetentionPolicy.shouldPurge(
                fileName: "notes.txt",
                creationDate: old,
                contentModificationDate: old,
                now: now,
                maxAge: 86_400
            ),
            "Retention cleanup should not delete unrelated text files without a MyWispr timestamp."
        )
    }

    private static func testActivationWaitPolicy() {
        expect(
            !ActivationWaitPolicy.shouldKeepWaiting(
                elapsedMilliseconds: 0,
                maxMilliseconds: 150,
                targetIsFrontmost: true
            ),
            "Insertion should not wait when the target app is already active."
        )
        expect(
            ActivationWaitPolicy.shouldKeepWaiting(
                elapsedMilliseconds: 45,
                maxMilliseconds: 150,
                targetIsFrontmost: false
            ),
            "Insertion should continue briefly while the target app is not active."
        )
        expect(
            !ActivationWaitPolicy.shouldKeepWaiting(
                elapsedMilliseconds: 150,
                maxMilliseconds: 150,
                targetIsFrontmost: false
            ),
            "Insertion wait should stop at the maximum wait cap."
        )
    }

    private static func testSilentTranscriptFilter() {
        expect(!TranscriptPostProcessor.shouldInsert("Thank you."), "Common silence hallucinations should not be inserted.")
        expect(!TranscriptPostProcessor.shouldInsert(" [BLANK_AUDIO] "), "Blank audio markers should not be inserted.")
        expect(TranscriptPostProcessor.shouldInsert("Please send the report."), "Real dictation should still be inserted.")
    }

    private static func testAudioSilencePolicy() {
        expect(
            !AudioSilencePolicy.hasSpeech(duration: 2.0, rootMeanSquare: 0.0001, peakAmplitude: 0.001),
            "Very quiet audio should be treated as no speech before transcription."
        )
        expect(
            !AudioSilencePolicy.hasSpeech(duration: 0.1, rootMeanSquare: 0.1, peakAmplitude: 0.2),
            "Extremely short audio should be treated as no speech."
        )
        expect(
            AudioSilencePolicy.hasSpeech(duration: 2.0, rootMeanSquare: 0.02, peakAmplitude: 0.05),
            "Speech-level audio should be allowed through to transcription."
        )
    }

    private static func testMeetingLiveTranscriptionChunkPolicy() {
        expect(
            MeetingLiveTranscriptionSupport.chunkDuration == 10,
            "Meeting live transcription should use 10-second chunks."
        )
        expect(
            !MeetingLiveTranscriptionSupport.isChunkReady(elapsed: 9.0, start: 0),
            "Live transcription should not export a chunk before enough audio exists."
        )
        expect(
            MeetingLiveTranscriptionSupport.isChunkReady(elapsed: 9.8, start: 0),
            "Live transcription should tolerate minor recorder timing drift."
        )
    }

    private static func testMeetingLiveTranscriptionAppendPolicy() {
        expect(
            MeetingLiveTranscriptionSupport.appendedTranscript(existing: "", newText: " First point. ") == "First point.",
            "First live transcript chunk should be trimmed."
        )
        expect(
            MeetingLiveTranscriptionSupport.appendedTranscript(existing: "First point.", newText: "Second point.") == "First point.\nSecond point.",
            "Live transcript chunks should stay separated by line breaks."
        )
        expect(
            MeetingLiveTranscriptionSupport.appendedTranscript(existing: "First point.", newText: "  ") == "First point.",
            "Blank live transcript chunks should be ignored."
        )
    }

    private static func testInsertionTextFormatterAddsSpaceAndLowercasesInSentence() {
        let formatted = InsertionTextFormatter.formattedTranscript(
            "Hello team",
            context: InsertionTextContext(previousCharacter: "e")
        )

        expect(formatted == " hello team", "Insertion in the middle of a sentence should add a space and lowercase the first word.")
    }

    private static func testInsertionTextFormatterAddsSpaceBeforeNextWord() {
        let formatted = InsertionTextFormatter.formattedTranscript(
            "Hello team",
            context: InsertionTextContext(nextCharacter: "w")
        )

        expect(formatted == " hello team", "Insertion directly before an existing word should add a leading space and lowercase the first word.")
    }

    private static func sampleMeetingBundle() -> RecordedMeetingBundle {
        RecordedMeetingBundle(
            title: "Weekly sync",
            participants: [MeetingParticipant(displayName: "Ada Lovelace", email: "ada@example.com")],
            personalNotes: "Decision already made offline.",
            personalNotesPriority: .higherThanTranscriptWhenConflictExists,
            transcript: "We discussed launch timing.",
            recordingStartedAt: Date(timeIntervalSince1970: 100),
            recordingEndedAt: Date(timeIntervalSince1970: 200),
            audioFileName: "Meeting-2026-05-06T09-00-00Z.m4a",
            audioFilePath: "/tmp/Meeting-2026-05-06T09-00-00Z.m4a"
        )
    }

    private static func tryValue<T>(_ operation: () throws -> T) -> T {
        do {
            return try operation()
        } catch {
            fatalError("Unexpected error: \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
