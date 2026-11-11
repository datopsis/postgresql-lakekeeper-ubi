\set ON_ERROR_STOP on
BEGIN;
SET LOCAL plpgsql.check_asserts = on;
-- Call the actual extension functions (core gen_random_uuid is insufficient).
DO $$
BEGIN
    ASSERT uuid_generate_v4()::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$';
    ASSERT encode(digest('abc', 'sha256'), 'hex') =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
    ASSERT similarity('lakekeeper', 'lakekeeper') = 1;
    ASSERT similarity('lakekeeper', 'xyz') = 0;
END $$;
-- Integer GIN/GiST operator classes are provided by btree_gin/btree_gist.
-- Exercise index construction, writes, and indexed reads independently.
CREATE TEMP TABLE gin_probe (value integer);
CREATE INDEX gin_probe_idx ON gin_probe USING gin (value);
CREATE TEMP TABLE gist_probe (value integer);
CREATE INDEX gist_probe_idx ON gist_probe USING gist (value);
INSERT INTO gin_probe SELECT generate_series(1, 100);
INSERT INTO gist_probe SELECT generate_series(1, 100);
SET LOCAL enable_seqscan = off;
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM gin_probe WHERE value BETWEEN 42 AND 44) = 3;
    ASSERT (SELECT count(*) FROM gist_probe WHERE value BETWEEN 42 AND 44) = 3;
END $$;
ROLLBACK;
