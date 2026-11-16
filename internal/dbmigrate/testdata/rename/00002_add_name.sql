-- +goose Up
-- Nullable and without a default: adding it rewrites no row, and the release before keeps inserting title alone.
ALTER TABLE items ADD COLUMN name text;
-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before.
-- squawk-ignore ban-drop-column
ALTER TABLE items DROP COLUMN name;
