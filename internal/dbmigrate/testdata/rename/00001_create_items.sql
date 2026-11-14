-- +goose Up
CREATE TABLE items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  title text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before.
-- squawk-ignore ban-drop-table
DROP TABLE items;
