-- =============================================================================
-- Project 03 · Automated DB Backup & Cloud Sync — demo schema
-- =============================================================================
-- Executed once by the postgres image on first initialisation
-- (/docker-entrypoint-initdb.d). It exists so a backup cycle protects a real
-- schema with real rows instead of an empty database.

CREATE SCHEMA IF NOT EXISTS app;

CREATE TABLE IF NOT EXISTS app.customers (
    id            bigserial PRIMARY KEY,
    email         text        NOT NULL UNIQUE,
    display_name  text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app.events (
    id           bigserial   PRIMARY KEY,
    customer_id  bigint      REFERENCES app.customers (id) ON DELETE CASCADE,
    kind         text        NOT NULL,
    payload      jsonb       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS events_occurred_at_idx ON app.events (occurred_at DESC);

INSERT INTO app.customers (email, display_name)
SELECT
    'customer-' || n || '@example.test',
    'Demo Customer ' || n
FROM generate_series(1, 25) AS n
ON CONFLICT (email) DO NOTHING;

INSERT INTO app.events (customer_id, kind, payload)
SELECT
    c.id,
    (ARRAY['signup', 'login', 'export', 'backup'])[1 + (n % 4)],
    jsonb_build_object('seed', true, 'sequence', n)
FROM app.customers c
CROSS JOIN generate_series(1, 40) AS n
WHERE NOT EXISTS (SELECT 1 FROM app.events);

-- Helpful marker for anyone inspecting a restored database.
COMMENT ON SCHEMA app IS 'CloudGuard Project 03 demo schema (seeded at initdb)';
