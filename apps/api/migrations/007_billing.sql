-- Additive billing authority. Existing usage ledger is retained, never reset.
CREATE TABLE billing_plans(id uuid PRIMARY KEY,code text UNIQUE NOT NULL,display_name text NOT NULL,quota_bytes bigint NOT NULL CHECK(quota_bytes>=0),active boolean NOT NULL DEFAULT true);
INSERT INTO billing_plans VALUES
('70000000-0000-4000-8000-000000000001','FREE_5','5 GB Free',5000000000,true),
('70000000-0000-4000-8000-000000000002','STANDARD_64','64 GB',64000000000,true),
('70000000-0000-4000-8000-000000000003','STANDARD_128','128 GB',128000000000,true),
('70000000-0000-4000-8000-000000000004','STANDARD_256','256 GB',256000000000,true),
('70000000-0000-4000-8000-000000000005','STANDARD_512','512 GB',512000000000,true),
('70000000-0000-4000-8000-000000000006','STANDARD_1TB','1 TB',1000000000000,true),
('70000000-0000-4000-8000-000000000007','STANDARD_2TB','2 TB',2000000000000,true);
CREATE TABLE billing_prices(id uuid PRIMARY KEY,plan_id uuid NOT NULL REFERENCES billing_plans(id),billing_interval text NOT NULL CHECK(billing_interval IN('MONTHLY','ANNUAL')),currency text NOT NULL CHECK(currency ~ '^[A-Z]{3}$'),amount_minor bigint NOT NULL CHECK(amount_minor>0 AND amount_minor<=9007199254740991),provider_plan_code text NOT NULL,environment text NOT NULL CHECK(environment IN('TEST','LIVE')),active boolean NOT NULL DEFAULT false,effective_at timestamptz NOT NULL DEFAULT now(),ends_at timestamptz,CHECK(ends_at IS NULL OR ends_at>effective_at));
CREATE INDEX billing_prices_lookup ON billing_prices(plan_id,billing_interval,effective_at DESC);
CREATE TABLE billing_customers(user_id uuid PRIMARY KEY REFERENCES users(id),provider text NOT NULL DEFAULT 'PAYSTACK' CHECK(provider='PAYSTACK'),provider_customer_id text UNIQUE NOT NULL,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE billing_checkouts(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),price_id uuid NOT NULL REFERENCES billing_prices(id),request_key uuid NOT NULL,provider_reference text UNIQUE NOT NULL,generation bigint NOT NULL,status text NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','READY','VERIFIED','FAILED')),authorization_url text,created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL DEFAULT now()+interval '1 hour',UNIQUE(user_id,request_key));
CREATE UNIQUE INDEX billing_one_pending_checkout ON billing_checkouts(user_id) WHERE status IN('PENDING','READY');
CREATE TABLE subscriptions(id uuid PRIMARY KEY,user_id uuid UNIQUE NOT NULL REFERENCES users(id),plan_id uuid NOT NULL REFERENCES billing_plans(id),price_id uuid NOT NULL REFERENCES billing_prices(id),provider_subscription_id text UNIQUE,status text NOT NULL CHECK(status IN('ACTIVE','PAST_DUE','GRACE_PERIOD','CANCEL_AT_PERIOD_END','CANCELED','EXPIRED')),billing_interval text NOT NULL CHECK(billing_interval IN('MONTHLY','ANNUAL')),current_period_start timestamptz NOT NULL,current_period_end timestamptz NOT NULL,cancel_at_period_end boolean NOT NULL DEFAULT false,grace_period_end timestamptz NOT NULL,last_paid_at timestamptz NOT NULL,generation bigint NOT NULL,scheduled_plan_id uuid REFERENCES billing_plans(id),scheduled_price_id uuid REFERENCES billing_prices(id),scheduled_effective_at timestamptz,provision_state text NOT NULL DEFAULT 'PENDING' CHECK(provision_state IN('PENDING','READY','AMBIGUOUS')),updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE entitlements(user_id uuid PRIMARY KEY REFERENCES users(id),plan_id uuid NOT NULL REFERENCES billing_plans(id),quota_bytes bigint NOT NULL CHECK(quota_bytes>=0),source text NOT NULL CHECK(source IN('FREE','SUBSCRIPTION')),effective_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE manual_entitlements(user_id uuid PRIMARY KEY REFERENCES users(id),quota_bytes bigint NOT NULL CHECK(quota_bytes>=0 AND quota_bytes<=10995116277760),expires_at timestamptz,reason text NOT NULL,updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO entitlements SELECT id,'70000000-0000-4000-8000-000000000001',5000000000,'FREE',now(),now() FROM users;
-- Preserve previously authorized development/manual overrides instead of changing old quotas silently.
INSERT INTO manual_entitlements(user_id,quota_bytes,reason) SELECT user_id,quota_bytes,'LEGACY_DEVELOPMENT_QUOTA' FROM development_entitlements;
CREATE FUNCTION initialize_free_entitlement() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN INSERT INTO entitlements(user_id,plan_id,quota_bytes,source) VALUES(NEW.id,'70000000-0000-4000-8000-000000000001',5000000000,'FREE'); RETURN NEW; END $$;
CREATE TRIGGER users_free_entitlement AFTER INSERT ON users FOR EACH ROW EXECUTE FUNCTION initialize_free_entitlement();
CREATE TABLE billing_transactions(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),subscription_id uuid REFERENCES subscriptions(id),provider_reference text NOT NULL,provider_transaction_id text NOT NULL,amount_minor bigint NOT NULL CHECK(amount_minor>=0),currency text NOT NULL,status text NOT NULL CHECK(status IN('SUCCESS','FAILED')),paid_at timestamptz,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(provider_reference,status),UNIQUE(provider_transaction_id,status));
CREATE TABLE billing_webhook_events(id uuid PRIMARY KEY,event_key text UNIQUE NOT NULL,event_type text NOT NULL,payload_hash text NOT NULL,processing_status text NOT NULL CHECK(processing_status IN('PROCESSED','IGNORED')),processed_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE billing_audit(id uuid PRIMARY KEY,user_id uuid REFERENCES users(id),action text NOT NULL,correlation_id text NOT NULL,summary jsonb NOT NULL DEFAULT '{}',created_at timestamptz NOT NULL DEFAULT now());
CREATE TRIGGER billing_audit_immutable BEFORE UPDATE OR DELETE ON billing_audit FOR EACH ROW EXECUTE FUNCTION reject_internal_audit_change();
CREATE TRIGGER billing_transaction_immutable BEFORE UPDATE OR DELETE ON billing_transactions FOR EACH ROW EXECUTE FUNCTION reject_internal_audit_change();
CREATE TABLE billing_provider_jobs(id uuid PRIMARY KEY,user_id uuid NOT NULL REFERENCES users(id),subscription_code text UNIQUE NOT NULL,status text NOT NULL DEFAULT 'PENDING' CHECK(status IN('PENDING','DONE')),created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX billing_audit_user ON billing_audit(user_id,created_at DESC,id DESC);
CREATE INDEX billing_transactions_user ON billing_transactions(user_id,created_at DESC,id DESC);
CREATE UNIQUE INDEX billing_audit_transition ON billing_audit(user_id,action,correlation_id);
CREATE FUNCTION prevent_price_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF (NEW.plan_id,NEW.billing_interval,NEW.currency,NEW.amount_minor,NEW.provider_plan_code,NEW.environment) IS DISTINCT FROM (OLD.plan_id,OLD.billing_interval,OLD.currency,OLD.amount_minor,OLD.provider_plan_code,OLD.environment) THEN RAISE EXCEPTION 'Create a new immutable price version'; END IF; RETURN NEW; END $$;
CREATE TRIGGER billing_price_version BEFORE UPDATE ON billing_prices FOR EACH ROW EXECUTE FUNCTION prevent_price_rewrite();
-- Relax the old development-only aggregate ceiling so an over-quota account can
-- retain its usage after a legitimate downgrade. Nonnegative counter constraints
-- remain. Reservation UPDATEs enforce the current authoritative quota atomically.
ALTER TABLE development_entitlements DROP CONSTRAINT development_entitlements_check;
CREATE FUNCTION prevent_plan_quota_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF (NEW.code,NEW.quota_bytes) IS DISTINCT FROM (OLD.code,OLD.quota_bytes) THEN RAISE EXCEPTION 'Canonical plan quotas are immutable'; END IF; RETURN NEW; END $$;
CREATE TRIGGER billing_plan_quota BEFORE UPDATE ON billing_plans FOR EACH ROW EXECUTE FUNCTION prevent_plan_quota_rewrite();
