# Ghost Placeholder Capitalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve sentence capitalization when an empty editor exposes word-like ghost placeholder text after the insertion point.

**Architecture:** Keep sentence normalization in `RuleBasedDictationTextFormatter` and context-aware insertion in `InsertionTextFormatter`. Continue using surrounding word-like characters to decide whether spacing is needed, but use only a preceding word-like character as evidence that insertion occurs mid-sentence.

**Tech Stack:** Swift 6, Foundation, Swift Package Manager behavior-test executable

## Global Constraints

- Support macOS 14 or later.
- Do not add dependencies or application-specific checks.
- Preserve contextual lowercasing after a preceding word-like character.

---

### Task 1: Separate spacing context from capitalization context

**Files:**
- Modify: `Tests/MyWisprBehaviorTests/main.swift:32-39,469-476`
- Modify: `Sources/MyWisprCore/TranscriptPostProcessing.swift:40-52`

**Interfaces:**
- Consumes: `InsertionTextFormatter.formattedTranscript(_:context:) -> String`
- Produces: unchanged public interface with corrected capitalization behavior for following-only word context

- [ ] **Step 1: Replace the following-word behavior test with the reported regression**

Add this invocation to `MyWisprBehaviorTests.main()`:

```swift
testInsertionTextFormatterPreservesCapitalizationBeforeGhostPlaceholder()
```

Replace `testInsertionTextFormatterAddsSpaceBeforeNextWord()` with:

```swift
private static func testInsertionTextFormatterPreservesCapitalizationBeforeGhostPlaceholder() {
    let formatted = InsertionTextFormatter.formattedTranscript(
        "Bonjour, est-ce que tu vas comprendre que celui-là c'est du français?",
        context: InsertionTextContext(nextCharacter: "A")
    )

    expect(
        formatted == " Bonjour, est-ce que tu vas comprendre que celui-là c'est du français?",
        "Ghost placeholder text may require spacing but must not lowercase a new sentence."
    )
}
```

- [ ] **Step 2: Run the behavior tests to verify the regression fails**

Run:

```bash
swift run MyWisprBehaviorTests
```

Expected: the executable fails with `Ghost placeholder text may require spacing but must not lowercase a new sentence.`

- [ ] **Step 3: Restrict contextual lowercasing to preceding text**

In `InsertionTextFormatter.formattedTranscript(_:context:)`, replace:

```swift
let shouldLowercaseFirstLetter = touchesPreviousWord || touchesNextWord
```

with:

```swift
let shouldLowercaseFirstLetter = touchesPreviousWord
```

Keep `shouldAddLeadingSpace = touchesPreviousWord || touchesNextWord` unchanged.

- [ ] **Step 4: Run the full behavior suite and build**

Run:

```bash
swift run MyWisprBehaviorTests
swift build
```

Expected: both commands exit successfully with no test fatal errors or compiler errors.

- [ ] **Step 5: Commit the implementation**

```bash
git add Tests/MyWisprBehaviorTests/main.swift Sources/MyWisprCore/TranscriptPostProcessing.swift
git commit -m "Preserve capitalization before ghost placeholders"
```
