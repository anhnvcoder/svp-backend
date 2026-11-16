-- +goose Up
-- Wrong on purpose: the release before still reads and writes title, and fails from the moment this commits.
ALTER TABLE items RENAME COLUMN title TO name;
-- +goose Down
ALTER TABLE items RENAME COLUMN name TO title;
