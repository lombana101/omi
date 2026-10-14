# Navigation

## Choice

Use a compact app-switcher button in the root-page header. It shows the current destination's icon and label plus a disclosure chevron. Activating it opens an Omi sheet containing Capture, Sessions, Tasks, Assistant, and Settings.

This is clearer than the current bottom bar because it:

- returns permanent vertical space to content;
- gives each destination a short explanation rather than only an icon and noun;
- makes the current context explicit in the page header;
- leaves room for one contextual trailing action such as New Task;
- keeps all five destinations reachable without a swipe-only gesture;
- avoids replacing the bottom bar with another large permanent object.

Capture remains the initial destination.

## Header

Root pages share one header pattern:

- leading/current-area control: a minimum 44 × 44-point app-switcher button with current icon, label, and “Switch area” accessibility hint;
- centre/remaining space: optional concise page context, never a second navigation title that repeats the button;
- trailing: at most one contextual action, such as New Task or a filter/overflow action, with a visible or accessible label.

The header is not shown as a fake app bar above pushed detail pages. Detail pages use the standard app bar and `OmiBackButton`.

## App-switcher sheet

Open with `showOmiSheet`, not a raw modal. The sheet title is “Go To.” Each destination is one 56-point-or-taller row with:

| Destination | Description | Optional count |
|---|---|---|
| Capture | Start or monitor a private capture | Current state, not a bare number |
| Sessions | Review captures stored on this phone | Stored-session count |
| Tasks | Work through one focused list | Due/overdue or pending-suggestion summary |
| Assistant | Ask about tasks and review TimeTree | No badge; status is shown inside Assistant |
| Settings | Quick capture, privacy, and connection | “Needs attention” only when actionable |

The active destination is identified by text and a check, not color alone. Selecting a destination closes the sheet, gives selection haptic feedback, and switches the root body. Selecting the current destination simply closes the sheet.

Rows are reachable in the lower sheet region for one-handed use. The sheet has the standard drag handle, trailing close button, safe area, and system-back behavior. Navigation never depends on the drag gesture.

## State preservation

Keep the five root destinations alive in an `IndexedStack` or equivalent state-preserving shell. Assign each a stable `PageStorageKey` and its own scroll controller/state owner.

Preserve at minimum:

- Capture disclosure state only while the app remains foregrounded; never capture authorization or active recording across lifecycle changes;
- Sessions scroll position;
- selected Tasks category, category scroll position, and non-sensitive local draft until explicitly cancelled;
- Assistant scroll position and already displayed results, without triggering a network read while it is offstage;
- Settings scroll position and the selected Appearance substate.

Do not use navigation preservation to resume capture, re-arm consent, or restore Quick Self Capture assertions. Privacy lifecycle rules outrank UI continuity.

## Detail and modal behavior

- Session Detail and Project Detail are pushed pages opened with `routeToPage`; the leading control is `OmiBackButton`.
- Task Detail, New Task, Edit and Accept, Manual Capture Options, Quick Self Capture setup, and focused settings editors use `showOmiEditSheet` when they edit a bounded object. Dirty sheets guard all dismissal paths with the shared discard-changes flow.
- Read-only/contextual sheets use `showOmiSheet` and `OmiCloseButton`.
- Rare row operations use the shared overflow/row menu. Destructive operations are last and visually destructive.
- The keyboard must inset an editing sheet so Save and Cancel remain visible.

## Back behavior

1. If a sheet is open, system back closes it or invokes its dirty-state guard.
2. If a detail page is open, back pops to its owning root destination and restores that root's position.
3. On Android, back from Sessions, Tasks, Assistant, or Settings returns to Capture before exiting, matching the mobile UX contract's Home-first behavior.
4. Back from Capture exits according to the platform shell.
5. iOS edge swipe remains available on pushed detail routes; no custom `PageRouteBuilder` is used.

After a sheet closes, accessibility focus returns to the control that opened it. After a task/project/session mutation, focus returns to the affected row or the nearest surviving row rather than resetting to the header.

## Counts and announcements

Counts are supplemental. They say what they count (“3 pending suggestions”), never appear as an unexplained badge, and are omitted when unavailable. Opening the switcher announces its title and active destination once. Root destination changes announce the destination heading without re-reading the entire page.
