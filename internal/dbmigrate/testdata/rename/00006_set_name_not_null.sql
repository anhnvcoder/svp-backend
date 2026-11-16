-- +goose Up
-- The validated check proves no row is NULL, so SET NOT NULL skips the table scan and holds its lock only briefly.
-- squawk-ignore adding-not-nullable-field
ALTER TABLE items ALTER COLUMN name SET NOT NULL;
-- The column's NOT NULL now enforces what the check did.
-- squawk-ignore ban-drop-constraint
ALTER TABLE items DROP CONSTRAINT items_name_not_null;
-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before. It restores the validated
-- check, so a later Up of this file again skips the table scan.
-- squawk-ignore constraint-missing-not-valid
ALTER TABLE items ADD CONSTRAINT items_name_not_null CHECK (name IS NOT NULL);
-- squawk-ignore ban-drop-not-null
ALTER TABLE items ALTER COLUMN name DROP NOT NULL;
