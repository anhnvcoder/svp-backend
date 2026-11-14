-- +goose Up
-- VALIDATE scans the table under SHARE UPDATE EXCLUSIVE, which lets the app read and write meanwhile.
ALTER TABLE items VALIDATE CONSTRAINT items_name_not_null;
-- +goose Down
-- Nothing to undo: the Down of the file before drops the constraint.
SELECT 1;
