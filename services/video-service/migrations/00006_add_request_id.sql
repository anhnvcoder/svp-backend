-- +goose Up
-- The idempotency key of InitUpload, unique per author: a repeated call finds the video its first
-- call created instead of creating another. NULL for videos created without a key, which the
-- partial index leaves out. Adding a nullable column without a default rewrites no row.
ALTER TABLE videos ADD COLUMN request_id uuid;
CREATE UNIQUE INDEX videos_author_request_idx ON videos (author_id, request_id) WHERE request_id IS NOT NULL;

-- +goose Down
DROP INDEX videos_author_request_idx;
ALTER TABLE videos DROP COLUMN request_id;
