-- +goose NO TRANSACTION
-- squawk-disable-assume-in-transaction
-- +goose Up

-- Rows the relay gave up on (internal/outbox): when and with which Kafka error. Nullable without a default, so adding
-- them rewrites no row, and the release before, which names neither column, reads and writes the table as before.
-- This runs under the runner's short lock_timeout: the ALTER waits for an exclusive lock that would queue the app.
ALTER TABLE outbox ADD COLUMN IF NOT EXISTS failed_at timestamptz, ADD COLUMN IF NOT EXISTS last_error text;

-- The relay's read skips failed rows. outbox_unpublished_idx stays while the release before reads through it.
-- The longer wait only covers CREATE INDEX CONCURRENTLY, whose waits hold a lock that blocks no read or write.
SET lock_timeout = '30s';
DROP INDEX CONCURRENTLY IF EXISTS outbox_pending_idx;
CREATE INDEX CONCURRENTLY IF NOT EXISTS outbox_pending_idx ON outbox (id)
    WHERE published_at IS NULL AND failed_at IS NULL;
RESET lock_timeout;

-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before.
DROP INDEX CONCURRENTLY IF EXISTS outbox_pending_idx;
-- squawk-ignore ban-drop-column
ALTER TABLE outbox DROP COLUMN IF EXISTS last_error, DROP COLUMN IF EXISTS failed_at;
