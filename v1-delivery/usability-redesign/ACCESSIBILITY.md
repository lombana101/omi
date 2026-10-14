# Accessibility requirements

## Non-negotiable baseline

- Every target is at least 44 × 44 points; Android may use 48 dp.
- Body and metadata text has at least 4.5:1 contrast on its actual surface. Large text has at least 3:1. Focus indicators and meaningful component boundaries have at least 3:1 against adjacent colors.
- No status, urgency, selection, validation, or destructive meaning is communicated by color alone.
- Text containers use min-height and reflow. The complete app must work at 200% Dynamic Type on a 320 × 568 viewport without clipping, overlap, hidden actions, or horizontal page scrolling.
- Reduce Motion removes looping/pulsing effects and uses zero-duration Omi motion tokens while keeping every state understandable.

Contrast is verified programmatically for Signal Green, Electric Blue, Warm Ember, and Quiet Light. Pendant connection, button notifications, and audio admission use body-size high-contrast text in every theme; the previous secondary-text treatment is not sufficient evidence.

## Semantics and labels

### Navigation

- App-switcher control: “Capture, current area. Switch area,” or the equivalent current destination.
- App-switcher sheet announces “Go To,” then four destination rows in visual order.
- Each destination row exposes button role, label, description, selected state, and a meaningful count such as “3 pending suggestions.”
- Pushed details use the standard platform back label; sheets use Close. Neither relies on an unlabeled glyph.

### Capture

- The capture state is one live region with concise announcements: “Authorizing. Microphone off,” “Recording,” “Processing. Microphone off,” “Completed,” or “Interrupted. Recording stopped.”
- Announce transitions once; do not continuously announce animation frames, elapsed visual effects, or repeated diagnostics.
- The central state surface exposes its actual action. Before Recording it must not be labeled “Stop” or “Recording.”
- Quick readiness is grouped into one readable unit containing purpose, retention, and “Double-tap means self-only.”
- Pendant, button, and audio rows have independent text labels and values.
- The physical double-tap is not the only accessible path to understand or stop a capture. Manual Capture Options and an on-screen Stop action remain available. A phone action does not silently reuse the pendant's self-only assertion.

### Tasks and sessions

- Category chips expose selected state and counts; focus order follows Today, Inbox, Projects, Habits, Suggestions, Completed.
- A task row's completion control has a task-specific label. The remainder of the row is one button to open details; nested semantics do not cause duplicate title announcements.
- Due/overdue meaning is spoken in text, not inferred from color or icon.
- Suggestions begin with “Suggestion—not a task.” Accept, Edit and Accept, and Dismiss are distinct buttons. Focus does not enter hidden editing fields until the edit sheet opens.
- Session cards announce date/time, purpose, outcome, and retention in that order. Safe preview is last and may be omitted.
- Collapsible session sections expose expanded/collapsed state. Outcome, privacy basis, retention, and deletion scope are never hidden in a collapsed region.

## Focus behavior

- Initial focus lands on the root heading/current-area control, not a destructive or recording action.
- Opening a sheet moves focus to its title, then the first field/action. Closing returns focus to the opener.
- Opening a detail page focuses its heading. Returning restores focus to the originating card and preserves scroll position.
- Switching task categories moves focus to the selected category heading/first state message, not back to the app header.
- After completion, acceptance, dismissal, archive, deletion, or undo, focus moves to the changed row or nearest surviving row and a concise feedback announcement confirms the outcome.
- Hidden/offstage root pages and collapsed controls are excluded from semantics and keyboard focus.

## Fields and keyboard

- Every field has a persistent accessible label, value, hint where useful, error/help relationship, enabled state, and secure-entry semantics when applicable.
- Placeholder text alone is not a label. Read-only metadata is not represented as a disabled field.
- Error text is announced when it appears and remains visually adjacent to the field.
- At 200% text, Save and Cancel remain visible or reachable without dismissing the keyboard. Sheets honor keyboard insets and scroll the focused field into view.
- Return/Next actions follow logical field order. Multiline notes use the multiline keyboard; task/project titles use the appropriate text action; token fields disable autocorrect and obscure content.

## Motion, haptics, and state truth

- Recording may use one calm pulse only while the controller reports Recording. Connecting/authorizing/processing use bounded standard indicators; Interrupted never loops.
- With Reduce Motion, state changes are immediate and still announced. No essential meaning depends on movement.
- Haptics supplement visible and spoken feedback: start, stop, failure, selection, and completion remain fully understandable when haptics are disabled.
- No animation, label, or haptic may imply capture before the authorization acknowledgement admits audio.

## Required accessibility verification

Automated/widget coverage must include:

- semantics labels, roles, selected/expanded states, and focus traversal for the app switcher and all destinations;
- capture live-region text for all seven states and truthful pre-ack behavior;
- 44-point target checks for icon, completion, chip, menu, and close/back controls;
- programmatic contrast checks for text, focus, field boundaries, connection status, and disabled controls in all four themes;
- 320 × 568 at 100% and 200% text for every root, representative detail sheets/pages, and the app-switcher sheet;
- keyboard-visible New Task, Task Detail, Edit and Accept, connection credentials, and Manual Capture Options;
- Reduce Motion for capture transitions, category changes, sheet arrival, and task completion;
- no overflow and no hidden primary/destructive action;
- theme persistence without losing semantic state.

Manual VoiceOver/TalkBack review must verify announcement order, focus restoration, rotor/control discoverability, no duplicate card reading, and operation of the complete capture-stop path. A physical owner-present pass remains required for pendant haptics and the double-tap flow.
