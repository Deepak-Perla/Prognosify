-- =============================================================================================
-- 020_clinical.sql — Prognosify core clinical model (multi-tenant)
-- PostgreSQL 15+ / Supabase (ap-south-1). Idempotent: safe to re-run. Requires 010 first.
--
-- WHAT THIS FILE OWNS
--   departments and visit types · staff practice profile · care teams · encounters/admissions
--   appointments and the front-desk queue · vitals · lab catalogue, orders and results
--   clinical notes (the Timeline) · medication orders
--
-- WHAT IT DOES NOT OWN (deliberately, so the boundaries stay reviewable)
--   * organisations, membership, roles, the session helper API and public.patient — 010.
--     This file NEVER redefines them; it references them and calls app.* helpers.
--   * documents/binaries, AI scores, prognosis reports, the "AI note" column on the Labs
--     screen, no-show risk, messages, care plans, billing — 030.
--   * the audit trail — 040. Every table here carries created_by/updated_by member ids and
--     an amendment path so 040 has something truthful to attach to.
--
-- CONSOLIDATION NOTE (this file replaces 001_core_clinical.sql)
--   001 modelled 27 clinical tables in 122 KB. This one models 15 in a fraction of that. Each
--   survivor names the screen it serves; the notes marked "NOT MODELLED" say what was dropped
--   and why, because a reviewer needs to see the omissions as clearly as the inclusions. A
--   schema guarding health records is only as safe as the last person who read all of it.
--
-- THE ACCESS MODEL IN ONE PARAGRAPH (the policies and their reasoning are §33)
--   Tenant first: every table carries organization_id and every policy opens with
--   `organization_id = app.current_org_id()`, which is NULL for a vendor admin and therefore
--   returns them nothing. Purpose second: the patient INDEX (010's public.patient) stays
--   findable by clinical and front-desk staff, while the CHART — everything in this file — is
--   care-team-scoped. Reception gets scheduling and administrative demographics and no
--   clinical rows at all; hospital_admin gets configuration and no chart; a patient gets their
--   own rows, and only what has been released to them.
--
-- COMPLIANCE POSTURE (unchanged from 010, and equally modest)
--   The operator is in India: the governing regime is the DPDP Act 2023, not HIPAA. Nothing
--   here is a certification claim. Retention periods, the lawful basis for keeping amended
--   clinical history, and what "erasure" means for a medical record are questions for counsel;
--   the schema makes deliberate erasure possible (§4 of 010) rather than deciding the policy.
-- =============================================================================================


-- =============================================================================================
-- SECTION 20 — PRECONDITIONS
--
-- Fail early and loudly rather than half-applying a clinical schema onto the wrong foundation.
-- =============================================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('app.current_org_id()') IS NULL THEN
    RAISE EXCEPTION '010_tenancy_identity.sql has not been applied: app.current_org_id() is missing.'
      USING hint = 'Run 010 first. 001-004 are the single-tenant drafts and must NOT be in the path.';
  END IF;

  IF to_regclass('public.patient') IS NULL THEN
    RAISE EXCEPTION 'public.patient is missing; 010 owns it and this file will not create it.';
  END IF;

  -- The single most likely way to break the build (010's own open question #1): the drafts
  -- define app.has_role(text), which becomes an overload of 010's app.has_role(app.org_role)
  -- and makes every `app.has_role('doctor')` in every policy ambiguous.
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'app' AND p.proname = 'has_role') > 1 THEN
    RAISE EXCEPTION 'app.has_role() is overloaded — the 001-004 drafts are still installed.'
      USING hint = 'Drop the draft objects; `app.has_role(''doctor'')` cannot resolve while both exist.';
  END IF;
END
$preflight$;

-- ---------------------------------------------------------------------------------------------
-- MRN UNIQUENESS IS PER ORGANISATION. This is the constraint the brief singled out, so this
-- file asserts it rather than assuming it.
--
-- Two hospitals can both legitimately issue "104-882": each registration desk allocates from
-- its own number space and no authority coordinates them. A GLOBAL unique index would reject a
-- lawful registration at hospital B because hospital A got there first — and the rejection
-- itself would leak the existence of another tenant's patient, a cross-tenant disclosure with
-- no query and no policy involved. It would also make MRN look like a global key, which is how
-- a join eventually gets written without organization_id in it.
-- 010 declares it correctly as UNIQUE (organization_id, upper(mrn)) — upper() so "104-882a"
-- and "104-882A" cannot coexist inside one hospital. This block fails the migration if anyone
-- ever "fixes" that index into a global one.
-- ---------------------------------------------------------------------------------------------
DO $mrn_guard$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_indexdef(i.indexrelid)
    INTO v_def
    FROM pg_index i
    JOIN pg_class c ON c.oid = i.indexrelid
   WHERE c.relname = 'patient_mrn_uk';

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'patient_mrn_uk is missing: MRN uniqueness is unenforced.';
  END IF;

  IF v_def !~ 'organization_id' THEN
    RAISE EXCEPTION 'patient_mrn_uk is not tenant-scoped: %', v_def
      USING hint = 'MRN must be unique per organisation, never globally. See §20 of 020_clinical.sql.';
  END IF;

  -- A GLOBAL index is one whose column list is EXACTLY (mrn) / (upper(mrn)). The earlier draft of
  -- this check only anchored the END of the definition, so it also matched the correct composite
  -- index — "(organization_id, upper(mrn))" ends in "mrn))" too — and failed every apply,
  -- including a pristine one. Anchoring on "USING btree (" makes the column list itself the match.
  IF EXISTS (SELECT 1 FROM pg_indexes
              WHERE schemaname = 'public' AND tablename = 'patient'
                AND indexdef ~* 'CREATE UNIQUE INDEX'
                AND indexdef ~* 'USING btree \((upper\(mrn\)|mrn)\)$') THEN
    RAISE EXCEPTION 'A GLOBAL unique index on patient.mrn exists. Drop it.'
      USING hint = 'It rejects lawful registrations and leaks the existence of other tenants'' patients.';
  END IF;
END
$mrn_guard$;


-- =============================================================================================
-- SECTION 21 — CLOSED VALUE SETS
--
-- All in schema `app` so they cannot collide with the public-schema types the 001-004 drafts
-- created. Anything genuinely open-ended (a dosing frequency, a room label, an allergy
-- reaction) stays text and says so — an enum over a set that is not actually closed just
-- moves the mess into a migration.
-- =============================================================================================

DO $types$
BEGIN
  -- Shared by every amendable clinical row. One type instead of the drafts' four near-copies.
  IF to_regtype('app.record_status') IS NULL THEN
    CREATE TYPE app.record_status AS ENUM ('active', 'amended', 'entered_in_error');
  END IF;

  IF to_regtype('app.encounter_class') IS NULL THEN
    CREATE TYPE app.encounter_class AS ENUM
      ('inpatient', 'outpatient', 'emergency', 'observation', 'virtual');
  END IF;

  IF to_regtype('app.encounter_status') IS NULL THEN
    CREATE TYPE app.encounter_status AS ENUM
      ('planned', 'in_progress', 'discharged', 'cancelled');
  END IF;

  -- EXACTLY the lifecycle the reception screens need. 'waiting' is the Check-in queue's
  -- "Waiting (7)" tab (arrived, not yet roomed) and 'done' is its "Done (18)" tab. The names
  -- match the UI on purpose: a status vocabulary that has to be translated in the frontend is
  -- a status vocabulary that will eventually be translated wrongly.
  IF to_regtype('app.appointment_status') IS NULL THEN
    CREATE TYPE app.appointment_status AS ENUM
      ('booked', 'waiting', 'in_room', 'done', 'cancelled', 'no_show');
  END IF;

  IF to_regtype('app.appointment_modality') IS NULL THEN
    CREATE TYPE app.appointment_modality AS ENUM ('in_person', 'video', 'phone');
  END IF;

  IF to_regtype('app.booking_origin') IS NULL THEN
    CREATE TYPE app.booking_origin AS ENUM ('scheduled', 'walk_in');
  END IF;

  IF to_regtype('app.care_team_role') IS NULL THEN
    CREATE TYPE app.care_team_role AS ENUM
      ('attending', 'resident', 'consulting', 'nurse', 'care_coordinator');
  END IF;

  IF to_regtype('app.condition_status') IS NULL THEN
    CREATE TYPE app.condition_status AS ENUM ('active', 'resolved', 'inactive');
  END IF;

  IF to_regtype('app.allergy_category') IS NULL THEN
    CREATE TYPE app.allergy_category AS ENUM ('medication', 'food', 'environment', 'other');
  END IF;

  IF to_regtype('app.allergy_severity') IS NULL THEN
    CREATE TYPE app.allergy_severity AS ENUM
      ('mild', 'moderate', 'severe', 'life_threatening', 'unknown');
  END IF;

  IF to_regtype('app.vital_source') IS NULL THEN
    CREATE TYPE app.vital_source AS ENUM ('clinician_measured', 'device', 'patient_reported');
  END IF;

  IF to_regtype('app.lab_priority') IS NULL THEN
    CREATE TYPE app.lab_priority AS ENUM ('routine', 'urgent', 'stat');
  END IF;

  IF to_regtype('app.lab_order_status') IS NULL THEN
    CREATE TYPE app.lab_order_status AS ENUM
      ('ordered', 'collected', 'in_progress', 'resulted', 'cancelled');
  END IF;

  -- The Labs screen's Flag pill: 'Critical ↑' is critical_high, 'Abnormal' is low/high,
  -- 'Normal' is normal.
  IF to_regtype('app.lab_abnormal_flag') IS NULL THEN
    CREATE TYPE app.lab_abnormal_flag AS ENUM
      ('normal', 'low', 'high', 'critical_low', 'critical_high', 'indeterminate');
  END IF;

  -- The All / Abnormal / Reviewed filter chips.
  IF to_regtype('app.lab_review_status') IS NULL THEN
    CREATE TYPE app.lab_review_status AS ENUM ('unreviewed', 'acknowledged', 'reviewed');
  END IF;

  IF to_regtype('app.note_type') IS NULL THEN
    CREATE TYPE app.note_type AS ENUM
      ('admission', 'progress', 'nursing', 'procedure', 'discharge', 'telephone');
  END IF;

  IF to_regtype('app.medication_route') IS NULL THEN
    CREATE TYPE app.medication_route AS ENUM
      ('oral', 'intravenous', 'intramuscular', 'subcutaneous', 'inhaled', 'topical',
       'rectal', 'ophthalmic', 'other');
  END IF;

  IF to_regtype('app.medication_status') IS NULL THEN
    CREATE TYPE app.medication_status AS ENUM
      ('active', 'on_hold', 'completed', 'discontinued');
  END IF;
END
$types$;


-- =============================================================================================
-- SECTION 22 — THE CARE-TEAM SCOPE PRIMITIVE
--
-- WHY AN ARRAY-RETURNING, ARGUMENT-FREE FUNCTION
--   Same reason 010's helpers take no arguments: Postgres folds a no-argument STABLE function
--   used in a policy into an InitPlan, so it runs ONCE PER STATEMENT. Listing a doctor's 42
--   patients costs one index probe of care_team_member, not 42. Writing the same rule as a
--   correlated EXISTS in every policy would re-evaluate per row and would also drag
--   care_team_member's own RLS into every clinical policy — an evaluation graph nobody wants
--   to reason about at 2am.
--   SECURITY DEFINER for the same mechanical reason as 010 §8.5: care_team_member has RLS, and
--   this function is what its neighbours' policies call. No arguments, no dynamic SQL, returns
--   a set of ids derived solely from the verified `sub`, search_path pinned.
--   SCALE CAVEAT: an array is the right shape for a personal patient panel (tens, maybe low
--   hundreds). If a service account ever ends up on ten thousand care teams, replace the body
--   with a set-returning function and an `IN (SELECT ...)` policy; do not just let the array
--   grow.
-- =============================================================================================

-- The body reads care_team_member, which §26 below creates. SQL function bodies are parsed at
-- CREATE time, so validation is suspended for this one statement and the body is checked on
-- first call instead — by then the table exists.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION app.care_patient_ids()
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(array_agg(DISTINCT ct.patient_id), ARRAY[]::uuid[])
    FROM public.care_team_member ct
   WHERE ct.organization_id = app.current_org_id()
     AND ct.member_id       = app.current_member_id()
     AND ct.ended_at IS NULL;
$$;

SET check_function_bodies = on;

COMMENT ON FUNCTION app.care_patient_ids() IS
  'The patients whose chart the caller may open in the active organisation: those they hold an '
  'open care_team_member row for. Empty array for anyone with no seat, no tenant or no '
  'assignments — `= ANY (empty array)` is false, so every clinical policy fails closed. '
  'Use as `patient_id = ANY (app.care_patient_ids())`; never wrap it in a per-row expression.';


-- =============================================================================================
-- SECTION 23 — SHARED WRITE GUARDS
--
-- Rule 4 of the brief: clinical data is never hard-deleted and is amended rather than
-- overwritten. deny_hard_delete() (010 §3) covers the first half; these cover the second.
-- =============================================================================================

-- Freezes every column of a row except the ones named in the trigger argument. Attach as:
--   CREATE TRIGGER t_append_only BEFORE UPDATE ON public.lab_result
--     FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only('{review_status,reviewed_at,...}');
-- One function for every append-only table, instead of one bespoke trigger each: the list of
-- mutable columns then sits in the CREATE TRIGGER where a reviewer can read it beside the
-- table, which is the whole point.
CREATE OR REPLACE FUNCTION app.enforce_append_only()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_mutable text[] := coalesce(TG_ARGV[0], '{}')::text[];
BEGIN
  -- Same shape of escape hatch as app.allow_hard_delete: explicit, per-transaction, greppable.
  -- Meant for a data-fix runbook, never for application code.
  IF coalesce(current_setting('app.allow_clinical_rewrite', true), 'off') = 'on' THEN
    RETURN NEW;
  END IF;

  IF (to_jsonb(OLD) - v_mutable) IS DISTINCT FROM (to_jsonb(NEW) - v_mutable) THEN
    RAISE EXCEPTION
      'Clinical facts on % are append-only; only (%) may be updated in place.',
      TG_TABLE_NAME, array_to_string(v_mutable, ', ')
      USING errcode = '42501',
            hint = 'Insert a superseding row and set the old one to record_status = ''amended''.';
  END IF;
  RETURN NEW;
END;
$$;

-- Column-level authorisation for the one thing RLS cannot express: "the patient may update
-- THIS column of their own row and nothing else". Used for the portal's Confirm button and the
-- care plan's Request refill link.
CREATE OR REPLACE FUNCTION app.enforce_patient_writable_columns()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_writable text[] := coalesce(TG_ARGV[0], '{}')::text[];
BEGIN
  -- Only constrains a caller acting purely as a patient. Staff (including a nurse who is also
  -- a patient at her own hospital) are governed by the policies instead; a trusted server-side
  -- worker has no patient identity at all, so it passes straight through.
  IF app.current_patient_id() IS NULL OR app.is_staff() THEN
    RETURN NEW;
  END IF;

  IF (to_jsonb(OLD) - v_writable) IS DISTINCT FROM (to_jsonb(NEW) - v_writable) THEN
    RAISE EXCEPTION 'As a patient you may only change (%) on %.',
      array_to_string(v_writable, ', '), TG_TABLE_NAME
      USING errcode = '42501';
  END IF;
  RETURN NEW;
END;
$$;

-- Renders a reference range for display, including the one-sided cases the mock actually
-- contains ("< 5" for CRP). Kept in SQL so the API, an export and a report cannot each invent
-- their own formatting of the same three columns.
CREATE OR REPLACE FUNCTION app.format_reference_range(
    p_low numeric, p_high numeric, p_note text DEFAULT NULL, p_unit text DEFAULT NULL)
RETURNS text LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT CASE
    WHEN p_low IS NOT NULL AND p_high IS NOT NULL
      THEN trim(to_char(p_low, 'FM999999990.999') || '–' || to_char(p_high, 'FM999999990.999')
                || coalesce(' ' || p_unit, ''))
    WHEN p_low IS NULL AND p_high IS NOT NULL
      THEN trim('< ' || to_char(p_high, 'FM999999990.999') || coalesce(' ' || p_unit, ''))
    WHEN p_low IS NOT NULL AND p_high IS NULL
      THEN trim('> ' || to_char(p_low, 'FM999999990.999') || coalesce(' ' || p_unit, ''))
    ELSE nullif(btrim(coalesce(p_note, '')), '')
  END;
$$;

COMMENT ON FUNCTION app.format_reference_range(numeric, numeric, text, text) IS
  'Reference range as the UI shows it: "0.5–2.2" when bounded both sides, "< 5" when only an '
  'upper bound exists (the CRP row), "> 40" when only a lower one, and the free-text note when '
  'the normal range is not numeric at all ("negative", "see report").';

-- =============================================================================================
-- SECTION 24 — HOSPITAL CONFIGURATION
--
-- Three small tenant-scoped catalogues. Each exists because a screen renders a list the user
-- picks from, and a picker backed by free text is a picker that produces "Cardiology",
-- "cardiology" and "Cardio" in the same week.
-- =============================================================================================

-- OWNERSHIP NOTE (resolved cross-file conflict). An earlier pass created public.department in
-- BOTH this file and 040. Two CREATE TABLE IF NOT EXISTS statements for one name do not error —
-- they silently keep whichever ran first and drop the other's columns on the floor, which is a
-- worse failure than a clash because nothing complains. THIS FILE OWNS THE TABLE: it runs first
-- and four of its own foreign keys point at it (staff_profile, encounter, appointment,
-- lab_panel). 040's two extra columns are folded in below; 040 now asserts the table exists
-- instead of creating it, and adds only the vendor-support read policy it actually needs.
CREATE TABLE IF NOT EXISTS public.department (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid        NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    code                text        NOT NULL,
    name                text        NOT NULL,

    -- The DENOMINATOR of the front desk's "Clinic load today" card (Cardiology 85%, Radiology
    -- 92%). The numerator is booked appointments, so the percentage is a join computed at read
    -- time — a stored percentage would be wrong the moment anyone books. Nullable: a department
    -- that does not run a slot-based clinic simply has no capacity, and 0 would mean something
    -- different (closed) that nothing in the app expresses.
    daily_slot_capacity integer     NULL,

    is_active           boolean     NOT NULL DEFAULT true,
    sort_order          integer     NOT NULL DEFAULT 100,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT department_code_ck CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
    CONSTRAINT department_name_ck CHECK (btrim(name) <> ''),
    CONSTRAINT department_capacity_ck
      CHECK (daily_slot_capacity IS NULL OR daily_slot_capacity > 0),
    CONSTRAINT department_id_org_uk UNIQUE (id, organization_id)
);
-- No lower(code) here: department_code_ck already forbids anything but lowercase, so a
-- functional index would only be a second place to get the same rule slightly wrong.
CREATE UNIQUE INDEX IF NOT EXISTS department_code_uk
  ON public.department (organization_id, code);

COMMENT ON TABLE public.department IS
  'Cardiology, Radiology, Gen. medicine, Pediatrics — the clinic-load bars on the reception '
  'dashboard, the provider picker grouping, and the department column on an appointment. '
  'Owned by 020; 040 references it and must not re-create it. NOT MODELLED: a utilisation '
  'target. The "85%" the dashboard shows is daily_slot_capacity joined against today''s '
  'appointments, computed at read time rather than stored.';
COMMENT ON COLUMN public.department.is_active IS
  'Departments retire, they do not vanish: appointments, encounters and invoice lines point at '
  'them for years. There is no DELETE policy on this table — deactivate instead.';

CREATE TABLE IF NOT EXISTS public.visit_type (
    id                       uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id          uuid        NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    code                     text        NOT NULL,
    name                     text        NOT NULL,
    default_duration_minutes integer     NOT NULL DEFAULT 30,
    default_modality         app.appointment_modality NOT NULL DEFAULT 'in_person',
    is_active                boolean     NOT NULL DEFAULT true,
    created_at               timestamptz NOT NULL DEFAULT now(),
    updated_at               timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT visit_type_code_ck CHECK (code ~ '^[a-z][a-z0-9_]{1,30}$'),
    CONSTRAINT visit_type_name_ck CHECK (btrim(name) <> ''),
    CONSTRAINT visit_type_duration_ck CHECK (default_duration_minutes BETWEEN 5 AND 480),
    CONSTRAINT visit_type_id_org_uk UNIQUE (id, organization_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS visit_type_code_uk
  ON public.visit_type (organization_id, code);

COMMENT ON TABLE public.visit_type IS
  'The Booking screen''s visit-type dropdown (Diabetes follow-up, Post-op consult, Annual '
  'physical, Consult) and the default that pre-selects its 15/30/45 duration control.';

-- The practice attributes of a staff seat. This is NOT a second staff table: identity, roles,
-- job title and licence number all live on 010's organization_member, and organization_member.id
-- IS "staff_id" throughout this file. What lives here is the handful of facts 010 has no
-- business knowing — which department a clinician practises in, and whether they take bookings.
-- Modelled as its own table rather than columns on organization_member because 010 owns that
-- table and a later migration reaching in to add columns to it is exactly how the ownership
-- boundary stops meaning anything.
CREATE TABLE IF NOT EXISTS public.staff_profile (
    member_id        uuid        PRIMARY KEY,
    organization_id  uuid        NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    department_id    uuid        NULL,
    specialty        text        NULL,
    default_room     text        NULL,
    accepts_bookings boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT staff_profile_member_org_uk UNIQUE (member_id, organization_id),
    CONSTRAINT staff_profile_member_fk
      FOREIGN KEY (member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT staff_profile_department_fk
      FOREIGN KEY (department_id, organization_id)
      REFERENCES public.department (id, organization_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS staff_profile_department_ix
  ON public.staff_profile (organization_id, department_id) WHERE accepts_bookings;

COMMENT ON TABLE public.staff_profile IS
  'Practice attributes of a staff seat, keyed on organization_member.id (= staff_id). Gives '
  'the app "Dr. Anita Mehta · Cardiology" for the provider picker and filters the picker to '
  'people who actually take bookings. A patient seat simply has no row here.';
COMMENT ON COLUMN public.staff_profile.specialty IS
  'Free text, shown when it differs from the department name (a cardiologist in Gen. medicine). '
  'Not an enum: medical specialty lists are long, local and revised, and nothing in this app '
  'branches on the value.';


-- =============================================================================================
-- SECTION 25 — PATIENT CLINICAL FACTS
--
-- 010 owns WHO the patient is. These own the two things every clinical screen shows beside the
-- name: what they are being treated for, and what will hurt them.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.patient_condition (
    id               uuid                PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid                NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id       uuid                NOT NULL,
    name             text                NOT NULL,
    code             text                NULL,
    code_system      text                NULL,
    clinical_status  app.condition_status NOT NULL DEFAULT 'active',
    is_primary       boolean             NOT NULL DEFAULT false,
    onset_date       date                NULL,
    resolved_date    date                NULL,
    note             text                NULL,
    recorded_by      uuid                NOT NULL,
    record_status    app.record_status   NOT NULL DEFAULT 'active',
    created_at       timestamptz         NOT NULL DEFAULT now(),
    updated_at       timestamptz         NOT NULL DEFAULT now(),

    CONSTRAINT patient_condition_name_ck CHECK (btrim(name) <> ''),
    CONSTRAINT patient_condition_code_ck
      CHECK ((code IS NULL) = (code_system IS NULL)),
    CONSTRAINT patient_condition_resolved_ck
      CHECK ((clinical_status = 'resolved') = (resolved_date IS NOT NULL)),
    CONSTRAINT patient_condition_dates_ck
      CHECK (resolved_date IS NULL OR onset_date IS NULL OR resolved_date >= onset_date),
    CONSTRAINT patient_condition_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT patient_condition_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT patient_condition_recorder_fk
      FOREIGN KEY (recorded_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);
-- "Primary condition" is one column on the Patients table, so at most one active primary.
CREATE UNIQUE INDEX IF NOT EXISTS patient_condition_primary_uk
  ON public.patient_condition (organization_id, patient_id)
  WHERE is_primary AND clinical_status = 'active'::app.condition_status
    AND record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS patient_condition_patient_ix
  ON public.patient_condition (organization_id, patient_id)
  WHERE record_status = 'active'::app.record_status;

COMMENT ON TABLE public.patient_condition IS
  'The problem list. Feeds "Primary condition" on the Patients table (Pneumonia, CHF, Type 2 '
  'diabetes, CKD stage 3) and the care-plan header. code/code_system are free for ICD-10 or '
  'SNOMED when the operator adopts one; name is what the UI renders either way.';

CREATE TABLE IF NOT EXISTS public.patient_allergy (
    id               uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid                 NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id       uuid                 NOT NULL,
    substance        text                 NOT NULL,
    category         app.allergy_category NOT NULL DEFAULT 'medication',
    severity         app.allergy_severity NOT NULL DEFAULT 'unknown',
    reaction         text                 NULL,
    noted_on         date                 NULL,
    inactivated_at   timestamptz          NULL,
    inactivated_reason text               NULL,
    recorded_by      uuid                 NOT NULL,
    created_at       timestamptz          NOT NULL DEFAULT now(),
    updated_at       timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT patient_allergy_substance_ck CHECK (btrim(substance) <> ''),
    CONSTRAINT patient_allergy_inactive_ck
      CHECK (inactivated_reason IS NULL OR inactivated_at IS NOT NULL),
    CONSTRAINT patient_allergy_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT patient_allergy_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT patient_allergy_recorder_fk
      FOREIGN KEY (recorded_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS patient_allergy_active_uk
  ON public.patient_allergy (organization_id, patient_id, lower(substance))
  WHERE inactivated_at IS NULL;
CREATE INDEX IF NOT EXISTS patient_allergy_patient_ix
  ON public.patient_allergy (organization_id, patient_id) WHERE inactivated_at IS NULL;

COMMENT ON TABLE public.patient_allergy IS
  'The "Allergies: penicillin" line in the patient header. Never deleted — an allergy that '
  'turns out to be wrong is inactivated with a reason, because "we removed it" and "it was '
  'never recorded" must not look the same afterwards.';
COMMENT ON COLUMN public.patient_allergy.severity IS
  '''unknown'' is a real answer and the default: a nurse recording a reported allergy at the '
  'desk usually cannot grade it, and forcing a guess produces confident nonsense.';


-- =============================================================================================
-- SECTION 26 — CARE TEAM
--
-- This table is the access-control spine of the whole file (§22), and it is also just the
-- "Care team" card on the patient detail screen. Those being the same table is the point: the
-- list a clinician sees is the list that decides what they can see.
--
-- SELF-ASSERTION, ARGUED
--   A clinician may add THEMSELVES to any patient's care team within their hospital. That
--   sounds like a hole; it is the least-bad option. A doctor covering a colleague's ward at 3am
--   cannot wait for an administrator, and a system that makes them wait gets a shared login
--   instead; the alternative — an admin-managed assignment list — puts a non-clinician in the
--   path of urgent care and decays into "give everyone everything". Assuming care leaves a row
--   with a name and a timestamp, so "why were you in that chart" has an answer: an
--   accountability control does not prevent, it makes the act undeniable.
--   What it is NOT: a route into another hospital, a route for reception or hospital_admin
--   (is_clinician() only), or a way to add somebody else to a team without an admin.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.care_team_member (
    id               uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid               NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id       uuid               NOT NULL,
    member_id        uuid               NOT NULL,
    role             app.care_team_role NOT NULL,
    assignment_note  text               NULL,
    started_at       timestamptz        NOT NULL DEFAULT now(),
    ended_at         timestamptz        NULL,
    added_by         uuid               NOT NULL,
    created_at       timestamptz        NOT NULL DEFAULT now(),

    CONSTRAINT care_team_window_ck CHECK (ended_at IS NULL OR ended_at >= started_at),
    CONSTRAINT care_team_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT care_team_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT care_team_member_fk
      FOREIGN KEY (member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT care_team_added_by_fk
      FOREIGN KEY (added_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS care_team_open_uk
  ON public.care_team_member (organization_id, patient_id, member_id, role)
  WHERE ended_at IS NULL;
-- One attending at a time: "who is responsible for this patient" must have one answer.
CREATE UNIQUE INDEX IF NOT EXISTS care_team_one_attending_uk
  ON public.care_team_member (organization_id, patient_id)
  WHERE role = 'attending'::app.care_team_role AND ended_at IS NULL;
-- THE index behind app.care_patient_ids(): one probe per statement, covering.
CREATE INDEX IF NOT EXISTS care_team_by_member_ix
  ON public.care_team_member (member_id) INCLUDE (patient_id, organization_id)
  WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS care_team_by_patient_ix
  ON public.care_team_member (organization_id, patient_id) WHERE ended_at IS NULL;

COMMENT ON TABLE public.care_team_member IS
  'Who is looking after this patient, and therefore who may open the chart (app.care_patient_ids()). '
  'Ending an assignment sets ended_at; rows are never deleted, so "who could see this chart in '
  'August" stays answerable. A clinician may add themselves — see §26 for why.';
COMMENT ON COLUMN public.care_team_member.assignment_note IS
  'Free-text qualifier the card renders beside the role — "Ward 4" for the ward nurse. Not a '
  'location FK: no screen in this app treats a ward as an entity with its own behaviour.';

-- =============================================================================================
-- SECTION 27 — ENCOUNTERS AND ADMISSIONS
--
-- A contact that HAPPENED, as opposed to an appointment, which is an intention. The Patients
-- table's "Inpatient · Rm 412" and "Admitted Aug 13" both come from here, as does "Last visit".
--
-- NOT MODELLED: a bed/location inventory and a bed-assignment history (three tables in the
-- draft). Nothing in the app books a room, checks a room's availability or reports on bed
-- occupancy — the room appears only as a label the reader is expected to recognise ("Rm 412",
-- "Clinic room 2"). Text is the honest model of that until a screen needs otherwise; when one
-- does, room_label becomes an FK and this comment becomes the migration note.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.encounter (
    id                  uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid                 NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id          uuid                 NOT NULL,
    class               app.encounter_class  NOT NULL,
    status              app.encounter_status NOT NULL DEFAULT 'in_progress',
    department_id       uuid                 NULL,
    attending_member_id uuid                 NULL,
    room_label          text                 NULL,
    reason              text                 NULL,
    started_at          timestamptz          NOT NULL DEFAULT now(),
    ended_at            timestamptz          NULL,
    discharge_summary   text                 NULL,
    record_status       app.record_status    NOT NULL DEFAULT 'active',
    created_by          uuid                 NOT NULL,
    created_at          timestamptz          NOT NULL DEFAULT now(),
    updated_at          timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT encounter_window_ck   CHECK (ended_at IS NULL OR ended_at >= started_at),
    CONSTRAINT encounter_closed_ck
      CHECK ((status IN ('discharged', 'cancelled')) = (ended_at IS NOT NULL)),
    CONSTRAINT encounter_room_ck     CHECK (room_label IS NULL OR btrim(room_label) <> ''),
    CONSTRAINT encounter_id_org_uk   UNIQUE (id, organization_id),
    -- Lets appointment and the clinical tables FK to (encounter_id, patient_id) and get
    -- "this row belongs to that patient's encounter" enforced by the database.
    CONSTRAINT encounter_id_patient_uk UNIQUE (id, patient_id),
    CONSTRAINT encounter_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT encounter_department_fk
      FOREIGN KEY (department_id, organization_id)
      REFERENCES public.department (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT encounter_attending_fk
      FOREIGN KEY (attending_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT encounter_created_by_fk
      FOREIGN KEY (created_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);
-- A patient is in one bed at a time, so "which room is Rosa in" has exactly one answer and
-- v_patient_summary never has to pick.
CREATE UNIQUE INDEX IF NOT EXISTS encounter_one_open_admission_uk
  ON public.encounter (organization_id, patient_id)
  WHERE class = 'inpatient'::app.encounter_class
    AND status = 'in_progress'::app.encounter_status;
CREATE INDEX IF NOT EXISTS encounter_patient_ix
  ON public.encounter (organization_id, patient_id, started_at DESC)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS encounter_open_ix
  ON public.encounter (organization_id, class, started_at DESC)
  WHERE status = 'in_progress'::app.encounter_status;

COMMENT ON TABLE public.encounter IS
  'One episode of care: an admission, a clinic visit, an ED attendance. Source of the patient '
  'status column ("Inpatient · Rm 412" / "Outpatient"), the admission date in the patient '
  'header, and "Last visit" on the Patients table.';
COMMENT ON COLUMN public.encounter.room_label IS
  'Where the patient physically is, as printed: "Rm 412", "Clinic room 2". Deliberately text — '
  'see §27 on why there is no room table.';


-- =============================================================================================
-- SECTION 28 — APPOINTMENTS AND THE FRONT-DESK QUEUE
--
-- One table serves the doctor Schedule grid, the reception Next-arrivals list, the Check-in
-- queue tabs, the Booking slot grid and the portal's Next-appointment card. They are the same
-- row at different moments of its life, and splitting them would mean keeping two copies of
-- the same state in sync — which is how a patient ends up checked in on one screen and a
-- no-show on another.
--
-- NON-PATIENT CALENDAR BLOCKS: two of the five rows on the doctor's day are "Ward rounds" and
-- "MDT case conference" — time that is genuinely booked but belongs to no patient. They live
-- here with patient_id NULL and a block_title, so the double-booking constraint below protects
-- them too. The cost is a nullable patient_id on a clinical-adjacent table, paid for by not
-- having a second scheduling table that the same grid has to union.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.appointment (
    id                  uuid                     PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id     uuid                     NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id          uuid                     NULL,
    block_title         text                     NULL,
    encounter_id        uuid                     NULL,
    provider_member_id  uuid                     NULL,
    department_id       uuid                     NULL,
    visit_type_id       uuid                     NULL,

    modality            app.appointment_modality NOT NULL DEFAULT 'in_person',
    origin              app.booking_origin       NOT NULL DEFAULT 'scheduled',
    room_label          text                     NULL,
    scheduled_start     timestamptz              NOT NULL,
    scheduled_end       timestamptz              NOT NULL,
    duration_minutes    integer                  NOT NULL DEFAULT 0,
    status              app.appointment_status   NOT NULL DEFAULT 'booked',
    chief_complaint     text                     NULL,

    -- Front-desk queue placement. Both NULL until the patient walks in.
    queue_date          date                     NULL,
    queue_ticket        integer                  NULL,

    -- Lifecycle stamps, maintained by app.guard_appointment(). Each records when the row
    -- ENTERED a state, so every duration the UI shows is computed from real times rather than
    -- stored as a number that goes stale the moment nobody refreshes it.
    booked_at           timestamptz              NOT NULL DEFAULT now(),
    confirmed_at        timestamptz              NULL,
    checked_in_at       timestamptz              NULL,
    roomed_at           timestamptz              NULL,
    done_at             timestamptz              NULL,
    cancelled_at        timestamptz              NULL,
    no_show_at          timestamptz              NULL,
    cancellation_reason text                     NULL,

    record_status       app.record_status        NOT NULL DEFAULT 'active',
    created_by          uuid                     NULL,
    created_at          timestamptz              NOT NULL DEFAULT now(),
    updated_at          timestamptz              NOT NULL DEFAULT now(),

    CONSTRAINT appointment_subject_ck
      CHECK (num_nonnulls(patient_id, block_title) = 1),
    CONSTRAINT appointment_window_ck   CHECK (scheduled_end > scheduled_start),
    CONSTRAINT appointment_duration_ck CHECK (duration_minutes BETWEEN 1 AND 1440),
    -- A provider is required except for a walk-in nobody has triaged yet: the queue's
    -- "Triage pending" row is a real state, and pretending otherwise would force the desk to
    -- guess a doctor.
    CONSTRAINT appointment_provider_ck
      CHECK (provider_member_id IS NOT NULL
             OR (origin = 'walk_in' AND status IN ('booked', 'waiting', 'cancelled'))),
    CONSTRAINT appointment_queue_pair_ck CHECK ((queue_date IS NULL) = (queue_ticket IS NULL)),
    CONSTRAINT appointment_queue_ticket_ck CHECK (queue_ticket IS NULL OR queue_ticket > 0),
    -- Status and its stamp are one fact written twice; keep them agreeing.
    CONSTRAINT appointment_waiting_ck   CHECK (status <> 'waiting'   OR checked_in_at IS NOT NULL),
    CONSTRAINT appointment_in_room_ck   CHECK (status <> 'in_room'   OR roomed_at     IS NOT NULL),
    CONSTRAINT appointment_done_ck      CHECK (status <> 'done'      OR done_at       IS NOT NULL),
    CONSTRAINT appointment_cancelled_ck CHECK (status <> 'cancelled' OR cancelled_at  IS NOT NULL),
    CONSTRAINT appointment_no_show_ck   CHECK (status <> 'no_show'   OR no_show_at    IS NOT NULL),
    CONSTRAINT appointment_order_ck
      CHECK ((roomed_at IS NULL OR checked_in_at IS NULL OR roomed_at >= checked_in_at)
         AND (done_at   IS NULL OR roomed_at     IS NULL OR done_at   >= roomed_at)),
    CONSTRAINT appointment_cancel_reason_ck
      CHECK (cancellation_reason IS NULL OR cancelled_at IS NOT NULL),

    CONSTRAINT appointment_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT appointment_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    -- Composite on (id, patient_id): an appointment cannot be attached to another patient's
    -- encounter, and the database says so rather than a reviewer noticing.
    CONSTRAINT appointment_encounter_fk
      FOREIGN KEY (encounter_id, patient_id)
      REFERENCES public.encounter (id, patient_id) ON DELETE RESTRICT,
    CONSTRAINT appointment_provider_fk
      FOREIGN KEY (provider_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT appointment_department_fk
      FOREIGN KEY (department_id, organization_id)
      REFERENCES public.department (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT appointment_visit_type_fk
      FOREIGN KEY (visit_type_id, organization_id)
      REFERENCES public.visit_type (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT appointment_created_by_fk
      FOREIGN KEY (created_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);

-- The queue badge ("01".."05") restarts each clinic day, so it is unique per tenant per day.
CREATE UNIQUE INDEX IF NOT EXISTS appointment_queue_ticket_uk
  ON public.appointment (organization_id, queue_date, queue_ticket)
  WHERE queue_ticket IS NOT NULL;
CREATE INDEX IF NOT EXISTS appointment_day_ix
  ON public.appointment (organization_id, scheduled_start)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS appointment_provider_day_ix
  ON public.appointment (organization_id, provider_member_id, scheduled_start)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS appointment_queue_ix
  ON public.appointment (organization_id, status, scheduled_start)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS appointment_patient_ix
  ON public.appointment (organization_id, patient_id, scheduled_start DESC)
  WHERE patient_id IS NOT NULL AND record_status = 'active'::app.record_status;

COMMENT ON TABLE public.appointment IS
  'Scheduled visits, walk-ins and non-patient calendar blocks, plus the front-desk queue. '
  'Serves the Schedule day/week grid, Next arrivals, the Check-in queue tabs (Waiting / In '
  'room / Done), the Booking slot grid and the portal Next-appointment card.';
COMMENT ON COLUMN public.appointment.status IS
  'booked → waiting (arrived at the desk) → in_room → done, with cancelled and no_show as '
  'terminal exits. The Check-in queue tabs are literally these values. Transitions are '
  'enforced by app.guard_appointment(), which also sets the matching timestamp.';
COMMENT ON COLUMN public.appointment.checked_in_at IS
  'Arrival at the front desk. "Waiting 32 min" is now() - checked_in_at while status = '
  '''waiting'' — always live, never a stored counter. Distinct from confirmed_at: confirming '
  'is remote (the portal button), checking in is being physically present.';
COMMENT ON COLUMN public.appointment.encounter_id IS
  'The encounter this visit produced, NULL until the patient is actually seen. Pointing the '
  'relationship this way means a no-show does not manufacture an encounter that never happened.';
COMMENT ON COLUMN public.appointment.block_title IS
  '"Ward rounds — 4th floor", "MDT case conference": booked time with no patient. Exactly one '
  'of patient_id / block_title is set (appointment_subject_ck).';

-- One provider cannot be in two places at once. Deferrable so a bulk reschedule can shuffle a
-- whole clinic inside one transaction without tripping over its own intermediate states.
-- Needs btree_gist for `uuid WITH =`; guarded so the migration still applies on a host without
-- the extension, loudly rather than silently.
DO $double_book$
DECLARE
  v_opc_schema text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'appointment_no_double_book_ck') THEN
    BEGIN
      CREATE EXTENSION IF NOT EXISTS btree_gist;

      -- 000_extensions.sql installs btree_gist into `extensions` on Supabase and into the
      -- default creation schema elsewhere. An unqualified `provider_member_id WITH =` resolves
      -- gist_uuid_ops through the search_path, so on a session whose search_path does not
      -- include the extension schema the ALTER fails and the constraint is silently lost to the
      -- handler below. Resolving the opclass from the catalogue and qualifying it makes the
      -- constraint independent of the search_path of whoever runs the migration.
      SELECT n.nspname INTO v_opc_schema
        FROM pg_opclass oc
        JOIN pg_am        am ON am.oid = oc.opcmethod AND am.amname = 'gist'
        JOIN pg_namespace n  ON n.oid  = oc.opcnamespace
        JOIN pg_type      t  ON t.oid  = oc.opcintype AND t.typname = 'uuid'
       LIMIT 1;

      IF v_opc_schema IS NULL THEN
        RAISE EXCEPTION 'no gist operator class for uuid (btree_gist unavailable)';
      END IF;

      EXECUTE format($ddl$
        ALTER TABLE public.appointment
          ADD CONSTRAINT appointment_no_double_book_ck
          EXCLUDE USING gist (
            provider_member_id %I.gist_uuid_ops WITH =,
            tstzrange(scheduled_start, scheduled_end, '[)') WITH &&
          )
          WHERE (provider_member_id IS NOT NULL
                 AND record_status = 'active'::app.record_status
                 AND status <> ALL (ARRAY['cancelled'::app.appointment_status,
                                          'no_show'::app.appointment_status]))
          DEFERRABLE INITIALLY IMMEDIATE
      $ddl$, v_opc_schema);

      RAISE NOTICE 'prognosify/020: provider double-booking constraint created (opclass %.gist_uuid_ops).',
                   v_opc_schema;
    EXCEPTION WHEN OTHERS THEN
      -- Broad on purpose: a missing btree_gist surfaces as "no default operator class for gist"
      -- rather than a tidy errcode. The constraint is a hardening measure, so losing it must
      -- not block the migration — but it must be impossible to lose it quietly.
      RAISE WARNING 'prognosify/020: provider double-booking constraint NOT created (%). '
                    'Run 000_extensions.sql, then re-run this file. Until it exists, '
                    'double-booking is prevented by nothing but the booking service.', SQLERRM;
    END;
  END IF;
END
$double_book$;

-- Lifecycle guard: legal transitions, automatic stamps, derived duration.
CREATE OR REPLACE FUNCTION app.guard_appointment()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  NEW.duration_minutes :=
    greatest(1, (extract(epoch FROM (NEW.scheduled_end - NEW.scheduled_start)) / 60)::int);

  IF TG_OP = 'UPDATE' THEN
    IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
       OR NEW.patient_id IS DISTINCT FROM OLD.patient_id THEN
      RAISE EXCEPTION 'An appointment cannot be moved to another tenant or another patient.'
        USING errcode = '42501',
              hint = 'Cancel this row and book a new one, so both stay visible in history.';
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
      IF OLD.status IN ('done', 'cancelled', 'no_show') THEN
        RAISE EXCEPTION 'Appointment is already %; it cannot move to %.', OLD.status, NEW.status
          USING errcode = '23514';
      END IF;
      IF NOT (
           (OLD.status = 'booked'  AND NEW.status IN ('waiting', 'cancelled', 'no_show'))
        OR (OLD.status = 'waiting' AND NEW.status IN ('in_room', 'done', 'cancelled', 'no_show'))
        OR (OLD.status = 'in_room' AND NEW.status IN ('done', 'cancelled'))
      ) THEN
        RAISE EXCEPTION 'Illegal appointment transition % → %.', OLD.status, NEW.status
          USING errcode = '23514';
      END IF;
    END IF;
    NEW.updated_at := now();
  END IF;

  -- Stamp the state being entered, once. Callers set status; they do not have to remember the
  -- six timestamp columns, which is how those columns stay trustworthy.
  IF NEW.status = 'waiting'   AND NEW.checked_in_at IS NULL THEN NEW.checked_in_at := now(); END IF;
  IF NEW.status = 'in_room'   THEN
    IF NEW.checked_in_at IS NULL THEN NEW.checked_in_at := now(); END IF;
    IF NEW.roomed_at     IS NULL THEN NEW.roomed_at     := now(); END IF;
  END IF;
  IF NEW.status = 'done'      AND NEW.done_at      IS NULL THEN NEW.done_at      := now(); END IF;
  IF NEW.status = 'cancelled' AND NEW.cancelled_at IS NULL THEN NEW.cancelled_at := now(); END IF;
  IF NEW.status = 'no_show'   AND NEW.no_show_at   IS NULL THEN NEW.no_show_at   := now(); END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_guard ON public.appointment;
CREATE TRIGGER t_guard BEFORE INSERT OR UPDATE ON public.appointment
  FOR EACH ROW EXECUTE FUNCTION app.guard_appointment();

-- The portal's Confirm button, and nothing else: a patient may stamp confirmed_at on their own
-- appointment. Rescheduling and cancelling stay with the desk (the portal's "Reschedule" opens
-- the booking flow), because releasing a slot has consequences for other people's day.
DROP TRIGGER IF EXISTS t_patient_columns ON public.appointment;
CREATE TRIGGER t_patient_columns BEFORE UPDATE ON public.appointment
  FOR EACH ROW EXECUTE FUNCTION app.enforce_patient_writable_columns('{confirmed_at,updated_at}');

DROP TRIGGER IF EXISTS t_no_delete ON public.appointment;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.appointment
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

DROP TRIGGER IF EXISTS t_touch ON public.encounter;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.encounter
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.encounter;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.encounter
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

-- Admitting a patient puts the attending on the care team. Without this the admitting doctor
-- would write an encounter and then be unable to read it back — and the workaround people
-- invent for that is always worse than the trigger.
CREATE OR REPLACE FUNCTION app.ensure_attending_on_care_team()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.attending_member_id IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.care_team_member
      (organization_id, patient_id, member_id, role, assignment_note, added_by)
  VALUES
      (NEW.organization_id, NEW.patient_id, NEW.attending_member_id, 'attending',
       'auto: attending on encounter', NEW.created_by)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_attending_care_team ON public.encounter;
CREATE TRIGGER t_attending_care_team AFTER INSERT ON public.encounter
  FOR EACH ROW EXECUTE FUNCTION app.ensure_attending_on_care_team();

COMMENT ON FUNCTION app.ensure_attending_on_care_team() IS
  'Keeps "responsible clinician" and "may open the chart" from drifting apart. SECURITY DEFINER '
  'because it writes care_team_member on behalf of a caller whose own INSERT policy covers only '
  'themselves; the row it writes is fully determined by the encounter being inserted.';

DROP TRIGGER IF EXISTS t_touch ON public.department;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.department
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.visit_type;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.visit_type
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.staff_profile;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.staff_profile
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.patient_condition;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.patient_condition
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.patient_condition;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.patient_condition
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_touch ON public.patient_allergy;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.patient_allergy
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.patient_allergy;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.patient_allergy
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_no_delete ON public.care_team_member;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.care_team_member
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

-- =============================================================================================
-- SECTION 29 — VITALS
--
-- One row per observation event, one column per measure. The four cards on the patient screen
-- (HR 104, BP 96/61, Temp 38.4, SpO₂ 93%) are one row.
--
-- BLOOD PRESSURE IS TWO NUMBERS: systolic_mmhg and diastolic_mmhg, never "96/61". A string
-- cannot be compared, trended, range-checked or averaged — and the sepsis flag on this very
-- patient depends on a falling systolic. Rendering "96/61" is one line of frontend code;
-- recovering two numbers from a string someone typed as "96 \ 61" is a data-cleaning project.
--
-- One wide row rather than an EAV (observation_code, value) table: the app reads these measures
-- together on every patient screen and never iterates over "all observation types". A wide row
-- makes that one tuple with a real CHECK per measure; EAV buys extensibility nobody asked for
-- and pays with a self-join per card and range checks stranded in application code. Adding a
-- measure later is a one-line migration.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.vital_sign (
    id                   uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid              NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id           uuid              NOT NULL,
    encounter_id         uuid              NULL,
    measured_at          timestamptz       NOT NULL DEFAULT now(),
    source               app.vital_source  NOT NULL DEFAULT 'clinician_measured',

    heart_rate_bpm       smallint          NULL,
    systolic_mmhg        smallint          NULL,
    diastolic_mmhg       smallint          NULL,
    temperature_c        numeric(4,1)      NULL,
    spo2_percent         smallint          NULL,
    respiratory_rate_bpm smallint          NULL,
    pain_score           smallint          NULL,
    supplemental_o2      text              NULL,
    note                 text              NULL,

    recorded_by          uuid              NULL,
    record_status        app.record_status NOT NULL DEFAULT 'active',
    supersedes_id        uuid              NULL,
    created_at           timestamptz       NOT NULL DEFAULT now(),
    updated_at           timestamptz       NOT NULL DEFAULT now(),

    CONSTRAINT vital_sign_has_measure_ck
      CHECK (num_nonnulls(heart_rate_bpm, systolic_mmhg, temperature_c, spo2_percent,
                          respiratory_rate_bpm, pain_score) > 0),
    -- Half a blood pressure is not a blood pressure.
    CONSTRAINT vital_sign_bp_pair_ck  CHECK ((systolic_mmhg IS NULL) = (diastolic_mmhg IS NULL)),
    CONSTRAINT vital_sign_bp_order_ck
      CHECK (systolic_mmhg IS NULL OR systolic_mmhg > diastolic_mmhg),
    -- Physiologically-possible bounds, not clinically-normal ones: these catch a transposed
    -- pair or a fat finger, and must never reject a genuinely extreme patient.
    CONSTRAINT vital_sign_hr_ck   CHECK (heart_rate_bpm       IS NULL OR heart_rate_bpm       BETWEEN 10 AND 350),
    CONSTRAINT vital_sign_sbp_ck  CHECK (systolic_mmhg        IS NULL OR systolic_mmhg        BETWEEN 40 AND 300),
    CONSTRAINT vital_sign_dbp_ck  CHECK (diastolic_mmhg       IS NULL OR diastolic_mmhg       BETWEEN 10 AND 200),
    CONSTRAINT vital_sign_temp_ck CHECK (temperature_c        IS NULL OR temperature_c        BETWEEN 25.0 AND 45.0),
    CONSTRAINT vital_sign_spo2_ck CHECK (spo2_percent         IS NULL OR spo2_percent         BETWEEN 20 AND 100),
    CONSTRAINT vital_sign_rr_ck   CHECK (respiratory_rate_bpm IS NULL OR respiratory_rate_bpm BETWEEN 2 AND 90),
    CONSTRAINT vital_sign_pain_ck CHECK (pain_score           IS NULL OR pain_score           BETWEEN 0 AND 10),

    CONSTRAINT vital_sign_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT vital_sign_supersedes_uk UNIQUE (supersedes_id),
    CONSTRAINT vital_sign_no_self_supersede_ck CHECK (supersedes_id IS DISTINCT FROM id),
    CONSTRAINT vital_sign_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT vital_sign_encounter_fk
      FOREIGN KEY (encounter_id, patient_id)
      REFERENCES public.encounter (id, patient_id) ON DELETE RESTRICT,
    CONSTRAINT vital_sign_recorder_fk
      FOREIGN KEY (recorded_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT vital_sign_supersedes_fk
      FOREIGN KEY (supersedes_id, organization_id)
      REFERENCES public.vital_sign (id, organization_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS vital_sign_patient_ix
  ON public.vital_sign (organization_id, patient_id, measured_at DESC)
  WHERE record_status = 'active'::app.record_status;

COMMENT ON TABLE public.vital_sign IS
  'One set of observations taken at one moment. Feeds the four vitals cards and any trend line '
  'over them. Corrections are made by inserting a superseding row and marking the old one '
  '''amended'' — a vital that was charted and acted upon does not get quietly rewritten.';
COMMENT ON COLUMN public.vital_sign.supplemental_o2 IS
  'Oxygen delivery in the nurse''s own words ("2L NC"), because the timeline note that matters '
  '("O₂ titrated to 2L") is prose and a code set here would be filled in wrongly or not at all.';

DROP TRIGGER IF EXISTS t_touch ON public.vital_sign;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.vital_sign
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_append_only ON public.vital_sign;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.vital_sign
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only('{record_status,note,updated_at}');
DROP TRIGGER IF EXISTS t_no_delete ON public.vital_sign;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.vital_sign
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 30 — LABS
--
-- Four tables where the draft had six:
--   lab_panel  — what you can order ("Lactate, repeat", "BNP, renal panel", "Echo report")
--   lab_test   — the analyte, with its default unit and reference range
--   lab_order  — a request for a panel, for a patient, by a clinician
--   lab_result — one analyte value that came back
--
-- NOT MODELLED: panel↔test membership. It looks obviously necessary and is not: nothing in
-- this app displays a panel's expected contents, and results arrive with their own analyte
-- identity from the analyser. A membership table would exist only to be kept in sync with a
-- laboratory information system that is the real authority on it. When order-set validation
-- ("this panel should have produced four results, two are missing") becomes a feature, add
-- lab_panel_test then — it is an additive migration with no rewrites.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.lab_panel (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    code             text        NOT NULL,
    name             text        NOT NULL,
    department_id    uuid        NULL,
    is_active        boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT lab_panel_code_ck CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT lab_panel_name_ck CHECK (btrim(name) <> ''),
    CONSTRAINT lab_panel_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT lab_panel_department_fk
      FOREIGN KEY (department_id, organization_id)
      REFERENCES public.department (id, organization_id) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS lab_panel_code_uk ON public.lab_panel (organization_id, code);

CREATE TABLE IF NOT EXISTS public.lab_test (
    id               uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid         NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    code             text         NOT NULL,
    name             text         NOT NULL,
    default_unit     text         NULL,
    reference_low    numeric      NULL,
    reference_high   numeric      NULL,
    reference_note   text         NULL,
    critical_low     numeric      NULL,
    critical_high    numeric      NULL,
    is_active        boolean      NOT NULL DEFAULT true,
    created_at       timestamptz  NOT NULL DEFAULT now(),
    updated_at       timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT lab_test_code_ck CHECK (code ~ '^[a-z][a-z0-9_]{1,40}$'),
    CONSTRAINT lab_test_name_ck CHECK (btrim(name) <> ''),
    CONSTRAINT lab_test_range_ck
      CHECK (reference_low IS NULL OR reference_high IS NULL OR reference_low <= reference_high),
    CONSTRAINT lab_test_critical_ck
      CHECK (critical_low IS NULL OR critical_high IS NULL OR critical_low <= critical_high),
    CONSTRAINT lab_test_id_org_uk UNIQUE (id, organization_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS lab_test_code_uk ON public.lab_test (organization_id, code);

COMMENT ON TABLE public.lab_test IS
  'The analyte catalogue: Lactate, WBC, CRP, Creatinine, HbA1c, eGFR. Tenant-scoped because '
  'each hospital''s laboratory sets its own reference ranges and units, and importing another '
  'hospital''s ranges is how a normal result gets flagged critical.';
COMMENT ON COLUMN public.lab_test.reference_low IS
  'Lower bound of normal. NULL with a reference_high set means a one-sided range: the CRP row '
  'in the app renders "< 5". Both NULL means the normal range is not numeric — put it in '
  'reference_note. Render any of these with app.format_reference_range().';
COMMENT ON COLUMN public.lab_test.critical_low IS
  'Panic value, distinct from merely abnormal. Cannot be derived from the reference range — a '
  'lactate of 3.1 is outside 0.5–2.2 but it is the trajectory that makes it critical — so the '
  'thresholds are stated, and a flag sent by the laboratory always beats the derived one.';

CREATE TABLE IF NOT EXISTS public.lab_order (
    id                 uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id    uuid                 NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id         uuid                 NOT NULL,
    encounter_id       uuid                 NULL,
    panel_id           uuid                 NOT NULL,
    ordered_by         uuid                 NOT NULL,
    priority           app.lab_priority     NOT NULL DEFAULT 'routine',
    status             app.lab_order_status NOT NULL DEFAULT 'ordered',
    clinical_note      text                 NULL,
    ordered_at         timestamptz          NOT NULL DEFAULT now(),
    collected_at       timestamptz          NULL,
    cancelled_at       timestamptz          NULL,
    cancellation_reason text                NULL,
    record_status      app.record_status    NOT NULL DEFAULT 'active',
    created_at         timestamptz          NOT NULL DEFAULT now(),
    updated_at         timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT lab_order_collected_ck
      CHECK (status NOT IN ('collected', 'in_progress', 'resulted') OR collected_at IS NOT NULL),
    CONSTRAINT lab_order_cancelled_ck CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL)),
    CONSTRAINT lab_order_times_ck CHECK (collected_at IS NULL OR collected_at >= ordered_at),
    CONSTRAINT lab_order_id_org_uk     UNIQUE (id, organization_id),
    -- So lab_result can carry patient_id and have the database prove it matches the order.
    CONSTRAINT lab_order_id_patient_uk UNIQUE (id, patient_id),
    CONSTRAINT lab_order_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT lab_order_encounter_fk
      FOREIGN KEY (encounter_id, patient_id)
      REFERENCES public.encounter (id, patient_id) ON DELETE RESTRICT,
    CONSTRAINT lab_order_panel_fk
      FOREIGN KEY (panel_id, organization_id)
      REFERENCES public.lab_panel (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT lab_order_ordered_by_fk
      FOREIGN KEY (ordered_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS lab_order_patient_ix
  ON public.lab_order (organization_id, patient_id, ordered_at DESC)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS lab_order_open_ix
  ON public.lab_order (organization_id, status, ordered_at DESC)
  WHERE status <> 'resulted'::app.lab_order_status
    AND status <> 'cancelled'::app.lab_order_status;

COMMENT ON TABLE public.lab_order IS
  'A request for a panel. The "Order labs" action on the patient header creates one. Status '
  'tracks the specimen, not the interpretation — reviewing a RESULT is a separate act recorded '
  'on lab_result, because a clinician can accept a normal sodium while still chasing the '
  'potassium from the same order.';

CREATE TABLE IF NOT EXISTS public.lab_result (
    id                    uuid                  PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid                  NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    lab_order_id          uuid                  NOT NULL,
    patient_id            uuid                  NOT NULL,
    lab_test_id           uuid                  NOT NULL,

    value_numeric         numeric               NULL,
    value_text            text                  NULL,
    unit                  text                  NULL,
    reference_low         numeric               NULL,
    reference_high        numeric               NULL,
    reference_note        text                  NULL,
    -- NOT NULL, yet writers may omit it: app.fill_lab_result_flag() derives it BEFORE INSERT,
    -- and BEFORE triggers run ahead of constraint checks. So the column is always populated and
    -- an ETL that knows nothing about ranges still produces a usable flag.
    abnormal_flag         app.lab_abnormal_flag NOT NULL,
    resulted_at           timestamptz           NOT NULL DEFAULT now(),
    performing_lab        text                  NULL,

    review_status         app.lab_review_status NOT NULL DEFAULT 'unreviewed',
    reviewed_by           uuid                  NULL,
    reviewed_at           timestamptz           NULL,
    review_note           text                  NULL,

    released_to_patient_at timestamptz          NULL,
    supersedes_id         uuid                  NULL,
    record_status         app.record_status     NOT NULL DEFAULT 'active',
    created_at            timestamptz           NOT NULL DEFAULT now(),
    updated_at            timestamptz           NOT NULL DEFAULT now(),

    CONSTRAINT lab_result_has_value_ck  CHECK (num_nonnulls(value_numeric, value_text) > 0),
    CONSTRAINT lab_result_unit_ck       CHECK (value_numeric IS NULL OR unit IS NOT NULL),
    CONSTRAINT lab_result_range_ck
      CHECK (reference_low IS NULL OR reference_high IS NULL OR reference_low <= reference_high),
    CONSTRAINT lab_result_reviewed_ck
      CHECK ((review_status = 'unreviewed') = (reviewed_by IS NULL AND reviewed_at IS NULL)),
    CONSTRAINT lab_result_review_time_ck CHECK (reviewed_at IS NULL OR reviewed_at >= resulted_at),
    CONSTRAINT lab_result_supersedes_uk  UNIQUE (supersedes_id),
    CONSTRAINT lab_result_no_self_supersede_ck CHECK (supersedes_id IS DISTINCT FROM id),
    CONSTRAINT lab_result_id_org_uk      UNIQUE (id, organization_id),

    CONSTRAINT lab_result_order_org_fk
      FOREIGN KEY (lab_order_id, organization_id)
      REFERENCES public.lab_order (id, organization_id) ON DELETE RESTRICT,
    -- The pair that makes patient_id trustworthy rather than a hopeful copy.
    CONSTRAINT lab_result_order_patient_fk
      FOREIGN KEY (lab_order_id, patient_id)
      REFERENCES public.lab_order (id, patient_id) ON DELETE RESTRICT,
    CONSTRAINT lab_result_test_fk
      FOREIGN KEY (lab_test_id, organization_id)
      REFERENCES public.lab_test (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT lab_result_reviewer_fk
      FOREIGN KEY (reviewed_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT lab_result_supersedes_fk
      FOREIGN KEY (supersedes_id, organization_id)
      REFERENCES public.lab_result (id, organization_id) ON DELETE RESTRICT
);

-- "Labs awaiting review" — the queue the doctor screen opens on.
CREATE INDEX IF NOT EXISTS lab_result_review_queue_ix
  ON public.lab_result (organization_id, resulted_at DESC)
  INCLUDE (patient_id, lab_test_id, abnormal_flag)
  WHERE review_status = 'unreviewed'::app.lab_review_status
    AND record_status = 'active'::app.record_status;
-- The "Abnormal (3)" chip on the same screen.
CREATE INDEX IF NOT EXISTS lab_result_abnormal_ix
  ON public.lab_result (organization_id, resulted_at DESC)
  WHERE abnormal_flag <> 'normal'::app.lab_abnormal_flag
    AND record_status = 'active'::app.record_status;
-- "Recent labs" on the patient screen, and the per-analyte series behind any trend arrow.
CREATE INDEX IF NOT EXISTS lab_result_patient_ix
  ON public.lab_result (organization_id, patient_id, resulted_at DESC)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS lab_result_series_ix
  ON public.lab_result (organization_id, patient_id, lab_test_id, resulted_at)
  WHERE record_status = 'active'::app.record_status;
-- The patient portal's results list.
CREATE INDEX IF NOT EXISTS lab_result_released_ix
  ON public.lab_result (organization_id, patient_id, released_to_patient_at DESC)
  WHERE released_to_patient_at IS NOT NULL
    AND record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS lab_result_order_ix
  ON public.lab_result (organization_id, lab_order_id);

COMMENT ON TABLE public.lab_result IS
  'One analyte value. Feeds "Recent labs" on the patient screen, the doctor Labs review queue '
  'and the portal results list. A result is never edited after it arrives: a corrected value '
  'from the laboratory is a NEW row pointing at the old one through supersedes_id, and the old '
  'row becomes record_status = ''amended''. The append-only trigger enforces that.';
COMMENT ON COLUMN public.lab_result.reference_low IS
  'The range THIS result was interpreted against, copied from lab_test at result time rather '
  'than joined at read time. A catalogue change must not silently re-interpret a result a '
  'clinician already acted on. One-sided and non-numeric ranges work exactly as on lab_test.';
COMMENT ON COLUMN public.lab_result.review_status IS
  'Drives the All / Abnormal / Reviewed filter chips. "Labs awaiting review" is '
  '''unreviewed''. A panel counts as reviewed when all its active results are — aggregate at '
  'read time rather than storing that state a second time on lab_order, where it would drift.';
COMMENT ON COLUMN public.lab_result.released_to_patient_at IS
  'When this result was released to the portal. NULL means not released, and the patient RLS '
  'policy requires it to be non-NULL — so an unreviewed abnormal cannot reach a patient before '
  'anyone has spoken to them. Release is a clinical act, not a side effect of resulting.';
COMMENT ON COLUMN public.lab_result.value_text IS
  'The result when it is not a number: "EF 58%", "no growth at 48h". The report DOCUMENT (a '
  'PDF or DICOM study) is 030''s concern — no bytes are stored in any column of this file.';

-- Fills the abnormal flag when the writer did not send one, from the range on the row. A flag
-- the laboratory sent is never overwritten: they know about criticals, delta checks and
-- interference; a range comparison does not.
CREATE OR REPLACE FUNCTION app.fill_lab_result_flag()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_crit_low  numeric;
  v_crit_high numeric;
BEGIN
  IF NEW.abnormal_flag IS NOT NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.value_numeric IS NULL THEN
    NEW.abnormal_flag := 'indeterminate';
    RETURN NEW;
  END IF;

  SELECT t.critical_low, t.critical_high INTO v_crit_low, v_crit_high
    FROM public.lab_test t WHERE t.id = NEW.lab_test_id;

  NEW.abnormal_flag := CASE
    WHEN v_crit_low  IS NOT NULL AND NEW.value_numeric <= v_crit_low  THEN 'critical_low'
    WHEN v_crit_high IS NOT NULL AND NEW.value_numeric >= v_crit_high THEN 'critical_high'
    WHEN NEW.reference_low  IS NOT NULL AND NEW.value_numeric < NEW.reference_low  THEN 'low'
    WHEN NEW.reference_high IS NOT NULL AND NEW.value_numeric > NEW.reference_high THEN 'high'
    WHEN NEW.reference_low IS NULL AND NEW.reference_high IS NULL THEN 'indeterminate'
    ELSE 'normal'
  END::app.lab_abnormal_flag;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_fill_flag ON public.lab_result;
CREATE TRIGGER t_fill_flag BEFORE INSERT ON public.lab_result
  FOR EACH ROW EXECUTE FUNCTION app.fill_lab_result_flag();

DROP TRIGGER IF EXISTS t_touch ON public.lab_result;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.lab_result
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
-- Everything about the VALUE is frozen; the review and release decisions are not.
DROP TRIGGER IF EXISTS t_append_only ON public.lab_result;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.lab_result
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only(
    '{review_status,reviewed_by,reviewed_at,review_note,released_to_patient_at,record_status,updated_at}');
DROP TRIGGER IF EXISTS t_no_delete ON public.lab_result;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.lab_result
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

DROP TRIGGER IF EXISTS t_touch ON public.lab_order;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.lab_order
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.lab_order;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.lab_order
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_touch ON public.lab_panel;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.lab_panel
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_touch ON public.lab_test;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.lab_test
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- =============================================================================================
-- SECTION 31 — CLINICAL NOTES (the Timeline)
--
-- The Timeline card is a chronology, not a table: "Nursing note: increased work of breathing",
-- "Lactate 3.1 — flagged by Prognosify", "IV ceftriaxone administered per protocol", "Admitted
-- via ED". Only the prose entries are rows here; the lab and admission entries are assembled by
-- v_patient_timeline (§40) from the tables that already hold those facts. Copying them into a
-- notes table would create a second, divergent version of the same event.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.clinical_note (
    id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid              NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id       uuid              NOT NULL,
    encounter_id     uuid              NULL,
    author_member_id uuid              NOT NULL,
    note_type        app.note_type     NOT NULL DEFAULT 'progress',
    occurred_at      timestamptz       NOT NULL DEFAULT now(),
    body             text              NOT NULL,
    signed_at        timestamptz       NULL,
    supersedes_id    uuid              NULL,
    amendment_reason text              NULL,
    record_status    app.record_status NOT NULL DEFAULT 'active',
    created_at       timestamptz       NOT NULL DEFAULT now(),
    updated_at       timestamptz       NOT NULL DEFAULT now(),

    CONSTRAINT clinical_note_body_ck CHECK (btrim(body) <> ''),
    CONSTRAINT clinical_note_amendment_ck
      CHECK (supersedes_id IS NULL OR btrim(coalesce(amendment_reason, '')) <> ''),
    CONSTRAINT clinical_note_no_self_supersede_ck CHECK (supersedes_id IS DISTINCT FROM id),
    CONSTRAINT clinical_note_supersedes_uk UNIQUE (supersedes_id),
    CONSTRAINT clinical_note_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT clinical_note_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT clinical_note_encounter_fk
      FOREIGN KEY (encounter_id, patient_id)
      REFERENCES public.encounter (id, patient_id) ON DELETE RESTRICT,
    CONSTRAINT clinical_note_author_fk
      FOREIGN KEY (author_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT clinical_note_supersedes_fk
      FOREIGN KEY (supersedes_id, organization_id)
      REFERENCES public.clinical_note (id, organization_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS clinical_note_patient_ix
  ON public.clinical_note (organization_id, patient_id, occurred_at DESC)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS clinical_note_draft_ix
  ON public.clinical_note (organization_id, author_member_id, updated_at DESC)
  WHERE signed_at IS NULL AND record_status = 'active'::app.record_status;

COMMENT ON TABLE public.clinical_note IS
  'Narrative entries: nursing notes, progress notes, admission and discharge summaries. '
  'Unsigned notes are drafts and belong to their author. Once signed, the text is frozen — a '
  'correction is a new note with supersedes_id and a reason, so the record shows both what was '
  'believed at the time and what was later understood.';
COMMENT ON COLUMN public.clinical_note.signed_at IS
  'NULL means draft. Signing is the moment the note becomes part of the record; the guard '
  'trigger freezes body, type and occurred_at from then on.';

CREATE OR REPLACE FUNCTION app.guard_clinical_note()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF coalesce(current_setting('app.allow_clinical_rewrite', true), 'off') = 'on' THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  IF OLD.signed_at IS NOT NULL THEN
    IF NEW.body        IS DISTINCT FROM OLD.body
       OR NEW.note_type   IS DISTINCT FROM OLD.note_type
       OR NEW.occurred_at IS DISTINCT FROM OLD.occurred_at
       OR NEW.signed_at   IS DISTINCT FROM OLD.signed_at
       OR NEW.author_member_id IS DISTINCT FROM OLD.author_member_id THEN
      RAISE EXCEPTION 'A signed note cannot be rewritten.'
        USING errcode = '42501',
              hint = 'Write a new note with supersedes_id and amendment_reason, and set this one to ''amended''.';
    END IF;
  ELSIF OLD.author_member_id <> app.current_member_id() THEN
    -- A draft belongs to whoever is writing it. Co-signing is not modelled (see §92).
    RAISE EXCEPTION 'Only the author may edit an unsigned note.' USING errcode = '42501';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_guard ON public.clinical_note;
CREATE TRIGGER t_guard BEFORE UPDATE ON public.clinical_note
  FOR EACH ROW EXECUTE FUNCTION app.guard_clinical_note();
DROP TRIGGER IF EXISTS t_no_delete ON public.clinical_note;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.clinical_note
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 32 — MEDICATIONS
--
-- One table. The screens show a current medication list ("Ceftriaxone 1g IV — q24h",
-- "Paracetamol 1g — PRN", "Metformin 500mg with breakfast") and a Request-refill link.
--
-- NOT MODELLED, each a decision rather than an oversight:
--   * a drug master. We have no formulary, no code system and no interaction data, and an empty
--     catalogue the app fills with free text as it goes is worse than honest free text —
--     it looks authoritative.
--   * medication_administration (the eMAR). Nothing in the app records or displays individual
--     administrations; "IV ceftriaxone administered per protocol" is a timeline note. An eMAR
--     is a feature with its own screens, and modelling it now models a product nobody designed.
--   * frequency as an enum. "q24h", "PRN" and "with breakfast" are the strings the UI prints
--     and real sigs do not fit a closed set. route IS an enum: that one genuinely is closed.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.medication_order (
    id                    uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid                 NOT NULL REFERENCES public.organization (id) ON DELETE RESTRICT,
    patient_id            uuid                 NOT NULL,
    encounter_id          uuid                 NULL,
    prescriber_member_id  uuid                 NOT NULL,

    drug_name             text                 NOT NULL,
    drug_code             text                 NULL,
    dose_text             text                 NOT NULL,
    route                 app.medication_route NOT NULL DEFAULT 'oral',
    frequency_text        text                 NOT NULL,
    is_prn                boolean              NOT NULL DEFAULT false,
    instructions          text                 NULL,

    status                app.medication_status NOT NULL DEFAULT 'active',
    started_at            timestamptz          NOT NULL DEFAULT now(),
    ended_at              timestamptz          NULL,
    stop_reason           text                 NULL,
    refill_requested_at   timestamptz          NULL,

    record_status         app.record_status    NOT NULL DEFAULT 'active',
    created_at            timestamptz          NOT NULL DEFAULT now(),
    updated_at            timestamptz          NOT NULL DEFAULT now(),

    CONSTRAINT medication_order_drug_ck CHECK (btrim(drug_name) <> ''),
    CONSTRAINT medication_order_dose_ck CHECK (btrim(dose_text) <> ''),
    CONSTRAINT medication_order_freq_ck CHECK (btrim(frequency_text) <> ''),
    CONSTRAINT medication_order_ended_ck
      CHECK ((status IN ('completed', 'discontinued')) = (ended_at IS NOT NULL)),
    CONSTRAINT medication_order_window_ck CHECK (ended_at IS NULL OR ended_at >= started_at),
    CONSTRAINT medication_order_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT medication_order_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON DELETE RESTRICT,
    CONSTRAINT medication_order_encounter_fk
      FOREIGN KEY (encounter_id, patient_id)
      REFERENCES public.encounter (id, patient_id) ON DELETE RESTRICT,
    CONSTRAINT medication_order_prescriber_fk
      FOREIGN KEY (prescriber_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS medication_order_patient_ix
  ON public.medication_order (organization_id, patient_id, started_at DESC)
  WHERE record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS medication_order_active_ix
  ON public.medication_order (organization_id, patient_id)
  WHERE status = 'active'::app.medication_status
    AND record_status = 'active'::app.record_status;
CREATE INDEX IF NOT EXISTS medication_order_refill_ix
  ON public.medication_order (organization_id, refill_requested_at DESC)
  WHERE refill_requested_at IS NOT NULL;

COMMENT ON TABLE public.medication_order IS
  'What the patient has been prescribed. Feeds the Medications card on the patient screen and '
  'the portal care plan. Stopping a medication sets status and ended_at; rows are never '
  'deleted, because "was never prescribed" and "was stopped last Tuesday" are different '
  'clinical facts and the difference matters in a review.';
COMMENT ON COLUMN public.medication_order.refill_requested_at IS
  'Set by the patient through the portal''s "Request refill" link — the only column a patient '
  'may write here, enforced by app.enforce_patient_writable_columns(). Cleared by staff when '
  'the request is actioned.';

DROP TRIGGER IF EXISTS t_touch ON public.medication_order;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.medication_order
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_patient_columns ON public.medication_order;
CREATE TRIGGER t_patient_columns BEFORE UPDATE ON public.medication_order
  FOR EACH ROW EXECUTE FUNCTION app.enforce_patient_writable_columns('{refill_requested_at,updated_at}');
DROP TRIGGER IF EXISTS t_no_delete ON public.medication_order;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.medication_order
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

-- =============================================================================================
-- SECTION 33 — ROW LEVEL SECURITY
--
-- HOW TO READ EVERY POLICY BELOW: tenant, then purpose, then row.
--   1. `organization_id = app.current_org_id()` — always first, always present. This is the
--      isolation boundary. It is also what contains the vendor: a platform admin holds no
--      membership, so the expression is NULL for them and no clinical row is ever returned.
--   2. a purpose predicate — app.is_clinician() / app.is_front_desk() / app.is_hospital_admin().
--      NEVER app.is_staff() on a clinical table: it is true for hospital_admin, who has no
--      treatment relationship with anyone.
--   3. a row predicate — `patient_id = ANY (app.care_patient_ids())` for staff, or
--      `patient_id = app.current_patient_id()` for the patient themselves.
--
-- ENABLE, never FORCE (010 §8.1): the helpers are SECURITY DEFINER and owned by the table
-- owner, so FORCE would make the owner's own reads re-enter the policies that call them.
--
-- No DELETE policy exists on any table in this file, and every clinical table also carries
-- app.deny_hard_delete(). Two independent mechanisms, because one of them will be edited by
-- someone in a hurry.
-- =============================================================================================

ALTER TABLE public.department        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.visit_type        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_profile     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_condition ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.patient_allergy   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_team_member  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.encounter         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appointment       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vital_sign        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_panel         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_test          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_order         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.lab_result        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinical_note     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.medication_order  ENABLE ROW LEVEL SECURITY;

-- ---- 33.1 configuration: everyone in the tenant reads, hospital_admin writes -----------------
-- Readable by patients too: the portal booking screen names the department and the provider.
-- None of these tables contains a fact about a person.

DROP POLICY IF EXISTS department_select ON public.department;
CREATE POLICY department_select ON public.department FOR SELECT
  USING (organization_id = app.current_org_id());
DROP POLICY IF EXISTS department_write ON public.department;
CREATE POLICY department_write ON public.department FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());
DROP POLICY IF EXISTS department_update ON public.department;
CREATE POLICY department_update ON public.department FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_hospital_admin())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());

DROP POLICY IF EXISTS visit_type_select ON public.visit_type;
CREATE POLICY visit_type_select ON public.visit_type FOR SELECT
  USING (organization_id = app.current_org_id());
DROP POLICY IF EXISTS visit_type_write ON public.visit_type;
CREATE POLICY visit_type_write ON public.visit_type FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());
DROP POLICY IF EXISTS visit_type_update ON public.visit_type;
CREATE POLICY visit_type_update ON public.visit_type FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_hospital_admin())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());

DROP POLICY IF EXISTS lab_panel_select ON public.lab_panel;
CREATE POLICY lab_panel_select ON public.lab_panel FOR SELECT
  USING (organization_id = app.current_org_id() AND app.is_staff());
DROP POLICY IF EXISTS lab_panel_write ON public.lab_panel;
CREATE POLICY lab_panel_write ON public.lab_panel FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());
DROP POLICY IF EXISTS lab_panel_update ON public.lab_panel;
CREATE POLICY lab_panel_update ON public.lab_panel FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_hospital_admin())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());

-- lab_test is readable by patients as well: the portal explains a result in plain language and
-- needs the analyte's name and reference range to do it. It holds no patient data.
DROP POLICY IF EXISTS lab_test_select ON public.lab_test;
CREATE POLICY lab_test_select ON public.lab_test FOR SELECT
  USING (organization_id = app.current_org_id());
DROP POLICY IF EXISTS lab_test_write ON public.lab_test;
CREATE POLICY lab_test_write ON public.lab_test FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());
DROP POLICY IF EXISTS lab_test_update ON public.lab_test;
CREATE POLICY lab_test_update ON public.lab_test FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_hospital_admin())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());

-- staff_profile: any member of the tenant may see who works there and in which department —
-- that is a directory fact, and the portal shows it on the booking screen.
DROP POLICY IF EXISTS staff_profile_select ON public.staff_profile;
CREATE POLICY staff_profile_select ON public.staff_profile FOR SELECT
  USING (organization_id = app.current_org_id());
DROP POLICY IF EXISTS staff_profile_write ON public.staff_profile;
CREATE POLICY staff_profile_write ON public.staff_profile FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_hospital_admin());
DROP POLICY IF EXISTS staff_profile_update ON public.staff_profile;
CREATE POLICY staff_profile_update ON public.staff_profile FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR member_id = app.current_member_id()))
  WITH CHECK (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR member_id = app.current_member_id()));

-- ---- 33.2 care team --------------------------------------------------------------------------
-- Staff see the care team (it is a card on the patient screen and a provider picker elsewhere);
-- a patient sees who is looking after them, and nobody else's team.
DROP POLICY IF EXISTS care_team_select ON public.care_team_member;
CREATE POLICY care_team_select ON public.care_team_member FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (app.is_staff() OR patient_id = app.current_patient_id()));

-- A clinician may assume care of a patient in their own hospital — and only for themselves.
-- Assigning somebody ELSE is an administrative act. See §26 for the argument.
DROP POLICY IF EXISTS care_team_insert ON public.care_team_member;
CREATE POLICY care_team_insert ON public.care_team_member FOR INSERT
  WITH CHECK (
    organization_id = app.current_org_id()
    AND added_by = app.current_member_id()
    AND (
      (app.is_clinician() AND member_id = app.current_member_id())
      OR app.is_hospital_admin()
    )
  );

DROP POLICY IF EXISTS care_team_update ON public.care_team_member;
CREATE POLICY care_team_update ON public.care_team_member FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR member_id = app.current_member_id()))
  WITH CHECK (organization_id = app.current_org_id());

-- ---- 33.3 the chart ---------------------------------------------------------------------------
-- Identical shape on every table so a reviewer can check them at a glance:
--   read  : clinician on the care team, or the patient themselves
--   write : clinician on the care team
-- A receptionist matches none of these. A hospital_admin matches none of these. A vendor admin
-- has no organisation, so they fail at the first conjunct.

DROP POLICY IF EXISTS patient_condition_select ON public.patient_condition;
CREATE POLICY patient_condition_select ON public.patient_condition FOR SELECT
  USING (organization_id = app.current_org_id()
         AND ((app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()));
DROP POLICY IF EXISTS patient_condition_insert ON public.patient_condition;
CREATE POLICY patient_condition_insert ON public.patient_condition FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids())
              AND recorded_by = app.current_member_id());
DROP POLICY IF EXISTS patient_condition_update ON public.patient_condition;
CREATE POLICY patient_condition_update ON public.patient_condition FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

DROP POLICY IF EXISTS patient_allergy_select ON public.patient_allergy;
CREATE POLICY patient_allergy_select ON public.patient_allergy FOR SELECT
  USING (organization_id = app.current_org_id()
         AND ((app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()));
DROP POLICY IF EXISTS patient_allergy_insert ON public.patient_allergy;
CREATE POLICY patient_allergy_insert ON public.patient_allergy FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids())
              AND recorded_by = app.current_member_id());
DROP POLICY IF EXISTS patient_allergy_update ON public.patient_allergy;
CREATE POLICY patient_allergy_update ON public.patient_allergy FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

-- encounter INSERT is the one place care-team membership is NOT required, because admitting a
-- patient is precisely the act that creates the relationship. The AFTER trigger then puts the
-- attending on the care team, so the admitting clinician can read back what they just wrote.
-- A clinician who admits a patient under someone else's name cannot read the row afterwards —
-- deliberate, and the reason PostgREST callers should not rely on INSERT ... RETURNING here.
DROP POLICY IF EXISTS encounter_select ON public.encounter;
CREATE POLICY encounter_select ON public.encounter FOR SELECT
  USING (organization_id = app.current_org_id()
         AND ((app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()));
DROP POLICY IF EXISTS encounter_insert ON public.encounter;
CREATE POLICY encounter_insert ON public.encounter FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND created_by = app.current_member_id());
DROP POLICY IF EXISTS encounter_update ON public.encounter;
CREATE POLICY encounter_update ON public.encounter FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

DROP POLICY IF EXISTS vital_sign_select ON public.vital_sign;
CREATE POLICY vital_sign_select ON public.vital_sign FOR SELECT
  USING (organization_id = app.current_org_id()
         AND ((app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()));
DROP POLICY IF EXISTS vital_sign_insert ON public.vital_sign;
CREATE POLICY vital_sign_insert ON public.vital_sign FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids()));
DROP POLICY IF EXISTS vital_sign_update ON public.vital_sign;
CREATE POLICY vital_sign_update ON public.vital_sign FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

-- Lab ORDERS are staff-only: an order in flight is a clinical intention, and showing a patient
-- "sepsis workup ordered" before anyone has spoken to them is a conversation nobody planned.
-- The RESULT is what gets released to the portal, deliberately and per row.
DROP POLICY IF EXISTS lab_order_select ON public.lab_order;
CREATE POLICY lab_order_select ON public.lab_order FOR SELECT
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));
DROP POLICY IF EXISTS lab_order_insert ON public.lab_order;
CREATE POLICY lab_order_insert ON public.lab_order FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids())
              AND ordered_by = app.current_member_id());
DROP POLICY IF EXISTS lab_order_update ON public.lab_order;
CREATE POLICY lab_order_update ON public.lab_order FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

DROP POLICY IF EXISTS lab_result_select ON public.lab_result;
CREATE POLICY lab_result_select ON public.lab_result FOR SELECT
  USING (organization_id = app.current_org_id()
         AND ((app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
              OR (patient_id = app.current_patient_id()
                  AND released_to_patient_at IS NOT NULL
                  AND released_to_patient_at <= now())));
DROP POLICY IF EXISTS lab_result_insert ON public.lab_result;
CREATE POLICY lab_result_insert ON public.lab_result FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids()));
DROP POLICY IF EXISTS lab_result_update ON public.lab_result;
CREATE POLICY lab_result_update ON public.lab_result FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

-- Notes are the one clinical table a patient cannot read. Not because the content is secret
-- from them — DPDP gives data principals access rights and this schema does not obstruct them —
-- but because a note routinely contains third-party information (what a relative reported) and
-- provisional reasoning that needs a clinician alongside it. Access requests are served through
-- a mediated export, which is a workflow decision for the operator, not a policy line here.
DROP POLICY IF EXISTS clinical_note_select ON public.clinical_note;
CREATE POLICY clinical_note_select ON public.clinical_note FOR SELECT
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));
DROP POLICY IF EXISTS clinical_note_insert ON public.clinical_note;
CREATE POLICY clinical_note_insert ON public.clinical_note FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids())
              AND author_member_id = app.current_member_id());
DROP POLICY IF EXISTS clinical_note_update ON public.clinical_note;
CREATE POLICY clinical_note_update ON public.clinical_note FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());

-- Prescribing is a doctor's act, so INSERT is app.has_role('doctor') rather than is_clinician().
-- A nurse on the care team can read the list and stop nothing.
DROP POLICY IF EXISTS medication_order_select ON public.medication_order;
CREATE POLICY medication_order_select ON public.medication_order FOR SELECT
  USING (organization_id = app.current_org_id()
         AND ((app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()));
DROP POLICY IF EXISTS medication_order_insert ON public.medication_order;
CREATE POLICY medication_order_insert ON public.medication_order FOR INSERT
  WITH CHECK (organization_id = app.current_org_id() AND app.has_role('doctor')
              AND patient_id = ANY (app.care_patient_ids())
              AND prescriber_member_id = app.current_member_id());
-- The patient branch exists only for "Request refill"; the trigger limits it to that column.
DROP POLICY IF EXISTS medication_order_update ON public.medication_order;
CREATE POLICY medication_order_update ON public.medication_order FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND ((app.has_role('doctor') AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()))
  WITH CHECK (organization_id = app.current_org_id());

-- ---- 33.4 appointments: the one clinical-adjacent table reception owns -------------------------
-- Scheduling is org-wide for the front desk (they run the whole clinic's day) and for
-- clinicians (the day summary and the ward round need more than their own panel). It is NOT
-- open to hospital_admin: managing a hospital does not require knowing who is attending it
-- today. Patients see their own appointments and the block rows of nobody.
DROP POLICY IF EXISTS appointment_select ON public.appointment;
CREATE POLICY appointment_select ON public.appointment FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (app.is_front_desk() OR app.is_clinician()
              OR (patient_id IS NOT NULL AND patient_id = app.current_patient_id())));
DROP POLICY IF EXISTS appointment_insert ON public.appointment;
CREATE POLICY appointment_insert ON public.appointment FOR INSERT
  WITH CHECK (organization_id = app.current_org_id()
              AND (app.is_front_desk() OR app.is_clinician()));
DROP POLICY IF EXISTS appointment_update ON public.appointment;
CREATE POLICY appointment_update ON public.appointment FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_front_desk() OR app.is_clinician()
              OR (patient_id IS NOT NULL AND patient_id = app.current_patient_id())))
  WITH CHECK (organization_id = app.current_org_id());

-- =============================================================================================
-- SECTION 40 — READ SURFACES
--
-- EVERY view here is `WITH (security_invoker = true)`. A view without it runs as its OWNER,
-- which on Supabase is a superuser-ish role that bypasses RLS — the single easiest way to
-- build a perfect tenant-isolation model and then leak straight through a convenience view.
-- With security_invoker the underlying policies still apply, so these views narrow COLUMNS and
-- shape output; they never widen access. Both matter and neither substitutes for the other:
-- the column list keeps a receptionist's query from mentioning a result, and RLS is what stops
-- it returning one.
-- =============================================================================================

-- The front desk's patient. Every column here is administrative; there is deliberately no
-- condition, no allergy, no result, no note. Registration, booking and check-in need exactly
-- this much to do their job.
CREATE OR REPLACE VIEW public.v_front_desk_patient
WITH (security_invoker = true) AS
SELECT p.id                AS patient_id,
       p.organization_id,
       p.mrn,
       p.first_name,
       p.last_name,
       p.first_name || ' ' || p.last_name AS full_name,
       p.date_of_birth,
       (extract(year FROM age(p.date_of_birth)))::int AS age_years,
       p.sex,
       p.phone,
       p.email,
       p.status,
       p.merged_into_patient_id
  FROM public.patient p;

COMMENT ON VIEW public.v_front_desk_patient IS
  'Column-limited patient record for the reception screens (Register, Booking, Check-in, Front '
  'desk). Administrative fields only. security_invoker, so 010''s patient policy still decides '
  'which rows come back.';

-- The Check-in queue screen, including the live waiting time the amber row is driven by.
CREATE OR REPLACE VIEW public.v_checkin_queue
WITH (security_invoker = true) AS
SELECT a.id               AS appointment_id,
       a.organization_id,
       a.queue_date,
       a.queue_ticket,
       a.status,
       a.scheduled_start,
       a.modality,
       a.origin,
       a.room_label,
       a.chief_complaint,
       p.id               AS patient_id,
       p.mrn,
       p.first_name || ' ' || p.last_name AS patient_name,
       pu.full_name       AS provider_name,
       d.name             AS department_name,
       vt.name            AS visit_type_name,
       a.checked_in_at,
       -- Live, not stored: "waiting 32 min" is the truth at read time or it is a lie.
       CASE WHEN a.checked_in_at IS NOT NULL
            THEN floor(extract(epoch FROM (coalesce(a.roomed_at, now()) - a.checked_in_at)) / 60)::int
       END                AS waiting_minutes
  FROM public.appointment a
  LEFT JOIN public.patient p             ON p.id = a.patient_id
  LEFT JOIN public.organization_member m ON m.id = a.provider_member_id
  LEFT JOIN public.app_user pu           ON pu.id = m.app_user_id
  LEFT JOIN public.department d          ON d.id = a.department_id
  LEFT JOIN public.visit_type vt         ON vt.id = a.visit_type_id
 WHERE a.record_status = 'active'::app.record_status
   AND a.patient_id IS NOT NULL;

COMMENT ON VIEW public.v_checkin_queue IS
  'The reception Check-in queue and Next-arrivals list: queue number, patient, provider, '
  'appointment time and live waiting time. Filter by status for the Waiting / In room / Done '
  'tabs. Carries no clinical column beyond the chief complaint the desk itself typed.';

-- The doctor's Patients table in one row per patient: status ("Inpatient · Rm 412"), primary
-- condition, last visit. LEFT JOIN LATERAL so a caller who cannot read encounters still gets
-- the patient row with NULL clinical columns rather than losing the row entirely.
CREATE OR REPLACE VIEW public.v_patient_summary
WITH (security_invoker = true) AS
SELECT p.id               AS patient_id,
       p.organization_id,
       p.mrn,
       p.first_name || ' ' || p.last_name AS full_name,
       (extract(year FROM age(p.date_of_birth)))::int AS age_years,
       p.sex,
       p.status,
       adm.class          AS current_encounter_class,
       adm.room_label     AS current_room,
       adm.started_at     AS admitted_at,
       (adm.id IS NOT NULL) AS is_inpatient,
       cond.name          AS primary_condition,
       lastv.started_at   AS last_visit_at
  FROM public.patient p
  LEFT JOIN LATERAL (
    SELECT e.id, e.class, e.room_label, e.started_at
      FROM public.encounter e
     WHERE e.patient_id = p.id
       AND e.class  = 'inpatient'::app.encounter_class
       AND e.status = 'in_progress'::app.encounter_status
     LIMIT 1
  ) adm ON true
  LEFT JOIN LATERAL (
    SELECT c.name
      FROM public.patient_condition c
     WHERE c.patient_id = p.id
       AND c.is_primary
       AND c.clinical_status = 'active'::app.condition_status
       AND c.record_status   = 'active'::app.record_status
     LIMIT 1
  ) cond ON true
  LEFT JOIN LATERAL (
    SELECT e.started_at
      FROM public.encounter e
     WHERE e.patient_id = p.id
       AND e.record_status = 'active'::app.record_status
     ORDER BY e.started_at DESC
     LIMIT 1
  ) lastv ON true;

COMMENT ON VIEW public.v_patient_summary IS
  'One row per patient for the Patients table: MRN, age/sex, inpatient status and room, primary '
  'condition, last visit. AI risk pills are 030''s and are joined on by the caller.';

-- The Labs review queue, already carrying the range in the form the UI prints.
CREATE OR REPLACE VIEW public.v_lab_review_queue
WITH (security_invoker = true) AS
SELECT r.id               AS lab_result_id,
       r.organization_id,
       r.patient_id,
       p.first_name || ' ' || p.last_name AS patient_name,
       pan.name           AS panel_name,
       t.name             AS test_name,
       r.value_numeric,
       r.value_text,
       r.unit,
       app.format_reference_range(r.reference_low, r.reference_high, r.reference_note, r.unit)
                          AS reference_range,
       r.abnormal_flag,
       r.review_status,
       r.resulted_at,
       r.released_to_patient_at
  FROM public.lab_result r
  JOIN public.lab_order  o   ON o.id = r.lab_order_id
  JOIN public.lab_panel  pan ON pan.id = o.panel_id
  JOIN public.lab_test   t   ON t.id = r.lab_test_id
  JOIN public.patient    p   ON p.id = r.patient_id
 WHERE r.record_status = 'active'::app.record_status;

COMMENT ON VIEW public.v_lab_review_queue IS
  'The doctor Labs screen. The All / Abnormal / Reviewed chips are filters over review_status '
  'and abnormal_flag on this view; the "Resulted" column is resulted_at.';

-- The Timeline card. Assembled from the tables that already own each event rather than from a
-- copy: a note, a result and an admission are three different kinds of fact, and the only thing
-- they share is a clock. Each branch carries its own RLS, so a caller sees exactly the subset
-- of the story they are entitled to — which is the correct behaviour, not a bug to work around.
CREATE OR REPLACE VIEW public.v_patient_timeline
WITH (security_invoker = true) AS
SELECT n.organization_id, n.patient_id, n.occurred_at,
       'note'::text AS entry_kind,
       n.note_type::text AS entry_subtype,
       n.body AS summary,
       'clinical_note'::text AS source_table, n.id AS source_id
  FROM public.clinical_note n
 WHERE n.record_status = 'active'::app.record_status
UNION ALL
SELECT r.organization_id, r.patient_id, r.resulted_at,
       'lab_result', r.abnormal_flag::text,
       t.name || ' ' || coalesce(r.value_numeric::text, r.value_text, '')
                || coalesce(' ' || r.unit, ''),
       'lab_result', r.id
  FROM public.lab_result r
  JOIN public.lab_test t ON t.id = r.lab_test_id
 WHERE r.record_status = 'active'::app.record_status
UNION ALL
SELECT e.organization_id, e.patient_id, e.started_at,
       'encounter', e.class::text,
       coalesce(e.reason, e.class::text) || coalesce(' · ' || e.room_label, ''),
       'encounter', e.id
  FROM public.encounter e
 WHERE e.record_status = 'active'::app.record_status
UNION ALL
SELECT m.organization_id, m.patient_id, m.started_at,
       'medication', m.status::text,
       m.drug_name || ' ' || m.dose_text || ' · ' || m.frequency_text,
       'medication_order', m.id
  FROM public.medication_order m
 WHERE m.record_status = 'active'::app.record_status;

COMMENT ON VIEW public.v_patient_timeline IS
  'Chronological chart events for the Timeline card: notes, results, encounters and medication '
  'starts. ORDER BY occurred_at DESC at the call site. Events are never copied into a log table '
  'here — the owning table stays the single source of each fact.';

-- =============================================================================================
-- SECTION 50 — TENANT PROVISIONING SEED
--
-- A new hospital starts with empty catalogues, and empty catalogues mean the Booking screen has
-- no visit types and the Order-labs button has nothing to order. This gives a tenant a working
-- starting set, taken from the values the app itself displays. It is a provisioning step, not
-- application code: run it as service_role from the onboarding runbook, right after the tenant
-- and its first hospital_admin exist. It is idempotent and safe to re-run.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.seed_clinical_reference(p_organization_id uuid)
RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.organization o WHERE o.id = p_organization_id) THEN
    RAISE EXCEPTION 'No such organisation: %', p_organization_id USING errcode = '23503';
  END IF;

  INSERT INTO public.department (organization_id, code, name)
  VALUES (p_organization_id, 'cardiology',      'Cardiology'),
         (p_organization_id, 'radiology',       'Radiology'),
         (p_organization_id, 'general_medicine','Gen. medicine'),
         (p_organization_id, 'pediatrics',      'Pediatrics'),
         (p_organization_id, 'emergency',       'Emergency')
  ON CONFLICT (organization_id, code) DO NOTHING;

  INSERT INTO public.visit_type (organization_id, code, name, default_duration_minutes, default_modality)
  VALUES (p_organization_id, 'consult',            'Consult',            30, 'in_person'),
         (p_organization_id, 'diabetes_follow_up', 'Diabetes follow-up', 30, 'in_person'),
         (p_organization_id, 'post_op_consult',    'Post-op consult',    30, 'in_person'),
         (p_organization_id, 'annual_physical',    'Annual physical',    45, 'in_person'),
         (p_organization_id, 'video_follow_up',    'Video follow-up',    15, 'video'),
         (p_organization_id, 'walk_in',            'Walk-in',            15, 'in_person')
  ON CONFLICT (organization_id, code) DO NOTHING;

  -- Reference ranges are the ones the app prints. They are a STARTING POINT: every laboratory
  -- sets its own, and the hospital must confirm these before anyone treats a flag as clinical.
  INSERT INTO public.lab_test (organization_id, code, name, default_unit,
                               reference_low, reference_high, reference_note,
                               critical_low, critical_high)
  VALUES (p_organization_id, 'lactate',    'Lactate',            'mmol/L', 0.5,  2.2,  NULL, NULL, 4.0),
         (p_organization_id, 'wbc',        'WBC',                '×10⁹/L', 4.0,  11.0, NULL, 1.0,  30.0),
         (p_organization_id, 'crp',        'CRP',                'mg/L',   NULL, 5.0,  NULL, NULL, NULL),
         (p_organization_id, 'creatinine', 'Creatinine',         'mg/dL',  0.6,  1.2,  NULL, NULL, 4.0),
         (p_organization_id, 'hba1c',      'HbA1c',              '%',      4.0,  5.6,  NULL, NULL, NULL),
         (p_organization_id, 'glucose_f',  'Fasting glucose',    'mg/dL',  70,   99,   NULL, 40,   500),
         (p_organization_id, 'egfr',       'eGFR',               'mL/min', 60,   NULL, NULL, 15,   NULL),
         (p_organization_id, 'ldl',        'LDL cholesterol',    'mg/dL',  NULL, 100,  NULL, NULL, NULL),
         (p_organization_id, 'bnp',        'BNP',                'pg/mL',  NULL, 100,  NULL, NULL, NULL),
         (p_organization_id, 'pao2',       'PaO₂',               'mmHg',   75,   100,  'arterial blood gas', 50, NULL),
         (p_organization_id, 'paco2',      'PaCO₂',              'mmHg',   35,   45,   'arterial blood gas', NULL, 70)
  ON CONFLICT (organization_id, code) DO NOTHING;

  INSERT INTO public.lab_panel (organization_id, code, name)
  VALUES (p_organization_id, 'lactate_repeat',   'Lactate, repeat'),
         (p_organization_id, 'abg',              'ABG'),
         (p_organization_id, 'hba1c_panel',      'HbA1c'),
         (p_organization_id, 'bnp_renal',        'BNP, renal panel'),
         (p_organization_id, 'renal_electrolyte','eGFR, electrolytes'),
         (p_organization_id, 'lipid_panel',      'Cholesterol panel'),
         (p_organization_id, 'sepsis_screen',    'Sepsis screen'),
         (p_organization_id, 'echo_report',      'Echo report')
  ON CONFLICT (organization_id, code) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION app.seed_clinical_reference(uuid) IS
  'Provisioning helper: gives a new tenant a working department, visit-type and laboratory '
  'catalogue drawn from the values the app displays. Run as service_role during onboarding. '
  'The seeded reference ranges are defaults to be confirmed by the hospital, not clinical '
  'authority — see the comment in the body.';


-- =============================================================================================
-- SECTION 60 — GRANTS
-- >>> BEGIN SUPABASE-SPECIFIC: role names are the PostgREST convention <<<
--
-- Note what is absent: DELETE, on every table. The policies would refuse it and
-- app.deny_hard_delete() would refuse it again, but not granting it in the first place means
-- the refusal never has to work.
-- =============================================================================================

DO $grants$
BEGIN
  -- Postgres grants EXECUTE on new functions to PUBLIC. 010 revoked that for the functions it
  -- created; the ones added above need the same treatment before anything is handed out.
  EXECUTE 'REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA app FROM PUBLIC';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON
               public.department, public.visit_type, public.staff_profile,
               public.patient_condition, public.patient_allergy, public.care_team_member,
               public.encounter, public.appointment, public.vital_sign,
               public.lab_panel, public.lab_test, public.lab_order, public.lab_result,
               public.clinical_note, public.medication_order
             TO authenticated';

    EXECUTE 'GRANT SELECT ON
               public.v_front_desk_patient, public.v_checkin_queue, public.v_patient_summary,
               public.v_lab_review_queue, public.v_patient_timeline
             TO authenticated';

    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.care_patient_ids(),
               app.format_reference_range(numeric, numeric, text, text)
             TO authenticated';

    -- Trigger functions: Postgres checks EXECUTE when the trigger is created rather than when
    -- it fires, so this is belt-and-braces. Calling any of them directly just raises.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.enforce_append_only(), app.enforce_patient_writable_columns(),
               app.guard_appointment(), app.guard_clinical_note(),
               app.fill_lab_result_flag(), app.ensure_attending_on_care_team()
             TO authenticated';
  END IF;

  -- Provisioning and the laboratory ETL run here. seed_clinical_reference is deliberately NOT
  -- granted to authenticated: a hospital_admin has no reason to be able to reset a catalogue.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO service_role';
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO service_role';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon';
  END IF;
END
$grants$;
-- >>> END SUPABASE-SPECIFIC <<< --------------------------------------------------------------


-- =============================================================================================
-- SECTION 90 — SELF-CHECKS
--
-- These run as part of the migration. If any of them fires, the migration fails and the schema
-- is not left in a state where a tenant boundary is quietly missing. Re-run them in CI too.
-- =============================================================================================

-- 90.1 No tenant table left without RLS (010's view; it must be empty after this file).
DO $rls_gap$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(table_name, ', ') INTO v_bad FROM app.v_tenant_rls_gaps;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tables carry organization_id but have no row level security: %', v_bad;
  END IF;
END
$rls_gap$;

-- 90.2 No blanket vendor access to any clinical table (010's CI gate, called with this file's
--      PHI tables). If someone adds `OR app.is_super_admin()` to one of these policies, the
--      migration stops here rather than shipping a cross-tenant clinical read.
SELECT app.assert_no_vendor_phi_policies(ARRAY[
  'patient', 'patient_condition', 'patient_allergy', 'care_team_member', 'encounter',
  'appointment', 'vital_sign', 'lab_order', 'lab_result', 'clinical_note', 'medication_order'
]);

-- 90.3 Every table this file created must carry at least one policy. RLS with no policy denies
--      everything, which fails safe but also fails the product; RLS with a policy someone
--      forgot to write is the case this catches.
DO $policy_gap$
DECLARE
  v_tables text[] := ARRAY['department','visit_type','staff_profile','patient_condition',
                           'patient_allergy','care_team_member','encounter','appointment',
                           'vital_sign','lab_panel','lab_test','lab_order','lab_result',
                           'clinical_note','medication_order'];
  v_bad text;
BEGIN
  SELECT string_agg(t, ', ') INTO v_bad
    FROM unnest(v_tables) AS t
   WHERE NOT EXISTS (SELECT 1 FROM pg_policies p
                      WHERE p.schemaname = 'public' AND p.tablename = t);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tables have RLS enabled but no policy: %', v_bad;
  END IF;
END
$policy_gap$;

-- 90.4 Every view in this file must be security_invoker. A view that is not runs as its owner
--      and reads straight through RLS.
DO $view_check$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(c.relname, ', ') INTO v_bad
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'v'
     AND c.relname IN ('v_front_desk_patient','v_checkin_queue','v_patient_summary',
                       'v_lab_review_queue','v_patient_timeline')
     AND NOT coalesce((SELECT option_value = 'true'
                         FROM pg_options_to_table(c.reloptions)
                        WHERE option_name = 'security_invoker'), false);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Views are missing security_invoker and would bypass RLS: %', v_bad;
  END IF;
END
$view_check$;

-- 90.5 Nothing in this file may hold binary content. Rule 3 of the brief: object storage holds
--      bytes, the database holds a tenant-scoped key. This asserts the first half; 030 owns
--      the storage_key columns and must use app.storage_key_belongs_to() in a CHECK on each.
DO $no_blobs$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s.%s', c.relname, a.attname), ', ') INTO v_bad
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
     AND a.atttypid = 'bytea'::regtype
     AND c.relname = ANY (ARRAY['patient','patient_condition','patient_allergy',
                                'care_team_member','encounter','appointment','vital_sign',
                                'lab_panel','lab_test','lab_order','lab_result',
                                'clinical_note','medication_order','staff_profile',
                                'department','visit_type']);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'bytea columns exist; binaries belong in object storage: %', v_bad;
  END IF;
END
$no_blobs$;

DO $done$
BEGIN
  RAISE NOTICE 'prognosify/020: clinical model applied — 15 tables, 5 views, RLS on every one.';
END
$done$;


-- =============================================================================================
-- SECTION 91 — THE ONE ACCESS DECISION SOMEONE MUST CONFIRM
--
-- The patient INDEX is readable by every clinician and receptionist in the tenant (010's
-- patient_select). The CHART is not. If the operator wants the index narrowed too — so a doctor
-- cannot even confirm that a given person is a patient of this hospital unless they are on the
-- care team — this is the change, and it belongs in a migration of its own so that the day it
-- starts breaking registration there is something to revert:
--
--   CREATE POLICY patient_care_scope ON public.patient
--     AS RESTRICTIVE FOR SELECT
--     USING (
--       app.is_front_desk()                    -- reception must be able to find anyone
--       OR id = app.current_patient_id()
--       OR id = ANY (app.care_patient_ids())
--     );
--
-- A RESTRICTIVE policy ANDs with 010's permissive one, so this tightens without editing 010.
-- Understand the cost before running it: a doctor cannot look up a patient they have not yet
-- been assigned to, which means every referral, every cross-cover shift and every "which Rosa
-- Delgado is this" starts with an assignment step. That is a workflow decision for the
-- hospital, not a database decision, which is why it is written down here and not applied.
--
--
-- SECTION 92 — OPEN QUESTIONS (deferred deliberately, not overlooked)
--
--  1. NO KNOWN ALLERGIES vs NOT ASKED. Clinically these are very different and the schema
--     currently cannot tell them apart: an empty patient_allergy list means both. Fixing it
--     needs a column on public.patient (which 010 owns) or a small per-patient assessment
--     table. No screen shows the distinction today, so nothing was invented — but the first
--     time this schema is used for real prescribing, resolve it.
--  2. BREAK-GLASS ACCESS. A clinician who is not on the care team can assume care in one
--     INSERT (§26). That is the emergency path, and it is indistinguishable in the data from a
--     routine assignment. If the operator wants "emergency override" to be visibly different —
--     a reason, an alert, an automatic review — it needs a flag on care_team_member and a
--     report, and 040 needs to treat it as a distinct audit event.
--  3. AMENDMENT IS MODELLED, THE PROCEDURE IS NOT. supersedes_id + record_status describe the
--     end state; nothing enforces that inserting a superseding row also marks its predecessor
--     'amended'. That belongs in an RPC (amend_lab_result, amend_note) so the two writes are
--     one transaction. Until then a client can leave two 'active' rows in a chain.
--  4. PATIENT MERGE. 010 models the state (status='merged' + merged_into_patient_id); the
--     operation — which chart survives, and whether the loser's encounters, results and notes
--     are re-pointed or left in place — is unwritten. Re-pointing rewrites clinical history;
--     leaving them means every chart query must follow the merge chain. This file assumes the
--     latter and does NOT follow the chain anywhere, so a merged patient's old rows are
--     currently reachable only through the old id. Decide before the first merge, not after.
--  5. RETENTION AND ERASURE. The DPDP Act gives data principals erasure rights in defined
--     circumstances, and medical-record retention rules cut the other way. The schema makes
--     deliberate erasure possible (SET LOCAL app.allow_hard_delete) and accidental erasure
--     impossible. Which records, after how long, on whose authority: for counsel.
--  6. QUEUE TICKET ALLOCATION races the same way MRN does: two clerks checking patients in at
--     the same second both read max(queue_ticket)+1. The unique index makes one of them fail
--     rather than duplicate, which is the right failure — but the app must retry, or the
--     allocation should move into a small RPC that takes a per-(tenant, day) advisory lock.
--  7. CARE-TEAM ARRAY SIZE. app.care_patient_ids() returns an array (§22). Fine for a personal
--     panel; wrong for a service account on thousands of teams. Revisit if one appears.
--  8. NOT VERIFIED BY EXECUTION. No PostgreSQL, psql or docker exists on this machine, so this
--     file has been reviewed statically only: dollar-quote tags balanced, every app.* call
--     resolving to 010 or to a definition above its use, composite FKs matching a declared
--     unique key on the parent. Run it once against a scratch database before trusting it, and
--     run §90 as part of CI from then on.
-- =============================================================================================
