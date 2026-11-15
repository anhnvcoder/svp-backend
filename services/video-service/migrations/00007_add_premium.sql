-- +goose Up
-- premium is fixed at InitUpload. Its constant default is stored in the catalog, so adding it rewrites no row, and
-- the release before, which inserts without naming it, keeps creating regular videos.
ALTER TABLE videos ADD COLUMN premium boolean NOT NULL DEFAULT false;
-- The public preview's master playlist of a premium video, set with playlist_key once READY; NULL otherwise.
ALTER TABLE videos ADD COLUMN preview_playlist_key text;
-- One entitlement per user and video; a repeated purchase overwrites tier. user_id has no foreign key: users live
-- in user-service's database.
CREATE TABLE video_entitlements (
    user_id    uuid        NOT NULL,
    video_id   uuid        NOT NULL REFERENCES videos (id),
    tier       text        NOT NULL CHECK (tier IN ('sd', 'hd', 'fhd')),
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, video_id)
);

-- +goose Down
-- Down only runs locally and in tests: stg and prd go back by deploying the release before.
-- squawk-ignore ban-drop-table
DROP TABLE video_entitlements;
-- squawk-ignore ban-drop-column
ALTER TABLE videos DROP COLUMN preview_playlist_key;
-- squawk-ignore ban-drop-column
ALTER TABLE videos DROP COLUMN premium;
