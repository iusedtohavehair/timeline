-- Browser API for the timeline game. Run db/schema.sql first. Safe to re-run.
--
-- The publishable key (sb_publishable_...) signs in as the anon role and may
-- call only these functions. get_game_events returns a date for the first
-- card only (the anchor). Every other date stays in the database until
-- submit_game. Direct reads and writes are revoked for the
-- anon and authenticated roles, and row level security is enabled with no
-- policies (default deny).
--
-- The table owner and the Supabase service role are left alone, so the SQL
-- editor and an n8n workflow that uses the service role keep working.
--
-- get_game_events(p_n, p_level) draws active events whose niche_level matches
-- the choice: 1 is the easiest, 3 is niche.
-- check_placement judges one drop against the cards already on the line.
-- It returns only correct and the real insert index. No date, year, or precision.
-- submit_game turns each insert_index into guessed_before / guessed_after.
-- The score is the share of scored pairs in guess_pairs_v (ties are ignored).
-- region_group is derived from the ISO country so the analysis views fill in.

DROP FUNCTION IF EXISTS get_game_events(integer);
DROP FUNCTION IF EXISTS get_game_events(integer, integer);

CREATE OR REPLACE FUNCTION get_game_events(p_n integer DEFAULT 10, p_level integer DEFAULT 1)
RETURNS TABLE (
    id bigint,
    title text,
    description text,
    category text,
    date_text text,
    "precision" text
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH picked AS (
        SELECT
            e.id,
            e.title,
            e.description,
            e.category,
            e.date_text,
            e.precision,
            row_number() OVER (ORDER BY random()) AS n
        FROM events e
        WHERE e.active
          AND e.niche_level::text = LEAST(GREATEST(COALESCE(p_level, 1), 1), 3)::text
    )
    SELECT
        picked.id,
        picked.title,
        picked.description,
        picked.category,
        CASE WHEN picked.n = 1 THEN picked.date_text END,
        CASE WHEN picked.n = 1 THEN picked.precision END
    FROM picked
    WHERE picked.n <= LEAST(GREATEST(COALESCE(p_n, 10), 1), 50)
    ORDER BY picked.n;
$$;

CREATE OR REPLACE FUNCTION submit_game(
    p_player_id  uuid,
    p_demo       jsonb DEFAULT '{}'::jsonb,
    p_placements jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_demo     jsonb := COALESCE(p_demo, '{}'::jsonb);
    v_age      text;
    v_sex      text;
    v_country  text;
    v_sub      text;
    v_region   text;
    v_session  uuid := gen_random_uuid();
    v_tl       bigint[] := ARRAY[]::bigint[];
    v_item     jsonb;
    v_event    bigint;
    v_index    integer;
    v_ms_big   bigint;
    v_ms       integer;
    v_before   bigint[];
    v_after    bigint[];
    v_seq      integer := 0;
    v_score    integer;
    v_timeline jsonb;
    v_skipped  boolean;
    v_skipped_ids bigint[] := ARRAY[]::bigint[];
    v_earlier  integer;
BEGIN
    IF p_player_id IS NULL THEN
        RAISE EXCEPTION 'player id is required';
    END IF;
    IF jsonb_typeof(v_demo) <> 'object' THEN
        RAISE EXCEPTION 'demographics must be an object';
    END IF;
    IF p_placements IS NULL
       OR jsonb_typeof(p_placements) <> 'array'
       OR jsonb_array_length(p_placements) < 1
       OR jsonb_array_length(p_placements) > 30 THEN
        RAISE EXCEPTION 'placements must be a short non-empty list';
    END IF;

    v_age := CASE lower(btrim(COALESCE(v_demo->>'age_group', '')))
        WHEN '18-24' THEN '18-24'
        WHEN '25-34' THEN '25-34'
        WHEN '35-44' THEN '35-44'
        WHEN '45-54' THEN '45-54'
        WHEN '55-64' THEN '55-64'
        WHEN '65+' THEN '65+'
        ELSE 'undisclosed'
    END;

    v_sex := CASE lower(btrim(COALESCE(v_demo->>'sex', '')))
        WHEN 'female' THEN 'female'
        WHEN 'male' THEN 'male'
        WHEN 'other' THEN 'other'
        WHEN 'undisclosed' THEN 'undisclosed'
        WHEN 'prefer not to say' THEN 'undisclosed'
        WHEN 'prefer_not_to_say' THEN 'undisclosed'
        ELSE 'undisclosed'
    END;

    v_country := upper(btrim(COALESCE(v_demo->>'country', '')));
    IF v_country !~ '^[A-Z]{2}$' THEN
        v_country := NULL;
    END IF;

    v_sub := NULLIF(left(btrim(COALESCE(v_demo->>'subregion', '')), 80), '');

    v_region := CASE
        WHEN v_country IS NULL THEN NULL
        WHEN v_country = 'US' THEN 'us'
        WHEN v_country = 'CA' THEN 'canada'
        WHEN v_country IN ('GB', 'UK', 'IM', 'GG', 'JE', 'GI') THEN 'uk'
        WHEN v_country = 'AU' THEN 'australia'
        WHEN v_country = ANY (ARRAY[
            'AD','AL','AT','AX','BA','BE','BG','BY','CH','CY','CZ','DE','DK','EE','ES','FI',
            'FO','FR','GE','GR','HR','HU','IE','IS','IT','LI','LT','LU','LV','MC','MD','ME',
            'MK','MT','NL','NO','PL','PT','RO','RS','SE','SI','SK','SM','UA','VA','XK'
        ]) THEN 'europe'
        ELSE 'other'
    END;

    INSERT INTO players (id, age_group, sex, country, subregion, region_group)
    VALUES (p_player_id, v_age, v_sex, v_country, v_sub, v_region)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO sessions (id, player_id) VALUES (v_session, p_player_id);

    FOR v_item IN
        SELECT value FROM jsonb_array_elements(p_placements)
    LOOP
        v_seq := v_seq + 1;
        v_event := (v_item->>'event_id')::bigint;
        v_index := (v_item->>'insert_index')::integer;

        IF v_item ? 'response_ms'
           AND NULLIF(btrim(v_item->>'response_ms'), '') IS NOT NULL THEN
            v_ms_big := (v_item->>'response_ms')::bigint;
            IF v_ms_big < 0 THEN
                RAISE EXCEPTION 'invalid response time at step %', v_seq;
            ELSIF v_ms_big > 2147483647 THEN
                v_ms := 2147483647;
            ELSE
                v_ms := v_ms_big::integer;
            END IF;
        ELSE
            v_ms := NULL;
        END IF;

        v_skipped := lower(COALESCE(v_item->>'skipped', '')) = 'true';

        IF v_event IS NULL THEN
            RAISE EXCEPTION 'invalid placement at step %', v_seq;
        END IF;
        IF v_event = ANY (v_tl) THEN
            RAISE EXCEPTION 'duplicate event at step %', v_seq;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM events WHERE id = v_event) THEN
            RAISE EXCEPTION 'unknown event at step %', v_seq;
        END IF;

        IF v_skipped THEN
            SELECT count(*) FILTER (WHERE k.ko < k.ke)::integer
            INTO v_earlier
            FROM unnest(v_tl) AS u(id)
            JOIN events o ON o.id = u.id
            JOIN events e ON e.id = v_event
            CROSS JOIN LATERAL (
                SELECT
                    CASE WHEN e.precision = 'month' OR o.precision = 'month' THEN left(e.date_text, 7) ELSE e.date_text END AS ke,
                    CASE WHEN e.precision = 'month' OR o.precision = 'month' THEN left(o.date_text, 7) ELSE o.date_text END AS ko
            ) k;
            v_index := COALESCE(v_earlier, 0);
            v_skipped_ids := v_skipped_ids || v_event;
        ELSIF v_index IS NULL
           OR v_index < 0
           OR v_index > COALESCE(cardinality(v_tl), 0) THEN
            RAISE EXCEPTION 'invalid placement at step %', v_seq;
        END IF;

        IF v_index = 0 THEN
            v_before := ARRAY[]::bigint[];
        ELSE
            v_before := COALESCE(v_tl[1:v_index], ARRAY[]::bigint[]);
        END IF;
        IF v_index = COALESCE(cardinality(v_tl), 0) THEN
            v_after := ARRAY[]::bigint[];
        ELSE
            v_after := COALESCE(v_tl[v_index + 1:cardinality(v_tl)], ARRAY[]::bigint[]);
        END IF;

        v_tl := v_before || v_event || v_after;

        INSERT INTO session_events (session_id, event_id, seq)
        VALUES (v_session, v_event, v_seq);

        IF NOT v_skipped THEN
            INSERT INTO guesses (
                session_id, player_id, event_id, seq,
                guessed_before, guessed_after, response_ms
            ) VALUES (
                v_session, p_player_id, v_event, v_seq,
                v_before, v_after, v_ms
            );
        END IF;
    END LOOP;

    IF COALESCE(cardinality(v_tl), 0) <> v_seq THEN
        RAISE EXCEPTION 'timeline length mismatch';
    END IF;

    UPDATE sessions SET finished_at = now() WHERE id = v_session;

    SELECT COALESCE(
        round(100.0 * count(*) FILTER (WHERE correct) / NULLIF(count(correct), 0))::integer,
        0
    )
    INTO v_score
    FROM guess_pairs_v
    WHERE session_id = v_session;

    WITH ordered AS (
        SELECT t.id, (t.ord - 1)::integer AS your_pos
        FROM unnest(v_tl) WITH ORDINALITY AS t(id, ord)
    ),
    truth AS (
        SELECT
            e.id,
            e.title,
            e.description,
            e.category,
            e.date_text,
            e.precision,
            (row_number() OVER (
                ORDER BY (e.date_text || CASE WHEN length(e.date_text) = 7 THEN '-01' ELSE '' END)::date,
                         e.id
            ) - 1)::integer AS true_pos
        FROM events e
        WHERE e.id = ANY (v_tl)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', truth.id,
            'title', truth.title,
            'description', truth.description,
            'category', truth.category,
            'date_text', truth.date_text,
            'precision', truth.precision,
            'your_pos', ordered.your_pos,
            'true_pos', truth.true_pos,
            'shift', ordered.your_pos - truth.true_pos,
            'skipped', truth.id = ANY (v_skipped_ids)
        )
        ORDER BY ordered.your_pos
    ), '[]'::jsonb)
    INTO v_timeline
    FROM truth
    JOIN ordered ON ordered.id = truth.id;

    RETURN jsonb_build_object(
        'session_id', v_session,
        'score', v_score,
        'timeline', v_timeline
    );
END;
$$;

CREATE OR REPLACE FUNCTION check_placement(
    p_ordered      jsonb,
    p_event_id     bigint,
    p_insert_index integer
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ids     bigint[];
    v_n       integer;
    v_earlier integer;
    v_later   integer;
    v_low     integer;
    v_high    integer;
    v_at      integer;
BEGIN
    IF p_event_id IS NULL OR p_insert_index IS NULL THEN
        RAISE EXCEPTION 'placement is incomplete';
    END IF;
    IF p_ordered IS NULL OR jsonb_typeof(p_ordered) <> 'array' THEN
        RAISE EXCEPTION 'ordered timeline must be a list';
    END IF;

    SELECT COALESCE(array_agg(item.id ORDER BY item.ord), '{}')
    INTO v_ids
    FROM (
        SELECT (value)::bigint AS id, ordinality AS ord
        FROM jsonb_array_elements_text(p_ordered) WITH ORDINALITY
    ) item;

    v_n := COALESCE(cardinality(v_ids), 0);
    IF p_insert_index < 0 OR p_insert_index > v_n THEN
        RAISE EXCEPTION 'invalid placement';
    END IF;
    IF p_event_id = ANY (v_ids) THEN
        RAISE EXCEPTION 'event is already on the timeline';
    END IF;
    IF (SELECT count(DISTINCT x) FROM unnest(v_ids) AS x) <> v_n THEN
        RAISE EXCEPTION 'duplicate event on the timeline';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM events WHERE id = p_event_id)
       OR (SELECT count(*) FROM events WHERE id = ANY (v_ids)) <> v_n THEN
        RAISE EXCEPTION 'unknown event';
    END IF;

    SELECT
        count(*) FILTER (WHERE k.ko < k.ke)::integer,
        count(*) FILTER (WHERE k.ko > k.ke)::integer
    INTO v_earlier, v_later
    FROM unnest(v_ids) AS u(id)
    JOIN events o ON o.id = u.id
    JOIN events e ON e.id = p_event_id
    CROSS JOIN LATERAL (
        SELECT
            CASE WHEN e.precision = 'month' OR o.precision = 'month' THEN left(e.date_text, 7) ELSE e.date_text END AS ke,
            CASE WHEN e.precision = 'month' OR o.precision = 'month' THEN left(o.date_text, 7) ELSE o.date_text END AS ko
    ) k;

    v_low := COALESCE(v_earlier, 0);
    v_high := v_n - COALESCE(v_later, 0);
    v_at := least(greatest(p_insert_index, v_low), v_high);

    RETURN jsonb_build_object(
        'correct', p_insert_index BETWEEN v_low AND v_high,
        'insert_index', v_at
    );
END;
$$;

REVOKE ALL ON FUNCTION get_game_events(integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION submit_game(uuid, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION check_placement(jsonb, bigint, integer) FROM PUBLIC;

ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE events_review ENABLE ROW LEVEL SECURITY;
ALTER TABLE players ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE session_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE guesses ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['anon', 'authenticated']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I', r);
            EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I', r);
            EXECUTE format('GRANT EXECUTE ON FUNCTION get_game_events(integer, integer) TO %I', r);
            EXECUTE format('GRANT EXECUTE ON FUNCTION submit_game(uuid, jsonb, jsonb) TO %I', r);
            EXECUTE format('GRANT EXECUTE ON FUNCTION check_placement(jsonb, bigint, integer) TO %I', r);
        END IF;
    END LOOP;
END $$;
