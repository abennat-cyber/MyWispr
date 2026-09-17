# Ghost Placeholder Capitalization Fix

## Problem

MyWispr first capitalizes dictated sentences, then adjusts the result for text
surrounding the insertion point. Claude's empty composer can expose ghost
placeholder text through macOS Accessibility as a following character. The
insertion formatter currently treats either a preceding or following word-like
character as evidence that insertion is mid-sentence, so it changes `Bonjour`
back to `bonjour`.

## Design

Keep the existing spacing behavior: a word-like character on either side of the
cursor requires a leading space. Restrict contextual lowercasing to a word-like
character before the cursor. Following text, including inaccessible distinctions
between real content and ghost placeholders, must not override the sentence
capitalization produced by the dictation formatter.

This rule is application-independent and avoids brittle Claude-specific
Accessibility checks.

## Testing

Add a behavior test that models Claude's ghost placeholder as a following
word-like character and verifies the French dictation remains capitalized:

`Bonjour, est-ce que tu vas comprendre que celui-là c'est du français?`

Retain the existing test proving that insertion after a preceding word-like
character is lowercased.
