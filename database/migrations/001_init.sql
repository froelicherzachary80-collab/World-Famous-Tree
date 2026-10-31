-- WORLD TREE AI — genealogical database, migration 001
-- Conventions:
--   * Years are ASTRONOMICAL (1 BC = 0, 44 BC = -43). Display converts to BCE/CE.
--   * Nothing is ever hard-deleted by research; merges are logged and reversible.
--   * evidence_status: user_provided | verified | supported | candidate | disputed | legendary | rejected

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL);

CREATE TABLE IF NOT EXISTS persons (
    id              TEXT PRIMARY KEY,
    given_name      TEXT NOT NULL DEFAULT '',
    surname         TEXT NOT NULL DEFAULT '',
    sex             TEXT NOT NULL DEFAULT 'U',
    birth_date      TEXT,            -- original date string
    birth_year      INTEGER,         -- astronomical
    birth_place     TEXT,
    death_date      TEXT,
    death_year      INTEGER,
    death_place     TEXT,
    is_living       INTEGER NOT NULL DEFAULT 0,
    is_public_figure INTEGER NOT NULL DEFAULT 0,
    origin          TEXT NOT NULL DEFAULT 'gedcom',   -- gedcom | research | manual
    evidence_status TEXT NOT NULL DEFAULT 'user_provided',
    external_ids    TEXT NOT NULL DEFAULT '{}',       -- JSON: {"wikidata":"Q..","wikitree":".."}
    notes           TEXT NOT NULL DEFAULT '',
    merged_into     TEXT REFERENCES persons(id),      -- non-null => hidden duplicate
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_persons_surname ON persons(surname);

CREATE TABLE IF NOT EXISTS person_names (
    person_id TEXT NOT NULL REFERENCES persons(id),
    given_name TEXT NOT NULL DEFAULT '',
    surname TEXT NOT NULL DEFAULT '',
    name_type TEXT NOT NULL DEFAULT 'alternate'
);

-- Directed parent -> child edges and undirected spouse edges.
CREATE TABLE IF NOT EXISTS relationships (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    kind            TEXT NOT NULL,          -- parent | spouse
    person_a        TEXT NOT NULL REFERENCES persons(id),  -- parent (for kind=parent)
    person_b        TEXT NOT NULL REFERENCES persons(id),  -- child  (for kind=parent)
    pedigree        TEXT NOT NULL DEFAULT 'birth',         -- birth | adopted | step | foster | unknown
    evidence_status TEXT NOT NULL DEFAULT 'user_provided',
    family_id       TEXT,
    ended           TEXT,                   -- divorce etc.
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(kind, person_a, person_b, pedigree)
);

CREATE TABLE IF NOT EXISTS sources (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL DEFAULT '',
    url         TEXT,
    connector   TEXT,                       -- gedcom | wikidata | wikitree | manual ...
    retrieved_at TEXT,
    reliability INTEGER NOT NULL DEFAULT 1  -- 0 unreliable, 1 secondary, 2 primary/original
);

CREATE TABLE IF NOT EXISTS citations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id   TEXT NOT NULL REFERENCES sources(id),
    subject_type TEXT NOT NULL,             -- person | relationship
    subject_id  TEXT NOT NULL,
    detail      TEXT NOT NULL DEFAULT '',
    assessment  TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS universes (
    id    TEXT PRIMARY KEY,
    name  TEXT NOT NULL,
    color TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS universe_members (
    universe_id TEXT NOT NULL REFERENCES universes(id),
    person_id   TEXT NOT NULL REFERENCES persons(id),
    PRIMARY KEY (universe_id, person_id)
);

CREATE TABLE IF NOT EXISTS duplicate_candidates (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    person_a  TEXT NOT NULL REFERENCES persons(id),
    person_b  TEXT NOT NULL REFERENCES persons(id),
    score     REAL NOT NULL,
    matches   TEXT NOT NULL DEFAULT '[]',
    conflicts TEXT NOT NULL DEFAULT '[]',
    status    TEXT NOT NULL DEFAULT 'open',  -- open | merged | separate | investigating | different
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(person_a, person_b)
);

CREATE TABLE IF NOT EXISTS merge_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kept_id    TEXT NOT NULL,
    merged_id  TEXT NOT NULL,
    snapshot   TEXT NOT NULL,               -- JSON of moved edges, for undo
    undone     INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS goals (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    instruction TEXT NOT NULL,
    plan        TEXT NOT NULL,              -- JSON structured plan
    status      TEXT NOT NULL DEFAULT 'draft', -- draft | active | paused | stopped | completed
    priority    INTEGER NOT NULL DEFAULT 5,
    budget      INTEGER NOT NULL DEFAULT 200, -- max external requests
    spent       INTEGER NOT NULL DEFAULT 0,
    schedule    TEXT,                       -- e.g. 'daily'
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    goal_id     INTEGER REFERENCES goals(id),
    kind        TEXT NOT NULL,
    payload     TEXT NOT NULL DEFAULT '{}',
    status      TEXT NOT NULL DEFAULT 'queued', -- queued | running | done | failed | cancelled
    priority    INTEGER NOT NULL DEFAULT 5,
    attempts    INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 4,
    run_after   TEXT NOT NULL DEFAULT (datetime('now')),
    lease_until TEXT,
    last_error  TEXT,
    dedupe_key  TEXT UNIQUE,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_jobs_ready ON jobs(status, run_after, priority);

CREATE TABLE IF NOT EXISTS discoveries (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    goal_id     INTEGER REFERENCES goals(id),
    kind        TEXT NOT NULL,              -- new_person | relationship | identity_match | connection
    title       TEXT NOT NULL,
    detail      TEXT NOT NULL DEFAULT '{}',
    status      TEXT NOT NULL DEFAULT 'pending', -- pending | accepted | rejected | auto_accepted
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS activity (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    agent      TEXT NOT NULL,
    level      TEXT NOT NULL DEFAULT 'info', -- info | warn | error | blocked
    message    TEXT NOT NULL,
    goal_id    INTEGER,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    actor      TEXT NOT NULL,
    action     TEXT NOT NULL,
    detail     TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

INSERT OR IGNORE INTO universes(id, name, color) VALUES
 ('my_family','My Family','#E8C468'),
 ('minecraft','Minecraft Creators','#5FD38D'),
 ('young_hollywood','Young Hollywood','#F78FB3'),
 ('marvel','Marvel Actors','#E55353'),
 ('music','Pop Stars','#B48CFF'),
 ('royal','Royal History','#6FA8FF'),
 ('ancient','Ancient Civilizations','#D9A066');
