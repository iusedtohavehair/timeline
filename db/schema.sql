-- Timeline game: schema (PostgreSQL 13+)
-- Part 1: events (output of the n8n workflow)
-- Part 2: players, sessions, guesses (placements on a timeline)
-- Part 3: views for analysis
--
-- Migration: if an old-format `guesses` table exists (with guessed_year), it is
-- dropped automatically below (its data cannot be converted). Safe to re-run.

------------------------------------------------------------------
-- PART 1: EVENTS
------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS events (
    id                  BIGSERIAL PRIMARY KEY,
    title               TEXT        NOT NULL,
    date_text           TEXT        NOT NULL CHECK (date_text ~ '^\d{4}-\d{2}(-\d{2})?$'),  -- 'YYYY-MM-DD' or 'YYYY-MM'
    precision           TEXT        NOT NULL CHECK (precision IN ('day', 'month')),
    year                SMALLINT    NOT NULL CHECK (year BETWEEN 2020 AND 2100),
    category            TEXT        NOT NULL CHECK (category IN (
                            'pop_culture', 'music', 'film_tv', 'politics', 'sports',
                            'tech_internet', 'scandal', 'viral_meme', 'covid', 'world_news')),
    region              TEXT        CHECK (region IN ('global', 'us', 'uk', 'europe', 'canada', 'australia', 'other')),
    description         TEXT        NOT NULL,
    western_recognition TEXT        CHECK (western_recognition IN ('low', 'medium', 'high')),
    game_interest       TEXT        CHECK (game_interest IN ('low', 'medium', 'high')),
    verdict             TEXT        CHECK (verdict IN ('confirmed', 'corrected')),
    notes               TEXT,
    sources             JSONB       NOT NULL DEFAULT '[]'::jsonb,
    active              BOOLEAN     NOT NULL DEFAULT TRUE,   -- FALSE = pulled from the game (keeps guess history)
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (title, date_text)
);

CREATE INDEX IF NOT EXISTS idx_events_year     ON events (year);
CREATE INDEX IF NOT EXISTS idx_events_category ON events (category);
CREATE INDEX IF NOT EXISTS idx_events_active   ON events (active) WHERE active;

-- Events the verifier could not settle: to review by hand.
CREATE TABLE IF NOT EXISTS events_review (
    id                  BIGSERIAL PRIMARY KEY,
    title               TEXT        NOT NULL,
    date_claimed        TEXT,
    category            TEXT,
    description         TEXT,
    verdict             TEXT,       -- confirmed / corrected / rejected / uncertain / parse_error
    verified_date       TEXT,
    western_recognition TEXT,
    notes               TEXT,
    sources             JSONB       NOT NULL DEFAULT '[]'::jsonb,
    resolved            BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_review_open ON events_review (resolved) WHERE NOT resolved;

-- Real DATE column (month-precision events land on the 1st).
CREATE OR REPLACE VIEW events_v AS
SELECT
    id, title, date_text, precision, year, category, region, description,
    western_recognition, game_interest, notes, sources, created_at,
    (date_text || CASE WHEN length(date_text) = 7 THEN '-01' ELSE '' END)::date AS event_date
FROM events
WHERE active;

------------------------------------------------------------------
-- PART 2: PLAYERS AND GUESSES
------------------------------------------------------------------

-- Drop the old-format guesses table (guessed_year) and its views, only if present.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'guesses' AND column_name = 'guessed_year')
       AND NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = current_schema() AND table_name = 'guesses' AND column_name = 'guessed_before')
    THEN
        DROP VIEW IF EXISTS demo_event_stats_v, pair_stats_v, event_stats_v, guess_pairs_v, guesses_v;
        DROP TABLE guesses;
    END IF;
END $$;

-- Privacy by design: no name, email or IP. Age as a bracket (adults only),
-- every demographic field optional ('undisclosed' / NULL).

CREATE TABLE IF NOT EXISTS players (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    age_group     TEXT        NOT NULL DEFAULT 'undisclosed'
                              CHECK (age_group IN ('18-24', '25-34', '35-44', '45-54', '55-64', '65+', 'undisclosed')),
    sex           TEXT        NOT NULL DEFAULT 'undisclosed'
                              CHECK (sex IN ('female', 'male', 'other', 'undisclosed')),
    country       CHAR(2),                 -- ISO 3166-1 alpha-2, e.g. 'CA'
    subregion     TEXT,                    -- province / state, e.g. 'QC'
    region_group  TEXT        CHECK (region_group IN ('us', 'canada', 'uk', 'europe', 'australia', 'other')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_players_demo ON players (age_group, sex, region_group);

-- One session = one play-through of the game (one timeline being built).
CREATE TABLE IF NOT EXISTS sessions (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    player_id     UUID        NOT NULL REFERENCES players (id) ON DELETE CASCADE,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_sessions_player ON sessions (player_id);

-- The events dealt to a session, in the order they are presented (seq 1 = first card).
-- Lets the server check that a guess concerns an event that was really dealt.
CREATE TABLE IF NOT EXISTS session_events (
    session_id    UUID        NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    event_id      BIGINT      NOT NULL REFERENCES events (id),
    seq           SMALLINT    NOT NULL CHECK (seq >= 1),
    PRIMARY KEY (session_id, event_id),
    UNIQUE (session_id, seq)
);

-- One row = one event placed on the player's timeline.
--   guessed_before : ids of the events the player placed BEFORE this one (earlier)
--   guessed_after  : ids of the events the player placed AFTER this one (later)
-- Only events already on the timeline at that moment appear in the arrays.
-- The first event of a session has two empty arrays.
CREATE TABLE IF NOT EXISTS guesses (
    id             BIGSERIAL   PRIMARY KEY,
    session_id     UUID        NOT NULL REFERENCES sessions (id) ON DELETE CASCADE,
    player_id      UUID        NOT NULL REFERENCES players (id)  ON DELETE CASCADE,
    event_id       BIGINT      NOT NULL REFERENCES events (id),
    seq            SMALLINT    NOT NULL DEFAULT 1 CHECK (seq >= 1),   -- turn number within the session
    guessed_before BIGINT[]    NOT NULL DEFAULT '{}',
    guessed_after  BIGINT[]    NOT NULL DEFAULT '{}',
    response_ms    INTEGER     CHECK (response_ms >= 0),               -- time taken to place it
    answered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (session_id, event_id),
    UNIQUE (session_id, seq),
    CHECK (NOT (event_id = ANY (guessed_before || guessed_after))),   -- an event is not compared to itself
    CHECK (NOT (guessed_before && guessed_after))                      -- an event cannot be both before and after
);

CREATE INDEX IF NOT EXISTS idx_guesses_event  ON guesses (event_id);
CREATE INDEX IF NOT EXISTS idx_guesses_player ON guesses (player_id);
CREATE INDEX IF NOT EXISTS idx_guesses_before ON guesses USING GIN (guessed_before);
CREATE INDEX IF NOT EXISTS idx_guesses_after  ON guesses USING GIN (guessed_after);

------------------------------------------------------------------
-- PART 3: ANALYSIS VIEWS
------------------------------------------------------------------

DROP VIEW IF EXISTS demo_event_stats_v, pair_stats_v, event_stats_v, guess_pairs_v, guesses_v;

-- One row per (placed event, other event) comparison, with the true answer.
-- other_guessed : where the player put the OTHER event relative to the placed one ('before' / 'after')
-- other_true    : where it really is. NULL when it cannot be told (same day, or same month
--                 when one of the two dates is month-precision): those pairs are not scored.
-- correct       : NULL when not scored.
-- event_seems   : on a wrong answer, does the placed event feel 'too_recent' or 'too_old'?
--                 (player put the other event before it, but it was after => placed event feels too recent)
CREATE VIEW guess_pairs_v AS
SELECT
    q.*,
    (q.other_guessed = q.other_true) AS correct,
    CASE
        WHEN q.other_true IS NULL OR q.other_guessed = q.other_true THEN NULL
        WHEN q.other_guessed = 'before' THEN 'too_recent'
        ELSE 'too_old'
    END AS event_seems
FROM (
    SELECT
        g.id                AS guess_id,
        g.session_id,
        g.player_id,
        g.seq,
        g.event_id,
        e.title,
        e.category,
        e.region            AS event_region,
        x.other_id,
        o.title             AS other_title,
        x.other_guessed,
        CASE WHEN k.ko < k.ke THEN 'before'
             WHEN k.ko > k.ke THEN 'after' END AS other_true,
        p.age_group,
        p.sex,
        p.country,
        p.subregion,
        p.region_group,
        (e.region <> 'global' AND p.region_group = e.region) AS same_region_as_event,
        g.response_ms,
        g.answered_at
    FROM guesses g
    CROSS JOIN LATERAL (
        SELECT unnest(g.guessed_before) AS other_id, 'before'::text AS other_guessed
        UNION ALL
        SELECT unnest(g.guessed_after), 'after'::text
    ) x
    JOIN events  e ON e.id = g.event_id
    JOIN events  o ON o.id = x.other_id
    JOIN players p ON p.id = g.player_id
    CROSS JOIN LATERAL (
        SELECT
            CASE WHEN e.precision = 'month' OR o.precision = 'month' THEN left(e.date_text, 7) ELSE e.date_text END AS ke,
            CASE WHEN e.precision = 'month' OR o.precision = 'month' THEN left(o.date_text, 7) ELSE o.date_text END AS ko
    ) k
) q;

-- Per event (as the placed event), all players.
CREATE VIEW event_stats_v AS
SELECT
    event_id,
    title,
    category,
    count(DISTINCT player_id)                                                        AS n_players,
    count(correct)                                                                   AS n_scored,
    round(100.0 * count(*) FILTER (WHERE correct)                      / nullif(count(correct), 0), 1) AS pct_correct,
    round(100.0 * count(*) FILTER (WHERE event_seems = 'too_recent')   / nullif(count(correct), 0), 1) AS pct_too_recent,
    round(100.0 * count(*) FILTER (WHERE event_seems = 'too_old')      / nullif(count(correct), 0), 1) AS pct_too_old
FROM guess_pairs_v
GROUP BY event_id, title, category;

-- Per pair of events: which orders do people get wrong the most?
CREATE VIEW pair_stats_v AS
SELECT
    event_id,
    title,
    other_id,
    other_title,
    max(other_true)                                                                  AS other_true,
    count(correct)                                                                   AS n_scored,
    round(100.0 * count(*) FILTER (WHERE correct) / nullif(count(correct), 0), 1)    AS pct_correct
FROM guess_pairs_v
GROUP BY event_id, title, other_id, other_title;

-- Per event x demographic cohort. Cohorts with fewer than 10 players are hidden
-- (statistical noise, and keeps small groups from being identifiable).
CREATE VIEW demo_event_stats_v AS
SELECT
    event_id,
    title,
    category,
    age_group,
    sex,
    region_group,
    count(DISTINCT player_id)                                                        AS n_players,
    count(correct)                                                                   AS n_scored,
    round(100.0 * count(*) FILTER (WHERE correct)                      / nullif(count(correct), 0), 1) AS pct_correct,
    round(100.0 * count(*) FILTER (WHERE event_seems = 'too_recent')   / nullif(count(correct), 0), 1) AS pct_too_recent,
    round(100.0 * count(*) FILTER (WHERE event_seems = 'too_old')      / nullif(count(correct), 0), 1) AS pct_too_old
FROM guess_pairs_v
GROUP BY event_id, title, category, age_group, sex, region_group
HAVING count(DISTINCT player_id) >= 10;

------------------------------------------------------------------
-- EXAMPLE QUERIES
------------------------------------------------------------------
-- Overall accuracy by age group:
--   SELECT age_group, count(DISTINCT player_id) AS players, count(correct) AS n_scored,
--          round(100.0 * count(*) FILTER (WHERE correct) / nullif(count(correct), 0), 1) AS pct_correct
--   FROM guess_pairs_v WHERE age_group <> 'undisclosed'
--   GROUP BY age_group ORDER BY age_group;
--
-- Do people order events from their own region better?
--   SELECT same_region_as_event, count(correct) AS n_scored,
--          round(100.0 * count(*) FILTER (WHERE correct) / nullif(count(correct), 0), 1) AS pct_correct
--   FROM guess_pairs_v GROUP BY same_region_as_event;
--
-- Events that feel the most distorted (min 30 scored comparisons):
--   SELECT * FROM event_stats_v WHERE n_scored >= 30 ORDER BY pct_correct ASC LIMIT 20;
--
-- Most confused pairs:
--   SELECT * FROM pair_stats_v WHERE n_scored >= 30 ORDER BY pct_correct ASC LIMIT 20;
