# Assisted commands and paste formatting

Clio is local-first and makes no network requests of its own. Two optional
features are the exception. Both are off until you turn them on, both are
powered by [TypeSafe](https://docs.typesafe.ai), and both degrade to Clio's
ordinary local behaviour whenever they are off, unconfigured, or unreachable.

## What they do

**Assisted commands.** The command palette matches what you type against
command names as it always has. When that match finds nothing — you typed
"send this to my editor in Word" rather than `/export` — Clio asks what the
request meant and offers the commands that fit, marked *Best guess at what you
meant*. Nothing runs until you choose it.

**Paste formatting.** Text pasted from an email or a plain-text export arrives
hard-wrapped mid-sentence with its headings and bullets stripped. Clio pastes it
unchanged, then rebuilds the Markdown structure and replaces it. The
reformatting is its own undo step: one Command-Z takes it back and leaves your
pasted text in place.

## What leaves the machine

| Feature | Sent | Not sent |
| --- | --- | --- |
| Assisted commands | The text you typed into the command bar, plus five booleans: whether a document is open, whether it is saved to disk, and whether focus mode, typewriter scrolling and the sidebar are on | Your document, its name, its path, your workspace folders |
| Paste formatting | The pasted text only | Anything already in the document |

Paste formatting can be turned off on its own while assisted commands stay on,
because it is the one that sends prose.

A paste is only sent when it needs the help. Clio reads the direct evidence
itself: text that still carries Markdown markers, text under about 240
characters, and text on fewer than three lines are all handled locally and never
leave the machine.

## Turning them on

Settings → **Assisted Commands**. Enable the feature, then paste your own
TypeSafe API key into **Your API key** and press Save. **Check** sends one
minimal request to confirm the key works; **Remove** deletes it.

Clio ships no key and has no account of its own. Each person supplies their own,
and it is stored in that macOS account's login Keychain
(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`): this device only, not synced to
other Macs, never written to preferences or the app bundle, and never logged. Two
people using the same Mac under different accounts each hold their own key and
cannot see one another's.

Enabling this adds `com.apple.security.network.client` to Clio's sandbox. That
entitlement is present in every build, but `IntelligenceService` is the only
code that makes an outbound request, and it refuses before building one while
the feature is off or no key is stored.

## How it works

Clio does not ask a model to rewrite anything. It asks narrow, typed questions
and assembles the result in code, so every character of a reformatted paste came
from the paste.

- **Commands.** One request carries a Choice over the twelve palette commands
  plus a no-match option, and — speculatively, whether or not the request turns
  out to be an export — a Choice over the four export formats and a yes/no on
  whether the request named one at all. Asking a question whose answer may go
  unread costs only that question's tokens; a second round trip would cost a
  whole request of latency. The descriptions the model reads are in
  `CommandIntentSpec`; editing them is how you change the matching.

- **Pastes.** Two requests in sequence. The first asks, for each adjacent pair
  of lines, whether the line break tore a sentence in half, and code merges the
  continuations into blocks. The second classifies each block — heading,
  paragraph, list item, quote, code, callout — with companion questions for
  heading level, step order and callout kind asked up front and read only where
  they apply. The blocks do not exist until the first request has answered,
  which is why this is two requests rather than one.

Answers carry probabilities, and code decides what to do with them. A command
below `CommandIntentResolver.minimumConfidence`, or one that merely leads a
scattered field, is not offered at all. A run of list items is numbered when its
items' mean step probability clears `StructureRecovery.stepThreshold` — a
group-level decision no single question asked about directly.

## Cost and limits

`jev-1.13.0` is pinned rather than the `jev-latest` alias, so answers cannot
shift under tuned thresholds without a deliberate change. Input tokens are
charged and output tokens are free. Requests are budgeted against the model's
64k combined and 32k state windows before they are sent, and an oversized one
fails locally rather than at the API.

Rate limits (429) and overload (529) are retried with exponential backoff,
honouring `retry-after`. A rejected key is not retried.

## Tests

`ClioTests/IntelligenceTests.swift` covers the wire contracts, transport and
retry behaviour, both features' question construction and answer handling, and
the gates. The ones worth keeping green above all:

- `testNoRequestIsMadeWhileTheFeatureIsOff`
- `testNoRequestIsMadeWithoutAKey`
- `testKeyCheckStaysBehindTheOptIn` — even checking a key waits for the opt-in
- `testEachKeyStoreIsIndependent`
- `testStructuredStateEncodesNestedFields` — asserts only window state travels
- `testSkipsPastesThatAlreadyCarryTheirMarkup`
