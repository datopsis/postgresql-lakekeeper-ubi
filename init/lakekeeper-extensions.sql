-- Explicit operator action in the selected Lakekeeper database; never run by
-- the entrypoint and never modify template databases.
\set ON_ERROR_STOP on
BEGIN;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;
CREATE EXTENSION IF NOT EXISTS btree_gist;
COMMIT;
