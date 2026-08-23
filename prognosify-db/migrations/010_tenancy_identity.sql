-- =============================================================================================
-- 010_tenancy_identity.sql — Prognosify multi-tenant foundation
-- PostgreSQL 15+ / Supabase (ap-south-1). Idempotent: safe to re-run.
--
-- WHAT THIS FILE OWNS
--   * organisations (hospital tenants), plans and feature entitlements
--   * identities (app_user), memberships (organization_member), vendor staff (platform_admin)
--   * the patient IDENTITY root (public.patient: tenant, MRN, demographics, portal link)
--   * the session helper API that every later migration's RLS policy is built on
--   * vendor (super_admin) containment: support_session
--
-- RETIRE THE SINGLE-TENANT DRAFTS FIRST
--   001–004 in this directory are the pre-multi-tenancy drafts. Do not load them alongside
--   this file. They create a conflicting public.patient, and their app.has_role(text) would
--   sit beside this file's app.has_role(app.org_role) as an OVERLOAD — after which
--   `app.has_role('doctor')` is ambiguous and every policy using it fails to resolve. Move
--   them out of the migration path before running 010.
--
-- WHAT LATER MIGRATIONS MUST NOT DO
--   * do not re-create public.patient — add clinical facts as separate tables keyed on it
--   * do not put is_super_admin() into a policy on any table holding clinical data (§8.6)
--   * do not read roles from the JWT — read them through app.has_role() (§8.2)
--
-- HOUSE RULES FOR EVERY TENANT TABLE ADDED LATER (this is the isolation contract)
--   1. carry `organization_id uuid NOT NULL REFERENCES public.organization(id) ON DELETE RESTRICT`
--   2. declare `UNIQUE (id, organization_id)` so children can FK compositely
--   3. FK to a parent as `FOREIGN KEY (parent_id, organization_id)
--        REFERENCES public.parent (id, organization_id)` — this makes a cross-tenant
--        reference a foreign-key violation rather than a code review finding
--   4. `ENABLE ROW LEVEL SECURITY` and start every policy with
--        `organization_id = app.current_org_id()`
--   5. no DELETE policy for clinical data; attach app.deny_hard_delete()
--   Run `SELECT * FROM app.v_tenant_rls_gaps;` after every migration — it lists tables that
--   carry organization_id and forgot step 4.
--
-- COMPLIANCE POSTURE (deliberately modest — not legal advice)
--   The operator is in India, so the governing regime here is the Digital Personal Data
--   Protection Act, 2023, not HIPAA. This schema implements ordinary security engineering —
--   tenant isolation, least privilege, auditability, erasure being possible but deliberate.
--   Whether that satisfies any specific DPDP obligation is a question for counsel; nothing
--   in this file should be read as a claim of certification or of legal sufficiency.
--   (Note for the product team: the login screen currently prints "HIPAA compliant · SOC 2
--   Type II". Neither claim is substantiated anywhere in this repository.)
-- =============================================================================================


-- =============================================================================================
-- SECTION 0 — SCHEMAS
-- =============================================================================================

CREATE SCHEMA IF NOT EXISTS app;

COMMENT ON SCHEMA app IS
  'Authorisation helpers and shared trigger utilities. Contains no tenant data. Everything '
  'here is called from RLS policies, so treat any change as a security change.';


-- =============================================================================================
-- SECTION 1 — AUTHENTICATION SEAM (the only host-specific code in this file)
--
-- Everything downstream depends on exactly one fact from the host: "which authenticated
-- subject is making this call". app.current_auth_uid() is that seam. The portable body reads
-- the PostgREST claim GUC; on Supabase we rebind it to auth.uid(), which is the same value.
-- To move to RDS/Neon, delete the Supabase block below and keep the portable body.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.current_auth_uid()
RETURNS uuid
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT nullif(
           coalesce(
             current_setting('request.jwt.claim.sub', true),
             nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
           ), '')::uuid;
$$;

-- Reads a vendor-set claim naming the organisation the client wants to act in. This is a
-- HINT ONLY — §8.2 explains why it is never trusted to say what the caller may do.
CREATE OR REPLACE FUNCTION app.jwt_org_id()
RETURNS uuid
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT nullif(
           coalesce(
             nullif(current_setting('request.jwt.claims', true), '')::jsonb
               -> 'app_metadata' ->> 'organization_id',
             nullif(current_setting('request.jwt.claims', true), '')::jsonb
               ->> 'organization_id'
           ), '')::uuid;
$$;

-- >>> BEGIN SUPABASE-SPECIFIC <<< ------------------------------------------------------------
DO $supabase$
BEGIN
  IF to_regprocedure('auth.uid()') IS NOT NULL THEN
    EXECUTE $fn$
      CREATE OR REPLACE FUNCTION app.current_auth_uid()
      RETURNS uuid LANGUAGE sql STABLE
      SET search_path = pg_catalog, pg_temp
      AS 'SELECT auth.uid()';
    $fn$;
  END IF;

  RAISE NOTICE 'prognosify/010: Supabase service_role holds BYPASSRLS. It defeats every policy '
               'in this file. Use it for migrations and trusted server-side workers only, and '
               'never on a request carrying an end user''s identity.';
END
$supabase$;
-- >>> END SUPABASE-SPECIFIC <<< --------------------------------------------------------------

COMMENT ON FUNCTION app.current_auth_uid() IS
  'The authenticated subject (auth.users.id on Supabase). The single value this schema takes '
  'on trust from the host: it is carried in a signature-verified JWT and cannot be forged by '
  'a client. Everything else is resolved from tables.';


-- =============================================================================================
-- SECTION 2 — CLOSED VALUE SETS
-- =============================================================================================

DO $types$
BEGIN
  IF to_regtype('app.org_status') IS NULL THEN
    CREATE TYPE app.org_status AS ENUM ('trial', 'active', 'suspended', 'closed');
  END IF;

  -- NOTE: super_admin is deliberately ABSENT. It is not a role inside an organisation, so
  -- modelling it here would make "vendor" expressible as a membership row — exactly the
  -- magic-flag design the brief rules out. It lives in public.platform_admin instead.
  IF to_regtype('app.org_role') IS NULL THEN
    CREATE TYPE app.org_role AS ENUM
      ('hospital_admin', 'doctor', 'nurse', 'receptionist', 'patient');
  END IF;

  IF to_regtype('app.member_status') IS NULL THEN
    CREATE TYPE app.member_status AS ENUM ('invited', 'active', 'suspended', 'revoked');
  END IF;

  IF to_regtype('app.user_status') IS NULL THEN
    CREATE TYPE app.user_status AS ENUM ('active', 'suspended', 'deactivated');
  END IF;

  IF to_regtype('app.feature_kind') IS NULL THEN
    CREATE TYPE app.feature_kind AS ENUM ('flag', 'limit');
  END IF;

  IF to_regtype('app.support_scope') IS NULL THEN
    CREATE TYPE app.support_scope AS ENUM ('operational', 'phi');
  END IF;

  IF to_regtype('app.patient_status') IS NULL THEN
    CREATE TYPE app.patient_status AS ENUM ('active', 'inactive', 'deceased', 'merged');
  END IF;

  -- Matches the Register-patient screen's Sex field exactly.
  IF to_regtype('app.sex') IS NULL THEN
    CREATE TYPE app.sex AS ENUM ('male', 'female', 'other', 'undisclosed');
  END IF;
END
$types$;


-- =============================================================================================
-- SECTION 3 — SHARED TRIGGER UTILITIES (exported: later migrations attach these)
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Clinical history must survive. Attach to every clinical table:
--   CREATE TRIGGER t_no_delete BEFORE DELETE ON public.x
--     FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
-- The escape hatch is deliberate and greppable: a lawful erasure request (DPDP gives data
-- principals a right to erasure in defined circumstances) or a retention job runs
--   SET LOCAL app.allow_hard_delete = 'on';
-- inside its own transaction, which makes the intent explicit and auditable rather than
-- leaving the door open by default.
CREATE OR REPLACE FUNCTION app.deny_hard_delete()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('app.allow_hard_delete', true), 'off') = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Hard delete is not permitted on %. Amend, void or supersede the row instead.',
                  TG_TABLE_NAME
    USING errcode = '42501',
          hint = 'A deliberate erasure sets app.allow_hard_delete for one transaction.';
END;
$$;

-- Object-storage keys. Bytes never live in a column (rule 3); the DB holds this key. Making
-- the tenant the FIRST path segment means a guessed or leaked key cannot cross hospitals, and
-- a storage-side policy can be written as a simple prefix match.
CREATE OR REPLACE FUNCTION app.storage_prefix(p_organization_id uuid)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT 'org/' || p_organization_id::text || '/' $$;

-- IMMUTABLE so it can be used directly in a CHECK constraint, e.g.
--   CONSTRAINT document_key_tenant_ck
--     CHECK (app.storage_key_belongs_to(storage_key, organization_id))
CREATE OR REPLACE FUNCTION app.storage_key_belongs_to(p_key text, p_organization_id uuid)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT p_key IS NOT NULL
     AND p_organization_id IS NOT NULL
     AND left(p_key, length(app.storage_prefix(p_organization_id)))
         = app.storage_prefix(p_organization_id);
$$;


-- =============================================================================================
-- SECTION 4 — TENANTS, PLANS, ENTITLEMENTS
--
-- WHY ENTITLEMENTS ARE TABLES, NOT A jsonb BLOB ON organization
--   A blob is faster to write and worse at everything else that matters here:
--     * no key registry, so `ai_prognosis` and `ai-prognosis` are both "valid" and one of
--       them silently fails open or closed — a feature gate that fails open is a billing
--       leak, one that fails closed is a support ticket at 2am;
--     * the Super Admin surface has to render a list of features to toggle. With a catalog
--       table that list is a SELECT; with a blob it is a hard-coded array in the frontend
--       that drifts from the backend;
--     * "which tenants have SSO?" and "who is over their seat limit?" are ordinary joins
--       against tables and full-table jsonb scans against a blob;
--     * a per-tenant override needs a validity window, a grantor and a note (a trial grant
--       of one feature is the single most common sales ask). Those are columns.
--   The cost is three small tables and one resolution function. Paid gladly.
--   jsonb IS used for organization.settings — genuinely open-ended, never security-relevant.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.subscription_plan (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text        NOT NULL,
    name          text        NOT NULL,
    description   text        NOT NULL DEFAULT '',
    is_active     boolean     NOT NULL DEFAULT true,
    sort_order    integer     NOT NULL DEFAULT 100,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT subscription_plan_code_ck CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$')
);
CREATE UNIQUE INDEX IF NOT EXISTS subscription_plan_code_uk ON public.subscription_plan (code);

CREATE TABLE IF NOT EXISTS public.feature (
    key           text            PRIMARY KEY,
    name          text            NOT NULL,
    description   text            NOT NULL DEFAULT '',
    kind          app.feature_kind NOT NULL DEFAULT 'flag',
    created_at    timestamptz     NOT NULL DEFAULT now(),
    CONSTRAINT feature_key_ck CHECK (key ~ '^[a-z][a-z0-9_]{1,40}$')
);

COMMENT ON TABLE public.feature IS
  'The registry of every gateable capability. A feature key that is not in this table cannot '
  'be granted anywhere — that is the whole point of it being a table.';

CREATE TABLE IF NOT EXISTS public.plan_feature (
    plan_id       uuid        NOT NULL REFERENCES public.subscription_plan (id)
                              ON UPDATE CASCADE ON DELETE CASCADE,
    feature_key   text        NOT NULL REFERENCES public.feature (key)
                              ON UPDATE CASCADE ON DELETE RESTRICT,
    enabled       boolean     NOT NULL DEFAULT true,
    limit_value   integer     NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (plan_id, feature_key),
    CONSTRAINT plan_feature_limit_ck CHECK (limit_value IS NULL OR limit_value >= 0)
);

CREATE TABLE IF NOT EXISTS public.organization (
    id                uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    slug              text            NOT NULL,
    name              text            NOT NULL,
    status            app.org_status  NOT NULL DEFAULT 'trial',
    region            text            NOT NULL DEFAULT 'ap-south-1',
    timezone          text            NOT NULL DEFAULT 'Asia/Kolkata',

    plan_id           uuid            NOT NULL REFERENCES public.subscription_plan (id)
                                      ON UPDATE CASCADE ON DELETE RESTRICT,
    plan_started_at   timestamptz     NOT NULL DEFAULT now(),
    trial_ends_at     timestamptz     NULL,

    -- Non-security UI/operational preferences only (clinic hours, branding). Never read this
    -- in a policy: it is customer-writable.
    settings          jsonb           NOT NULL DEFAULT '{}'::jsonb,

    suspended_at      timestamptz     NULL,
    suspended_reason  text            NULL,
    created_at        timestamptz     NOT NULL DEFAULT now(),
    updated_at        timestamptz     NOT NULL DEFAULT now(),

    -- Slug is the tenant's public handle (subdomain, storage namespace): keep it boring.
    CONSTRAINT organization_slug_ck   CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$'),
    CONSTRAINT organization_name_ck   CHECK (btrim(name) <> ''),
    CONSTRAINT organization_settings_ck CHECK (jsonb_typeof(settings) = 'object'),
    CONSTRAINT organization_suspend_ck
      CHECK ((status = 'suspended') = (suspended_at IS NOT NULL)),
    -- A trial tenant must have a clock. A converted tenant may keep the old date as history.
    CONSTRAINT organization_trial_ck
      CHECK (status <> 'trial' OR trial_ends_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS organization_slug_uk ON public.organization (lower(slug));

COMMENT ON TABLE public.organization IS
  'One hospital tenant. Every row of tenant data in this database traces back to exactly one '
  'of these. status gates access: app.current_org_id() resolves to NULL for a suspended or '
  'closed tenant, so non-payment or an incident locks the tenant out on the next statement '
  'without touching a single GRANT.';
COMMENT ON COLUMN public.organization.region IS
  'Where this tenant''s data is hosted. Single-region today (ap-south-1). Recorded per tenant '
  'so a future residency requirement is a data question, not a migration.';

CREATE TABLE IF NOT EXISTS public.organization_entitlement (
    organization_id uuid        NOT NULL REFERENCES public.organization (id)
                                ON UPDATE CASCADE ON DELETE CASCADE,
    feature_key     text        NOT NULL REFERENCES public.feature (key)
                                ON UPDATE CASCADE ON DELETE RESTRICT,
    enabled         boolean     NOT NULL,
    limit_value     integer     NULL,
    effective_from  timestamptz NOT NULL DEFAULT now(),
    effective_to    timestamptz NULL,
    note            text        NOT NULL DEFAULT '',
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, feature_key),
    CONSTRAINT organization_entitlement_window_ck
      CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT organization_entitlement_limit_ck
      CHECK (limit_value IS NULL OR limit_value >= 0)
);

COMMENT ON TABLE public.organization_entitlement IS
  'Per-tenant override of the plan default, with a validity window. Written by the vendor '
  'only: a customer cannot grant themselves a feature they are not paying for. An expired '
  'override simply stops applying — no cron job needed.';

DROP TRIGGER IF EXISTS t_touch ON public.subscription_plan;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.subscription_plan
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.organization;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.organization
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.organization_entitlement;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.organization_entitlement
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();


-- =============================================================================================
-- SECTION 5 — IDENTITY
--
-- THE THREE QUESTIONS THE BRIEF ASKED, ANSWERED IN THE MODEL
--
-- 1. Can one human belong to two hospitals? YES.
--    app_user is a PERSON and is tenant-agnostic; organization_member is that person's seat
--    in one hospital. A locum with two hospitals has one login and two membership rows.
--    What it costs:
--      * "which organisation is this request for?" stops being obvious, so every session
--        needs an ACTIVE organisation (§8.2) and the app needs an org switcher;
--      * app_user itself cannot be tenant-scoped, so it is the one table where a careless
--        policy could leak the existence of another hospital's users. Its policy (§10) is
--        therefore membership-scoped, not open to all authenticated users;
--      * audit entries must record the acting organisation, not just the actor — hence
--        app.current_org_id() being part of the exported API for 040.
--    The alternative (one login per hospital) costs the locum a password manager entry and
--    costs us a duplicated person with no way to revoke both seats at once. Not worth it.
--
-- 2. A patient is a person AND a record. How do they map?
--    public.patient is a CHART: tenant-scoped, MRN-keyed, and it exists whether or not the
--    person ever logs in (reception registers walk-ins). A portal login is a separate fact:
--    patient.portal_member_id points at the person's membership row in the same hospital.
--    Same person a patient at two hospitals: TWO charts, two MRNs, two membership rows, one
--    app_user. The charts are NOT linked, deliberately — there is no consent mechanism in
--    this product for one hospital to learn that its patient is also treated elsewhere, and
--    inventing a cross-tenant master patient index would quietly create exactly the leak
--    tenant isolation exists to prevent. The person sees both, one hospital at a time, by
--    switching organisation.
--
-- 3. super_admin belongs to no organisation. It is public.platform_admin — a separate table,
--    not a role value, not a nullable organization_id. See §7 and §8.6.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.app_user (
    id                      uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id            uuid            NOT NULL,
    email                   text            NOT NULL,
    full_name               text            NOT NULL,
    status                  app.user_status NOT NULL DEFAULT 'active',

    -- Which organisation this person is currently acting in. A preference, validated on
    -- every use against live membership (§8.2) — never itself a grant.
    active_organization_id  uuid            NULL REFERENCES public.organization (id)
                                            ON UPDATE CASCADE ON DELETE SET NULL,

    created_at              timestamptz     NOT NULL DEFAULT now(),
    updated_at              timestamptz     NOT NULL DEFAULT now(),
    deactivated_at          timestamptz     NULL,

    CONSTRAINT app_user_email_ck CHECK (email = lower(btrim(email)) AND email LIKE '%_@_%'),
    CONSTRAINT app_user_name_ck  CHECK (btrim(full_name) <> ''),
    CONSTRAINT app_user_deactivated_ck
      CHECK ((status = 'deactivated') = (deactivated_at IS NOT NULL)),
    -- Lets children FK to (app_user_id, auth_user_id) so the denormalised auth_user_id on
    -- organization_member / platform_admin cannot drift. See the note on that column.
    CONSTRAINT app_user_id_auth_uk UNIQUE (id, auth_user_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS app_user_auth_uk  ON public.app_user (auth_user_id);
CREATE UNIQUE INDEX IF NOT EXISTS app_user_email_uk ON public.app_user (lower(email));

COMMENT ON TABLE public.app_user IS
  'One row per human login, tenant-agnostic on purpose so a locum or a patient of two '
  'hospitals is one person. Holds no clinical data and no role: what someone may do is '
  'decided by organization_member within one organisation.';

-- >>> BEGIN SUPABASE-SPECIFIC: bind to GoTrue <<< --------------------------------------------
DO $fk_auth$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'app_user_auth_user_fk') THEN
    -- RESTRICT: deleting an auth user must never cascade away the row that names the actor
    -- on thousands of audit entries.
    EXECUTE 'ALTER TABLE public.app_user ADD CONSTRAINT app_user_auth_user_fk
               FOREIGN KEY (auth_user_id) REFERENCES auth.users (id)
               ON UPDATE CASCADE ON DELETE RESTRICT';
  END IF;
END
$fk_auth$;
-- >>> END SUPABASE-SPECIFIC <<< --------------------------------------------------------------


CREATE TABLE IF NOT EXISTS public.organization_member (
    id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid              NOT NULL REFERENCES public.organization (id)
                                       ON UPDATE CASCADE ON DELETE RESTRICT,
    app_user_id      uuid              NOT NULL REFERENCES public.app_user (id)
                                       ON UPDATE CASCADE ON DELETE RESTRICT,

    -- Denormalised from app_user and maintained by trigger, never by the caller. It exists
    -- so every authorisation helper is ONE index probe (auth_user_id -> membership) instead
    -- of two (auth_user_id -> app_user -> membership). The composite FK below makes drift
    -- impossible: this is a cached join key with referential integrity, not a second truth.
    auth_user_id     uuid              NOT NULL,

    -- Multi-valued because small clinics really do have an owner who is both hospital_admin
    -- and doctor, and a nurse treated at her own hospital is staff AND a patient there.
    -- One row per person per hospital keeps "the staff id" unambiguous for later migrations.
    roles            app.org_role[]    NOT NULL,
    status           app.member_status NOT NULL DEFAULT 'active',

    -- Staff directory fields the Settings screen edits. Patients keep none of this.
    job_title        text              NULL,
    license_number   text              NULL,

    invited_at       timestamptz       NULL,
    joined_at        timestamptz       NOT NULL DEFAULT now(),
    revoked_at       timestamptz       NULL,
    created_by       uuid              NULL REFERENCES public.app_user (id)
                                       ON UPDATE CASCADE ON DELETE SET NULL,
    created_at       timestamptz       NOT NULL DEFAULT now(),
    updated_at       timestamptz       NOT NULL DEFAULT now(),

    -- cardinality(), not array_length(): array_length of an empty array is NULL, and a NULL
    -- CHECK passes. That distinction is the difference between "must have a role" and
    -- "silently accepts a member with no roles at all".
    CONSTRAINT organization_member_roles_ck
      CHECK (cardinality(roles) >= 1 AND array_position(roles, NULL::app.org_role) IS NULL),
    CONSTRAINT organization_member_revoked_ck
      CHECK ((status = 'revoked') = (revoked_at IS NOT NULL)),
    CONSTRAINT organization_member_one_seat_uk UNIQUE (organization_id, app_user_id),
    CONSTRAINT organization_member_id_org_uk   UNIQUE (id, organization_id),
    CONSTRAINT organization_member_user_auth_fk
      FOREIGN KEY (app_user_id, auth_user_id) REFERENCES public.app_user (id, auth_user_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);

-- THE index. Every RLS policy in the database funnels through it, so it is covering and
-- partial: an index-only scan over active memberships and nothing else.
CREATE INDEX IF NOT EXISTS organization_member_session_ix
  ON public.organization_member (auth_user_id)
  INCLUDE (organization_id, id, roles)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS organization_member_org_ix
  ON public.organization_member (organization_id) WHERE status = 'active';

COMMENT ON TABLE public.organization_member IS
  'A person''s seat in one hospital: the join between identity and tenant, and the staff '
  'directory row. Later migrations should treat organization_member.id as "staff_id" and FK '
  'to (id, organization_id).';
COMMENT ON COLUMN public.organization_member.roles IS
  'Every role this person holds in this hospital. The cost of allowing more than one is that '
  '"which hat were they wearing" is no longer answerable from the row alone — 040''s audit '
  'entries must therefore record the role that authorised each action, not just the actor.';

CREATE OR REPLACE FUNCTION app.sync_member_identity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_sorted app.org_role[];
BEGIN
  -- Fill the cached join key; callers never set it.
  SELECT u.auth_user_id INTO NEW.auth_user_id
    FROM public.app_user u WHERE u.id = NEW.app_user_id;
  IF NEW.auth_user_id IS NULL THEN
    RAISE EXCEPTION 'app_user % does not exist.', NEW.app_user_id USING errcode = '23503';
  END IF;

  -- Canonical, duplicate-free role array. A CHECK cannot express "no duplicates" without a
  -- subquery, so normalise instead of validating.
  SELECT array_agg(DISTINCT r ORDER BY r) INTO v_sorted FROM unnest(NEW.roles) AS r;
  NEW.roles := v_sorted;

  IF TG_OP = 'UPDATE' THEN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
       OR NEW.app_user_id IS DISTINCT FROM OLD.app_user_id THEN
      RAISE EXCEPTION 'A membership cannot be moved between organisations or people.'
        USING errcode = '42501',
              hint = 'Revoke this seat and create the new one, so both are visible in history.';
    END IF;

    -- Four-eyes on privilege: nobody edits their own roles or reinstates their own seat.
    -- A hospital with exactly one admin gets unstuck by the vendor, which is audited.
    IF OLD.auth_user_id = app.current_auth_uid()
       AND (NEW.roles IS DISTINCT FROM OLD.roles OR NEW.status IS DISTINCT FROM OLD.status)
       AND NOT app.is_super_admin() THEN
      RAISE EXCEPTION 'You cannot change your own roles or seat status.'
        USING errcode = '42501',
              hint = 'Another administrator must make this change so it is separable in the audit trail.';
    END IF;

    NEW.updated_at := now();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_sync_identity ON public.organization_member;
CREATE TRIGGER t_sync_identity BEFORE INSERT OR UPDATE ON public.organization_member
  FOR EACH ROW EXECUTE FUNCTION app.sync_member_identity();

DROP TRIGGER IF EXISTS t_no_delete ON public.organization_member;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.organization_member
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

-- app_user is self-updatable (the Settings screen edits full_name, the org switcher writes
-- active_organization_id). RLS is row-level only, so the column rules live here.
CREATE OR REPLACE FUNCTION app.guard_app_user_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- The link to the identity provider is never editable by anyone through the API. Re-pointing
  -- it is precisely how one person ends up reading another's records.
  IF NEW.auth_user_id IS DISTINCT FROM OLD.auth_user_id THEN
    RAISE EXCEPTION 'auth_user_id is immutable; provision a new user instead.'
      USING errcode = '42501';
  END IF;

  IF OLD.auth_user_id = app.current_auth_uid()
     AND NOT (app.is_hospital_admin() OR app.is_super_admin())
     AND (NEW.email IS DISTINCT FROM OLD.email OR NEW.status IS DISTINCT FROM OLD.status) THEN
    RAISE EXCEPTION 'You cannot change your own sign-in email or account status.'
      USING errcode = '42501';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_touch ON public.app_user;
DROP TRIGGER IF EXISTS t_guard_update ON public.app_user;
CREATE TRIGGER t_guard_update BEFORE UPDATE ON public.app_user
  FOR EACH ROW EXECUTE FUNCTION app.guard_app_user_update();


-- ---- 5.3 vendor-side identity ---------------------------------------------------------------
-- super_admin as its own table, not a role value. Consequences that fall out for free:
--   * a vendor admin has no organization_id anywhere, so every tenant-scoped policy of the
--     form `organization_id = app.current_org_id()` returns them zero rows (§8.6);
--   * granting vendor power is structurally different from granting hospital power — a
--     different table, a different write path, a different audit signature;
--   * there is no way to typo a customer into vendor power.
CREATE TABLE IF NOT EXISTS public.platform_admin (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    app_user_id   uuid        NOT NULL REFERENCES public.app_user (id)
                              ON UPDATE CASCADE ON DELETE RESTRICT,
    auth_user_id  uuid        NOT NULL,
    granted_by    uuid        NULL REFERENCES public.app_user (id)
                              ON UPDATE CASCADE ON DELETE SET NULL,
    reason        text        NOT NULL,
    granted_at    timestamptz NOT NULL DEFAULT now(),
    revoked_at    timestamptz NULL,
    CONSTRAINT platform_admin_reason_ck CHECK (length(btrim(reason)) >= 10),
    CONSTRAINT platform_admin_user_auth_fk
      FOREIGN KEY (app_user_id, auth_user_id) REFERENCES public.app_user (id, auth_user_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS platform_admin_active_uk
  ON public.platform_admin (app_user_id) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS platform_admin_session_ix
  ON public.platform_admin (auth_user_id) WHERE revoked_at IS NULL;

COMMENT ON TABLE public.platform_admin IS
  'Vendor-side operators (super_admin). No organisation, ever. There is deliberately NO RLS '
  'policy allowing writes through the API: a platform admin is created out of band (migration '
  'or service_role runbook), so a compromised web session cannot mint one.';

DROP TRIGGER IF EXISTS t_no_delete ON public.platform_admin;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.platform_admin
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 6 — PATIENT IDENTITY ROOT
--
-- This is the identity half of the patient only: who they are, which tenant holds the record,
-- the MRN the UI shows, and the portal link. Conditions, encounters, vitals, labs, notes and
-- documents hang off patient(id, organization_id) in later migrations.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.patient (
    id                  uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid              NOT NULL REFERENCES public.organization (id)
                                          ON UPDATE CASCADE ON DELETE RESTRICT,

    -- "104-882" on every patient screen. Unique within the hospital, meaningless across it.
    mrn                 text              NOT NULL,

    first_name          text              NOT NULL,
    last_name           text              NOT NULL,
    date_of_birth       date              NOT NULL,
    sex                 app.sex           NOT NULL DEFAULT 'undisclosed',
    phone               text              NULL,
    email               text              NULL,

    status              app.patient_status NOT NULL DEFAULT 'active',

    -- The Register screen's duplicate warning resolves to this: the loser of a merge keeps
    -- its id (so old references stay valid) and points at the survivor.
    merged_into_patient_id uuid           NULL,

    -- The portal account, if this person ever logged in. NULL for a walk-in registered at
    -- the front desk. Composite FK: the seat must be in the SAME hospital as the chart.
    portal_member_id    uuid              NULL,

    created_by          uuid              NULL REFERENCES public.app_user (id)
                                          ON UPDATE CASCADE ON DELETE SET NULL,
    created_at          timestamptz       NOT NULL DEFAULT now(),
    updated_at          timestamptz       NOT NULL DEFAULT now(),

    CONSTRAINT patient_mrn_ck   CHECK (btrim(mrn) <> ''),
    CONSTRAINT patient_name_ck  CHECK (btrim(first_name) <> '' AND btrim(last_name) <> ''),
    CONSTRAINT patient_dob_ck   CHECK (date_of_birth > date '1875-01-01'
                                       AND date_of_birth <= current_date),
    CONSTRAINT patient_email_ck CHECK (email IS NULL OR email LIKE '%_@_%'),
    CONSTRAINT patient_merge_ck CHECK ((status = 'merged') = (merged_into_patient_id IS NOT NULL)),
    CONSTRAINT patient_no_self_merge_ck CHECK (merged_into_patient_id IS DISTINCT FROM id),
    CONSTRAINT patient_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT patient_merge_fk
      FOREIGN KEY (merged_into_patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT patient_portal_member_fk
      FOREIGN KEY (portal_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS patient_mrn_uk
  ON public.patient (organization_id, upper(mrn));
CREATE UNIQUE INDEX IF NOT EXISTS patient_portal_member_uk
  ON public.patient (portal_member_id) WHERE portal_member_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS patient_org_name_ix
  ON public.patient (organization_id, lower(last_name), lower(first_name));
CREATE INDEX IF NOT EXISTS patient_org_dob_ix
  ON public.patient (organization_id, date_of_birth);

COMMENT ON TABLE public.patient IS
  'The patient identity record, scoped to one hospital. Created in 010 because the tenant '
  'boundary and the portal link are identity concerns; later migrations MUST NOT redefine it. '
  'Two hospitals treating the same human hold two unrelated rows, by design.';
COMMENT ON COLUMN public.patient.portal_member_id IS
  'The person''s seat in this hospital, when they have a portal login. Access is granted only '
  'if that seat also carries the ''patient'' role (app.current_patient_id()), so a mislinked '
  'row fails closed rather than opening a chart.';

DROP TRIGGER IF EXISTS t_touch ON public.patient;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.patient
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.patient;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.patient
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 7 — VENDOR CONTAINMENT: SUPPORT SESSIONS
--
-- THE POSITION, ARGUED
--   The vendor should NOT be able to read patient clinical data. Not "should not by policy" —
--   should not be able to, by construction. Three reasons:
--     1. Nobody consented to it. A patient's relationship is with the hospital. The hospital
--        is the data fiduciary; we are a processor acting on its instructions. Standing
--        vendor read access to charts is a relationship the patient never entered.
--     2. It is the fattest possible target. One compromised vendor account with cross-tenant
--        clinical read is every patient in every hospital. No support workflow is worth that
--        blast radius, and the workflows people cite (billing questions, seat counts, "the
--        dashboard is slow") need operational metadata, not charts.
--     3. Break-fix genuinely needs data access sometimes — but it needs it for a named tenant,
--        for hours, with the customer's knowledge. That is a session, not a role.
--
--   IMPLEMENTATION: app.current_org_id() is derived ONLY from membership. A platform admin has
--   no membership, so it returns NULL for them, so every tenant-scoped policy written to the
--   house rule (`organization_id = app.current_org_id()`) yields zero rows. Vendor containment
--   is therefore the DEFAULT, and it holds even if a later migration's author never thinks
--   about super_admin at all. The only way to break it is to deliberately add
--   `OR app.is_super_admin()` to a clinical policy — which §12 makes greppable and testable.
--
--   Vendor reach is therefore granted explicitly, surface by surface, in three tiers (§10):
--     * always            — commercial metadata: organization, plans, entitlements, and the
--                           support-session log itself. No personal data in any of it.
--     * open session      — personal data belonging to the customer: app_user and the staff
--                           directory, reached through app.support_org_id(), one named tenant
--                           at a time, expiring, and visible to that tenant.
--     * approved session  — clinical data. NO policy in this file or any later one grants it.
--                           app.has_phi_support_access() exists for a break-fix that genuinely
--                           needs it, and requires the customer's own hospital_admin to say yes.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.support_session (
    id                 uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid              NOT NULL REFERENCES public.organization (id)
                                         ON UPDATE CASCADE ON DELETE RESTRICT,
    platform_admin_id  uuid              NOT NULL REFERENCES public.platform_admin (id)
                                         ON UPDATE CASCADE ON DELETE RESTRICT,

    scope              app.support_scope NOT NULL DEFAULT 'operational',
    reason             text              NOT NULL,
    ticket_ref         text              NULL,

    -- 'phi' scope is worthless without the customer's own consent, so it is a hard gate:
    -- a hospital_admin OF THAT HOSPITAL must approve before the session grants anything.
    approved_by_member_id uuid           NULL,
    approved_at        timestamptz       NULL,

    started_at         timestamptz       NOT NULL DEFAULT now(),
    expires_at         timestamptz       NOT NULL DEFAULT (now() + interval '4 hours'),
    revoked_at         timestamptz       NULL,
    created_at         timestamptz       NOT NULL DEFAULT now(),

    CONSTRAINT support_session_reason_ck   CHECK (length(btrim(reason)) >= 20),
    CONSTRAINT support_session_window_ck   CHECK (expires_at > started_at),
    -- Hard ceiling. A forgotten session must not become standing access.
    CONSTRAINT support_session_ceiling_ck  CHECK (expires_at <= started_at + interval '8 hours'),
    CONSTRAINT support_session_approval_ck CHECK ((approved_at IS NULL) = (approved_by_member_id IS NULL)),
    CONSTRAINT support_session_phi_ck      CHECK (scope <> 'phi' OR ticket_ref IS NOT NULL),
    CONSTRAINT support_session_approver_fk
      FOREIGN KEY (approved_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS support_session_live_ix
  ON public.support_session (platform_admin_id, organization_id, expires_at)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS support_session_org_ix
  ON public.support_session (organization_id, started_at DESC);

COMMENT ON TABLE public.support_session IS
  'Time-boxed, reason-bearing, customer-visible vendor access to ONE tenant. operational scope '
  'is self-service for the vendor; phi scope additionally requires a hospital_admin of that '
  'tenant to approve, and expires within 8 hours whatever happens. Customers can read their '
  'own rows — knowing when the vendor looked is part of the deal.';

DROP TRIGGER IF EXISTS t_no_delete ON public.support_session;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.support_session
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 8 — THE SESSION HELPER API
--
-- 8.1 WHY THESE ARE SHAPED THE WAY THEY ARE
--   Every function below is:
--     * STABLE and argument-free (except the two that must take an org id). Postgres folds a
--       no-argument STABLE function in a policy into an InitPlan: it runs ONCE PER STATEMENT,
--       not once per row. Listing 42 patients costs one index probe, not 42.
--     * SECURITY DEFINER where it reads organization_member / platform_admin / patient.
--       Genuinely required: those tables have RLS, and their own policies call these very
--       functions. Without DEFINER the evaluation recurses. See 8.5 for why this is not an
--       escalation path.
--     * search_path-pinned to `pg_catalog, pg_temp` with every object fully qualified. A
--       SECURITY DEFINER function with a mutable search_path is a privilege-escalation bug.
--   DO NOT `ALTER TABLE ... FORCE ROW LEVEL SECURITY` on organization_member, app_user,
--   platform_admin or patient. FORCE subjects the table owner to RLS too, and since these
--   functions are DEFINER-owned by that same owner, the policies would start calling the
--   functions that are reading the table: infinite recursion, and every policy fails closed
--   at the worst possible moment. Ordinary ENABLE (used below) is what makes this work.
--
-- 8.2 THE JWT TRADE-OFF, STATED PLAINLY
--   The fast, common design is to stuff role and org into a JWT claim and read the claim in
--   every policy — zero table access. We do not, quite:
--     * we trust the JWT for IDENTITY (`sub`). It is signature-verified and identity does not
--       change mid-session, so there is no staleness risk worth naming.
--     * we trust the JWT only as a HINT for WHICH ORG the client wants (app.jwt_org_id()).
--     * we NEVER trust it for what the caller may do. Roles, membership status and tenant
--       status are read from tables and re-validated on every statement.
--   The risk we are buying out is staleness: a Supabase access token lives up to an hour, so
--   a claims-only design keeps a fired doctor, a revoked seat or a suspended (non-paying)
--   tenant working until the token expires. For a system holding health records that is not
--   an acceptable window, and "sign them out everywhere" is not reliably available.
--   The price is one index-only probe of organization_member_session_ix per statement. That
--   is microseconds, and it is the difference between revocation taking effect on the next
--   statement and taking effect in up to an hour. Measured, not assumed: if it ever shows up
--   in a profile, the fix is a shorter token TTL plus claims — not silently trusting claims.
--   If you DO move roles into claims later, you must also shorten the token TTL and add a
--   per-user "claims valid from" watermark; do not do the first without the second.
--
-- 8.3 WHAT NULL MEANS
--   current_org_id() returning NULL means "this session has no tenant context": an anonymous
--   caller, a revoked seat, a suspended tenant, a vendor admin, or a multi-hospital user who
--   has not chosen. Since `organization_id = NULL` is never true, every tenant policy denies.
--   Fail-closed is the default in all five cases.
-- =============================================================================================

-- ---- 8.4 identity ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.current_user_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT u.id FROM public.app_user u
   WHERE u.auth_user_id = app.current_auth_uid() AND u.status = 'active';
$$;

CREATE OR REPLACE FUNCTION app.is_super_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admin pa
     JOIN public.app_user u ON u.id = pa.app_user_id AND u.status = 'active'
     WHERE pa.auth_user_id = app.current_auth_uid() AND pa.revoked_at IS NULL);
$$;

-- The organisation the client asked for: JWT claim first, stored preference second. A HINT.
-- It confers nothing on its own — current_org_id() only echoes it back if live membership
-- and a live tenant agree.
CREATE OR REPLACE FUNCTION app.requested_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(
           app.jwt_org_id(),
           (SELECT u.active_organization_id FROM public.app_user u
             WHERE u.auth_user_id = app.current_auth_uid() AND u.status = 'active'));
$$;

-- ---- 8.5 THE HINGE --------------------------------------------------------------------------
--
-- WHY SECURITY DEFINER HERE IS NOT AN ESCALATION PATH
--   1. It takes no arguments. There is no input a caller can bend; the answer is derived
--      entirely from app.current_auth_uid(), which comes from a signature-verified JWT.
--   2. It returns a single uuid — never a row of anyone's data — and only ever the caller's
--      own organisation. A caller who lies about `sub` cannot: they would have to forge the
--      JWT signature, which is the host's problem and not one DEFINER makes worse.
--   3. No dynamic SQL, so no injection surface; search_path is pinned so no shadowing of
--      `public.organization_member` by a temp table or a schema the caller can create in.
--   4. It is elevated only to escape the RLS-recursion trap on organization_member, which is
--      a mechanical need, not a privilege need.
CREATE OR REPLACE FUNCTION app.current_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  WITH live AS (
    SELECT m.organization_id
      FROM public.organization_member m
      JOIN public.organization o ON o.id = m.organization_id
     WHERE m.auth_user_id = app.current_auth_uid()
       AND m.status = 'active'
       AND o.status IN ('trial', 'active')
  )
  SELECT CASE
    WHEN app.requested_org_id() IS NOT NULL
      -- Asked for a specific tenant: honour it only if the seat and the tenant are live.
      THEN (SELECT l.organization_id FROM live l
             WHERE l.organization_id = app.requested_org_id())
    -- Asked for nothing: one membership is unambiguous, more than one is not. Refusing to
    -- guess is the safe answer — the app calls app.set_active_organization() to choose.
    ELSE (SELECT l.organization_id FROM live l
           WHERE (SELECT count(*) FROM live) = 1 LIMIT 1)
  END;
$$;

COMMENT ON FUNCTION app.current_org_id() IS
  'The caller''s active organisation, or NULL. THE tenant-isolation primitive: every policy '
  'on tenant data starts `organization_id = app.current_org_id()`. Returns NULL for vendor '
  'admins (they hold no membership), which is what contains super_admin by default.';

CREATE OR REPLACE FUNCTION app.current_member_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT m.id FROM public.organization_member m
   WHERE m.auth_user_id = app.current_auth_uid()
     AND m.organization_id = app.current_org_id()
     AND m.status = 'active';
$$;

COMMENT ON FUNCTION app.current_member_id() IS
  'The caller''s seat id in the active organisation — i.e. "staff_id" for later migrations '
  '(care team membership, order/note authorship, appointment provider).';

CREATE OR REPLACE FUNCTION app.current_roles()
RETURNS app.org_role[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT m.roles FROM public.organization_member m
   WHERE m.auth_user_id = app.current_auth_uid()
     AND m.organization_id = app.current_org_id()
     AND m.status = 'active';
$$;

-- ---- 8.6 role predicates --------------------------------------------------------------------
-- All plain STABLE (no DEFINER needed — they only call functions that already are).

CREATE OR REPLACE FUNCTION app.has_role(p_role app.org_role)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT coalesce(p_role = ANY (app.current_roles()), false) $$;

CREATE OR REPLACE FUNCTION app.is_hospital_admin()
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$ SELECT app.has_role('hospital_admin') $$;

CREATE OR REPLACE FUNCTION app.is_clinician()
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$ SELECT app.has_role('doctor') OR app.has_role('nurse') $$;

CREATE OR REPLACE FUNCTION app.is_front_desk()
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$ SELECT app.has_role('receptionist') $$;

CREATE OR REPLACE FUNCTION app.is_patient()
RETURNS boolean LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp
AS $$ SELECT app.has_role('patient') $$;

-- "Works here in a non-patient capacity". NOT a clinical grant: hospital_admin is staff and
-- still has no route to a chart.
CREATE OR REPLACE FUNCTION app.is_staff()
RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  -- coalesce because `NULL && anything` is NULL, and a helper that returns NULL turns any
  -- `NOT app.is_staff()` written downstream into "unknown", which is not what the author meant.
  SELECT coalesce(
    app.current_roles() && ARRAY['hospital_admin','doctor','nurse','receptionist']::app.org_role[],
    false);
$$;

COMMENT ON FUNCTION app.is_staff() IS
  'Any non-patient seat in the active organisation. Use for directory and operational data. '
  'Do NOT use it as the gate on clinical rows — hospital_admin is staff and has no treatment '
  'purpose. Clinical policies use app.is_clinician() plus per-patient scope from 020.';

-- The caller's own chart in the active organisation, or NULL. Requires the seat to actually
-- carry the patient role, so a mislinked portal_member_id grants nothing.
CREATE OR REPLACE FUNCTION app.current_patient_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT p.id
    FROM public.patient p
    JOIN public.organization_member m ON m.id = p.portal_member_id
   WHERE p.organization_id = app.current_org_id()
     AND m.auth_user_id = app.current_auth_uid()
     AND m.status = 'active'
     AND 'patient'::app.org_role = ANY (m.roles)
     AND p.status <> 'merged';
$$;

-- ---- 8.7 vendor reach -----------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.current_support_session_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT s.id
    FROM public.support_session s
    JOIN public.platform_admin pa ON pa.id = s.platform_admin_id AND pa.revoked_at IS NULL
   WHERE pa.auth_user_id = app.current_auth_uid()
     AND s.revoked_at IS NULL
     AND s.expires_at > now()
   ORDER BY s.started_at DESC
   LIMIT 1;
$$;

-- Operational reach into ONE tenant (support queues, configuration, seat counts). Never a
-- clinical grant.
CREATE OR REPLACE FUNCTION app.support_org_id()
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT s.organization_id
    FROM public.support_session s
    JOIN public.platform_admin pa ON pa.id = s.platform_admin_id AND pa.revoked_at IS NULL
   WHERE pa.auth_user_id = app.current_auth_uid()
     AND s.revoked_at IS NULL
     AND s.expires_at > now()
   ORDER BY s.started_at DESC
   LIMIT 1;
$$;

-- The ONLY sanctioned way a vendor admin can reach clinical rows, and only if a hospital_admin
-- of that tenant approved a phi-scoped session that has not expired. Later migrations should
-- normally NOT use it. If you do, put it in its own separately-named policy so it shows up in
-- app.v_super_admin_policy_review, and expect 040 to log every read it enables.
CREATE OR REPLACE FUNCTION app.has_phi_support_access(p_organization_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
      FROM public.support_session s
      JOIN public.platform_admin pa ON pa.id = s.platform_admin_id AND pa.revoked_at IS NULL
     WHERE pa.auth_user_id = app.current_auth_uid()
       AND s.organization_id = p_organization_id
       AND s.scope = 'phi'
       AND s.approved_at IS NOT NULL
       AND s.revoked_at IS NULL
       AND s.expires_at > now());
$$;

-- ---- 8.8 entitlements -----------------------------------------------------------------------
-- Override (within its window) beats plan default; absent means off. Not for use in a policy
-- on a large table — gate features in the app or in an RPC, not per row.

CREATE OR REPLACE FUNCTION app.org_has_feature(p_organization_id uuid, p_feature_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(
    (SELECT e.enabled FROM public.organization_entitlement e
      WHERE e.organization_id = p_organization_id
        AND e.feature_key = p_feature_key
        AND e.effective_from <= now()
        AND (e.effective_to IS NULL OR e.effective_to > now())),
    (SELECT pf.enabled FROM public.organization o
       JOIN public.plan_feature pf ON pf.plan_id = o.plan_id
      WHERE o.id = p_organization_id AND pf.feature_key = p_feature_key),
    false);
$$;

CREATE OR REPLACE FUNCTION app.has_feature(p_feature_key text)
RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT app.org_has_feature(app.current_org_id(), p_feature_key) $$;

CREATE OR REPLACE FUNCTION app.feature_limit(p_feature_key text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(
    (SELECT e.limit_value FROM public.organization_entitlement e
      WHERE e.organization_id = app.current_org_id()
        AND e.feature_key = p_feature_key
        AND e.enabled
        AND e.effective_from <= now()
        AND (e.effective_to IS NULL OR e.effective_to > now())),
    (SELECT pf.limit_value FROM public.organization o
       JOIN public.plan_feature pf ON pf.plan_id = o.plan_id
      WHERE o.id = app.current_org_id() AND pf.feature_key = p_feature_key AND pf.enabled));
$$;

CREATE OR REPLACE VIEW app.v_effective_entitlement
WITH (security_invoker = true) AS
SELECT o.id            AS organization_id,
       o.slug,
       f.key            AS feature_key,
       f.kind,
       app.org_has_feature(o.id, f.key) AS enabled,
       e.effective_to   AS override_expires_at,
       (e.organization_id IS NOT NULL)  AS is_override
  FROM public.organization o
 CROSS JOIN public.feature f
  LEFT JOIN public.organization_entitlement e
         ON e.organization_id = o.id AND e.feature_key = f.key;

COMMENT ON VIEW app.v_effective_entitlement IS
  'Resolved entitlements for the Super Admin surface. security_invoker so the underlying RLS '
  'still applies — a hospital_admin sees only their own tenant through it.';


-- =============================================================================================
-- SECTION 9 — RPCs
-- =============================================================================================

-- Switch the active organisation. Validates membership, so calling it with someone else's
-- org id is a no-op that raises, not a way in.
CREATE OR REPLACE FUNCTION app.set_active_organization(p_organization_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_user uuid := app.current_user_id();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING errcode = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.organization_member m
      JOIN public.organization o ON o.id = m.organization_id
     WHERE m.app_user_id = v_user
       AND m.organization_id = p_organization_id
       AND m.status = 'active'
       AND o.status IN ('trial', 'active')) THEN
    RAISE EXCEPTION 'No active seat in that organisation.' USING errcode = '42501';
  END IF;

  UPDATE public.app_user SET active_organization_id = p_organization_id WHERE id = v_user;
  RETURN p_organization_id;
END;
$$;

CREATE OR REPLACE FUNCTION app.open_support_session(
    p_organization_id uuid,
    p_reason          text,
    p_scope           app.support_scope DEFAULT 'operational',
    p_ticket_ref      text DEFAULT NULL,
    p_minutes         integer DEFAULT 120)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_admin uuid;
  v_id    uuid;
BEGIN
  SELECT pa.id INTO v_admin FROM public.platform_admin pa
   WHERE pa.auth_user_id = app.current_auth_uid() AND pa.revoked_at IS NULL;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'Only platform administrators open support sessions.' USING errcode = '42501';
  END IF;
  IF p_minutes IS NULL OR p_minutes < 15 OR p_minutes > 480 THEN
    RAISE EXCEPTION 'Support sessions run between 15 and 480 minutes.' USING errcode = '22023';
  END IF;

  INSERT INTO public.support_session
      (organization_id, platform_admin_id, scope, reason, ticket_ref, expires_at)
  VALUES
      (p_organization_id, v_admin, p_scope, p_reason, p_ticket_ref,
       now() + make_interval(mins => p_minutes))
  RETURNING id INTO v_id;

  -- Loud on purpose: this reaches the server log as well as 040's audit trail, so it can page
  -- somebody without anyone remembering to poll a view. A phi-scoped session grants nothing
  -- until a hospital_admin of that tenant approves it.
  RAISE WARNING 'SUPPORT SESSION opened: admin=% org=% scope=% minutes=%',
                v_admin, p_organization_id, p_scope, p_minutes;
  RETURN v_id;
END;
$$;

-- Customer-side consent for phi scope. Only a hospital_admin of the target tenant can call it.
CREATE OR REPLACE FUNCTION app.approve_support_session(p_session_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_member uuid := app.current_member_id();
BEGIN
  IF v_member IS NULL OR NOT app.is_hospital_admin() THEN
    RAISE EXCEPTION 'Only a hospital administrator of the tenant may approve vendor access.'
      USING errcode = '42501';
  END IF;

  UPDATE public.support_session
     SET approved_by_member_id = v_member, approved_at = now()
   WHERE id = p_session_id
     AND organization_id = app.current_org_id()
     AND approved_at IS NULL
     AND revoked_at IS NULL
     AND expires_at > now();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No approvable support session % in your organisation.', p_session_id
      USING errcode = '42501';
  END IF;
END;
$$;

-- Either side can end it early: the vendor when finished, the customer at any time.
CREATE OR REPLACE FUNCTION app.close_support_session(p_session_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  UPDATE public.support_session s
     SET revoked_at = now()
   WHERE s.id = p_session_id
     AND s.revoked_at IS NULL
     AND ((s.organization_id = app.current_org_id() AND app.is_hospital_admin())
          OR EXISTS (SELECT 1 FROM public.platform_admin pa
                      WHERE pa.id = s.platform_admin_id
                        AND pa.auth_user_id = app.current_auth_uid()
                        AND pa.revoked_at IS NULL));
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No open support session % that you may close.', p_session_id
      USING errcode = '42501';
  END IF;
END;
$$;


-- =============================================================================================
-- SECTION 10 — ROW LEVEL SECURITY
--
-- Read every policy as: tenant first, then role, then row. No table below grants a vendor
-- admin anything clinical; public.patient does not mention is_super_admin() at all.
-- =============================================================================================

ALTER TABLE public.organization             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_plan        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.feature                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.plan_feature             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_entitlement ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_user                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_member      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.platform_admin           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_session          ENABLE ROW LEVEL SECURITY;

-- ---- organization ---------------------------------------------------------------------------
DROP POLICY IF EXISTS organization_select ON public.organization;
CREATE POLICY organization_select ON public.organization FOR SELECT
  USING (id = app.current_org_id() OR app.is_super_admin());

-- Tenants are created and re-planned by the vendor. A hospital_admin may edit presentation
-- fields only; the trigger below enforces which columns, because RLS cannot.
DROP POLICY IF EXISTS organization_insert_vendor ON public.organization;
CREATE POLICY organization_insert_vendor ON public.organization FOR INSERT
  WITH CHECK (app.is_super_admin());

DROP POLICY IF EXISTS organization_update ON public.organization;
CREATE POLICY organization_update ON public.organization FOR UPDATE
  USING (app.is_super_admin() OR (id = app.current_org_id() AND app.is_hospital_admin()))
  WITH CHECK (app.is_super_admin() OR (id = app.current_org_id() AND app.is_hospital_admin()));

CREATE OR REPLACE FUNCTION app.guard_organization_update()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF app.is_super_admin() THEN
    RETURN NEW;
  END IF;
  -- Commercial and identity columns are vendor-owned. A customer editing their own plan or
  -- lifting their own suspension is the obvious attack on a SaaS billing model.
  IF NEW.slug     IS DISTINCT FROM OLD.slug
     OR NEW.status   IS DISTINCT FROM OLD.status
     OR NEW.plan_id  IS DISTINCT FROM OLD.plan_id
     OR NEW.region   IS DISTINCT FROM OLD.region
     OR NEW.trial_ends_at   IS DISTINCT FROM OLD.trial_ends_at
     OR NEW.suspended_at    IS DISTINCT FROM OLD.suspended_at
     OR NEW.plan_started_at IS DISTINCT FROM OLD.plan_started_at THEN
    RAISE EXCEPTION 'Only the vendor may change plan, status, slug or region.'
      USING errcode = '42501';
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS t_guard_update ON public.organization;
CREATE TRIGGER t_guard_update BEFORE UPDATE ON public.organization
  FOR EACH ROW EXECUTE FUNCTION app.guard_organization_update();

-- ---- plan catalogue (not tenant data: readable by any signed-in user) -----------------------
DROP POLICY IF EXISTS subscription_plan_select ON public.subscription_plan;
CREATE POLICY subscription_plan_select ON public.subscription_plan FOR SELECT
  USING (app.current_user_id() IS NOT NULL);
DROP POLICY IF EXISTS subscription_plan_write ON public.subscription_plan;
CREATE POLICY subscription_plan_write ON public.subscription_plan FOR ALL
  USING (app.is_super_admin()) WITH CHECK (app.is_super_admin());

DROP POLICY IF EXISTS feature_select ON public.feature;
CREATE POLICY feature_select ON public.feature FOR SELECT
  USING (app.current_user_id() IS NOT NULL);
DROP POLICY IF EXISTS feature_write ON public.feature;
CREATE POLICY feature_write ON public.feature FOR ALL
  USING (app.is_super_admin()) WITH CHECK (app.is_super_admin());

DROP POLICY IF EXISTS plan_feature_select ON public.plan_feature;
CREATE POLICY plan_feature_select ON public.plan_feature FOR SELECT
  USING (app.current_user_id() IS NOT NULL);
DROP POLICY IF EXISTS plan_feature_write ON public.plan_feature;
CREATE POLICY plan_feature_write ON public.plan_feature FOR ALL
  USING (app.is_super_admin()) WITH CHECK (app.is_super_admin());

-- ---- entitlements: read your own, write is vendor-only --------------------------------------
DROP POLICY IF EXISTS organization_entitlement_select ON public.organization_entitlement;
CREATE POLICY organization_entitlement_select ON public.organization_entitlement FOR SELECT
  USING (organization_id = app.current_org_id() OR app.is_super_admin());
DROP POLICY IF EXISTS organization_entitlement_write ON public.organization_entitlement;
CREATE POLICY organization_entitlement_write ON public.organization_entitlement FOR ALL
  USING (app.is_super_admin()) WITH CHECK (app.is_super_admin());

-- ---- app_user: yourself, or someone who shares your current tenant --------------------------
-- Scoped through membership rather than left open to `authenticated`, because app_user is the
-- one table that is not tenant-scoped — an open policy here would let one hospital enumerate
-- another's users.
-- Note what is NOT here: a bare app.is_super_admin(). Names and email addresses are personal
-- data belonging to the customer, so the vendor reaches them only through an open support
-- session (app.support_org_id()). Tenant onboarding, which needs to write a first admin before
-- any session exists, runs as service_role from a runbook — not from the web session.
DROP POLICY IF EXISTS app_user_select ON public.app_user;
CREATE POLICY app_user_select ON public.app_user FOR SELECT
  USING (
    id = app.current_user_id()
    OR EXISTS (SELECT 1 FROM public.organization_member m
                WHERE m.app_user_id = app_user.id
                  AND m.status = 'active'
                  AND m.organization_id IN (app.current_org_id(), app.support_org_id()))
  );

DROP POLICY IF EXISTS app_user_update_self ON public.app_user;
CREATE POLICY app_user_update_self ON public.app_user FOR UPDATE
  USING (id = app.current_user_id()) WITH CHECK (id = app.current_user_id());

DROP POLICY IF EXISTS app_user_admin_write ON public.app_user;
CREATE POLICY app_user_admin_write ON public.app_user FOR INSERT
  WITH CHECK (app.is_super_admin() OR app.is_hospital_admin());

-- ---- organization_member --------------------------------------------------------------------
-- Staff see colleagues (provider pickers, care-team cards). Patients see staff, and only
-- their own seat among patient rows — a patient must never enumerate other patients.
-- The vendor clause is app.support_org_id(), NOT is_super_admin(): reading a customer's staff
-- directory is support work on one named tenant, time-boxed and visible to that customer.
DROP POLICY IF EXISTS organization_member_select ON public.organization_member;
CREATE POLICY organization_member_select ON public.organization_member FOR SELECT
  USING (
    (organization_id = app.current_org_id()
       AND (app.is_staff()
            OR app_user_id = app.current_user_id()
            OR NOT ('patient'::app.org_role = ANY (roles))))
    OR organization_id = app.support_org_id()
  );

DROP POLICY IF EXISTS organization_member_write ON public.organization_member;
CREATE POLICY organization_member_write ON public.organization_member FOR INSERT
  WITH CHECK (
    (organization_id = app.current_org_id() AND app.is_hospital_admin())
    OR app.is_super_admin()
  );

DROP POLICY IF EXISTS organization_member_update ON public.organization_member;
CREATE POLICY organization_member_update ON public.organization_member FOR UPDATE
  USING (
    (organization_id = app.current_org_id()
      AND (app.is_hospital_admin() OR app_user_id = app.current_user_id()))
    OR app.is_super_admin()
  )
  WITH CHECK (
    (organization_id = app.current_org_id()
      AND (app.is_hospital_admin() OR app_user_id = app.current_user_id()))
    OR app.is_super_admin()
  );
-- Self-update is for job_title and the like; app.sync_member_identity() blocks self-edits of
-- roles and status, so this is not a self-promotion route.

-- ---- platform_admin: vendor-visible, written only out of band --------------------------------
DROP POLICY IF EXISTS platform_admin_select ON public.platform_admin;
CREATE POLICY platform_admin_select ON public.platform_admin FOR SELECT
  USING (app.is_super_admin());
-- Deliberately no INSERT/UPDATE policy: minting a vendor admin requires service_role.

-- ---- patient: tenant + care-staff, or the patient themselves ---------------------------------
-- No is_super_admin() here, and none anywhere in a later clinical migration. hospital_admin is
-- absent too: administering a hospital is not a treatment purpose.
DROP POLICY IF EXISTS patient_select ON public.patient;
CREATE POLICY patient_select ON public.patient FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND (app.is_clinician() OR app.is_front_desk() OR id = app.current_patient_id())
  );

DROP POLICY IF EXISTS patient_insert ON public.patient;
CREATE POLICY patient_insert ON public.patient FOR INSERT
  WITH CHECK (
    organization_id = app.current_org_id()
    AND (app.is_front_desk() OR app.is_clinician())
  );

DROP POLICY IF EXISTS patient_update ON public.patient;
CREATE POLICY patient_update ON public.patient FOR UPDATE
  USING (
    organization_id = app.current_org_id()
    AND (app.is_front_desk() OR app.is_clinician() OR id = app.current_patient_id())
  )
  WITH CHECK (organization_id = app.current_org_id());
-- No DELETE policy, and app.deny_hard_delete() on top of it.

-- ---- support_session: the customer can see who looked ---------------------------------------
DROP POLICY IF EXISTS support_session_select ON public.support_session;
CREATE POLICY support_session_select ON public.support_session FOR SELECT
  USING (
    (organization_id = app.current_org_id() AND app.is_hospital_admin())
    OR app.is_super_admin()
  );
-- Writes go through the RPCs in §9 only.


-- =============================================================================================
-- SECTION 11 — GRANTS
-- >>> BEGIN SUPABASE-SPECIFIC: role names are the PostgREST convention <<<
-- =============================================================================================

DO $grants$
BEGIN
  -- Postgres grants EXECUTE on every new function to PUBLIC. Take it back first, then hand it
  -- out deliberately: these functions ARE the security model.
  EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA app TO authenticated';

    EXECUTE 'GRANT SELECT ON public.organization, public.subscription_plan, public.feature,
                              public.plan_feature, public.organization_entitlement,
                              public.platform_admin, public.support_session
             TO authenticated';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON public.app_user, public.organization_member,
                                             public.patient TO authenticated';

    -- Read-only helpers the policies themselves evaluate.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.current_auth_uid(), app.jwt_org_id(), app.current_user_id(),
               app.requested_org_id(), app.current_org_id(), app.current_member_id(),
               app.current_roles(), app.has_role(app.org_role), app.is_staff(),
               app.is_clinician(), app.is_front_desk(), app.is_patient(),
               app.is_hospital_admin(), app.is_super_admin(), app.current_patient_id(),
               app.support_org_id(), app.current_support_session_id(),
               app.has_phi_support_access(uuid), app.has_feature(text),
               app.org_has_feature(uuid, text), app.feature_limit(text),
               app.storage_prefix(uuid), app.storage_key_belongs_to(text, uuid)
             TO authenticated';

    -- Trigger and constraint helpers. Postgres checks EXECUTE on a trigger function when the
    -- trigger is created rather than when it fires, so this is belt-and-braces — but
    -- storage_key_belongs_to() really is evaluated inside a CHECK on the caller's INSERT.
    -- Calling any of the trigger functions directly just raises.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.touch_updated_at(), app.deny_hard_delete(), app.sync_member_identity(),
               app.guard_app_user_update(), app.guard_organization_update()
             TO authenticated';

    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.set_active_organization(uuid),
               app.open_support_session(uuid, text, app.support_scope, text, integer),
               app.approve_support_session(uuid), app.close_support_session(uuid)
             TO authenticated';

    EXECUTE 'GRANT SELECT ON app.v_effective_entitlement TO authenticated';
  END IF;

  -- Trusted server-side workers (tenant provisioning, retention jobs). They already hold
  -- BYPASSRLS; they still need EXECUTE to call the RPCs.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA app TO service_role';
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO service_role';
  END IF;

  -- Anonymous callers get nothing at all. The login screen talks to GoTrue, not to these
  -- tables.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon';
    EXECUTE 'REVOKE ALL ON SCHEMA app FROM anon';
  END IF;
END
$grants$;
-- >>> END SUPABASE-SPECIFIC <<< --------------------------------------------------------------


-- =============================================================================================
-- SECTION 12 — REVIEW AIDS (run these in CI; they are the cheapest audit you will ever get)
-- =============================================================================================

-- Tables that carry organization_id and forgot to switch RLS on. Should always be empty.
CREATE OR REPLACE VIEW app.v_tenant_rls_gaps AS
SELECT n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid
 WHERE n.nspname = 'public'
   AND c.relkind = 'r'
   AND a.attname = 'organization_id'
   AND a.attnum > 0 AND NOT a.attisdropped
   AND NOT c.relrowsecurity;

-- Every policy that reaches across the tenant boundary. This list should be short, and every
-- entry on it should be a deliberate decision someone can name.
CREATE OR REPLACE VIEW app.v_super_admin_policy_review AS
SELECT schemaname, tablename, policyname, cmd,
       coalesce(qual, '') || ' / ' || coalesce(with_check, '') AS expression
  FROM pg_policies
 WHERE coalesce(qual, '') || coalesce(with_check, '') LIKE '%is_super_admin%'
    OR coalesce(qual, '') || coalesce(with_check, '') LIKE '%support_org_id%'
    OR coalesce(qual, '') || coalesce(with_check, '') LIKE '%has_phi_support_access%';

-- CI gate for later migrations: fails loudly if a clinical table ever grants the vendor
-- blanket access. Call it with the PHI tables 020/030 create, e.g.
--   SELECT app.assert_no_vendor_phi_policies(ARRAY['patient','encounter','lab_result']);
CREATE OR REPLACE FUNCTION app.assert_no_vendor_phi_policies(p_tables text[])
RETURNS void LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s.%s', p.tablename, p.policyname), ', ')
    INTO v_bad
    FROM pg_policies p
   WHERE p.schemaname = 'public'
     AND p.tablename = ANY (p_tables)
     AND coalesce(p.qual, '') || coalesce(p.with_check, '') LIKE '%is_super_admin%';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Vendor-wide access granted on clinical tables: %', v_bad
      USING errcode = '42501',
            hint = 'Use app.has_phi_support_access(organization_id) in a separate policy, or nothing at all.';
  END IF;
END;
$$;

-- Created after §11's blanket revoke, so it needs its own.
REVOKE EXECUTE ON FUNCTION app.assert_no_vendor_phi_policies(text[]) FROM PUBLIC;


-- =============================================================================================
-- SECTION 13 — SEED: plan catalogue and feature registry
-- Grounded in what the 20 screens actually gate. Idempotent.
-- =============================================================================================

INSERT INTO public.subscription_plan (code, name, description, sort_order) VALUES
  ('trial',        'Trial',        '30-day evaluation, one department.',            10),
  ('essentials',   'Essentials',   'Scheduling, front desk and patient records.',   20),
  ('clinical_ai',  'Clinical AI',  'Essentials plus AI risk flags and prognosis.',  30),
  ('enterprise',   'Enterprise',   'Clinical AI plus SSO, audit export and support SLA.', 40)
ON CONFLICT (code) DO NOTHING;

INSERT INTO public.feature (key, name, description, kind) VALUES
  ('patient_portal',  'Patient portal',      'Patient home, booking, results, messages, care plan.', 'flag'),
  ('ai_risk_flags',   'AI risk flags',       'Risk pills and the dashboard flag list.',              'flag'),
  ('ai_prognosis',    'AI prognosis report', 'Full prognosis report with contributing factors.',     'flag'),
  ('ai_assistant',    'AI assistant',        'Clinician chat assistant.',                            'flag'),
  ('billing',         'Billing',             'Invoices, denial risk and collections.',               'flag'),
  ('sso',             'SSO',                 'SAML / OIDC sign-in.',                                 'flag'),
  ('audit_export',    'Audit export',        'Export of the access audit trail.',                    'flag'),
  ('staff_seats',     'Staff seats',         'Maximum active non-patient seats.',                    'limit')
ON CONFLICT (key) DO NOTHING;

INSERT INTO public.plan_feature (plan_id, feature_key, enabled, limit_value)
SELECT p.id, v.feature_key, v.enabled, v.limit_value
  FROM public.subscription_plan p
  JOIN (VALUES
      ('trial',       'patient_portal', true,  NULL::integer),
      ('trial',       'ai_risk_flags',  true,  NULL),
      ('trial',       'ai_prognosis',   true,  NULL),
      ('trial',       'ai_assistant',   true,  NULL),
      ('trial',       'billing',        false, NULL),
      ('trial',       'sso',            false, NULL),
      ('trial',       'audit_export',   false, NULL),
      ('trial',       'staff_seats',    true,  10),
      ('essentials',  'patient_portal', true,  NULL),
      ('essentials',  'ai_risk_flags',  false, NULL),
      ('essentials',  'ai_prognosis',   false, NULL),
      ('essentials',  'ai_assistant',   false, NULL),
      ('essentials',  'billing',        true,  NULL),
      ('essentials',  'sso',            false, NULL),
      ('essentials',  'audit_export',   false, NULL),
      ('essentials',  'staff_seats',    true,  50),
      ('clinical_ai', 'patient_portal', true,  NULL),
      ('clinical_ai', 'ai_risk_flags',  true,  NULL),
      ('clinical_ai', 'ai_prognosis',   true,  NULL),
      ('clinical_ai', 'ai_assistant',   true,  NULL),
      ('clinical_ai', 'billing',        true,  NULL),
      ('clinical_ai', 'sso',            false, NULL),
      ('clinical_ai', 'audit_export',   true,  NULL),
      ('clinical_ai', 'staff_seats',    true,  250),
      ('enterprise',  'patient_portal', true,  NULL),
      ('enterprise',  'ai_risk_flags',  true,  NULL),
      ('enterprise',  'ai_prognosis',   true,  NULL),
      ('enterprise',  'ai_assistant',   true,  NULL),
      ('enterprise',  'billing',        true,  NULL),
      ('enterprise',  'sso',            true,  NULL),
      ('enterprise',  'audit_export',   true,  NULL),
      ('enterprise',  'staff_seats',    true,  NULL)
  ) AS v(plan_code, feature_key, enabled, limit_value) ON v.plan_code = p.code
ON CONFLICT (plan_id, feature_key) DO NOTHING;


-- =============================================================================================
-- OPEN QUESTIONS — decisions deferred, not overlooked
--
-- 1. MRN allocation. The app supplies mrn today. A per-tenant sequence would remove a race
--    at the front desk; it needs a format decision from the operator first.
-- 2. Patient merge is modelled (status + merged_into_patient_id) but the actual merge
--    procedure — which chart wins, what happens to the loser's clinical rows — belongs with
--    020, which owns those rows.
-- 3. Step-up authentication for platform admins (recent-MFA requirement before
--    open_support_session) cannot be expressed in the database; it needs an auth-hook claim.
--    Until it exists, a stolen vendor session can open an operational support session.
-- 4. Plan-change history is not kept here. If billing ever needs "what plan were they on in
--    March", 040's audit trail is the source; promote it to a table then, not before.
-- 5. Token TTL is a Supabase project setting, not schema. The staleness argument in §8.2
--    assumes it is set to the shortest value the project allows.
-- =============================================================================================
