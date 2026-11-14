-- +goose Up
-- This release stops writing title, so title must take NULL; the release before still writes it.
-- squawk-ignore ban-drop-not-null
ALTER TABLE items ALTER COLUMN title DROP NOT NULL;
-- +goose Down
-- Down only runs locally and in tests; rows written without title get it back from name first.
UPDATE items SET title = name WHERE title IS NULL;
-- squawk-ignore adding-not-nullable-field
ALTER TABLE items ALTER COLUMN title SET NOT NULL;
