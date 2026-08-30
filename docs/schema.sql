-- Tally bookkeeping automation — Phase 1 schema
-- No users/auth table — single-user app for now.

CREATE TABLE clients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    tally_company_name TEXT NOT NULL,
    gstin TEXT,
    active INTEGER NOT NULL DEFAULT 1,
    notes TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE ledger_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    tally_ledger_name TEXT NOT NULL,
    group_name TEXT,
    current_balance REAL,
    last_synced_at TEXT,
    UNIQUE(client_id, tally_ledger_name)
);

CREATE TABLE bank_statements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    bank_name TEXT,
    account_number_last4 TEXT,
    period_start TEXT,
    period_end TEXT,
    uploaded_at TEXT NOT NULL DEFAULT (datetime('now')),
    status TEXT NOT NULL DEFAULT 'uploaded'
);

CREATE TABLE bank_transactions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    statement_id INTEGER NOT NULL REFERENCES bank_statements(id),
    client_id INTEGER NOT NULL REFERENCES clients(id),
    txn_date TEXT NOT NULL,
    narration_raw TEXT NOT NULL,
    narration_parsed TEXT,               -- JSON: {counterparty, utr, rail_type, ...}
    debit_amount REAL,
    credit_amount REAL,
    running_balance REAL,
    match_status TEXT NOT NULL DEFAULT 'unmatched',  -- unmatched|matched|suspense|ignored
    matched_ledger_name TEXT,
    match_method TEXT,                   -- exact|fuzzy|cache|manual
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE vouchers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    source_type TEXT NOT NULL,           -- bank | bill
    source_ref_id INTEGER NOT NULL,
    voucher_type TEXT NOT NULL,          -- Payment|Receipt|Sales|Purchase|Journal
    voucher_date TEXT NOT NULL,
    ledger_entries TEXT NOT NULL,        -- JSON: [{ledger_name, amount, dr_cr}]
    narration TEXT,
    reference_token TEXT NOT NULL UNIQUE,-- idempotency token, embedded in narration too
    status TEXT NOT NULL DEFAULT 'draft',-- draft|ready|synced|failed
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE sync_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    job_type TEXT NOT NULL,
    payload TEXT NOT NULL,               -- JSON
    status TEXT NOT NULL DEFAULT 'pending', -- pending|in_progress|synced|retrying|needs_attention
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_retry_at TEXT,
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE correction_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL REFERENCES clients(id),
    narration_pattern TEXT NOT NULL,
    matched_ledger_name TEXT NOT NULL,
    match_count INTEGER NOT NULL DEFAULT 1,
    last_used_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(client_id, narration_pattern)
);

CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER,
    entity_type TEXT NOT NULL,
    entity_id INTEGER NOT NULL,
    action TEXT NOT NULL,
    detail TEXT,
    timestamp TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX idx_bank_transactions_client_status ON bank_transactions(client_id, match_status);
CREATE INDEX idx_sync_jobs_status ON sync_jobs(status);
CREATE INDEX idx_ledger_cache_client ON ledger_cache(client_id);
