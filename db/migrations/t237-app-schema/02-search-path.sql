-- t237 P-app · WIDEN search_path — add `app` immediately before `public` (after the
-- medallion + barcode schemas). Unqualified reads/writes of app tables resolve to
-- `app`; the unqualified-CREATE landing schema stays `gold` (no new footgun).
-- NOTE: mirror_replay_cursor / user_screen_config still live in `gold` until P-app.2
-- — with `gold` ahead of `app` on the path, unqualified refs to those two keep
-- resolving to the live gold copy until P-app.2 moves them.
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, app, public;
