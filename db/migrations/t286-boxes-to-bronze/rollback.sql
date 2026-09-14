-- Rollback for t286 — move the box tables back bronze -> public.
-- Target DB: packiot_analytics (10.10.10.89)

ALTER TABLE bronze.scanned_boxes SET SCHEMA public;
ALTER TABLE bronze.sample_boxes  SET SCHEMA public;
