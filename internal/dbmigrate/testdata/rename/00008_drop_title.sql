-- +goose Up
-- The release before neither reads nor writes title any more.
-- squawk-ignore ban-drop-column
ALTER TABLE items DROP COLUMN title;
-- +goose Down
-- Down only runs locally and in tests; the Down of the file before fills the values back from name.
ALTER TABLE items ADD COLUMN title text;
