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

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}
