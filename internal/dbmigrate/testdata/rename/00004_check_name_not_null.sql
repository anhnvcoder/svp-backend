-- +goose Up
-- NOT VALID checks new rows only, so its ACCESS EXCLUSIVE lock covers no table scan; the next file validates.
ALTER TABLE items ADD CONSTRAINT items_name_not_null CHECK (name IS NOT NULL) NOT VALID;
-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before.
-- squawk-ignore ban-drop-constraint
ALTER TABLE items DROP CONSTRAINT items_name_not_null;
