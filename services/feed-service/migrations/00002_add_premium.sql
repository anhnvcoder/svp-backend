-- +goose Up
-- A premium video's playlist_key holds its public preview, so the feed never stores a key under premium/. The
-- constant default is stored in the catalog: adding it rewrites no row, rows already here read as regular videos,
-- and the release before, which inserts without naming it, keeps storing regular ones.
ALTER TABLE videos ADD COLUMN premium boolean NOT NULL DEFAULT false;

-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before.
-- squawk-ignore ban-drop-column
ALTER TABLE videos DROP COLUMN premium;
