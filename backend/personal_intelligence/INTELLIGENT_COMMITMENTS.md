# Intelligent commitments vertical slice

This release keeps the iPhone's privacy store authoritative for tasks, projects,
habits, and suggestion review. Ubuntu is the intelligence and integration
boundary; it receives only the compact open-task fields needed for a request.

## Implementation map

- The privacy capture app already requires deliberate, authorized capture; this change adds no recording path.
- Structured extraction already accepts self-authored or explicitly consented input and preserves source references, excerpts, uncertainty, and pending review state.
- Deterministic grounding rejects model suggestions whose supporting excerpt is absent from the authorized source.
- The local iPhone store already persists tasks, projects, habits, candidates, tombstones, and source-deletion lineage.
- Candidate acceptance already creates a task only after an owner gesture; dismissal leaves a tombstone that prevents reappearance.
- TimeTree reads and confirmation-gated writes remain in the standalone Ubuntu service.
- Calendar previews, idempotency, uncertain-write reconciliation, and owner authentication are unchanged.
- `POST /v1/intelligence/proactive/evaluate` now evaluates a minimized open-task snapshot without an LLM.
- A task due tomorrow produces at most one stable advice candidate per task and local date.
- TimeTree density strengthens the advice when tomorrow has at least three events or four scheduled hours.
- TimeTree failure degrades to task-only advice instead of losing the useful task signal.
- The app invokes proactive evaluation during its existing context/calendar refresh and persists returned candidates locally.
- `What should I focus/prioritize/work on tomorrow?` uses deterministic routing, task deadlines, project names, and—when configured—TimeTree events.
- The proactive path performs no task write, calendar write, notification, ambient capture, or third-party profiling.
- Memoria, push notifications, generalized graphs, Redis, and agent frameworks remain out of scope.

## Event and data flow

```text
owner refresh / explicit assistant request
  -> minimized open-task projection (id, title, due time, project, today flag)
  -> authenticated loopback-backed Ubuntu API
  -> deterministic deadline evaluation + optional TimeTree read
  -> grounded pending candidate with stable source reference
  -> iPhone candidate store deduplication / tombstone check
  -> suggestion review
       accept commitment -> local authoritative task
       dismiss advice     -> durable local tombstone
```

The app never sends task notes, transcript text, source excerpts, completed
tasks, habit history, or the local candidate ledger during proactive evaluation.
No database migration is required because the existing candidate record already
stores the needed type, provenance reference, uncertainty, expiry, and lifecycle
state.

## Trigger model

Evaluation is event-driven from the existing owner-visible refresh action. It is
not a polling loop and does not create notifications. The API is idempotent at
the product boundary: it returns a stable source reference, and the iPhone store
uses that reference and content to deduplicate candidates. A dismissed candidate
retains its tombstone and cannot reappear on a repeated evaluation.
