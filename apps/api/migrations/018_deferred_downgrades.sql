-- Existing paid scheduled changes retain their original semantics. New changes await verified renewal.
ALTER TABLE subscriptions ADD COLUMN scheduled_prepaid boolean NOT NULL DEFAULT true;
