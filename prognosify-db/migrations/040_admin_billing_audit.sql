-- =============================================================================================
-- 040_admin_billing_audit.sql — Prognosify admin, billing and audit layer
-- PostgreSQL 15+ / Supabase (ap-south-1). Idempotent: safe to re-run.
--
-- DEPENDS ON 010_tenancy_identity.sql. It owns organisations, membership, roles, the patient
-- identity root and the whole app.* helper API. Nothing here redefines any of that; every
-- policy below is built on app.current_org_id() and its siblings.
--
-- WHAT THIS FILE OWNS
--   ADMIN    (hospital_admin dashboard)  org_setting  (public.department is owned by 020; this
--                                        file extends it with daily_slot_capacity/sort_order and
--                                        adds the vendor-support read policy — see §2)
--   BILLING  (reception Billing screen)  payer, patient_coverage, invoice, invoice_line, payment
--   VENDOR   (super_admin dashboard)     usage_metric, organization_usage_daily, app.v_tenant_health
--   AUDIT    (everything)                schema `audit`: event (append-only), redacted_column
--
-- DEPENDS ON 020 AND 030 as well as 010, because §8 attaches the audit trigger to their tables
-- by name. Applying it earlier is not an error — audit.attach() skips a missing table with a
-- NOTICE — but it leaves clinical tables unaudited. Run the four files in numeric order.
--
-- THE ONE IDEA WORTH READING BEFORE THE SQL
--   The vendor dashboard is built entirely from COUNTS (§4). organization_usage_daily is the
--   only table here whose SELECT policy says `OR app.is_super_admin()`, and it can say that
--   safely because a count of patients is not a patient.
--
-- MONEY
--   Minor units in bigint (paise for INR), never float, with an explicit ISO-4217 currency on
--   every invoice. Default 'INR': the operator is in India. The mock UI prints '$' — that is a
--   design placeholder, not a decision, and it is flagged at the bottom of this file.
--
-- COMPLIANCE POSTURE — same as 010, deliberately modest and not legal advice. The operator is
--   in India, so the regime in view is the Digital Personal Data Protection Act, 2023, not
--   HIPAA. What follows is ordinary security engineering: tenant isolation, least privilege,
--   an append-only trail, and erasure that is possible but deliberate. Whether any of it
--   satisfies a specific DPDP obligation is a question for counsel.
-- =============================================================================================


-- =============================================================================================
-- SECTION 0 — PREFLIGHT
--
-- Two failures are worth catching here rather than in production. Both are cheap to test and
-- expensive to discover late.
-- =============================================================================================

DO $preflight$
BEGIN
  -- 1. 010 must have run. Checking one representative function is enough: if the helper API is
  --    present, so are the tables it reads, because 010 creates them in the same transaction.
  IF to_regprocedure('app.current_org_id()') IS NULL THEN
    RAISE EXCEPTION '040 requires 010_tenancy_identity.sql. Run it first.'
      USING errcode = '42P01';
  END IF;

  -- 2. The single-tenant drafts (001-004) must NOT be in the migration path. Their
  --    app.has_role(text) sits alongside 010's app.has_role(app.org_role) as an OVERLOAD,
  --    after which `app.has_role('doctor')` is ambiguous and every policy in this file and in
  --    010 fails to resolve at query time. This is the most likely way to break the build, so
  --    it fails loudly at migration time instead.
  IF to_regprocedure('app.has_role(text)') IS NOT NULL THEN
    RAISE EXCEPTION
      'app.has_role(text) exists — the single-tenant drafts 001-004 are still loaded. '
      'Remove them from the migration path; their overload makes every role check ambiguous.'
      USING errcode = '42723';
  END IF;

  -- 3. Same story for the drafts' audit schema, which used a different actor model
  --    (authz.app_role, no acting organisation) and would collide with audit.event below.
  IF to_regtype('audit.action') IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_attribute a
                  WHERE a.attrelid = to_regclass('audit.event')
                    AND a.attname = 'actor_role'
                    AND NOT a.attisdropped
                    AND format_type(a.atttypid, NULL) LIKE 'authz.%') THEN
    RAISE EXCEPTION
      'audit.event already exists in the pre-multi-tenancy shape (authz.app_role actor). '
      'Drop schema audit cascade, or run 040 on a clean database.'
      USING errcode = '42710';
  END IF;
END
$preflight$;


-- =============================================================================================
-- SECTION 1 — SCHEMAS AND CLOSED VALUE SETS
-- =============================================================================================

CREATE SCHEMA IF NOT EXISTS audit;

COMMENT ON SCHEMA audit IS
  'The append-only trail and the machinery that writes it. Separate from `app` because the '
  'privilege story is different: `app` is read by every policy, `audit` is written by triggers '
  'running as the table owner and read by almost nobody.';

DO $types$
BEGIN
  -- ---- billing -----------------------------------------------------------------------------
  -- The first four values are exactly the four statuses the Billing screen paints. The rest are
  -- the lifecycle states an invoice needs to exist at all; without them the screen's four
  -- become a dead end (nothing can ever be paid, corrected or cancelled).
  IF to_regtype('app.invoice_status') IS NULL THEN
    CREATE TYPE app.invoice_status AS ENUM (
      'copay_due',    -- patient owes a share now                    (screen: "Copay due")
      'auth_missing', -- payer wants prior authorisation we lack     (screen: "Auth missing")
      'covered',      -- payer settles it in full, patient owes 0    (screen: "Covered")
      'overdue',      -- past due_at and still unpaid                (screen: "21 days overdue")
      'draft',        -- being assembled at the desk; lines editable
      'paid',
      'written_off',
      'void'
    );
  END IF;

  IF to_regtype('app.payment_method') IS NULL THEN
    CREATE TYPE app.payment_method AS ENUM
      ('cash', 'card', 'upi', 'netbanking', 'cheque', 'insurance', 'adjustment');
  END IF;

  IF to_regtype('app.payer_kind') IS NULL THEN
    -- 'tpa' (third-party administrator) is how most Indian hospital insurance actually
    -- settles; 'self_pay' is a payer row so that an uninsured patient still has a coverage
    -- record and the billing screens have one code path instead of two.
    CREATE TYPE app.payer_kind AS ENUM
      ('insurer', 'tpa', 'government', 'corporate', 'self_pay');
  END IF;

  IF to_regtype('app.coverage_priority') IS NULL THEN
    CREATE TYPE app.coverage_priority AS ENUM ('primary', 'secondary', 'tertiary');
  END IF;

  -- ---- audit -------------------------------------------------------------------------------
  IF to_regtype('audit.action') IS NULL THEN
    CREATE TYPE audit.action AS ENUM (
      'insert', 'update', 'delete',       -- written by the row trigger, never by hand
      'read', 'export',                   -- app-reported only; see the honesty block in §5.1
      'login', 'login_failed', 'logout',
      'role_change', 'entitlement_change',
      'support_open', 'support_approve', 'support_close'
    );
  END IF;

  IF to_regtype('audit.severity') IS NULL THEN
    -- 'alert' is not decoration: audit.v_alerts is the feed a human is expected to read, and
    -- every vendor action that crosses a tenant boundary lands in it.
    CREATE TYPE audit.severity AS ENUM ('normal', 'sensitive', 'alert');
  END IF;

  IF to_regtype('audit.purpose') IS NULL THEN
    -- Why the actor says they touched the data. Only meaningful on app-reported reads, where
    -- it is the difference between "a doctor opened a chart" and "a doctor opened a chart they
    -- have no treatment relationship with".
    CREATE TYPE audit.purpose AS ENUM
      ('treatment', 'front_desk', 'billing', 'patient_self', 'admin', 'support', 'compliance');
  END IF;
END
$types$;


-- =============================================================================================
-- SECTION 2 — ADMIN: what the hospital_admin dashboard manages
--
-- The brief lists three things: staff, departments, org settings. Only two of them need new
-- tables.
--
--   STAFF is already modelled. organization_member IS the staff directory row (010 §5.2):
--   roles, status, job_title, license_number, and RLS that already lets a hospital_admin
--   insert and update seats in their own organisation. Re-modelling it here would create the
--   second source of truth that 010 spent a section arguing against. What was genuinely
--   missing is (a) which department someone works in — the doctor Settings screen has a
--   "Department" field and the front desk shows "Dr. Mehta · Clinic 2" — and (b) an enforced
--   seat limit, which is what the `staff_seats` entitlement is for. Both are added below
--   without touching 010's table definition.
--
--   ORG SETTINGS are half-modelled. organization.settings jsonb exists for open-ended tenant
--   preferences and 010's guard trigger already lets a hospital_admin write it. What it cannot
--   express is the PER-PERSON setting the Settings screen actually shows: three AI toggles
--   that belong to one doctor, not to the hospital. org_setting below carries both, in one
--   table, distinguished by whether member_id is null.
-- =============================================================================================

-- ---- department: OWNED BY 020, referenced here ------------------------------------------------
-- RESOLVED CROSS-FILE CONFLICT. An earlier pass created public.department in this file AND in
-- 020. Both used CREATE TABLE IF NOT EXISTS, so neither errored — 020 ran first, its definition
-- won, and this file's daily_slot_capacity and sort_order were silently discarded. A column that
-- disappears without a message is worse than a clash that stops the migration.
--
-- The table now lives in 020, for the reason that decides these questions: 020 has four foreign
-- keys pointing at it (staff_profile, encounter, appointment, lab_panel) and runs first, so it
-- cannot reference a table this file has not created yet. The two columns this file wanted are
-- folded into 020's definition. What stays here is what genuinely belongs to the admin layer:
-- the ALTER that back-fills those columns on a database migrated before this fix, and the
-- vendor-support read policy in §6.
DO $department_owner$
BEGIN
  IF to_regclass('public.department') IS NULL THEN
    RAISE EXCEPTION 'public.department is missing; 020_clinical.sql owns it and must run first.'
      USING errcode = '42P01';
  END IF;

  -- Additive and idempotent: no-ops against a database where 020 already carries them.
  ALTER TABLE public.department ADD COLUMN IF NOT EXISTS daily_slot_capacity integer NULL;
  ALTER TABLE public.department ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 100;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'department_capacity_ck') THEN
    ALTER TABLE public.department ADD CONSTRAINT department_capacity_ck
      CHECK (daily_slot_capacity IS NULL OR daily_slot_capacity > 0);
  END IF;
END
$department_owner$;

COMMENT ON COLUMN public.department.daily_slot_capacity IS
  'The denominator of the front desk''s "Clinic load today" card (Cardiology 85%, Radiology '
  '92%). The numerator is 020''s appointments, so the card is a join computed at read time, not '
  'a stored percentage that goes stale on the next booking.';

-- ---- staff_department: DELIBERATELY NOT CREATED ------------------------------------------------
-- An earlier pass had this file model "which departments a staff member works in" as a join
-- table, while 020 modelled the same fact as staff_profile.department_id. Two tables answering
-- "which department is Dr. Mehta in" is exactly the second source of truth 010 spends a section
-- arguing against, and the failure is not hypothetical: staff_department.is_primary and
-- staff_profile.department_id can disagree, and nothing in the schema would notice.
--
-- 020's staff_profile wins. It is keyed on organization_member.id, so "their department" has one
-- answer by construction rather than by a partial unique index, and it already carries the other
-- practice attributes the same screens need (specialty, default room, accepts_bookings).
--
-- WHAT THAT COSTS, NAMED: a radiologist who genuinely covers two units can only be recorded in
-- one. Nothing in the 20 screens shows more than one department per provider ("Dr. Mehta ·
-- Cardiology", "Dr. Osei · Clinic 4"), so this buys back a table and a whole class of drift.
-- When a screen needs the many-to-many, add public.staff_department THEN, keeping
-- staff_profile.department_id as the primary — an additive migration, not a rewrite.

CREATE TABLE IF NOT EXISTS public.org_setting (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid        NOT NULL REFERENCES public.organization (id)
                                ON UPDATE CASCADE ON DELETE RESTRICT,

    -- NULL = the hospital's default, written by a hospital_admin.
    -- NOT NULL = one person's override of it, written by that person.
    member_id       uuid        NULL,

    key             text        NOT NULL,
    value           jsonb       NOT NULL,
    updated_by      uuid        NULL,
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT org_setting_key_ck CHECK (key ~ '^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$'),
    CONSTRAINT org_setting_member_fk
      FOREIGN KEY (member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE CASCADE,
    -- RESTRICT, not SET NULL: a composite FK's SET NULL nulls EVERY column in the key, and
    -- organization_id is NOT NULL here — the delete would fail with a confusing constraint
    -- error instead of an obvious one. It never fires anyway: 010 attaches
    -- app.deny_hard_delete() to organization_member, so seats are revoked, not removed.
    -- The same reasoning applies to every created_by/received_by key below.
    CONSTRAINT org_setting_updated_by_fk
      FOREIGN KEY (updated_by, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
-- Two partial indexes rather than one, because a PK cannot contain a nullable column and
-- coalescing member_id to a sentinel uuid would put a fake id in a real foreign key.
CREATE UNIQUE INDEX IF NOT EXISTS org_setting_org_default_uk
  ON public.org_setting (organization_id, key) WHERE member_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS org_setting_member_uk
  ON public.org_setting (organization_id, member_id, key) WHERE member_id IS NOT NULL;

COMMENT ON TABLE public.org_setting IS
  'Non-security preferences, at hospital level (member_id NULL) or personal level. The doctor '
  'Settings screen writes ai.risk_flags_on_lists, ai.confirm_before_chart and '
  'ai.daily_summary_email here as personal rows; a hospital_admin writes the same keys with '
  'member_id NULL to set the default for everyone.';
COMMENT ON COLUMN public.org_setting.key IS
  'Dotted namespace, e.g. ai.risk_flags_on_lists or billing.default_currency. Deliberately NOT '
  'backed by a registry table, unlike public.feature — the argument 010 makes for entitlements '
  '(a typo silently grants or denies revenue) does not apply here, because app.setting() '
  'returns NULL for an unknown key and every caller supplies its own default. The cost is that '
  'a typo is a silently ignored preference; that is a support ticket, not a breach.';
COMMENT ON COLUMN public.org_setting.value IS
  'jsonb so a setting can be a boolean, a number or a small object without a migration. Never '
  'read this in an RLS policy: it is customer-writable, and 010 makes the same point about '
  'organization.settings.';

-- Resolution order, and the only function anything should call: personal override, then the
-- hospital default, then NULL (meaning "the app decides").
CREATE OR REPLACE FUNCTION app.setting(p_key text)
RETURNS jsonb LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(
    (SELECT s.value FROM public.org_setting s
      WHERE s.organization_id = app.current_org_id()
        AND s.member_id = app.current_member_id()
        AND s.key = p_key),
    (SELECT s.value FROM public.org_setting s
      WHERE s.organization_id = app.current_org_id()
        AND s.member_id IS NULL
        AND s.key = p_key));
$$;

COMMENT ON FUNCTION app.setting(text) IS
  'Effective value of one preference for the calling user. Runs as invoker, so org_setting''s '
  'own RLS applies and it can never read another tenant''s configuration.';

-- 020 already attaches t_touch to public.department; re-attaching the same function is a no-op
-- and keeps this file readable on its own.
DROP TRIGGER IF EXISTS t_touch ON public.department;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.department
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.org_setting;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.org_setting
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.department;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.department
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
-- org_setting DOES allow hard delete: resetting a preference is ordinary configuration and the
-- audit trail in §6 keeps the history that matters. Clinical and financial rows get no such
-- licence.


-- =============================================================================================
-- SECTION 3 — BILLING (reception screen 15)
--
-- WHAT IS DELIBERATELY ABSENT
--   There is no `claim` table. A real revenue-cycle system tracks a claim as an object with its
--   own submission/adjudication/appeal lifecycle, separate from the invoice. This product has
--   one screen with three tabs (Pending / Denied claims / Paid) and derives all three from the
--   invoice's own status. Adding a claim table would double the write path and the RLS surface
--   for a lifecycle nothing renders. The payer-facing facts that DO show up — the claim
--   reference, whether prior authorisation is missing, the AI denial-risk flag — are columns on
--   the invoice. Revisit when a screen needs an appeal history; it will be a clean addition.
--
-- MONEY, PRECISELY
--   * bigint minor units. Floats are wrong for money and the argument is not worth rehearsing.
--   * currency lives on the invoice, once. Lines and payments carry no currency column at all:
--     they belong to exactly one invoice and are denominated in its currency by construction.
--     That removes an entire class of mismatch bug rather than constraining it away.
--   * default 'INR'. The operator is in India.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.payer (
    id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid          NOT NULL REFERENCES public.organization (id)
                                  ON UPDATE CASCADE ON DELETE RESTRICT,
    kind            app.payer_kind NOT NULL DEFAULT 'insurer',
    code            text          NOT NULL,
    name            text          NOT NULL,
    contact_phone   text          NULL,
    contact_email   text          NULL,
    is_active       boolean       NOT NULL DEFAULT true,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    updated_at      timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT payer_code_ck  CHECK (btrim(code) <> ''),
    CONSTRAINT payer_name_ck  CHECK (btrim(name) <> ''),
    CONSTRAINT payer_email_ck CHECK (contact_email IS NULL OR contact_email LIKE '%_@_%'),
    CONSTRAINT payer_id_org_uk UNIQUE (id, organization_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS payer_code_uk
  ON public.payer (organization_id, upper(code));

COMMENT ON TABLE public.payer IS
  'Who settles a bill: an insurer, a TPA, a government scheme, a corporate account, or the '
  'patient themselves. Tenant-scoped because each hospital negotiates its own panel — two '
  'hospitals both dealing with the same insurer hold two rows, and that is correct: the codes, '
  'contacts and rates differ.';

CREATE TABLE IF NOT EXISTS public.patient_coverage (
    id              uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id uuid                 NOT NULL REFERENCES public.organization (id)
                                         ON UPDATE CASCADE ON DELETE RESTRICT,
    patient_id      uuid                 NOT NULL,
    payer_id        uuid                 NOT NULL,

    priority        app.coverage_priority NOT NULL DEFAULT 'primary',
    member_number   text                 NOT NULL,
    group_number    text                 NULL,
    plan_name       text                 NULL,
    valid_from      date                 NOT NULL DEFAULT current_date,
    valid_to        date                 NULL,
    is_active       boolean              NOT NULL DEFAULT true,

    created_by      uuid                 NULL,
    created_at      timestamptz          NOT NULL DEFAULT now(),
    updated_at      timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT patient_coverage_member_no_ck CHECK (btrim(member_number) <> ''),
    CONSTRAINT patient_coverage_window_ck    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    CONSTRAINT patient_coverage_id_org_uk    UNIQUE (id, organization_id),
    CONSTRAINT patient_coverage_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT patient_coverage_payer_fk
      FOREIGN KEY (payer_id, organization_id)
      REFERENCES public.payer (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT patient_coverage_creator_fk
      FOREIGN KEY (created_by, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
-- One active primary policy per patient. Secondary coverage is common; two primaries is a
-- data-entry error that produces two different answers to "who do we bill first".
CREATE UNIQUE INDEX IF NOT EXISTS patient_coverage_primary_uk
  ON public.patient_coverage (patient_id) WHERE is_active AND priority = 'primary';
CREATE INDEX IF NOT EXISTS patient_coverage_patient_ix
  ON public.patient_coverage (organization_id, patient_id) WHERE is_active;

COMMENT ON TABLE public.patient_coverage IS
  'Step 2 of the Register-patient flow ("Identity · Insurance · Consent"). Personal financial '
  'data, so its policies match the patient chart''s rather than the configuration tables '
  'above: front desk, treating clinicians, and the patient themselves. No vendor route, not '
  'even through an open support session — member_number is a credential-grade identifier.';

CREATE TABLE IF NOT EXISTS public.invoice (
    id                  uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid               NOT NULL REFERENCES public.organization (id)
                                           ON UPDATE CASCADE ON DELETE RESTRICT,
    patient_id          uuid               NOT NULL,

    -- "INV-2241" on the screen. Allocated by the app, unique within the tenant. Same open
    -- question as MRN in 010: a per-tenant sequence would remove a front-desk race but needs a
    -- format decision from the operator first.
    number              text               NOT NULL,
    status              app.invoice_status NOT NULL DEFAULT 'draft',

    -- MONEY ---------------------------------------------------------------------------------
    currency            char(3)            NOT NULL DEFAULT 'INR',
    total_minor         bigint             NOT NULL DEFAULT 0,
    patient_due_minor   bigint             NOT NULL DEFAULT 0,

    -- WHO PAYS ------------------------------------------------------------------------------
    coverage_id         uuid               NULL,
    payer_id            uuid               NULL,
    payer_claim_ref     text               NULL,

    prior_auth_required boolean            NOT NULL DEFAULT false,
    prior_auth_ref      text               NULL,

    -- AI DENIAL RISK (the "Claims at denial risk (AI) 3" tile and the dashed strip) ----------
    denial_risk_flag    boolean            NOT NULL DEFAULT false,
    denial_risk_score   numeric(4,3)       NULL,
    denial_risk_note    text               NULL,
    denial_model_version text              NULL,

    -- DATES ---------------------------------------------------------------------------------
    issued_at           timestamptz        NULL,
    due_at              timestamptz        NULL,
    closed_at           timestamptz        NULL,
    void_reason         text               NULL,

    -- Rule 3: bytes never live in a column. The generated invoice PDF sits in object storage
    -- under the tenant prefix, and the CHECK makes a cross-tenant key a constraint violation
    -- rather than something a reviewer has to notice.
    pdf_storage_key     text               NULL,

    created_by          uuid               NULL,
    created_at          timestamptz        NOT NULL DEFAULT now(),
    updated_at          timestamptz        NOT NULL DEFAULT now(),

    CONSTRAINT invoice_number_ck   CHECK (btrim(number) <> ''),
    CONSTRAINT invoice_currency_ck CHECK (currency ~ '^[A-Z]{3}$'),
    CONSTRAINT invoice_amounts_ck  CHECK (total_minor >= 0 AND patient_due_minor >= 0
                                          AND patient_due_minor <= total_minor),
    CONSTRAINT invoice_risk_ck     CHECK (denial_risk_score IS NULL
                                          OR (denial_risk_score >= 0 AND denial_risk_score <= 1)),
    -- A flag with no stated reason is an alert nobody can act on.
    CONSTRAINT invoice_risk_reason_ck
      CHECK (NOT denial_risk_flag OR denial_risk_score IS NOT NULL OR denial_risk_note IS NOT NULL),
    -- The screen's "Auth missing" status means exactly this and nothing else.
    CONSTRAINT invoice_auth_ck
      CHECK (status <> 'auth_missing' OR (prior_auth_required AND prior_auth_ref IS NULL)),
    CONSTRAINT invoice_overdue_ck  CHECK (status <> 'overdue' OR due_at IS NOT NULL),
    CONSTRAINT invoice_void_ck     CHECK ((status = 'void') = (void_reason IS NOT NULL)),
    -- 'void' is exempt as well as 'draft': abandoning a half-built invoice must not require
    -- pretending it was ever issued.
    CONSTRAINT invoice_issued_ck   CHECK (status IN ('draft', 'void') OR issued_at IS NOT NULL),
    CONSTRAINT invoice_due_ck      CHECK (due_at IS NULL OR issued_at IS NULL OR due_at >= issued_at),
    CONSTRAINT invoice_storage_ck
      CHECK (pdf_storage_key IS NULL
             OR app.storage_key_belongs_to(pdf_storage_key, organization_id)),
    CONSTRAINT invoice_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT invoice_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT invoice_coverage_fk
      FOREIGN KEY (coverage_id, organization_id)
      REFERENCES public.patient_coverage (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT invoice_payer_fk
      FOREIGN KEY (payer_id, organization_id)
      REFERENCES public.payer (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT invoice_creator_fk
      FOREIGN KEY (created_by, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS invoice_number_uk
  ON public.invoice (organization_id, upper(number));
-- The three Billing tabs and the "Outstanding balance" tile are all this index.
CREATE INDEX IF NOT EXISTS invoice_worklist_ix
  ON public.invoice (organization_id, status, due_at)
  WHERE status IN ('copay_due', 'auth_missing', 'overdue');
CREATE INDEX IF NOT EXISTS invoice_patient_ix
  ON public.invoice (organization_id, patient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS invoice_denial_ix
  ON public.invoice (organization_id) WHERE denial_risk_flag;

COMMENT ON TABLE public.invoice IS
  'One bill for one patient. Carries no clinical text of its own — the "Service" column on the '
  'Billing screen comes from invoice_line — so that the row itself is financial rather than '
  'diagnostic. Never deleted: a cancelled invoice is status=void with a reason.';
COMMENT ON COLUMN public.invoice.total_minor IS
  'Minor units of `currency` (paise for INR). Integer, never numeric-with-decimals and never '
  'float. patient_due_minor is the share the patient owes; total minus it is the payer''s.';
COMMENT ON COLUMN public.invoice.status IS
  'The workflow state the front desk sees and sets. It is NOT derived from the payments below, '
  'deliberately: "covered" and "written_off" are decisions, not arithmetic. The arithmetic '
  'lives in app.v_invoice_balance, and the two disagreeing is a real signal — see the open '
  'question about auto-transitioning at the end of this file.';
COMMENT ON COLUMN public.invoice.denial_risk_flag IS
  'What the screen renders. denial_risk_score and denial_model_version are why, and they are '
  'kept because an AI claim with no recorded model version cannot be re-examined after the '
  'model changes. Advisory only: nothing in this schema acts on it automatically.';

CREATE TABLE IF NOT EXISTS public.invoice_line (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES public.organization (id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT,
    invoice_id       uuid        NOT NULL,

    line_no          integer     NOT NULL,
    description      text        NOT NULL,
    service_code     text        NULL,
    code_system      text        NOT NULL DEFAULT 'local',
    department_id    uuid        NULL,

    quantity         numeric(10,2) NOT NULL DEFAULT 1,
    unit_price_minor bigint      NOT NULL,
    amount_minor     bigint      NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT invoice_line_desc_ck  CHECK (btrim(description) <> ''),
    CONSTRAINT invoice_line_qty_ck   CHECK (quantity <> 0),
    CONSTRAINT invoice_line_no_ck    CHECK (line_no > 0),
    -- Negative amounts are how a correction is made after an invoice is issued (see the
    -- immutability trigger below), so the sign is not constrained — only the arithmetic is.
    CONSTRAINT invoice_line_code_ck
      CHECK (code_system IN ('local', 'cpt', 'icd10', 'icd10pcs', 'snomed', 'cghs')),
    CONSTRAINT invoice_line_invoice_fk
      FOREIGN KEY (invoice_id, organization_id)
      REFERENCES public.invoice (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT invoice_line_department_fk
      FOREIGN KEY (department_id, organization_id)
      REFERENCES public.department (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS invoice_line_no_uk
  ON public.invoice_line (invoice_id, line_no);
CREATE INDEX IF NOT EXISTS invoice_line_invoice_ix
  ON public.invoice_line (invoice_id);

COMMENT ON TABLE public.invoice_line IS
  'What was billed: "CT scan, chest", code 71260. This is the clinically revealing half of a '
  'bill, which is why its read policy is narrower than the invoice header''s. code_system is '
  'explicit and defaults to ''local'' because CPT is a US code set and the operator is in '
  'India — the mock data''s 71260 is a CPT code and should be re-coded before go-live.';

CREATE TABLE IF NOT EXISTS public.payment (
    id                  uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid               NOT NULL REFERENCES public.organization (id)
                                           ON UPDATE CASCADE ON DELETE RESTRICT,
    invoice_id          uuid               NOT NULL,

    -- Signed. A refund or a correction is a NEGATIVE row that references the payment it
    -- reverses, so the history survives (rule 4) and the balance is still one SUM.
    amount_minor        bigint             NOT NULL,
    method              app.payment_method NOT NULL,
    reference           text               NULL,
    reverses_payment_id uuid               NULL,

    received_at         timestamptz        NOT NULL DEFAULT now(),
    received_by         uuid               NULL,
    created_at          timestamptz        NOT NULL DEFAULT now(),

    CONSTRAINT payment_amount_ck   CHECK (amount_minor <> 0),
    CONSTRAINT payment_reversal_ck CHECK (reverses_payment_id IS NULL OR amount_minor < 0),
    CONSTRAINT payment_id_org_uk   UNIQUE (id, organization_id),
    CONSTRAINT payment_invoice_fk
      FOREIGN KEY (invoice_id, organization_id)
      REFERENCES public.invoice (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT payment_reversal_fk
      FOREIGN KEY (reverses_payment_id, organization_id)
      REFERENCES public.payment (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT payment_receiver_fk
      FOREIGN KEY (received_by, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS payment_invoice_ix ON public.payment (invoice_id);
-- "Collected today $1,880 · 14 payments".
CREATE INDEX IF NOT EXISTS payment_org_day_ix ON public.payment (organization_id, received_at DESC);

COMMENT ON TABLE public.payment IS
  'Money actually received, in the currency of the parent invoice. Append-only in practice: no '
  'DELETE policy and app.deny_hard_delete() attached, because a payment record that can vanish '
  'is not a financial record. Reversals are negative rows.';

-- Once an invoice leaves draft, its lines are settled: a correction is a new (negative) line,
-- not an edit of an old one. This is rule 4 applied to money — the same reason clinical rows
-- are amended rather than overwritten.
CREATE OR REPLACE FUNCTION app.guard_invoice_line_immutable()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_status  app.invoice_status;
  v_invoice uuid;
BEGIN
  -- NEW is unassigned in a DELETE trigger and OLD in an INSERT one, so neither may be touched
  -- outside its own branch: coalesce(NEW, OLD) does not compile for trigger records, and
  -- reading NEW.x on a DELETE raises at runtime.
  IF TG_OP = 'DELETE' THEN
    v_invoice := OLD.invoice_id;
  ELSE
    v_invoice := NEW.invoice_id;
  END IF;

  SELECT i.status INTO v_status FROM public.invoice i WHERE i.id = v_invoice;

  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'Invoice % is no longer a draft; its lines cannot be changed (%).',
                    v_invoice, lower(TG_OP)
      USING errcode = '42501',
            hint = 'Correct an issued invoice by adding a line with a negative amount.';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_line_immutable ON public.invoice_line;
CREATE TRIGGER t_line_immutable BEFORE UPDATE OR DELETE ON public.invoice_line
  FOR EACH ROW EXECUTE FUNCTION app.guard_invoice_line_immutable();

DROP TRIGGER IF EXISTS t_touch ON public.payer;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.payer
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.patient_coverage;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.patient_coverage
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.invoice;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

DROP TRIGGER IF EXISTS t_no_delete ON public.patient_coverage;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.patient_coverage
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_no_delete ON public.invoice;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.invoice
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_no_delete ON public.payment;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.payment
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_no_delete ON public.payer;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.payer
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

-- Optional link to the clinical encounter that generated the bill. Added conditionally so this
-- file runs whether or not 020 is present, and so it never has to guess a table name that
-- might not exist yet. If 020 names its table something else, wire it up there.
DO $encounter_fk$
BEGIN
  IF to_regclass('public.encounter') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'invoice_encounter_fk') THEN
    BEGIN
      EXECUTE 'ALTER TABLE public.invoice ADD COLUMN IF NOT EXISTS encounter_id uuid NULL';
      EXECUTE 'ALTER TABLE public.invoice ADD CONSTRAINT invoice_encounter_fk
                 FOREIGN KEY (encounter_id, organization_id)
                 REFERENCES public.encounter (id, organization_id)
                 ON UPDATE CASCADE ON DELETE RESTRICT';
      RAISE NOTICE 'prognosify/040: linked invoice.encounter_id to public.encounter.';
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'prognosify/040: could not link invoice to public.encounter (%). '
                   'Add the FK in the clinical migration instead.', SQLERRM;
    END;
  ELSIF to_regclass('public.encounter') IS NULL THEN
    RAISE NOTICE 'prognosify/040: public.encounter absent — invoice has no encounter link. '
                 'The clinical migration should add it compositely on (id, organization_id).';
  END IF;
END
$encounter_fk$;

-- The Billing screen in one query: header, patient, what was billed, what is still owed.
-- security_invoker so every policy below still applies — a receptionist sees their hospital's
-- invoices and nobody else's, and a patient sees only their own.
CREATE OR REPLACE VIEW app.v_invoice_balance
WITH (security_invoker = true) AS
SELECT i.id                AS invoice_id,
       i.organization_id,
       i.number,
       i.status,
       i.currency,
       i.total_minor,
       i.patient_due_minor,
       coalesce(sum(p.amount_minor), 0)                       AS paid_minor,
       i.patient_due_minor - coalesce(sum(p.amount_minor), 0) AS balance_minor,
       i.due_at,
       greatest(0, (current_date - i.due_at::date))           AS days_overdue,
       i.denial_risk_flag,
       i.denial_risk_score
  FROM public.invoice i
  LEFT JOIN public.payment p ON p.invoice_id = i.id
 GROUP BY i.id;

COMMENT ON VIEW app.v_invoice_balance IS
  'Arithmetic the Billing screen needs: paid, outstanding, and how many days past due. '
  '"21 days overdue" on the mock is status=overdue plus days_overdue from here. Deliberately '
  'not a stored column on invoice — a cached balance and a payments table drift, and when they '
  'do the cached one is the liar.';


-- =============================================================================================
-- SECTION 4 — THE VENDOR DASHBOARD, BUILT FROM COUNTS
--
-- THE REQUIREMENT, RESTATED AS A CONSTRAINT
--   super_admin needs a tenant list with health and usage signals. It must be answerable
--   WITHOUT reading a single patient row. That is not a nicety — it is the whole containment
--   argument from 010 §7. If the vendor dashboard needed `SELECT count(*) FROM patient` at
--   request time, then either the vendor gets a policy on the patient table (and containment
--   is gone) or the dashboard does not work. So the counting happens on a schedule, in one
--   SECURITY DEFINER function, and what it leaves behind is arithmetic.
--
-- WHY A NARROW (org, date, metric, value) TABLE RATHER THAN WIDE COLUMNS
--   Because 020 and 030 own tables this file has never seen. A wide table would need an ALTER
--   every time someone wants "AI reports generated" on the dashboard, and that ALTER would
--   live in the wrong migration. Narrow means a clinical migration can register its own metric
--   and start writing it without touching this file. The cost is that the dashboard pivots;
--   at one row per tenant per metric per day that is nothing.
--
-- THE REGISTRY IS THE SAME ARGUMENT 010 MAKES FOR public.feature
--   The vendor dashboard renders a list of metrics. With a registry that list is a SELECT;
--   without one it is a hard-coded array in the frontend that drifts. And an unregistered key
--   cannot be written at all, so `ai_reports` and `ai-reports` cannot quietly become two
--   half-populated series that each look like a 50% usage drop.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.usage_metric (
    key         text        PRIMARY KEY,
    name        text        NOT NULL,
    description text        NOT NULL DEFAULT '',
    unit        text        NOT NULL DEFAULT 'count',
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT usage_metric_key_ck  CHECK (key ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT usage_metric_unit_ck CHECK (unit IN ('count', 'bytes', 'minutes'))
);

COMMENT ON TABLE public.usage_metric IS
  'Registry of every per-tenant counter the vendor dashboard can show. Not tenant data — the '
  'same list applies to every hospital. A later migration adds a row here and then writes '
  'values with app.record_usage(); it does not need to alter anything in this file.';

CREATE TABLE IF NOT EXISTS public.organization_usage_daily (
    organization_id uuid        NOT NULL REFERENCES public.organization (id)
                                ON UPDATE CASCADE ON DELETE CASCADE,
    usage_date      date        NOT NULL,
    metric_key      text        NOT NULL REFERENCES public.usage_metric (key)
                                ON UPDATE CASCADE ON DELETE RESTRICT,
    metric_value    bigint      NOT NULL,
    computed_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (organization_id, usage_date, metric_key),
    CONSTRAINT organization_usage_daily_value_ck CHECK (metric_value >= 0)
);
CREATE INDEX IF NOT EXISTS organization_usage_daily_metric_ix
  ON public.organization_usage_daily (metric_key, usage_date DESC, organization_id);

COMMENT ON TABLE public.organization_usage_daily IS
  'Per-tenant, per-day counters. THE ONLY TABLE IN THIS FILE WHOSE SELECT POLICY MENTIONS '
  'app.is_super_admin(), and the reason that is safe is structural: every column is a count, a '
  'date or a tenant id. No name, no MRN, no clinical value can be represented here — '
  'metric_value is a bigint. ON DELETE CASCADE (not RESTRICT) because when a tenant is truly '
  'erased, their usage counters should go with them; nothing references these rows.';
COMMENT ON COLUMN public.organization_usage_daily.metric_value IS
  'Deliberately bigint rather than jsonb or text. A counter table that can hold a string is a '
  'counter table that will eventually hold a patient name.';

-- ON CONFLICT rather than INSERT-or-fail: a collector that is re-run for the same day must be
-- idempotent, otherwise nobody will ever dare re-run it after a bad deploy.
CREATE OR REPLACE FUNCTION app.record_usage(
    p_organization_id uuid,
    p_metric_key      text,
    p_metric_value    bigint,
    p_usage_date      date DEFAULT current_date)
RETURNS void LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  INSERT INTO public.organization_usage_daily
      (organization_id, usage_date, metric_key, metric_value, computed_at)
  VALUES (p_organization_id, p_usage_date, p_metric_key, p_metric_value, now())
  ON CONFLICT (organization_id, usage_date, metric_key)
  DO UPDATE SET metric_value = excluded.metric_value, computed_at = now();
$$;

COMMENT ON FUNCTION app.record_usage(uuid, text, bigint, date) IS
  'The only write path into organization_usage_daily (the table has no INSERT or UPDATE '
  'policy). SECURITY DEFINER because a collector must count rows across every tenant, which is '
  'precisely what RLS is there to stop for everyone else. EXECUTE is granted to service_role '
  'only — an ordinary session cannot call it and cannot forge usage numbers.';

-- 010 exports app.feature_limit() for the CALLER'S org. The vendor dashboard needs the limit
-- for an arbitrary org, so this is the org-scoped sibling of it, resolving in exactly the same
-- order (live override, then plan default, then nothing) as app.org_has_feature().
CREATE OR REPLACE FUNCTION app.org_feature_limit(p_organization_id uuid, p_feature_key text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(
    (SELECT e.limit_value FROM public.organization_entitlement e
      WHERE e.organization_id = p_organization_id
        AND e.feature_key = p_feature_key
        AND e.enabled
        AND e.effective_from <= now()
        AND (e.effective_to IS NULL OR e.effective_to > now())),
    (SELECT pf.limit_value FROM public.organization o
       JOIN public.plan_feature pf ON pf.plan_id = o.plan_id
      WHERE o.id = p_organization_id AND pf.feature_key = p_feature_key AND pf.enabled));
$$;

-- ---- the seat limit, actually enforced -------------------------------------------------------
-- An entitlement nothing checks is a number in a table. `staff_seats` is the one entitlement
-- with an obvious enforcement point, so it gets one. Attached to 010's organization_member as
-- an additional BEFORE trigger — additive, not a redefinition.
CREATE OR REPLACE FUNCTION app.enforce_staff_seat_limit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_staff CONSTANT app.org_role[] :=
    ARRAY['hospital_admin','doctor','nurse','receptionist']::app.org_role[];
  v_limit integer;
  v_used  integer;
BEGIN
  -- Patients are not seats, and a change that does not add a staff role cannot cross a limit.
  IF NOT (NEW.roles && v_staff) THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND (OLD.roles && v_staff) AND NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF NEW.status NOT IN ('invited', 'active') THEN
    RETURN NEW;
  END IF;

  v_limit := app.org_feature_limit(NEW.organization_id, 'staff_seats');
  IF v_limit IS NULL THEN            -- unlimited, or the feature is off entirely
    RETURN NEW;
  END IF;

  SELECT count(*) INTO v_used
    FROM public.organization_member m
   WHERE m.organization_id = NEW.organization_id
     AND m.status IN ('invited', 'active')
     AND m.roles && v_staff
     AND m.id IS DISTINCT FROM NEW.id;

  IF v_used >= v_limit THEN
    RAISE EXCEPTION 'Staff seat limit reached: % of % seats are in use on this plan.',
                    v_used, v_limit
      USING errcode = '53400',
            hint = 'Revoke an unused seat, or ask the vendor to raise the staff_seats limit.';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.enforce_staff_seat_limit() IS
  'Fails the INSERT closed when a hospital is at its plan''s seat limit. Invited seats count, '
  'otherwise a hospital can queue up unlimited invitations and cross the limit the moment they '
  'are accepted. SECURITY DEFINER only so it can count members without RLS deciding it sees '
  'none of them.';

DROP TRIGGER IF EXISTS t_seat_limit ON public.organization_member;
CREATE TRIGGER t_seat_limit BEFORE INSERT OR UPDATE ON public.organization_member
  FOR EACH ROW EXECUTE FUNCTION app.enforce_staff_seat_limit();

-- ---- the collector ---------------------------------------------------------------------------
-- Runs on a schedule (pg_cron on Supabase, or any external scheduler) as service_role. It is
-- the one place in the system that reads clinical tables on the vendor's behalf, and every
-- value it emits is a count. Optional tables are probed with to_regclass so this file does not
-- depend on what 020/030 chose to call things.
--
-- SECURITY INVOKER, and that is not an oversight. audit.event is the one table in this schema
-- with FORCE ROW LEVEL SECURITY (§5.4), which subjects the table OWNER to its policies too — so
-- a SECURITY DEFINER version of this function would count the audit rows it is allowed to see
-- (roughly none) and quietly report every tenant as dormant. Running as the caller, and
-- granting EXECUTE only to a role holding BYPASSRLS (service_role on Supabase; on RDS/Neon,
-- whatever role the scheduler uses), makes the counts correct and keeps the privilege visible
-- in a GRANT rather than buried in a function definition.
CREATE OR REPLACE FUNCTION app.refresh_organization_usage(p_usage_date date DEFAULT current_date)
RETURNS integer LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_org      record;
  v_count    bigint;
  v_written  integer := 0;
  v_optional CONSTANT text[][] := ARRAY[
    -- metric key            table                     timestamp column to filter on the day
    ARRAY['appointments',   'public.appointment',      'created_at'],
    ARRAY['encounters',     'public.encounter',        'created_at'],
    -- CORRECTED: this named 'public.ai_report', which no migration creates. to_regclass() then
    -- skipped it silently and the vendor dashboard's AI usage series was permanently empty.
    -- One row per model call is the honest meaning of "AI reports generated".
    ARRAY['ai_reports',     'public.ai_analysis_run',  'created_at'],
    ARRAY['documents',      'public.document',         'created_at']
  ];
  v_row      text[];
BEGIN
  FOR v_org IN SELECT id FROM public.organization WHERE status IN ('trial', 'active') LOOP

    SELECT count(*) INTO v_count FROM public.organization_member m
     WHERE m.organization_id = v_org.id AND m.status IN ('invited', 'active')
       AND m.roles && ARRAY['hospital_admin','doctor','nurse','receptionist']::app.org_role[];
    PERFORM app.record_usage(v_org.id, 'staff_seats_used', v_count, p_usage_date);
    v_written := v_written + 1;

    SELECT count(*) INTO v_count FROM public.patient p
     WHERE p.organization_id = v_org.id AND p.status = 'active';
    PERFORM app.record_usage(v_org.id, 'patients_active', v_count, p_usage_date);
    v_written := v_written + 1;

    SELECT count(*) INTO v_count FROM public.invoice i
     WHERE i.organization_id = v_org.id AND i.created_at::date = p_usage_date;
    PERFORM app.record_usage(v_org.id, 'invoices_created', v_count, p_usage_date);
    v_written := v_written + 1;

    SELECT count(*) INTO v_count FROM audit.event e
     WHERE e.organization_id = v_org.id AND e.occurred_at::date = p_usage_date;
    PERFORM app.record_usage(v_org.id, 'audit_events', v_count, p_usage_date);
    v_written := v_written + 1;

    -- Liveness. "When did anyone last do anything here" is the single most useful health
    -- signal for a SaaS operator, and it is answerable from the audit trail alone.
    SELECT count(DISTINCT e.actor_app_user_id) INTO v_count FROM audit.event e
     WHERE e.organization_id = v_org.id AND e.occurred_at::date = p_usage_date;
    PERFORM app.record_usage(v_org.id, 'active_users', v_count, p_usage_date);
    v_written := v_written + 1;

    FOREACH v_row SLICE 1 IN ARRAY v_optional LOOP
      CONTINUE WHEN to_regclass(v_row[2]) IS NULL;
      CONTINUE WHEN NOT EXISTS (SELECT 1 FROM public.usage_metric u WHERE u.key = v_row[1]);
      EXECUTE format(
        'SELECT count(*) FROM %s t WHERE t.organization_id = $1 AND t.%I::date = $2',
        v_row[2], v_row[3])
        INTO v_count USING v_org.id, p_usage_date;
      PERFORM app.record_usage(v_org.id, v_row[1], v_count, p_usage_date);
      v_written := v_written + 1;
    END LOOP;

  END LOOP;
  RETURN v_written;
END;
$$;

COMMENT ON FUNCTION app.refresh_organization_usage(date) IS
  'Schedule daily as service_role (or another BYPASSRLS role). Reads clinical tables and emits '
  'nothing but counts — this is the seam where personal data becomes commercial metadata, and '
  'it is deliberately one short function so that seam is reviewable in one screen. Idempotent: '
  're-running for a past date overwrites that date''s rows.';

-- ---- the tenant list -------------------------------------------------------------------------
CREATE OR REPLACE VIEW app.v_tenant_health
WITH (security_invoker = true) AS
SELECT o.id                         AS organization_id,
       o.slug,
       o.name,
       o.status,
       o.region,
       sp.code                      AS plan_code,
       sp.name                      AS plan_name,
       o.trial_ends_at,
       CASE WHEN o.status = 'trial'
            THEN greatest(0, (o.trial_ends_at::date - current_date)) END AS trial_days_left,
       o.created_at                 AS tenant_since,

       u.staff_seats_used,
       app.org_feature_limit(o.id, 'staff_seats')                        AS staff_seats_limit,
       CASE WHEN app.org_feature_limit(o.id, 'staff_seats') IS NULL THEN false
            ELSE u.staff_seats_used >= app.org_feature_limit(o.id, 'staff_seats') END
                                    AS at_seat_limit,
       u.patients_active,
       -- Person-days, not distinct people: summing daily distinct counts double-counts anyone
       -- who worked on more than one day. Named for what it is so nobody reads it as "seats
       -- in use this week" and concludes the tenant is over its limit.
       u.active_user_days_7d,
       u.last_activity_date,
       (current_date - u.last_activity_date)                             AS days_since_activity,

       app.org_has_feature(o.id, 'ai_prognosis')                         AS has_ai_prognosis,
       app.org_has_feature(o.id, 'billing')                              AS has_billing,
       app.org_has_feature(o.id, 'sso')                                  AS has_sso,

       (SELECT count(*) FROM public.support_session s
         WHERE s.organization_id = o.id AND s.revoked_at IS NULL AND s.expires_at > now())
                                    AS open_support_sessions
  FROM public.organization o
  JOIN public.subscription_plan sp ON sp.id = o.plan_id
  LEFT JOIN LATERAL (
      SELECT max(d.metric_value) FILTER (WHERE d.metric_key = 'staff_seats_used')  AS staff_seats_used,
             max(d.metric_value) FILTER (WHERE d.metric_key = 'patients_active')   AS patients_active,
             sum(d.metric_value) FILTER (WHERE d.metric_key = 'active_users')      AS active_user_days_7d,
             max(d.usage_date)   FILTER (WHERE d.metric_key = 'active_users'
                                           AND d.metric_value > 0)                 AS last_activity_date
        FROM public.organization_usage_daily d
       WHERE d.organization_id = o.id
         AND d.usage_date > current_date - 7
  ) u ON true;

COMMENT ON VIEW app.v_tenant_health IS
  'The Super Admin tenant list. Every usage figure comes from organization_usage_daily, never '
  'from a live count of clinical rows — which is what lets this view exist at all without '
  'granting the vendor a policy on the patient table. security_invoker means a hospital_admin '
  'querying it sees exactly one row: their own.';


-- =============================================================================================
-- SECTION 5 — AUDIT
--
-- 5.1 WHAT A DATABASE CAN AND CANNOT AUDIT, STATED HONESTLY
--
--   COVERED, RELIABLY, BY THIS FILE — every INSERT, UPDATE and DELETE on every table listed in
--   §8, captured by an AFTER ... FOR EACH ROW trigger. A trigger cannot be bypassed by the
--   application, by PostgREST, or by anyone holding only table privileges. If the write
--   happened, the row exists. This covers: who wrote, from which organisation, under which
--   roles, what changed, when, and in which transaction. It also covers every privilege change
--   (roles, entitlements, support sessions), which is the category that matters most.
--
--   NOT COVERED — SELECT. PostgreSQL has no SELECT trigger, and this is not an oversight to be
--   worked around cleverly; it is a design property. The available approaches and their real
--   costs:
--     (a) pgaudit — logs statement text to the server log. It records that a SELECT ran, not
--         which rows came back, and the output is a log file, not a queryable table. Useful for
--         forensics, useless for "show this patient who opened their chart".
--     (b) revoke SELECT and route every read through a SECURITY DEFINER function that logs
--         first. This is the only DB-side approach that is actually complete — and it is
--         complete ONLY if the direct table grant is removed, which means giving up PostgREST's
--         query interface and hand-writing an RPC for every screen. That is a real product
--         decision, not a schema one.
--     (c) the app reports its own reads. Incomplete by construction: an attacker with direct
--         database credentials reads without reporting. It is nonetheless what catches the
--         realistic case — a legitimate user with legitimate credentials looking at a chart
--         they had no business opening — because that user goes through the app.
--
--   THIS FILE IMPLEMENTS (c) AND SAYS SO. audit.log_read() and app.log_chart_open() exist and
--   are granted to authenticated. THE APPLICATION MUST CALL THEM on: opening a patient chart,
--   opening a prognosis report, viewing lab results, opening the billing detail of another
--   person's invoice, and every export or PDF download. audit.v_read_coverage lists what has
--   actually been reported so the gap between intent and practice is visible rather than
--   assumed. A read that is never reported leaves no trace, and no comment in this file
--   changes that.
--
--   AN ATTACKER WITH SUPERUSER can disable these triggers and edit these rows. In-database
--   append-only is a strong control against application compromise and human error; it is not
--   a control against whoever holds superuser. If that is in the threat model, stream events
--   off-box continuously and reconcile counts. That is the honest ceiling of this design.
--
-- 5.2 REQUEST CONTEXT
--   The database knows the SQL. It does not know the HTTP request unless the app says so.
--   These GUCs are transaction-local (is_local => true), so they cannot leak between pooled
--   requests sharing a connection — which is exactly why session-level settings are wrong here.
-- =============================================================================================

CREATE OR REPLACE FUNCTION audit.set_request_context(
    p_request_id uuid          DEFAULT NULL,
    p_client_ip  inet          DEFAULT NULL,
    p_user_agent text          DEFAULT NULL,
    p_route      text          DEFAULT NULL,
    p_purpose    audit.purpose DEFAULT NULL,
    p_acting_role app.org_role DEFAULT NULL)
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  PERFORM set_config('audit.request_id',   coalesce(p_request_id::text,  ''), true);
  PERFORM set_config('audit.client_ip',    coalesce(p_client_ip::text,   ''), true);
  PERFORM set_config('audit.user_agent',   coalesce(p_user_agent,        ''), true);
  PERFORM set_config('audit.route',        coalesce(p_route,             ''), true);
  PERFORM set_config('audit.purpose',      coalesce(p_purpose::text,     ''), true);
  PERFORM set_config('audit.acting_role',  coalesce(p_acting_role::text, ''), true);
END;
$$;

COMMENT ON FUNCTION audit.set_request_context(uuid, inet, text, text, audit.purpose, app.org_role) IS
  'Call once at the start of every request transaction. Without it the trail still records who '
  'and what — those come from the JWT and from tables — but loses the request id, the client '
  'address and the acting role, which are what make an incident reconstructable rather than '
  'merely detectable.';

CREATE OR REPLACE FUNCTION audit.ctx(p_key text)
RETURNS text LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT nullif(current_setting('audit.' || p_key, true), '') $$;

-- 010 made multi-role seats possible and named the consequence: "which hat were they wearing"
-- is no longer answerable from the membership row, so 040 must record it. It cannot be
-- inferred — a person who is both hospital_admin and doctor genuinely could be acting as
-- either — so the app declares it and a NULL means the app did not say. That is honest;
-- guessing would not be.
CREATE OR REPLACE FUNCTION audit.acting_role()
RETURNS app.org_role LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT audit.ctx('acting_role')::app.org_role $$;


-- ---- 5.3 THE EVENT TABLE ---------------------------------------------------------------------
-- Partitioned monthly. Not premature: this table outgrows every other table in the database
-- within a year, and retention has to be enforced by dropping whole partitions, because the
-- one thing an append-only table must not support is DELETE.

CREATE SEQUENCE IF NOT EXISTS audit.event_seq AS bigint;

CREATE TABLE IF NOT EXISTS audit.event (
    id                  uuid           NOT NULL DEFAULT gen_random_uuid(),
    -- Monotonic within the cluster. A uuid cannot tell you whether something is missing; a gap
    -- spanning a whole range of timestamps can.
    seq                 bigint         NOT NULL DEFAULT nextval('audit.event_seq'),
    occurred_at         timestamptz    NOT NULL DEFAULT clock_timestamp(),
    txid                bigint         NOT NULL DEFAULT txid_current(),

    -- WHO -------------------------------------------------------------------------------------
    actor_app_user_id   uuid           NULL,          -- NULL for migrations and system jobs
    actor_auth_uid      uuid           NULL,
    actor_org_id        uuid           NULL,          -- the organisation they were ACTING IN
    actor_roles         app.org_role[] NULL,
    acting_role         app.org_role   NULL,          -- which hat, app-declared (see above)
    actor_db_role       name           NOT NULL DEFAULT current_user,
    actor_is_vendor     boolean        NOT NULL DEFAULT false,
    support_session_id  uuid           NULL,

    -- WHAT ------------------------------------------------------------------------------------
    action              audit.action   NOT NULL,
    severity            audit.severity NOT NULL DEFAULT 'normal',
    purpose             audit.purpose  NULL,
    table_schema        name           NULL,
    table_name          name           NULL,
    row_id              uuid           NULL,
    organization_id     uuid           NULL,          -- the TENANT THE DATA BELONGS TO
    patient_id          uuid           NULL,
    changed_columns     text[]         NULL,
    old_values          jsonb          NULL,          -- changed columns only, redaction applied
    new_values          jsonb          NULL,

    -- CONTEXT ---------------------------------------------------------------------------------
    request_id          uuid           NULL,
    client_ip           inet           NULL,
    user_agent          text           NULL,
    route               text           NULL,
    reason              text           NULL,
    detail              jsonb          NULL,

    CONSTRAINT event_pk PRIMARY KEY (id, occurred_at),
    CONSTRAINT event_table_ck CHECK ((table_schema IS NULL) = (table_name IS NULL)),
    CONSTRAINT event_update_ck CHECK (action <> 'update' OR changed_columns IS NOT NULL)
) PARTITION BY RANGE (occurred_at);

COMMENT ON TABLE audit.event IS
  'Append-only record of every write to audited data, plus identity, entitlement and vendor '
  'access events. One row per affected row per statement. Never updated; never deleted except '
  'by dropping an expired partition.';
COMMENT ON COLUMN audit.event.actor_org_id IS
  'The organisation the actor was acting in — app.current_org_id() at the moment of the write. '
  '010 requires this because one human can hold seats at two hospitals: "who" is not enough to '
  'reconstruct an event, "who, wearing which hospital''s badge" is.';
COMMENT ON COLUMN audit.event.organization_id IS
  'The tenant that OWNS the affected row, which is not always the actor''s. The two differing '
  'is the definition of cross-tenant access — see audit.v_cross_tenant_access. This pair of '
  'columns is the single most important thing in the table.';
COMMENT ON COLUMN audit.event.old_values IS
  'For UPDATE, the previous values of the CHANGED columns only. The audit trail is itself '
  'sensitive; copying unchanged columns into it doubles the exposure for no investigative '
  'gain. Columns listed in audit.redacted_column are omitted entirely, though the fact that '
  'they changed still appears in changed_columns.';
COMMENT ON COLUMN audit.event.actor_db_role IS
  'The PostgreSQL role. On Supabase this distinguishes an ordinary `authenticated` request from '
  '`service_role`, which holds BYPASSRLS — service_role rows deserve a second look.';
COMMENT ON COLUMN audit.event.acting_role IS
  'NULL means the application did not declare which role it was acting under. It is not '
  'inferred from actor_roles, because for a multi-role seat any inference would be a guess '
  'recorded as a fact.';

CREATE INDEX IF NOT EXISTS event_patient_time_ix
  ON audit.event (patient_id, occurred_at DESC) WHERE patient_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS event_actor_time_ix
  ON audit.event (actor_app_user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS event_org_time_ix
  ON audit.event (organization_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS event_row_ix
  ON audit.event (table_schema, table_name, row_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS event_alert_ix
  ON audit.event (occurred_at DESC) WHERE severity <> 'normal';
CREATE INDEX IF NOT EXISTS event_vendor_ix
  ON audit.event (occurred_at DESC) WHERE actor_is_vendor;

CREATE OR REPLACE FUNCTION audit.ensure_partitions(p_months_ahead integer DEFAULT 3)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_start date := date_trunc('month', now())::date;
  v_from  date;
  v_name  text;
  i       integer;
BEGIN
  -- From one month back, so clock skew or a late-arriving transaction still lands in a real
  -- partition rather than the default one.
  FOR i IN -1 .. greatest(p_months_ahead, 1) LOOP
    v_from := (v_start + make_interval(months => i))::date;
    v_name := format('event_%s', to_char(v_from, 'YYYYMM'));
    IF to_regclass(format('audit.%I', v_name)) IS NULL THEN
      EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.event FOR VALUES FROM (%L) TO (%L)',
                     v_name, v_from, (v_from + interval '1 month')::date);
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON audit.%I FROM PUBLIC', v_name);
    END IF;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION audit.ensure_partitions(integer) IS
  'Creates monthly partitions ahead of time; schedule monthly. The DEFAULT partition below '
  'means forgetting to run it degrades performance, never correctness — an audit write must '
  'never be the reason a clinical write fails.';

DO $default_partition$
BEGIN
  IF to_regclass('audit.event_default') IS NULL THEN
    CREATE TABLE audit.event_default PARTITION OF audit.event DEFAULT;
  END IF;
END
$default_partition$;

SELECT audit.ensure_partitions(6);

-- Retention. Deliberately dry-run by default and deliberately DDL: expired audit data leaves
-- by dropping a whole partition, never as row-level DML that could be mistaken for cleanup.
CREATE OR REPLACE FUNCTION audit.drop_partitions_before(
    p_cutoff  date,
    p_dry_run boolean DEFAULT true)
RETURNS text[] LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_dropped text[] := '{}'; v_part record;
BEGIN
  FOR v_part IN
    SELECT c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'audit'
       AND c.relname ~ '^event_[0-9]{6}$'
       AND to_date(right(c.relname, 6), 'YYYYMM') < date_trunc('month', p_cutoff)
  LOOP
    v_dropped := v_dropped || v_part.relname;
    IF NOT p_dry_run THEN
      EXECUTE format('DROP TABLE audit.%I', v_part.relname);
    END IF;
  END LOOP;
  RETURN v_dropped;
END;
$$;

COMMENT ON FUNCTION audit.drop_partitions_before(date, boolean) IS
  'Retention, as an explicit act. Dry-run by default so the first call always answers "what '
  'would you delete" rather than deleting it. How long to keep audit data is a policy question '
  'for the operator and their counsel under the DPDP Act, and is not decided in this file.';


-- ---- 5.4 APPEND-ONLY, FOUR INDEPENDENT LOCKS -------------------------------------------------
-- Any one of these can be undone by a single mistake, so there are four:
--   1. no UPDATE/DELETE/TRUNCATE privilege is granted to any application role (§9);
--   2. RLS is enabled AND forced, and there is no UPDATE or DELETE policy — so even the table
--      owner matches zero rows, which is the part most designs get wrong;
--   3. a BEFORE UPDATE OR DELETE trigger raises, turning that silence into an error;
--   4. expiry happens by dropping a partition, above.
--
-- FORCE is safe HERE, and 010 warns against it for its own tables for a reason worth repeating:
-- FORCE subjects the table owner to RLS, and 010's helpers are SECURITY DEFINER functions owned
-- by that same owner reading the very tables their policies protect — hence recursion. No
-- policy on audit.event reads audit.event, so the cycle does not exist and FORCE buys real
-- protection.
ALTER TABLE audit.event ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.event FORCE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION audit.deny_mutation()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  RAISE EXCEPTION 'audit.% is append-only: % is not permitted.', TG_TABLE_NAME, TG_OP
    USING errcode = '42501',
          hint = 'Correct the record by appending an event that references the old one. '
                 'Expired data leaves only by dropping a whole retention partition.';
END;
$$;

DROP TRIGGER IF EXISTS event_append_only ON audit.event;
CREATE TRIGGER event_append_only BEFORE UPDATE OR DELETE ON audit.event
  FOR EACH ROW EXECUTE FUNCTION audit.deny_mutation();


-- ---- 5.5 REDACTION ---------------------------------------------------------------------------
-- The audit trail is itself sensitive data. Some columns should never be copied into it.

CREATE TABLE IF NOT EXISTS audit.redacted_column (
    table_schema name NOT NULL,
    table_name   name NOT NULL,
    column_name  name NOT NULL,
    reason       text NOT NULL,
    PRIMARY KEY (table_schema, table_name, column_name)
);

COMMENT ON TABLE audit.redacted_column IS
  'Columns whose VALUES are omitted from old_values/new_values. The fact that the column '
  'changed is still recorded in changed_columns, so a redacted column is still auditable — '
  'you learn that it changed and who changed it, just not to what.';

INSERT INTO audit.redacted_column (table_schema, table_name, column_name, reason) VALUES
  ('public', 'app_user', 'auth_user_id',
     'Identity-provider subject. Spreading a credential-adjacent identifier through the trail buys no investigative value.'),
  ('public', 'organization_member', 'auth_user_id',
     'The same identifier, denormalised.'),
  ('public', 'platform_admin', 'auth_user_id',
     'The same identifier, vendor side.'),
  ('public', 'patient_coverage', 'member_number',
     'Insurance member number: a financial identifier usable for fraud on its own.'),
  ('public', 'patient_coverage', 'group_number',
     'Same family of identifier.')
ON CONFLICT (table_schema, table_name, column_name) DO NOTHING;

CREATE OR REPLACE FUNCTION audit.redact(p_row jsonb, p_schema name, p_table name)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
           WHEN p_row IS NULL THEN NULL
           ELSE coalesce(
             (SELECT p_row - array_agg(rc.column_name::text)
                FROM audit.redacted_column rc
               WHERE rc.table_schema = p_schema AND rc.table_name = p_table),
             p_row)
         END;
$$;


-- ---- 5.6 THE ROW TRIGGER ---------------------------------------------------------------------
-- One generic function for every audited table. SECURITY DEFINER so it can insert into
-- audit.event while the caller holds no INSERT privilege there — which is the point: the actor,
-- the table name and the organisation cannot be forged by the writer, because the writer never
-- touches the audit table.
--
-- TG_ARGV lists columns whose change makes the event an ALERT. That is how a role edit and an
-- ordinary job-title edit on the same table end up with different severities without a second
-- trigger function.
--
-- If this function raises, the parent write fails. That is intended: a system that silently
-- keeps writing when its audit trail is broken has an audit trail nobody can rely on.
CREATE OR REPLACE FUNCTION audit.fn_row_audit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_full     jsonb;
  v_old      jsonb;
  v_new      jsonb;
  v_changed  text[];
  v_action   audit.action;
  v_severity audit.severity := 'normal';
  v_actor_org uuid    := app.current_org_id();
  v_vendor   boolean  := app.is_super_admin();
  v_support  uuid     := app.current_support_session_id();
  v_org      uuid;
  v_patient  uuid;
  v_row      uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_action := 'delete';
    v_full   := to_jsonb(OLD);
    v_old    := v_full;
  ELSIF TG_OP = 'INSERT' THEN
    v_action := 'insert';
    v_full   := to_jsonb(NEW);
    v_new    := v_full;
  ELSE
    v_action := 'update';
    v_full   := to_jsonb(NEW);
    v_old    := to_jsonb(OLD);
    v_new    := v_full;

    SELECT array_agg(n.key ORDER BY n.key) INTO v_changed
      FROM jsonb_each(v_new) AS n(key, value)
     WHERE n.value IS DISTINCT FROM (v_old -> n.key);

    -- An UPDATE that changed nothing is not an event. Recording it buries the ones that are.
    IF v_changed IS NULL THEN
      RETURN NULL;
    END IF;

    -- Keep only the changed columns, both sides.
    v_old := (SELECT jsonb_object_agg(k, v_old -> k) FROM unnest(v_changed) AS k);
    v_new := (SELECT jsonb_object_agg(k, v_new -> k) FROM unnest(v_changed) AS k);
  END IF;

  -- Identity of the affected row, read from the FULL row before redaction narrows it.
  v_row     := nullif(v_full ->> 'id', '')::uuid;
  v_org     := nullif(v_full ->> 'organization_id', '')::uuid;
  v_patient := nullif(v_full ->> 'patient_id', '')::uuid;
  IF v_patient IS NULL AND TG_TABLE_NAME = 'patient' THEN
    v_patient := v_row;
  END IF;
  -- public.organization IS the tenant; it has no organization_id column, and without this the
  -- most consequential vendor action of all — suspending a hospital or changing its plan —
  -- would record a NULL target and slip past audit.v_cross_tenant_access.
  IF v_org IS NULL AND TG_TABLE_NAME = 'organization' THEN
    v_org := v_row;
  END IF;

  -- Sensitive columns named by the trigger definition.
  IF TG_NARGS > 0 AND (TG_OP <> 'UPDATE' OR v_changed && TG_ARGV::text[]) THEN
    v_severity := 'alert';
  END IF;

  -- THE ONE THAT MUST NEVER BE MISSED: a vendor account touching tenant data. Legitimate
  -- vendor work (raising an entitlement, opening a support session) still lands here — it is
  -- just explained by a support session or by the table being commercial metadata.
  IF v_vendor AND v_org IS NOT NULL THEN
    v_severity := 'alert';
  END IF;

  INSERT INTO audit.event (
      actor_app_user_id, actor_auth_uid, actor_org_id, actor_roles, acting_role,
      actor_is_vendor, support_session_id,
      action, severity, purpose, table_schema, table_name, row_id,
      organization_id, patient_id, changed_columns, old_values, new_values,
      request_id, client_ip, user_agent, route)
  VALUES (
      app.current_user_id(), app.current_auth_uid(), v_actor_org, app.current_roles(),
      audit.acting_role(), v_vendor, v_support,
      v_action, v_severity, audit.ctx('purpose')::audit.purpose,
      TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row,
      v_org, v_patient, v_changed,
      audit.redact(v_old, TG_TABLE_SCHEMA, TG_TABLE_NAME),
      audit.redact(v_new, TG_TABLE_SCHEMA, TG_TABLE_NAME),
      audit.ctx('request_id')::uuid, audit.ctx('client_ip')::inet,
      audit.ctx('user_agent'), audit.ctx('route'));

  RETURN NULL;   -- AFTER trigger: the return value is discarded
END;
$$;

-- Named z_audit so it sorts last: AFTER triggers fire in name order, and the audit trigger
-- should see whatever the guard and touch triggers have already settled on.
CREATE OR REPLACE FUNCTION audit.attach(
    p_schema         name,
    p_table          name,
    p_alert_columns  text[] DEFAULT '{}')
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_args text;
BEGIN
  IF to_regclass(format('%I.%I', p_schema, p_table)) IS NULL THEN
    RAISE NOTICE 'prognosify/040: %.% does not exist — not audited. If a later migration '
                 'creates it, that migration must call audit.attach().', p_schema, p_table;
    RETURN;
  END IF;

  SELECT coalesce(string_agg(quote_literal(c), ', '), '')
    INTO v_args FROM unnest(p_alert_columns) AS c;

  EXECUTE format('DROP TRIGGER IF EXISTS z_audit ON %I.%I', p_schema, p_table);
  EXECUTE format(
    'CREATE TRIGGER z_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I '
    'FOR EACH ROW EXECUTE FUNCTION audit.fn_row_audit(%s)', p_schema, p_table, v_args);
END;
$$;

COMMENT ON FUNCTION audit.attach(name, name, text[]) IS
  'Attach the audit trigger to a table. Later migrations should call this for every table they '
  'create that holds tenant data — audit.v_unaudited_tenant_tables lists the ones that forgot.';


-- ---- 5.7 APP-REPORTED READS ------------------------------------------------------------------
-- Everything in §5.1 (c) made concrete.

CREATE OR REPLACE FUNCTION audit.log_read(
    p_table      name,
    p_row_id     uuid          DEFAULT NULL,
    p_patient_id uuid          DEFAULT NULL,
    p_purpose    audit.purpose DEFAULT NULL,
    p_action     audit.action  DEFAULT 'read',
    p_detail     jsonb         DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_vendor boolean := app.is_super_admin();
BEGIN
  IF p_action NOT IN ('read', 'export') THEN
    RAISE EXCEPTION 'audit.log_read records reads and exports, not %.', p_action
      USING errcode = '22023';
  END IF;

  INSERT INTO audit.event (
      actor_app_user_id, actor_auth_uid, actor_org_id, actor_roles, acting_role,
      actor_is_vendor, support_session_id,
      action, severity, purpose, table_schema, table_name, row_id,
      organization_id, patient_id, detail,
      request_id, client_ip, user_agent, route)
  VALUES (
      app.current_user_id(), app.current_auth_uid(), app.current_org_id(), app.current_roles(),
      audit.acting_role(), v_vendor, app.current_support_session_id(),
      p_action,
      CASE WHEN v_vendor THEN 'alert'
           WHEN p_action = 'export' THEN 'sensitive'
           WHEN p_patient_id IS NOT NULL THEN 'sensitive'
           ELSE 'normal' END,
      coalesce(p_purpose, audit.ctx('purpose')::audit.purpose),
      'public', p_table, p_row_id,
      app.current_org_id(), p_patient_id, p_detail,
      audit.ctx('request_id')::uuid, audit.ctx('client_ip')::inet,
      audit.ctx('user_agent'), audit.ctx('route'));
END;
$$;

COMMENT ON FUNCTION audit.log_read(name, uuid, uuid, audit.purpose, audit.action, jsonb) IS
  'App-reported read. organization_id is taken from app.current_org_id(), never from an '
  'argument, so a caller cannot attribute their read to somebody else''s tenant. A malicious '
  'client can log reads that did not happen (noise) but cannot suppress the ones it does '
  'report, and every row names its actor — so the failure mode is attributable spam, not '
  'concealment.';

-- The chart-open path, written so that the read is CHECKED before it is logged. SECURITY
-- INVOKER on purpose: the SELECT below is subject to public.patient's RLS, so a caller who
-- cannot see the chart gets an exception instead of an audit row claiming they opened it.
CREATE OR REPLACE FUNCTION app.log_chart_open(p_patient_id uuid)
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT p.organization_id INTO v_org
    FROM public.patient p WHERE p.id = p_patient_id;

  IF v_org IS NULL THEN
    RAISE EXCEPTION 'No such patient in your organisation.' USING errcode = '42501';
  END IF;

  PERFORM audit.log_read(
    'patient', p_patient_id, p_patient_id,
    CASE WHEN app.is_clinician()        THEN 'treatment'::audit.purpose
         WHEN app.is_front_desk()       THEN 'front_desk'
         WHEN p_patient_id = app.current_patient_id() THEN 'patient_self'
         ELSE NULL END);
END;
$$;

COMMENT ON FUNCTION app.log_chart_open(uuid) IS
  'Call this when a chart, prognosis report or results page is opened. The application MUST '
  'call it: no database mechanism can. See §5.1.';


-- ---- 5.8 THE VIEWS SOMEONE IS ACTUALLY MEANT TO READ -----------------------------------------

-- security_invoker on all three: PostgreSQL views default to running as their OWNER, and a
-- view over the audit trail that runs as its owner is one ALTER away from being a way around
-- the policy below. Being explicit costs nothing and removes the question.
--
-- The alert this whole design exists to make unmissable.
CREATE OR REPLACE VIEW audit.v_cross_tenant_access
WITH (security_invoker = true) AS
SELECT e.occurred_at,
       e.actor_app_user_id,
       e.actor_is_vendor,
       e.actor_org_id,
       e.organization_id AS target_organization_id,
       e.action,
       e.table_name,
       e.row_id,
       e.patient_id,
       e.support_session_id IS NOT NULL AS explained_by_support_session,
       e.request_id,
       e.client_ip
  FROM audit.event e
 WHERE e.organization_id IS NOT NULL
   AND e.actor_org_id IS DISTINCT FROM e.organization_id
 ORDER BY e.occurred_at DESC;

COMMENT ON VIEW audit.v_cross_tenant_access IS
  'Every event where the actor''s organisation differs from the affected row''s. For an '
  'ordinary user this view should be EMPTY — 010''s policies make it structurally impossible. '
  'Vendor rows appear here by design: raising an entitlement or opening a support session is '
  'legitimate cross-tenant work. What is worth a human''s attention is a row where '
  'explained_by_support_session is false and the table is not commercial metadata.';

CREATE OR REPLACE VIEW audit.v_alerts
WITH (security_invoker = true) AS
SELECT * FROM audit.event WHERE severity = 'alert' ORDER BY occurred_at DESC;

-- Whether the application is actually holding up its half of §5.1.
CREATE OR REPLACE VIEW audit.v_read_coverage
WITH (security_invoker = true) AS
SELECT e.table_name,
       count(*)                                        AS reads_reported,
       count(DISTINCT e.actor_app_user_id)             AS distinct_actors,
       max(e.occurred_at)                              AS last_reported
  FROM audit.event e
 WHERE e.action IN ('read', 'export')
 GROUP BY e.table_name
 ORDER BY max(e.occurred_at) DESC;

COMMENT ON VIEW audit.v_read_coverage IS
  'What the app has actually reported reading. A clinical table missing from this list is not '
  'evidence that nobody read it — it is evidence that nobody is reporting it. That distinction '
  'is the honest limit of database-side read auditing.';

-- Tenant tables nobody remembered to audit. The sibling of app.v_tenant_rls_gaps.
CREATE OR REPLACE VIEW audit.v_unaudited_tenant_tables AS
SELECT n.nspname AS schema_name, c.relname AS table_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'organization_id'
                     AND a.attnum > 0 AND NOT a.attisdropped
 WHERE n.nspname = 'public'
   AND c.relkind = 'r'
   -- Derived aggregates are exempt: they hold no personal data, they are rewritten every day
   -- by a scheduled job, and auditing them would bury the events that matter under a daily
   -- flood of counter updates. Their integrity question is "does the collector agree with the
   -- source", which a trigger cannot answer anyway.
   AND c.relname <> 'organization_usage_daily'
   AND NOT EXISTS (SELECT 1 FROM pg_trigger t
                    WHERE t.tgrelid = c.oid AND t.tgname = 'z_audit' AND NOT t.tgisinternal);

-- "Who has touched this patient's record?" — the question a patient is entitled to ask, and
-- the one an incident review starts from. SECURITY INVOKER: audit.event's own policy decides
-- whether the caller may see any of it.
CREATE OR REPLACE FUNCTION audit.patient_access_history(
    p_patient_id uuid,
    p_since      timestamptz DEFAULT now() - interval '90 days')
RETURNS TABLE (occurred_at timestamptz, action audit.action, table_name name,
               actor_app_user_id uuid, acting_role app.org_role, purpose audit.purpose)
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT e.occurred_at, e.action, e.table_name, e.actor_app_user_id, e.acting_role, e.purpose
    FROM audit.event e
   WHERE e.patient_id = p_patient_id
     AND e.occurred_at >= p_since
   ORDER BY e.occurred_at DESC;
$$;


-- =============================================================================================
-- SECTION 6 — ROW LEVEL SECURITY
--
-- Read every policy as: TENANT first, then role, then row. Two decisions are worth stating
-- before the SQL rather than defending afterwards.
--
--   1. hospital_admin GETS NO INVOICE ROWS. It is the least obvious call in this file. A
--      hospital's own administrator plausibly wants a revenue view — but an invoice names a
--      patient, and its lines say "CT scan, chest". Granting it would hand every customer
--      admin a patient list and a rough diagnosis for each, which is exactly the standing
--      access 010 refused when it wrote "administering a hospital is not a treatment purpose".
--      What a hospital_admin gets instead is organization_usage_daily: counts, no names. If
--      the customer genuinely needs a finance desk, the right fix is a `billing_clerk` value in
--      app.org_role — a deliberate act in a later migration, not a quiet widening here.
--
--   2. THE VENDOR APPEARS IN EXACTLY TWO PLACES. app.is_super_admin() is written into the
--      policies for organization_usage_daily and usage_metric, and nowhere else in this file.
--      Configuration tables (department, payer, org_setting) use app.support_org_id() instead —
--      one named tenant, time-boxed, visible to that customer, which is 010's tier 2. Financial
--      and personal tables (patient_coverage, invoice, invoice_line, payment) grant the vendor
--      nothing at all, and §10 asserts it.
-- =============================================================================================

ALTER TABLE public.department               ENABLE ROW LEVEL SECURITY;  -- already on from 020
ALTER TABLE public.org_setting              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payer                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_coverage         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_line             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usage_metric             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organization_usage_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.redacted_column           ENABLE ROW LEVEL SECURITY;
-- ENABLE, never FORCE, on everything above: 010 §8.1 explains why FORCE plus SECURITY DEFINER
-- helpers is an infinite recursion waiting for the worst possible moment. audit.event is the
-- one exception and §5.4 argues it.

-- ---- department: 020 owns the base policies; this file only adds the vendor door -------------
-- 020 already grants SELECT to everyone in the tenant (the portal's booking flow shows
-- "Radiology · CT") and INSERT/UPDATE to hospital_admin. Those policies are NOT redefined here:
-- two files taking turns rewriting the same policy name means the effective rule depends on
-- which migration ran last, which is not a thing anyone should have to reason about.
--
-- What this file adds is one ADDITIONAL PERMISSIVE policy — permissive policies OR together —
-- so a vendor operator with an open support session can read a customer's department list while
-- diagnosing a scheduling complaint. That is 010's tier 2: one named tenant, time-boxed,
-- visible to the customer in public.support_session. Note it is app.support_org_id() and never
-- app.is_super_admin(): there is no standing vendor read here.
DROP POLICY IF EXISTS department_select_support ON public.department;
CREATE POLICY department_select_support ON public.department FOR SELECT
  USING (organization_id = app.support_org_id());

DO $department_policy_check$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                  WHERE schemaname = 'public' AND tablename = 'department'
                    AND policyname = 'department_select') THEN
    RAISE EXCEPTION 'public.department has no department_select policy; 020 must run first.'
      USING errcode = '42501';
  END IF;
END
$department_policy_check$;

-- ---- org_setting: hospital defaults are shared, personal rows are private --------------------
DROP POLICY IF EXISTS org_setting_select ON public.org_setting;
CREATE POLICY org_setting_select ON public.org_setting FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (member_id IS NULL
              OR member_id = app.current_member_id()
              OR app.is_hospital_admin()));

DROP POLICY IF EXISTS org_setting_write_admin ON public.org_setting;
CREATE POLICY org_setting_write_admin ON public.org_setting FOR ALL
  USING (organization_id = app.current_org_id() AND member_id IS NULL AND app.is_hospital_admin())
  WITH CHECK (organization_id = app.current_org_id() AND member_id IS NULL AND app.is_hospital_admin());

-- Anyone may write their OWN preferences — that is the whole Settings screen. member_id is
-- pinned to app.current_member_id() in both USING and WITH CHECK, so this cannot be used to
-- write a preference onto somebody else's account.
DROP POLICY IF EXISTS org_setting_write_self ON public.org_setting;
CREATE POLICY org_setting_write_self ON public.org_setting FOR ALL
  USING (organization_id = app.current_org_id() AND member_id = app.current_member_id())
  WITH CHECK (organization_id = app.current_org_id() AND member_id = app.current_member_id());

-- ---- payer: billing configuration -------------------------------------------------------------
DROP POLICY IF EXISTS payer_select ON public.payer;
CREATE POLICY payer_select ON public.payer FOR SELECT
  USING ((organization_id = app.current_org_id()
          AND (app.is_front_desk() OR app.is_clinician() OR app.is_hospital_admin()))
         OR organization_id = app.support_org_id());

DROP POLICY IF EXISTS payer_write ON public.payer;
CREATE POLICY payer_write ON public.payer FOR INSERT
  WITH CHECK (organization_id = app.current_org_id()
              AND (app.is_hospital_admin() OR app.is_front_desk()));

DROP POLICY IF EXISTS payer_update ON public.payer;
CREATE POLICY payer_update ON public.payer FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR app.is_front_desk()))
  WITH CHECK (organization_id = app.current_org_id());

-- ---- patient_coverage: personal financial data ------------------------------------------------
-- Same shape as 010's patient policy, and for the same reason. No vendor clause of any kind:
-- an insurance member number is a credential, and no support workflow needs one.
DROP POLICY IF EXISTS patient_coverage_select ON public.patient_coverage;
CREATE POLICY patient_coverage_select ON public.patient_coverage FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (app.is_front_desk() OR app.is_clinician() OR patient_id = app.current_patient_id()));

DROP POLICY IF EXISTS patient_coverage_insert ON public.patient_coverage;
CREATE POLICY patient_coverage_insert ON public.patient_coverage FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_front_desk());

DROP POLICY IF EXISTS patient_coverage_update ON public.patient_coverage;
CREATE POLICY patient_coverage_update ON public.patient_coverage FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_front_desk())
  WITH CHECK (organization_id = app.current_org_id());
-- No DELETE policy, plus app.deny_hard_delete(): a lapsed policy is is_active = false, so the
-- bill raised while it was live still explains itself years later.

-- ---- invoice: the front desk's worklist, and the patient's own bill ---------------------------
DROP POLICY IF EXISTS invoice_select ON public.invoice;
CREATE POLICY invoice_select ON public.invoice FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (app.is_front_desk() OR patient_id = app.current_patient_id()));

DROP POLICY IF EXISTS invoice_insert ON public.invoice;
CREATE POLICY invoice_insert ON public.invoice FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_front_desk());

DROP POLICY IF EXISTS invoice_update ON public.invoice;
CREATE POLICY invoice_update ON public.invoice FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_front_desk())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_front_desk());

COMMENT ON POLICY invoice_select ON public.invoice IS
  'Front desk, plus the patient reading their own bill. A patient''s access to their own '
  'financial record is ordinary good practice and, under the DPDP Act, likely a right rather '
  'than a courtesy — it costs one clause here and would cost a support process otherwise. '
  'Clinicians are absent: treating someone is not a reason to see what they were charged.';

-- ---- invoice_line: the clinically revealing half ----------------------------------------------
-- Narrower than the header on purpose. "CT scan, chest" is a diagnosis-shaped fact.
DROP POLICY IF EXISTS invoice_line_select ON public.invoice_line;
CREATE POLICY invoice_line_select ON public.invoice_line FOR SELECT
  USING (organization_id = app.current_org_id()
         AND EXISTS (SELECT 1 FROM public.invoice i
                      WHERE i.id = invoice_line.invoice_id
                        AND (app.is_front_desk() OR i.patient_id = app.current_patient_id())));

DROP POLICY IF EXISTS invoice_line_write ON public.invoice_line;
CREATE POLICY invoice_line_write ON public.invoice_line FOR ALL
  USING (organization_id = app.current_org_id() AND app.is_front_desk())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_front_desk());
-- The FOR ALL above includes DELETE, but app.guard_invoice_line_immutable() refuses it on any
-- invoice that has left draft — so a mistyped draft line can be removed and an issued one
-- cannot. That is the amendment rule applied where it belongs.

-- ---- payment -----------------------------------------------------------------------------------
DROP POLICY IF EXISTS payment_select ON public.payment;
CREATE POLICY payment_select ON public.payment FOR SELECT
  USING (organization_id = app.current_org_id()
         AND EXISTS (SELECT 1 FROM public.invoice i
                      WHERE i.id = payment.invoice_id
                        AND (app.is_front_desk() OR i.patient_id = app.current_patient_id())));

DROP POLICY IF EXISTS payment_insert ON public.payment;
CREATE POLICY payment_insert ON public.payment FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_front_desk());
-- Deliberately no UPDATE and no DELETE policy. A payment is a fact about money that changed
-- hands; correcting it means inserting a reversal, which leaves both rows visible.

-- ---- vendor-readable aggregates ----------------------------------------------------------------
DROP POLICY IF EXISTS usage_metric_select ON public.usage_metric;
CREATE POLICY usage_metric_select ON public.usage_metric FOR SELECT
  USING (app.current_user_id() IS NOT NULL);
DROP POLICY IF EXISTS usage_metric_write ON public.usage_metric;
CREATE POLICY usage_metric_write ON public.usage_metric FOR ALL
  USING (app.is_super_admin()) WITH CHECK (app.is_super_admin());

DROP POLICY IF EXISTS organization_usage_daily_select ON public.organization_usage_daily;
CREATE POLICY organization_usage_daily_select ON public.organization_usage_daily FOR SELECT
  USING ((organization_id = app.current_org_id() AND app.is_hospital_admin())
         OR app.is_super_admin());

COMMENT ON POLICY organization_usage_daily_select ON public.organization_usage_daily IS
  'The one deliberate cross-tenant read grant in this file. It is safe because of the table''s '
  'shape, not because of this policy: every column is a tenant id, a date, a registered metric '
  'key or a bigint. There is no INSERT or UPDATE policy at all — app.record_usage() is the only '
  'writer, and it is granted to service_role alone.';

-- ---- audit.redacted_column ----------------------------------------------------------------------
-- Readable so anyone can verify what is withheld from the trail; writable by nobody through the
-- API, because "which values never get recorded" is a migration-level decision.
DROP POLICY IF EXISTS redacted_column_select ON audit.redacted_column;
CREATE POLICY redacted_column_select ON audit.redacted_column FOR SELECT
  USING (app.current_user_id() IS NOT NULL);

-- ---- audit.event -----------------------------------------------------------------------------
-- Reading the trail is itself a privileged act: it contains changed clinical and financial
-- values. Four narrow doors, no wide one.
DROP POLICY IF EXISTS event_insert ON audit.event;
CREATE POLICY event_insert ON audit.event FOR INSERT WITH CHECK (true);
-- Unrestricted INSERT is not a hole: no application role holds the INSERT privilege (§9), so
-- the only writers are the SECURITY DEFINER functions above, which fill in the actor
-- themselves. The policy exists so that FORCE RLS does not block them.

DROP POLICY IF EXISTS event_select ON audit.event;
CREATE POLICY event_select ON audit.event FOR SELECT
  USING (
    -- 1. the customer's own accountable person, for their own hospital
    (organization_id = app.current_org_id() AND app.is_hospital_admin())
    -- 2. anyone, for their own actions ("what have I done") — no other tenant's data can
    --    appear in a row whose actor is you
    OR actor_app_user_id = app.current_user_id()
    -- 3. a patient, for events about themselves
    OR (organization_id = app.current_org_id() AND patient_id = app.current_patient_id())
  );

COMMENT ON POLICY event_select ON audit.event IS
  'Note who is NOT here: app.is_super_admin(). The vendor cannot read a tenant''s audit trail, '
  'because the trail carries the clinical and financial values that 010 spent §7 keeping away '
  'from them — and a compromised vendor account reading every hospital''s trail would be a '
  'worse breach than reading one hospital''s charts. Clause 2 still lets a vendor see their '
  'OWN actions, which is what an operator actually needs. A hospital_admin does see their own '
  'hospital''s trail: they are the customer''s accountable person, and audit.redacted_column '
  'is the control that limits which values appear there.';
-- No UPDATE policy and no DELETE policy anywhere. That is lock 2 of §5.4.


-- =============================================================================================
-- SECTION 7 — SEED: the metric registry
-- Only metrics the vendor dashboard actually renders. 020/030 add their own rows.
-- =============================================================================================

INSERT INTO public.usage_metric (key, name, description, unit) VALUES
  ('staff_seats_used',  'Staff seats used',    'Active or invited non-patient members.',        'count'),
  ('patients_active',   'Active patients',     'Patient records with status = active.',          'count'),
  ('invoices_created',  'Invoices created',    'Invoices raised on the day.',                    'count'),
  ('audit_events',      'Audit events',        'Rows written to the audit trail on the day.',    'count'),
  ('active_users',      'Active users',        'Distinct people who did anything on the day — the liveness signal.', 'count'),
  ('appointments',      'Appointments',        'Booked on the day. Written once 020 exists.',    'count'),
  ('encounters',        'Encounters',          'Opened on the day. Written once 020 exists.',    'count'),
  ('ai_reports',        'AI reports',          'Model calls recorded in ai_analysis_run on the day.', 'count'),
  ('documents',         'Documents',           'Files stored on the day.',                       'count')
ON CONFLICT (key) DO NOTHING;


-- =============================================================================================
-- SECTION 8 — ATTACH THE AUDIT TRIGGERS
--
-- The list is the security boundary made explicit. Two groups: 010's identity and commercial
-- tables (because privilege changes are the events that matter most), and this file's own.
-- Clinical tables from 020/030 are attached with the same call and skipped with a NOTICE if
-- they do not exist yet — those migrations must call audit.attach() for whatever they create.
--
-- The second argument names the columns whose change raises severity to 'alert'.
-- =============================================================================================

DO $attach$
BEGIN
  -- ---- identity and privilege (010) ----------------------------------------------------------
  PERFORM audit.attach('public', 'organization_member',      ARRAY['roles', 'status']);
  PERFORM audit.attach('public', 'app_user',                 ARRAY['status', 'email']);
  PERFORM audit.attach('public', 'platform_admin',           ARRAY['revoked_at']);
  PERFORM audit.attach('public', 'support_session',          ARRAY['approved_at', 'revoked_at']);
  PERFORM audit.attach('public', 'organization',             ARRAY['status', 'plan_id']);
  PERFORM audit.attach('public', 'organization_entitlement', ARRAY['enabled', 'limit_value']);
  PERFORM audit.attach('public', 'patient',                  ARRAY['status', 'merged_into_patient_id']);

  -- ---- admin and billing (this file) ---------------------------------------------------------
  PERFORM audit.attach('public', 'department');
  PERFORM audit.attach('public', 'org_setting');
  PERFORM audit.attach('public', 'payer');
  PERFORM audit.attach('public', 'patient_coverage',         ARRAY['member_number', 'is_active']);
  PERFORM audit.attach('public', 'invoice',                  ARRAY['status', 'total_minor',
                                                                   'patient_due_minor', 'void_reason']);
  PERFORM audit.attach('public', 'invoice_line');
  PERFORM audit.attach('public', 'payment');

  -- ---- clinical (020) ---------------------------------------------------------------------------
  -- CORRECTED CROSS-FILE NAMES. An earlier pass attached to 'observation', 'medication' and
  -- 'ai_report' — three tables no migration in this directory creates. audit.attach() skips a
  -- missing table with a NOTICE rather than failing, so the result was three unaudited clinical
  -- tables and three notices nobody read. The names below are the ones 020 and 030 actually use;
  -- audit.v_unaudited_tenant_tables is the standing check that they stay right.
  PERFORM audit.attach('public', 'visit_type');
  PERFORM audit.attach('public', 'staff_profile',            ARRAY['department_id']);
  PERFORM audit.attach('public', 'patient_condition',        ARRAY['is_primary', 'record_status']);
  PERFORM audit.attach('public', 'patient_allergy',          ARRAY['substance', 'inactivated_at']);
  -- Care-team membership IS the chart-access grant in 020, so a change to it is a privilege
  -- change and deserves the same severity as a role edit.
  PERFORM audit.attach('public', 'care_team_member',         ARRAY['member_id', 'ended_at']);
  PERFORM audit.attach('public', 'encounter',                ARRAY['status', 'record_status']);
  PERFORM audit.attach('public', 'appointment',              ARRAY['status']);
  PERFORM audit.attach('public', 'vital_sign',               ARRAY['record_status']);
  PERFORM audit.attach('public', 'lab_panel');
  PERFORM audit.attach('public', 'lab_test',                 ARRAY['reference_low', 'reference_high',
                                                                   'critical_low', 'critical_high']);
  PERFORM audit.attach('public', 'lab_order',                ARRAY['status']);
  PERFORM audit.attach('public', 'lab_result',               ARRAY['review_status',
                                                                   'released_to_patient_at',
                                                                   'record_status']);
  PERFORM audit.attach('public', 'clinical_note',            ARRAY['signed_at', 'record_status']);
  PERFORM audit.attach('public', 'medication_order',         ARRAY['status']);

  -- ---- documents and AI (030) -------------------------------------------------------------------
  -- doc_type is an alert column because reclassification is what the radiology-image safety gate
  -- reads; patient_visible and the review columns are how AI output reaches a chart or a phone.
  PERFORM audit.attach('public', 'document',                 ARRAY['doc_type', 'patient_visible',
                                                                   'scan_status', 'retracted_at']);
  PERFORM audit.attach('public', 'document_text');
  PERFORM audit.attach('public', 'ai_analysis_run');
  PERFORM audit.attach('public', 'ai_finding',               ARRAY['review_state', 'patient_visible',
                                                                   'chart_committed_at']);
  PERFORM audit.attach('public', 'ai_risk_score');
  PERFORM audit.attach('public', 'ai_risk_factor');
  PERFORM audit.attach('public', 'ai_citation');
  -- Optional (030 §11, created only when pgvector is available). Skipped with a NOTICE if absent.
  PERFORM audit.attach('public', 'document_text_chunk');
END
$attach$;

-- A DELETE event will appear in the trail only when someone deliberately sets
-- app.allow_hard_delete for one transaction — every other attempt is refused by 010's
-- app.deny_hard_delete() BEFORE the audit trigger would ever fire. That is the right order:
-- the refusal is the record.


-- =============================================================================================
-- SECTION 9 — GRANTS
-- >>> BEGIN SUPABASE-SPECIFIC: role names are the PostgREST convention <<<
-- =============================================================================================

DO $grants$
BEGIN
  EXECUTE 'REVOKE ALL ON audit.event FROM PUBLIC';
  EXECUTE 'REVOKE ALL ON audit.redacted_column FROM PUBLIC';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA audit TO authenticated';

    EXECUTE 'GRANT SELECT ON public.org_setting, public.payer, public.usage_metric,
                              public.organization_usage_daily
             TO authenticated';
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON public.department, public.org_setting,
                                             public.payer, public.patient_coverage,
                                             public.invoice, public.invoice_line, public.payment
             TO authenticated';
    EXECUTE 'GRANT DELETE ON public.org_setting, public.invoice_line TO authenticated';

    -- Read-only on the trail, and read-only is the whole point.
    EXECUTE 'GRANT SELECT ON audit.event, audit.redacted_column TO authenticated';
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON audit.event FROM authenticated';

    EXECUTE 'GRANT SELECT ON app.v_invoice_balance, app.v_tenant_health,
                              audit.v_cross_tenant_access, audit.v_alerts,
                              audit.v_read_coverage, audit.v_unaudited_tenant_tables
             TO authenticated';

    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.setting(text), app.org_feature_limit(uuid, text),
               app.log_chart_open(uuid),
               audit.set_request_context(uuid, inet, text, text, audit.purpose, app.org_role),
               audit.ctx(text), audit.acting_role(),
               audit.log_read(name, uuid, uuid, audit.purpose, audit.action, jsonb),
               audit.patient_access_history(uuid, timestamptz)
             TO authenticated';

    -- Trigger and constraint helpers, for symmetry with 010 §11.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.guard_invoice_line_immutable(), app.enforce_staff_seat_limit(),
               audit.fn_row_audit(), audit.deny_mutation(),
               audit.redact(jsonb, name, name)
             TO authenticated';

    -- NOT granted, deliberately: app.record_usage() and app.refresh_organization_usage().
    -- Both are SECURITY DEFINER and write the table the vendor dashboard trusts. A session
    -- that could call them could invent its own usage figures.
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA audit TO service_role';
    EXECUTE 'GRANT SELECT, INSERT ON audit.event TO service_role';
    EXECUTE 'REVOKE UPDATE, DELETE, TRUNCATE ON audit.event FROM service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.record_usage(uuid, text, bigint, date),
               app.refresh_organization_usage(date),
               audit.ensure_partitions(integer),
               audit.drop_partitions_before(date, boolean)
             TO service_role';
    -- service_role holds BYPASSRLS, so the REVOKE above is what actually keeps the trail
    -- append-only against a compromised worker. Privileges are checked even for BYPASSRLS
    -- roles; policies are not. This line matters more than it looks.
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon';
    EXECUTE 'REVOKE ALL ON SCHEMA audit FROM anon';
  END IF;
END
$grants$;
-- >>> END SUPABASE-SPECIFIC <<< ----------------------------------------------------------------


-- =============================================================================================
-- SECTION 10 — SELF-CHECK
-- Run in CI. Every one of these has caught a real class of mistake somewhere.
-- =============================================================================================

DO $selfcheck$
DECLARE v_bad text;
BEGIN
  -- 1. 010's gate: no clinical or financial table may grant the vendor blanket access.
  PERFORM app.assert_no_vendor_phi_policies(
    ARRAY['patient_coverage', 'invoice', 'invoice_line', 'payment', 'org_setting',
          'department', 'payer']);

  -- 2. Every table carrying organization_id must have RLS on.
  SELECT string_agg(format('%s.%s', schema_name, table_name), ', ')
    INTO v_bad FROM app.v_tenant_rls_gaps;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tenant tables without RLS: %', v_bad USING errcode = '42501';
  END IF;

  -- 3. Every tenant table must be audited (aggregates excepted, see the view).
  SELECT string_agg(format('%s.%s', schema_name, table_name), ', ')
    INTO v_bad FROM audit.v_unaudited_tenant_tables;
  IF v_bad IS NOT NULL THEN
    RAISE WARNING 'prognosify/040: tenant tables with no audit trigger: %. '
                  'Call audit.attach() for each in the migration that creates it.', v_bad;
  END IF;

  -- 4. The audit trail must have no UPDATE or DELETE policy. This is the lock most likely to
  --    be undone later by someone "fixing" a typo in an old event.
  SELECT string_agg(policyname, ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'audit' AND tablename = 'event' AND cmd IN ('UPDATE', 'DELETE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'audit.event has mutation policies (%) — it is meant to be append-only.',
                    v_bad USING errcode = '42501';
  END IF;

  RAISE NOTICE 'prognosify/040: admin, billing and audit layer installed; self-checks passed.';
END
$selfcheck$;


-- =============================================================================================
-- OPEN QUESTIONS — decisions deferred, not overlooked
--
-- 1. CURRENCY IN THE UI. Every amount in the prototype is rendered with '$' (Billing shows
--    "$4,210" and "$1,140"). This schema defaults to INR because the operator is in India. One
--    of the two is wrong and it is a product decision, not a schema one. The database is ready
--    for either: currency is per-invoice, not global.
--
-- 2. INVOICE STATUS vs BALANCE. status is set by the front desk; balance is computed in
--    app.v_invoice_balance. They can disagree — an invoice marked copay_due with a zero
--    balance, or one marked paid with money outstanding. A trigger could force the transition,
--    but it would also overrule a receptionist who has a reason. Recommendation: leave it
--    manual, and put "status disagrees with balance" on the Billing screen as a worklist filter.
--
-- 3. INVOICE NUMBERING is left to the app, exactly as 010 left MRN. Two receptionists issuing
--    an invoice in the same second will collide on invoice_number_uk; the app must retry. A
--    per-tenant sequence would fix it and needs a format decision first.
--
-- 4. NO FINANCE ROLE. hospital_admin deliberately cannot read invoices (§6). If a customer
--    needs a billing manager who is not a receptionist, the fix is a new value in
--    app.org_role — which is an ALTER TYPE on 010's enum and therefore 010's decision to make,
--    not a policy widening here.
--
-- 5. READ AUDITING IS APP-DEPENDENT. §5.1 is explicit about it. The two things that would
--    close the gap are a product decision (route reads through RPCs and revoke direct SELECT)
--    and an ops decision (pgaudit for statement-level forensics). Until one of them happens,
--    audit.v_read_coverage is the honest measure of how much is actually being reported.
--
-- 6. VENDOR SUBSCRIPTION BILLING IS NOT MODELLED. public.invoice is the hospital billing its
--    patients. What the vendor charges each hospital lives in whatever billing system the
--    business uses (Razorpay, Stripe, a spreadsheet), and inventing tables for it here would
--    have been modelling a screen nobody has designed. subscription_plan and
--    organization_entitlement already carry what the product needs to gate features.
--
-- 7. ALERT FATIGUE IS THE REAL RISK IN §5.8. Every vendor write to a tenant-scoped row raises
--    an alert, which is correct and will also be routine. Before go-live someone should decide
--    what routes audit.v_alerts to a human, and at what point "the vendor changed an
--    entitlement" stops being worth waking anyone up. An alert feed nobody reads is worse than
--    none, because it looks like a control.
--
-- 8. NOT EXECUTED. There is no PostgreSQL, psql or docker on the machine this was written on,
--    so this file has been reviewed statically — dollar-quote tags balanced, every app.* call
--    resolving to a definition in 010, no forward references outside plpgsql bodies — but it
--    has NOT been run. Run it once against a scratch database, with 010 loaded and 001-004
--    removed, before trusting any of it.
-- =============================================================================================
