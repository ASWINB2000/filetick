# Tally Bookkeeping Automation — Design Plan

## Who this is for

An accounting/CA firm that manages multiple client businesses, all bookkept through
TallyPrime Silver. The firm's own PC runs one Tally install with each client kept as
a separate company. No client-side software or client involvement required — the
firm's staff use this tool directly.

Core pain point: manual bank entry and manual bill data entry consume most of the
firm's time. This tool automates both, with Tally staying the system of record for
accounting data.

## Stack

- **Wails** (desktop shell) + **Go** (backend/business logic) + **React** (frontend)
  + **SQLite** (local db)
- Fully local-first — no cloud backend to host. The desktop app *is* the Tally
  connector, talking directly to TallyPrime's local XML/HTTP gateway (port 9000).
- No login/auth for now (single-user app) — may be added later if the firm needs
  multi-staff access control.

---

## Phase 1 — Tally connector + bank reconciliation

### Tally integration
- Reads (Export) and writes (Import) via XML over HTTP to `localhost:9000`.
- Multi-company aware from day one: every cached record, sync job, and audit log
  entry is scoped to a `client_id`. Tally can hold multiple client companies open
  at once; requests target a specific one via `SVCURRENTCOMPANY`.
- Hard constraints from Tally itself: ledger names must match exactly what's in
  Tally (with the correct group), and every voucher must balance (debit = credit)
  or Tally imports it flagged as out-of-balance.
- No "API credentials" in the usual sense — the gateway is unauthenticated on the
  LAN. What's actually needed per client: host/port (rarely changes), the exact
  Tally company name, and GSTIN/metadata. If a client's Tally company has Security
  Control enabled, that's handled by whoever has the company open in Tally itself,
  not stored by this app.
- Defensive handling required: "company not open," ledger not found, out-of-balance
  rejection, connection refused.

### Bank statement reconciliation
- Upload a statement PDF → parse transactions → match against the client's ledger
  cache → push matched entries to Tally as vouchers via the outbox.
- Matching is **deterministic, no AI needed**: exact match on amount/date/reference
  first, then fuzzy match within a tolerance window, then a keyword dictionary for
  common categories (utilities, salary, etc.), then a correction-lookup cache that
  learns from what the reviewer picks over time.
- Unmatched transactions go to a **suspense queue** for human review — this and the
  multi-client dashboard are the two things the closest public competitor
  (Repotic — bank statement → Tally XML converter) doesn't visibly do.

### Bank statement parsing strategy (research-backed)
- Core fields (date, narration, debit, credit, balance) are regulator-mandated and
  present on every digitally-generated Indian bank statement, regardless of layout.
- The **UTR reference number format is fixed by RBI** (22 chars: 4-char bank code +
  2-digit year + 3-digit day + 7-digit sequence) — one regex extracts it across
  every bank.
- What varies by bank is the delimiter/template around that UTR (HDFC slashes,
  ICICI hyphens, Axis spaces), and narration structure clusters more by **payment
  rail** (NEFT/RTGS/IMPS/UPI/NACH/cheque) than by bank.
- Approach: generic table extractor for the universal fields → rail-aware narration
  parser using the RBI-standard UTR regex → bank-specific overrides added only when
  a real client statement defeats the generic layer. Not 690 bespoke parsers
  upfront — coverage grows on demand.
- Known edge cases: CSV exports often truncate narration (can cut off the UTR);
  cash/OTC deposits and some older co-op bank credits carry no reference number at
  all and should route straight to fuzzy-match or suspense; date/number formats
  vary and need normalizing.

### Idempotency (retry safety)
- Every voucher-push job carries a deterministic reference token (derived from
  `client_id + source_type + source_ref_id`), embedded in the voucher's
  `NARRATION`.
- Failures split into two kinds:
  - **Clean failure** (Tally clearly rejected it, nothing was created) → fix and
    retry freely.
  - **Ambiguous failure** (connection dropped/timed out, unclear what happened) →
    before retrying, query Tally for a voucher containing that reference token.
    Found it → mark synced, don't re-push. Not found → safe to retry.

---

## Phase 2 — OCR bill scanning (deferred until Phase 1 is solid)

- Purchase/sale bill photos or scans → extracted structured data → human review →
  posted as a Tally voucher. Never auto-posts, same discipline as the suspense
  queue.
- OCR sits behind a swappable adapter interface (image in, structured JSON out).
- Cost plan at the stated ~100,000+ bills/month scale:
  - Start on a cheap cloud vision API (Gemini Flash-Lite, paid tier — roughly
    $15-30/month at that volume; batch mode for further savings).
  - Move to self-hosted open model (Qwen2.5-VL on an owned GPU, ~₹20-25k one-time)
    later if the recurring cost is worth eliminating — the throughput works out
    fine on modest owned hardware at this volume, it just doesn't beat a cheap API
    if you're renting cloud GPU time instead of owning it.
- Free lever regardless of backend: cache a per-vendor extraction template after
  the first successful bill + correction, so repeat vendors skip the full model
  call on future bills.
- Natural follow-on once this pipeline exists: scanned/photographed bank
  statements too (Repotic explicitly rejects these — digital PDFs only).

### AI for Phase 1 matching — considered and declined
Evaluated using an LLM (e.g. via Groq) to assist bank transaction matching.
Conclusion: not needed. Deterministic parsing + fuzzy matching + keyword dictionary
+ correction cache covers this well — it's a finite-format problem (payment rails,
not free text), not a language-understanding problem. Worth revisiting only as a
narrow fallback for narration formats the deterministic parser doesn't recognize,
if that turns out to be a real, measured problem after Phase 1 ships.

---

## Data model (SQLite)

```
clients            id, name, tally_company_name, gstin, active, notes
ledger_cache       id, client_id, tally_ledger_name, group_name,
                   current_balance, last_synced_at
bank_statements    id, client_id, bank_name, account_number_last4,
                   period_start, period_end, uploaded_at, status
bank_transactions  id, statement_id, client_id, txn_date, narration_raw,
                   narration_parsed (json), debit_amount, credit_amount,
                   running_balance, match_status, matched_ledger_name,
                   match_method
vouchers           id, client_id, source_type, source_ref_id, voucher_type,
                   voucher_date, ledger_entries (json), narration, status
sync_jobs          id, client_id, job_type, payload (json), status,
                   attempt_count, next_retry_at, last_error
correction_cache   id, client_id, narration_pattern, matched_ledger_name,
                   match_count, last_used_at
audit_log          id, client_id, entity_type, entity_id, action, detail,
                   timestamp
```

No `users` table — no login for now.

## Sync engine

States: `pending` → `in_progress` → `synced` (success), or on failure either
`retrying` (transient, loops back to `in_progress`) or `needs_attention` (data
error, terminal until a human fixes it — never retries silently forever).

- Serial processing for v1 (not concurrent) — safer given Tally Silver is a single
  session; real-world reports of "wrong company open" errors make this the
  conservative default.
- Runs while the app is open: a polling goroutine + a manual "sync now" + a
  catch-up pass on startup. Not a background Windows service.

## Frontend

- **Component library: shadcn/ui** + Tailwind + **TanStack Table** (v9 — note the
  API changed in Aug 2026, build against current docs not older tutorials) for the
  review queue + shadcn's Recharts-based **Charts** for the dashboard + React Hook
  Form + Zod for forms. Chosen over Ant Design/Mantine specifically because the
  code lives in the repo (no dependency to chase through breaking upgrades) —
  worth it for a solo-maintained tool built by a capable engineer, even though it's
  more assembly than a batteries-included kit.
- **Layout**: collapsible sidebar with a Configuration tab (per-client connection
  details: host/port/company name/GSTIN; global settings: backup location,
  update/license status).
- **Firm-wide dashboard**: client grid with health status (last sync, suspense
  count, errors), aggregate charts (matched-vs-suspense rate over time, transaction
  volume, a time-saved estimate).
- **Per-client workspace**: connection status, suspense/review queue (the daily
  working screen — narration, amount, suggested ledger, accept/reassign/create-new,
  bulk-apply for repeat patterns), statement history, voucher/sync history.
- **Sync monitor**: pending/in-progress/synced/failed counts, needs-attention queue
  front and center.

## Backups

Daily automatic backup of the SQLite file, overwriting the previous one.
(Optional refinement on the table: keeping the last 2-3 days instead of a single
overwrite, cheap insurance against corruption going unnoticed for a day — not
required if the simpler version is preferred.)

## Distribution, updates, and licensing

- Published via GitHub; GitHub Actions builds the Wails app and publishes a
  Release on every push.
- A single consolidated manifest JSON (license status + latest version +
  announcement) fetched from a raw GitHub URL — one check covers all three instead
  of three separate mechanisms.
- Checked on startup, plus a fixed interval while running (6-12 hrs) — not a
  random schedule.
- License check is a soft mechanism (not real DRM) — appropriate for catching a
  lapsed engagement without friction, not for stopping a determined bypass.
- Update delivery: recommended approach is prompting the user to download and run
  the new installer rather than a self-swapping running .exe (which needs a
  separate updater helper process) — simpler, and proportionate to how few users
  this has.
- **Open**: public repo (simplest for unauthenticated fetches) vs. private source
  repo + a separate public releases/distribution repo.

## GST

Not building GST filing logic — relying on Tally's own native GSTR-1/3B reports.
Could optionally surface those reports inside the app later (cheap addition via
the same connector) if ever wanted — not needed for Phase 1.

## Testing strategy

1. Install TallyPrime Educational Mode (free) locally, build a dummy test company,
   develop and validate the entire connector + outbox loop against it — no client
   involvement needed for most of the work.
2. Build/test the OCR pipeline (Phase 2) standalone against sample bill images —
   no Tally dependency.
3. Package a Wails installer, dry-run it on a second machine/VM before anyone else
   sees it.
4. First real-client install over a screen-share (AnyDesk/TeamViewer), not a blind
   handoff.
5. Ongoing support: local log files + AnyDesk, not a custom telemetry backend.

## Competitor reference — Repotic (repotic.in)

Bank Statement Converter (690+ Indian banks, password-protected PDF support,
outputs Tally XML/JSON/CSV/Excel) + a separate E-Commerce Seller GSTR-1 tool.
Cloud-hosted, two disconnected point-tools. Explicitly rejects scanned statements
(digital PDFs only) and has no purchase/sale bill handling at all. No visible
suspense-account workflow or multi-client firm dashboard. These gaps are the basis
for this tool's differentiation: local-first, unified pipeline, visible
suspense/review workflow, multi-client dashboard as a first-class feature.

## Distribution — resolved

Private repo. The license/update manifest fetch will need some form of
authenticated access to GitHub since the repo isn't public — deferred to figure
out during build, not blocking Phase 1.

## Open questions

- Order of operations for onboarding a new client: create the company in Tally
  first, then register it in the app, or the reverse?
- A concrete Tally XML error taxonomy (which errors are "clean failure" vs which
  are "ambiguous") — needs to be catalogued against real Tally responses during
  build, not fully known yet.
