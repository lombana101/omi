# Information architecture

## Product model

Capture is the home and the only default destination. Sessions and Tasks are review/work spaces. Assistant is the explicit bridge to the private Ubuntu Personal Intelligence service and TimeTree. Settings changes behavior but is not part of the capture flow. The five areas are peers in the app switcher; detail screens and edit sheets belong to one peer and return to it without losing category, scroll position, or draft state.

```text
Privacy app
├── Capture (initial)
│   ├── Quick Self Capture status
│   ├── Compact pendant/button/audio status
│   ├── Quick Self Capture setup
│   └── Manual capture options
├── Sessions
│   └── Session detail
│       ├── Summary and privacy metadata
│       ├── Machine transcription
│       ├── Owner corrections
│       ├── Personal note
│       ├── Create task
│       ├── Suggestions
│       └── Delete session
├── Tasks
│   ├── Today
│   ├── Inbox
│   ├── Projects
│   │   ├── Project detail
│   │   └── Archived projects
│   ├── Habits
│   ├── Suggestions
│   └── Completed
│       ├── Task detail / edit
│       └── New task
├── Assistant
│   ├── Private, task-grounded questions
│   ├── Reviewable action extraction
│   ├── Upcoming TimeTree events
│   └── Preview-and-confirm TimeTree changes
└── Settings
    ├── Quick Self Capture
    ├── Appearance
    ├── Connection
    ├── Personal Intelligence
    ├── Privacy and retention
    ├── Local data
    ├── Diagnostics
    └── About
```

## Capture

Capture has one job: truthfully show whether capture can happen or is happening.

### Quick Self Capture configured

The visual order is:

1. controller-reported capture state and central state control;
2. “Quick Self Capture ready” with selected purpose, retention, and “Double-tap means self-only”;
3. compact status card for pendant connection, button notifications, and audio admission;
4. one secondary “Manual Capture Options” action.

The ready state is not itself a blanket consent grant. A pendant double-tap supplies the one-session self-only assertion defined by Quick Self Capture. A tap on a decorative orb must not synthesize that assertion. A phone-started capture remains in Manual Capture Options and requires an explicit self-only or mixed-party assertion.

### Quick Self Capture not configured

Show Recording Off, a two-sentence explanation, pendant status, and one primary “Set Up Quick Self Capture” action. Do not expose purpose, retention, consent, credentials, and manual controls at once.

### State-to-action model

| State | Essential message | Available action |
|---|---|---|
| Off | Microphone off; quick readiness or setup status | Set Up, Manual Capture Options, or wait for pendant double-tap |
| Connecting | Connecting to pendant | Cancel connection if cancellation is supported |
| Authorizing | Waiting for authorization; microphone off | Cancel |
| Recording | Recording, with source and privacy basis | Stop Capture |
| Processing | Processing; microphone off | None until terminal response, except safe cancellation if supported |
| Completed | Capture completed | View Session or return to ready state |
| Interrupted | Capture stopped and why, in non-sensitive language | Try Again when retry is meaningful; otherwise review status |

The UI changes to Recording only after the controller reports Recording. Audio admission remains a diagnostic fact, never an optimistic animation.

## Sessions

The root list is scan-only. A session card contains:

- localized date and time;
- configured purpose;
- Completed, Interrupted, or Incomplete in text and icon;
- retention;
- a bounded, safe preview only when policy permits it.

Tap pushes Session Detail. The list never exposes correction fields, note fields, task promotion, suggestion generation, or deletion controls.

Session Detail keeps outcome, purpose, consent basis, capture origin, retention, and deletion scope visible at the top. Machine text, owner correction, personal note, task creation, and suggestions are separate labeled sections. Long machine text and completed edit areas may collapse, but capture outcome and deletion consequences may not. “Session only” always says that the session is removed on the next launch.

## Tasks

Tasks remembers one selected category and displays only that category:

| Category | Root content | Count |
|---|---|---|
| Today | Open tasks due today plus overdue tasks | “N due today · M overdue” |
| Inbox | Open tasks with no due date and no project | “N inbox tasks” |
| Projects | Active project rows; archived access is a filter/management action | “N active projects” |
| Habits | Active local habits and today's completion state | “N active habits” |
| Suggestions | Pending task candidates only | “N pending suggestions” |
| Completed | Completed tasks, with a reversible reopen action | “N completed tasks” |

Use the shared accessible filter-chip pattern in a horizontally scrollable or wrapping category switcher. Each chip has a text label and meaningful count; urgency never relies on color.

### Task rows and detail

A task row shows completion control, title, due state, project, and a quiet provenance indicator when one exists. Tapping anywhere except the completion control opens a focused edit sheet or pushed detail. The detail owns title, note, due date, project, provenance, and delete. Completion stays reversible.

New Task is one compact header action. It opens a keyboard-aware edit sheet with a visibly editable title field, Cancel, and Save. Optional values are progressively disclosed.

### Suggestions

A suggestion is not a task. Its card always states “Suggestion—not a task,” shows proposed task text and bounded source context, and offers compact Accept, Edit and Accept, and Dismiss actions. Accept is the only direct promotion gesture. Edit and Accept opens a focused edit sheet and promotes only after Save. Dismiss never writes a task. This preserves INV-TASK-2.

### Projects

Projects is a category, not an inline section between task groups. A project row shows name, open-task count, and due/overdue summary. Tap pushes Project Detail, where the owner sees that project's tasks. Rename and Archive live in detail or overflow; Archive keeps its required confirmation. Archived Projects is a secondary filter/management view and does not crowd the active list.

### Habits

Habits is a focused category beside tasks and projects. A habit remains local to the phone until the owner explicitly creates or accepts it. Each row shows today's completion state and recent local history. Completion is reversible for the current day; Archive removes the habit from the active list without rewriting past completion records.

## Assistant

Assistant is a separate root destination so intelligence and calendar actions do not crowd Capture or disguise themselves as ordinary tasks. It accepts an owner-authored question, grounds the request in the local task context supplied by the app, and shows the private backend response. Reviewable action extraction stores candidates in Suggestions; it never silently creates a task, project, habit, or calendar event.

Upcoming TimeTree events are read only after the owner opens Assistant and explicitly refreshes or submits a request. Calendar create, update, and delete operations always pass through a concrete preview and one explicit confirmation. A timeout or uncertain result is surfaced as uncertain and is not automatically retried. Assistant failure never blocks local capture, sessions, tasks, projects, or habits.

## Settings

Settings is a list of groups. Each row has icon, title, concise value/status, and disclosure indicator. Selecting a row pushes a settings page or opens an edit sheet:

- Quick Self Capture — Off, Needs Setup, or “Personal Note · 24 hours”;
- Appearance — selected theme and compact preview;
- Connection — Connected, Not Connected, or Needs Attention;
- Personal Intelligence — private Ubuntu endpoint, owner mapping, bearer token, and connection test;
- Privacy and Retention — current default/local policy summary;
- Local Data — local scope and storage actions;
- Diagnostics — current diagnostic availability;
- About — build and experimental-status information.

Credential editing belongs to Connection, theme selection belongs to Appearance, and destructive clearing belongs to Local Data. Clear Local Data is visually separated from ordinary rows and always confirms its irreversible local scope.

The capture transcription connection and Personal Intelligence connection remain separate settings because they are separate services with separate credentials and failure modes. Personal Intelligence credentials are stored in the platform secure store and are never shown again after saving.

## State and data rules

- Empty, loading, partial, failed, and successful states use the shared Omi page-state and feedback primitives.
- A failed load keeps already loaded safe content when possible and offers Try Again.
- Navigation and visual restructuring do not change authorization-before-audio, consent meaning, retention, provenance, deletion, background interruption, or no-auto-resume behavior.
- Quick Self Capture purpose, retention, local `self_only_quick_gesture` basis, assertion time, policy revision, and pendant origin remain session provenance. The backend wire vocabulary remains unchanged.
- No screen implies that machine transcription is autobiographical fact or that local deletion has been remotely verified.
