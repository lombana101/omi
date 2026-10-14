# Privacy app usability audit

## Scope and evidence

This audit covers the standalone privacy shell, its five root destinations, pushed session detail, task/suggestion/project/habit interactions, Assistant and TimeTree review flows, Quick Self Capture, theme primitives, and the current widget and screenshot evidence.

Evidence inspected:

- `app/lib/services/privacy_capture/privacy_shell.dart`
- `app/lib/services/privacy_capture/privacy_widgets.dart`
- `app/lib/services/privacy_capture/privacy_theme.dart`
- `app/lib/services/privacy_capture/privacy_copy.dart`
- privacy controller, store, model, and suggestion tests under `app/test/unit/`
- the synthetic 390 × 844 renders in `v1-delivery/ui-redesign/`
- `PRODUCT.md`, `app/docs/ux-contract.md`, INV-UI-3, INV-TASK-2, and INV-CAP-1

The current implementation has strong privacy boundaries: capture is authorized before audio admission, self-only and mixed-party assertions are distinct, suggestions remain pending until accepted, deletion copy is local-only, and background/reconnect paths do not silently resume. The redesign must preserve those properties. Its usability problems come from presentation and navigation, not from a missing set of actions.

Today, `PrivacyShell` owns an integer tab index and swaps four bodies under a Material `NavigationBar`. Session Detail is the only pushed content page. Create-from-transcript and project assignment use sheets; task, suggestion, project, capture, connection, theme, and local-data controls otherwise live inline on their root page. Settings has no child routes. This shallow route tree is why unrelated controls accumulate instead of receiving focused surfaces.

## Screen inventory

| Surface | Purpose and primary action | Must remain visible | Move behind disclosure | Current friction |
|---|---|---|---|---|
| Global shell | Move among Capture, Sessions, Tasks, Assistant, and Settings | Current destination and a clearly labeled navigation entry | Other destinations and their descriptions/counts | A stock persistent bottom bar consumes space, gives no destination context, and does not fit the privacy app's identity. Root pages have no consistent header. Switching replaces the body without explicit state-preservation structure. |
| Capture — Quick ready | Monitor capture and use the pendant gesture | Controller-reported state, “Quick Self Capture ready,” purpose, retention, “Double-tap means self-only,” and compact pendant/button/audio status | Manual capture setup and explanatory detail | Quick readiness is added to an already long setup page. The readiness summary competes with retention, purpose, consent, connection, Start, and Stop controls. The central state is visually dominant but not enough of the surrounding controls are subordinated. |
| Capture — not configured | Configure Quick Self Capture | Recording off, fail-closed status, a short benefit statement, and one Setup action | Purpose, retention, consent explanation, and connection detail | Every manual option is exposed before the owner has chosen a path. Missing-value messages, four retention rows, purpose field, two consent checkboxes, Connect, Start, and Stop all appear together. |
| Capture — manual | Start one explicit phone capture | Purpose, retention, selected consent basis, current connection state, and one Start action | Explanations and uncommon connection diagnostics | The form is permanently present. Start and Stop are simultaneous full-width peers even when Stop has no useful action. Raw checkboxes make two mutually exclusive assertions look independent. |
| Capture states | Tell the truth about Off, Connecting, Authorizing, Recording, Processing, Completed, or Interrupted | Text plus a distinct icon/shape and the next valid action | Diagnostic detail | The state renderer has only three visual kinds: recording, interrupted, and accent. Connecting, authorizing, processing, completed, and ordinary off therefore share too much visual language. Stop remains prominent outside Recording. The 168-point orb is fixed while nearby text grows. |
| Sessions list | Find a stored session and open it | Date/time, configured purpose, outcome, retention, and only a safe preview | Transcript, corrections, notes, suggestions, task creation, and deletion | Rows currently show little more than outcome and date. Store-unavailable, loading, empty, and error cases collapse into plain text or an empty list. The list does not expose enough information for scanning. |
| Session detail | Review one session and perform deliberate follow-up | Outcome, purpose, retention, consent basis, capture origin/provenance, and deletion scope | Machine transcript, owner correction, note, task creation, and suggestions in separately opened/collapsible sections | The page is a flat sequence of transcript chunks, editable correction fields, multiple buttons, a note field, suggestion action, and destructive deletion. Every chunk permanently exposes edit and task actions. Metadata is unlabeled prose. |
| Tasks workspace | Work in one task category | Selected category, meaningful counts, one compact New Task action, and that category's rows | Other categories | Suggestions, Today, Inbox, Projects, and Completed are consecutive headings in one `ListView`. Empty headings still occupy the page. A loading spinner is the only intentional page state. |
| Task row | Scan and complete a task | Completion control, title, due state, project, and subtle provenance when relevant | Title/note editing, date picker, project assignment, source detail, and delete | Each row is an inline editor with two fields and up to seven action buttons. Complete, Save, Delete, due-date, and project operations have similar weight. Most actions expand across the available width. |
| Task creation | Create one task | Clearly editable title, Save, and Cancel | Optional note/due/project fields until requested | Creation is an always-visible field and full-width button at the end of a long page. It is easy to miss, and keyboard clearance is not established. |
| Suggestions | Decide whether a proposal becomes a task | “Suggestion—not a task,” proposed task, minimal source context, Accept, Edit and Accept, Dismiss | Editing controls until Edit and Accept is chosen | Every suggestion permanently shows an edit field and three large buttons. This obscures the essential ethical boundary even though the store correctly requires explicit acceptance. |
| Projects | Choose a project and view its work | Name, open-task count, due/overdue summary, and archived state where applicable | Rename/archive in detail or overflow; archived projects behind a filter | Projects are mixed into the task stream. Each active project permanently shows a rename field and actions. Project creation is another inline form. There is no focused project task list. |
| Settings | Understand current configuration and enter one settings area | Group names and a concise current value/status per row | Detailed controls on a pushed page or edit sheet | Quick Self Capture, all theme previews, connection credentials, local data, diagnostics, and build information form one long page. Sensitive connection fields have the same visual weight as everyday settings. Destructive local-data actions are not sufficiently isolated. |
| Feedback and page states | Explain loading, absence, success, interruption, or failure | What happened and one sensible next action when available | Technical detail | Several states are raw `Text`, receipts remain in page flow, and failures often offer no Try Again action. No-session, no-task, no-suggestion, no-project, disconnected, unavailable-store, and successful-delete states are not a coherent system. |

## Cross-cutting findings

### Information density and hierarchy

- The shell exposes storage policy, capture intent, consent, connection, capture controls, and diagnostics at the same level.
- Tasks is the largest problem: list, filter, create, edit, complete, schedule, assign, delete, suggest, accept, project-create, rename, and archive behaviors share one scrolling surface.
- Secondary and rare actions are permanently visible. Progressive disclosure exists only in a few existing sheets.
- Full-width is the default for primary, secondary, and destructive `PrivacyButton` variants, so visual size no longer communicates importance.

### Interaction clarity

- Several editable values use raw `TextField`; others use `PrivacyField`. The resulting fields have inconsistent fill, outline, focus, help, and spacing behavior.
- Mutually exclusive consent choices are rendered as two checkboxes rather than one explicit choice.
- Static rows, tappable cards, and editable content do not always have distinguishable affordances.
- Task completion is a button among many buttons instead of the familiar control at the task's leading edge.
- Existing deletion confirmation is appropriately explicit for irreversible local session/data deletion, but reversible task completion and editing lack equally clear feedback and undo behavior.

### Visual consistency and legibility

- Theme tokens are a useful base, but theme changes recolor the same dense structure.
- Connection, button-notification, and audio-admission status uses small secondary text. It is not a dedicated high-contrast status component, which creates the reported legibility defect.
- Page padding alternates between privacy constants and shared Omi constants. Cards, raw columns, `ListTile`, fields, and buttons do not share a reliable vertical rhythm.
- State color is sometimes doing too much. A status needs icon/shape and text even when color is unavailable.
- The synthetic screenshots demonstrate the persistent bottom bar and crowded Capture layout; they do not provide a Settings shot, task-detail state, small-screen example, 200% text example, or Quick Self Capture evidence.

### Accessibility evidence gaps

- Current tests pump a 320 × 568 viewport at 160% text and check only that Flutter reports no exception. The requirement is 200% text plus visual and semantic review.
- There is no automated focus-order, VoiceOver-label, keyboard-avoidance, or contrast-ratio coverage.
- The recording orb honors Reduce Motion, but the rest of the proposed transition system is not yet covered.
- Some semantics exist on buttons, choice rows, theme tiles, and capture state. The state is not currently marked as a live region, and grouped card meaning is not announced as one concise unit.

## Redesign priorities

1. Replace the bottom bar with a compact header switcher while preserving each root destination's state.
2. Make Capture state and Quick Self Capture readiness the home screen; move manual setup behind one intentional action.
3. Show one task category at a time and move all editing into focused detail surfaces.
4. Turn Sessions, Suggestions, Tasks, Projects, and Settings into scan-first lists with tap-through detail.
5. Consolidate fields, action hierarchy, status, page-state, spacing, and accessibility behavior into reusable components built on the shared Omi primitives.
6. Add evidence for every state, every theme, small screens, 200% text, keyboard visibility, semantics/focus order, and contrast.
