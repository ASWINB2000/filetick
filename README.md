# Filetick

Local-first Tally bookkeeping automation for accounting/CA firms that manage
multiple client businesses through TallyPrime Silver.

Automates the two biggest time sinks in day-to-day bookkeeping — bank
statement reconciliation and bill data entry — while Tally stays the system
of record for accounting data.

See [`docs/tally-automation-plan.md`](docs/tally-automation-plan.md) for the
full design plan.

## Stack

- **Wails** (desktop shell) + **Go** (backend) + **React** (frontend)
- **SQLite** (local db)
- Fully local-first — no cloud backend. The app talks directly to
  TallyPrime's local XML/HTTP gateway (`localhost:9000`).

## Status

Early design phase — see the plan doc for current scope, open questions, and
phased rollout (Phase 1: Tally connector + bank reconciliation; Phase 2: OCR
bill scanning).

## Development

Not yet scaffolded. Planned setup once implementation starts:

```
wails dev      # run in development mode
wails build    # produce a production build
```

## License

Private/proprietary — not for redistribution.
