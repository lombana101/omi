# Component contract

## Foundation

The privacy themes remain, with Signal Green as the default, but layout and interaction primitives are shared across every theme. New components compose the Omi primitives named in `app/docs/ux-contract.md`; they do not duplicate sheets, dialogs, toasts, copy, dates, spinners, back buttons, or general button behavior.

Theme accent is reserved for focus, selection, Quick-ready status, and actual Recording. Ordinary primary actions remain neutral/high-contrast as required by INV-UI-1. Success, warning, and danger colors communicate state only and always have a text/icon partner.

Use one spacing scale, one radius scale, and min-height rather than fixed-height containers for text. Root page margins are 16 points on compact phones and may grow to 24 on wider layouts. Default vertical gaps are 8 within a group, 16 between related groups, and 24 between sections.

## Shell components

### Root page header

Contains the app-switcher button, current destination, and at most one contextual action. Both controls have 44 × 44-point targets. It remains compact at 200% text by allowing the destination label to wrap or the trailing visible label to collapse to a labeled icon.

### App-switcher destination row

Contains icon, label, one-line description, optional meaningful count, active check, and selected semantics. It uses a min-height and grows with text. The full row is tappable.

## Capture components

### Capture state control

One central status surface maps every controller state to distinct text, icon/shape, and action. It is not visually “live” before the controller reports Recording.

| State | Shape/icon treatment | Motion |
|---|---|---|
| Off | open microphone/off symbol in a neutral ring | none |
| Connecting | link symbol with bounded progress | standard transition only |
| Authorizing | shield/check boundary with “Microphone off” | standard transition only |
| Recording | filled centre and waveform/stop symbol | calm pulse only when Reduce Motion is off |
| Processing | document/progress symbol with “Microphone off” | spinner only |
| Completed | check in a stable ring | one success transition |
| Interrupted | warning/pause shape | no looping animation |

When Recording, the central action may stop capture. When Off and Quick is ready, it communicates the pendant double-tap path but does not forge a gesture assertion. Manual start remains in Manual Capture Options.

### Quick readiness card

Shows exactly:

- “Quick Self Capture ready”;
- purpose;
- retention;
- “Double-tap means self-only.”

The card is informational, compact, and high contrast. It does not contain all configuration controls. An Edit action routes to the Quick Self Capture settings surface.

### Capture status card

Three concise rows: Pendant, Button Notifications, and Audio. Each row has icon, label, and textual value. Connected/disconnected and admitted/unsubscribed states never depend on color. Body-size text is used instead of low-contrast caption text. A disconnected row can expose one compact Connect/Try Again action.

### Manual Capture Options

A focused edit sheet, hidden by default. It separates:

1. purpose;
2. retention;
3. one consent-basis choice: self-only or everyone-present-consented;
4. connection readiness;
5. one Start Capture action.

Self-only and mixed-party copy is never merged. Start remains visibly disabled and names the missing requirement. Stop is not shown in this setup sheet.

## List and card components

### Session card

Tap-through card with date/time, purpose, outcome badge, retention, and optional bounded safe preview. Use `OmiDateFormat`. No edit or delete buttons appear in the list.

### Task category switcher

Uses `OmiFilterChip` for Today, Inbox, Projects, Habits, Suggestions, and Completed. Exactly one chip is selected. Counts have semantic labels. The wrapping layout keeps every category visible and reachable without hiding a horizontal scroll affordance.

### Task card

Leading completion control, title, one metadata line for due/project, and optional provenance mark. The entire non-completion area opens detail. Completion has an explicit “Complete [task]” or “Reopen [task]” label, gives restrained feedback, and remains reversible. No permanent fields or action wall.

### Suggestion card

Displays “Suggestion—not a task,” proposed text, minimal bounded source context, and compact Accept, Edit and Accept, and Dismiss actions. Accept is visually primary within this card but not full-screen width. Editing appears only in the edit sheet. A suggestion never adopts task styling before acceptance.

### Project row

Displays name, open-task count, due/overdue summary, and archived label if applicable. Tap opens Project Detail. Rename/Archive is in detail or overflow, not inline.

### Habit row

Displays the habit name, today's explicit completion control, recent local completion count, and a separately labeled archive action. Completion never depends on color alone and remains reversible for the current day.

### Assistant request and event cards

The request card uses the shared labeled multiline field and separates Ask from Find Reviewable Actions. Results, status, and events are distinct cards. Event edit and delete actions use explicit labels; any write opens an exact preview before the single confirmation step. An offstage Assistant performs no automatic network request.

### Settings row/group

Uses `OmiSettingsGroup`, `OmiSettingsRow`, `OmiSectionHeader`, and `OmiSwitch` for immediate booleans. Each navigable row has title, current value/status, and disclosure affordance. Quick Self Capture, Appearance, capture Connection, Personal Intelligence, Privacy and Retention, Local Data, Diagnostics, and About are distinct rows/surfaces. Theme previews are compact and apply immediately. Personal Intelligence uses shared labeled fields for the private endpoint, owner mapping, and obscured bearer token, plus Save, Test Connection, and a separated destructive clear action.

## Editing components

### Privacy field

One field treatment is used for task, project, purpose, note, correction, URL, and token input:

- persistent label;
- filled surface plus a boundary with at least 3:1 adjacent contrast;
- stronger non-color focus indicator;
- distinct disabled fill and disabled semantics;
- reserved help/error area connected to the field semantics;
- at least 12 points internal padding;
- appropriate keyboard, capitalization, autofill, autocorrect, and secure-text behavior;
- no fixed text height;
- visible Cancel and Save in editing surfaces.

Read-only values use definition rows, never a disabled-looking text field. A dirty editor uses `showOmiEditSheet` and the shared discard-changes guard.

## Action hierarchy

Use shared `OmiButton` behavior and these roles:

- Primary: one per screen/sheet; full-width only for the screen's single major action.
- Secondary: contained or outlined; intrinsic/compact width when adjacent to content.
- Contextual: compact text/icon action with 44-point target.
- Overflow: rare operations such as rename/archive/source detail.
- Destructive: red, separated from ordinary actions, and last in a menu/detail surface.

Irreversible local session deletion and Clear Local Data always use `showOmiConfirm(..., destructive: true)` with consequence-specific copy. Project archive retains its required confirmation. Reversible task deletion follows the mobile contract's immediate-delete-plus-Undo pattern; completion/reopen also provides concise reversible feedback.

## Page states and feedback

- First load: `OmiLoadingState` or a layout-matched skeleton with one `OmiSpinner`.
- Empty: `OmiEmptyState` with a specific title/message and at most one useful action.
- Failed: `OmiErrorState` with plain-language cause and Try Again when meaningful.
- Partial: retain safe rows and show `OmiPartialNotice`.
- Success/error/undo/progress: `OmiFeedback`, not an inline receipt that permanently shifts the page.

Provide specific empty states for Sessions, every Tasks category, Projects, Suggestions, and Completed. Disconnected pendant, store unavailable, failed connection, interrupted capture, and successful deletion each receive distinct text and next action.

## Motion and haptics

Use `OmiMotion.of(context)` for every transition and zero duration under Reduce Motion. Motion explains state changes; it never implies audio activity. Use selection haptics for app/category switches, light for settings toggles, medium for deliberate start/stop and task completion, success for completed outcomes, and error for rejected/failed capture. Haptics are supplemental, never the only feedback.
