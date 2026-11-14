-- +goose NO TRANSACTION
-- squawk-disable-assume-in-transaction

-- +goose Up
-- Each batch reads only its own range of ids, so the cost grows with the rows, not their square; one commit per batch
-- keeps its row locks short, and a rerun skips the rows that already have a name.
-- +goose StatementBegin
DO $$
DECLARE
  last_id bigint := 0;
  batch_end bigint;
BEGIN
  LOOP
    SELECT max(id) INTO batch_end FROM (SELECT id FROM items WHERE id > last_id ORDER BY id LIMIT 10000) AS batch;
    EXIT WHEN batch_end IS NULL;
    UPDATE items SET name = title WHERE id > last_id AND id <= batch_end AND name IS NULL;
    last_id := batch_end;
    COMMIT;
  END LOOP;
END $$;
-- +goose StatementEnd
-- +goose Down
-- Nothing to undo: the Down that drops name drops the copied values with it.
SELECT 1;
