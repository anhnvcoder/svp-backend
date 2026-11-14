-- +goose Up
-- Wrong on purpose: with no bound on the lock wait, every query on items queues behind this ALTER while it waits.
SET LOCAL lock_timeout = 0;
ALTER TABLE items ADD COLUMN name text;
-- +goose Down
ALTER TABLE items DROP COLUMN name;
