-- =============================================================================================
-- seed.sql — Prognosify demo data
-- Run AFTER 000, 010, 020, 030, 040. Idempotent: every row is keyed on a fixed uuid and
-- inserted ON CONFLICT DO NOTHING, so re-running changes nothing and never duplicates.
--
-- WHY THERE ARE TWO HOSPITALS
--   A single-org seed cannot prove tenant isolation. It can only show that a query returned
--   the rows you expected — which is also what a completely broken policy looks like when
--   there is nothing else in the database to leak. So this file creates two tenants with
--   overlapping-looking data (including the SAME MRN, 104-882, in both) and TESTING.md drives
--   sessions against them. If isolation ever breaks, org 2 is what shows up where it should not.
--
-- WHAT THIS FILE DOES NOT DO
--   It creates NO auth users and contains NO passwords. Supabase logins are created by hand in
--   Authentication → Users (see README §"Create the three test logins"). This file finds them
--   by email, or takes their ids from the PASTE-HERE block in §1, and links them to member rows.
--
-- THE DEMO CAST IS THE APP'S OWN
--   Every patient, condition, vital, lab, appointment, invoice and risk score below is taken
--   from prognosify-app/src/data/mock.ts and the 20 screens, not invented. Where the mock is
--   internally inconsistent the comment says so rather than quietly picking one.
--
-- DATES ARE RELATIVE TO THE DAY YOU RUN IT
--   Everything is anchored on current_date so the dashboard always has a "today". The clinic
--   day is Asia/Kolkata (organization.timezone); timestamps are written as local wall-clock
--   converted with AT TIME ZONE, never as bare timestamps.
--
-- FIXED UUID LEGEND (first hex digit is the entity kind, last two are the row number)
--   00…  organization        60…  vital_sign          c1…  ai_risk_score
--   10…  app_user            70…  lab_order           c2…  ai_risk_factor
--   20…  organization_member 80…  lab_result          c3…  ai_finding
--   30…  patient             90…  clinical_note       c4…  ai_citation
--   40…  encounter           a0…  medication_order    d0…  document
--   50…  appointment         b0…  patient_condition   e0…  payer
--   11…  organization (org)  b1…  patient_allergy     e1…  patient_coverage
--   c0…  ai_analysis_run     b2…  care_team_member    f0…  invoice / f1 line / f2 payment
--   Rows 01–13 are St. Luke's (org 1); rows 51–52 are Meridian (org 2).
-- =============================================================================================


-- =============================================================================================
-- SECTION 0 — PRECONDITIONS
-- =============================================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('app.current_org_id()') IS NULL
     OR to_regclass('public.lab_result') IS NULL
     OR to_regclass('public.ai_risk_score') IS NULL
     OR to_regclass('public.invoice') IS NULL THEN
    RAISE EXCEPTION 'Apply migrations 000, 010, 020, 030 and 040 before seeding.'
      USING errcode = '42P01';
  END IF;
END
$preflight$;


-- =============================================================================================
-- SECTION 1 — THE THREE TEST LOGINS  ◀── THIS IS THE ONLY PART YOU MAY NEED TO EDIT
--
-- HOW THIS RESOLVES, in order:
--   1. a uuid you paste into the block below (leave the all-zero sentinel to skip);
--   2. otherwise, a lookup of auth.users by email — which is why creating the logins in the
--      Supabase dashboard FIRST is the easy path;
--   3. otherwise, on a database with no GoTrue at all (plain RDS/Neon), a fixed placeholder so
--      the rest of the seed still loads. Nobody can sign in as those; they exist so the demo
--      data has an author.
--
-- If you are on Supabase and none of the three emails exists yet, this file stops with an
-- explicit message rather than half-loading.
-- =============================================================================================

DROP TABLE IF EXISTS _seed_login;
CREATE TEMPORARY TABLE _seed_login (
  slug          text PRIMARY KEY,
  email         text NOT NULL,
  full_name     text NOT NULL,
  job_title     text NULL,
  license_no    text NULL,
  roles         app.org_role[] NOT NULL,
  app_user_id   uuid NOT NULL,
  member_id     uuid NOT NULL,
  pasted_uid    uuid NOT NULL,   -- all-zero = "not pasted"
  auth_user_id  uuid NULL        -- resolved below
);

INSERT INTO _seed_login (slug, email, full_name, job_title, license_no, roles,
                         app_user_id, member_id, pasted_uid) VALUES

  -- ══════════════════════════════════════════════════════════════════════════════════════════
  --  ▼▼▼  PASTE THE auth.users UUIDs FROM YOUR SUPABASE PROJECT HERE  ▼▼▼
  --
  --  Supabase dashboard → Authentication → Users → click a user → copy the UID (the top field).
  --  Replace ONLY the last column. Leave '00000000-0000-0000-0000-000000000000' to fall back to
  --  the email lookup. Never put a password anywhere in this file.
  --
  --  These are identifiers, not secrets — but they are specific to ONE Supabase project.
  --  Anyone running this schema in a different project must substitute their own.
  -- ══════════════════════════════════════════════════════════════════════════════════════════
  ('doctor',       'doctor@clinic.com',       'Dr. Anita Mehta', 'Consultant cardiologist',
                   'MCI-2011-44192', ARRAY['doctor']::app.org_role[],
   '10000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001',
   '00000000-0000-0000-0000-000000000000'),   -- ◀ paste doctor@clinic.com's UID

  ('receptionist', 'receptionist@clinic.com', 'Jordan Cole',     'Front desk coordinator',
                   NULL, ARRAY['receptionist']::app.org_role[],
   '10000000-0000-4000-a000-000000000002',
   '20000000-0000-4000-a000-000000000002',
   '00000000-0000-0000-0000-000000000000'),   -- ◀ paste receptionist@clinic.com's UID

  -- The patient login IS Priya Nair, patient 03. organization_member.id below becomes
  -- patient.portal_member_id, which is what app.current_patient_id() resolves.
  ('patient',      'patient@gmail.com',       'Priya Nair',      NULL,
                   NULL, ARRAY['patient']::app.org_role[],
   '10000000-0000-4000-a000-000000000003',
   '20000000-0000-4000-a000-000000000003',
   '00000000-0000-0000-0000-000000000000');   -- ◀ paste patient@gmail.com's UID

-- ---- resolve ---------------------------------------------------------------------------------
DO $resolve$
DECLARE
  v_has_gotrue boolean := to_regclass('auth.users') IS NOT NULL;
  v_missing    text;
BEGIN
  -- 1. explicit paste wins
  UPDATE _seed_login
     SET auth_user_id = pasted_uid
   WHERE pasted_uid <> '00000000-0000-0000-0000-000000000000'::uuid;

  -- 2. email lookup in GoTrue
  IF v_has_gotrue THEN
    EXECUTE $lookup$
      UPDATE _seed_login s
         SET auth_user_id = u.id
        FROM auth.users u
       WHERE s.auth_user_id IS NULL
         AND lower(u.email) = s.email
    $lookup$;

    SELECT string_agg(email, ', ' ORDER BY email) INTO v_missing
      FROM _seed_login WHERE auth_user_id IS NULL;

    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION
        'No Supabase auth user for: %. Create the logins first (Authentication → Users → '
        'Add user → "Auto Confirm User"), or paste their UIDs into §1 of seed.sql.', v_missing
        USING errcode = '23503',
              hint = 'public.app_user.auth_user_id has a foreign key to auth.users, so the demo '
                     'identities cannot be invented. No password belongs in this file.';
    END IF;
  ELSE
    -- 3. no GoTrue (plain PostgreSQL): fixed placeholders, nobody can authenticate as them.
    UPDATE _seed_login
       SET auth_user_id = ('00000000-0000-4000-b000-0000000000'
                           || lpad((ascii(left(slug, 1)))::text, 2, '0'))::uuid
     WHERE auth_user_id IS NULL;
    RAISE NOTICE 'seed: no auth.users table — demo identities got placeholder subject ids. '
                 'On Supabase this branch never runs.';
  END IF;
END
$resolve$;


-- =============================================================================================
-- SECTION 2 — THE TWO TENANTS
--
-- org 1 St. Luke's General Hospital   — the whole demo cast, plan clinical_ai (AI features on)
-- org 2 Meridian Health Clinic        — two decoy patients and one bill, plan trial
--
-- Both are status trial/active, because app.current_org_id() returns NULL for a suspended or
-- closed tenant and every policy would then deny — correct behaviour, useless for a demo.
-- =============================================================================================

INSERT INTO public.organization (id, slug, name, status, region, timezone, plan_id,
                                 plan_started_at, trial_ends_at, settings)
SELECT '11111111-1111-4111-a111-111111111111', 'st-lukes',
       'St. Luke''s General Hospital', 'active', 'ap-south-1', 'Asia/Kolkata',
       p.id, now() - interval '9 months', NULL,
       jsonb_build_object('display_name', 'St. Luke''s', 'clinic_open', '08:00',
                          'clinic_close', '18:00')
  FROM public.subscription_plan p WHERE p.code = 'clinical_ai'
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organization (id, slug, name, status, region, timezone, plan_id,
                                 plan_started_at, trial_ends_at, settings)
SELECT '22222222-2222-4222-a222-222222222222', 'meridian-health',
       'Meridian Health Clinic', 'trial', 'ap-south-1', 'Asia/Kolkata',
       p.id, now() - interval '11 days', now() + interval '19 days',
       jsonb_build_object('display_name', 'Meridian')
  FROM public.subscription_plan p WHERE p.code = 'trial'
ON CONFLICT (id) DO NOTHING;

-- A per-tenant entitlement override: Meridian is on the trial plan but sales granted the full
-- prognosis report for 30 days. Vendor-written, windowed, and it expires with no cron job.
INSERT INTO public.organization_entitlement
       (organization_id, feature_key, enabled, effective_from, effective_to, note)
VALUES ('22222222-2222-4222-a222-222222222222', 'ai_prognosis', true,
        now() - interval '11 days', now() + interval '19 days',
        'Trial grant agreed on the discovery call; expires with the trial.')
ON CONFLICT (organization_id, feature_key) DO NOTHING;

-- Departments, visit types and the laboratory catalogue. This is the provisioning helper 020
-- exports, not seed-specific code: a new tenant gets exactly the same starting set.
SELECT app.seed_clinical_reference('11111111-1111-4111-a111-111111111111');
SELECT app.seed_clinical_reference('22222222-2222-4222-a222-222222222222');

-- One analyte the shared catalogue does not carry, because only the Labs screen's echo row
-- needs it. Added per tenant like every other reference range.
INSERT INTO public.lab_test (organization_id, code, name, default_unit,
                             reference_low, reference_high, critical_low)
VALUES ('11111111-1111-4111-a111-111111111111', 'echo_ef',
        'Echo — ejection fraction', '%', 55, 70, 30),
       ('22222222-2222-4222-a222-222222222222', 'echo_ef',
        'Echo — ejection fraction', '%', 55, 70, 30)
ON CONFLICT (organization_id, code) DO NOTHING;

-- Slot capacity: the DENOMINATOR of the front desk's "Clinic load today" card. The numerator is
-- today's appointments, so the percentage is computed at read time and is honest about how
-- little demo data there is — it will not read 85% just because the mock did.
UPDATE public.department d SET daily_slot_capacity = v.cap, sort_order = v.ord
  FROM (VALUES ('cardiology', 40, 10), ('radiology', 25, 20),
               ('general_medicine', 60, 30), ('pediatrics', 30, 40),
               ('emergency', NULL::integer, 50)) AS v(code, cap, ord)
 WHERE d.organization_id = '11111111-1111-4111-a111-111111111111'
   AND d.code = v.code
   AND d.daily_slot_capacity IS DISTINCT FROM v.cap;


-- =============================================================================================
-- SECTION 3 — IDENTITIES AND SEATS
--
-- One app_user per human (tenant-agnostic, 010 §5) and one organization_member per seat. All
-- three seats are in St. Luke's. MERIDIAN DELIBERATELY HAS NO MEMBERS: it exists to be
-- unreachable, and a tenant with no seats is the strongest possible version of that.
-- =============================================================================================

INSERT INTO public.app_user (id, auth_user_id, email, full_name, status, active_organization_id)
SELECT app_user_id, auth_user_id, email, full_name, 'active',
       '11111111-1111-4111-a111-111111111111'
  FROM _seed_login
ON CONFLICT (id) DO UPDATE
   -- auth_user_id is immutable through app.guard_app_user_update(); re-running with the SAME
   -- value is a no-op, re-running after recreating the login in the dashboard will raise. That
   -- is deliberate: silently re-pointing an identity is how one person reads another's records.
   SET auth_user_id           = excluded.auth_user_id,
       full_name              = excluded.full_name,
       active_organization_id = excluded.active_organization_id;

INSERT INTO public.organization_member
       (id, organization_id, app_user_id, roles, status, job_title, license_number, joined_at)
SELECT member_id, '11111111-1111-4111-a111-111111111111', app_user_id, roles, 'active',
       job_title, license_no, now() - interval '8 months'
  FROM _seed_login
ON CONFLICT (id) DO NOTHING;
-- organization_member.auth_user_id is filled by app.sync_member_identity(); callers never set it.

-- Practice attributes of the doctor's seat: "Dr. Anita Mehta · Cardiology", Clinic 2.
INSERT INTO public.staff_profile (member_id, organization_id, department_id, specialty,
                                  default_room, accepts_bookings)
SELECT '20000000-0000-4000-a000-000000000001',
       '11111111-1111-4111-a111-111111111111', d.id, 'Cardiology', 'Clinic 2', true
  FROM public.department d
 WHERE d.organization_id = '11111111-1111-4111-a111-111111111111' AND d.code = 'cardiology'
ON CONFLICT (member_id) DO NOTHING;

-- Personal preferences: the doctor Settings screen's three AI toggles, plus two hospital
-- defaults a hospital_admin would own (member_id NULL).
INSERT INTO public.org_setting (organization_id, member_id, key, value, updated_by) VALUES
  ('11111111-1111-4111-a111-111111111111', '20000000-0000-4000-a000-000000000001',
   'ai.risk_flags_on_lists',  'true'::jsonb,  '20000000-0000-4000-a000-000000000001'),
  ('11111111-1111-4111-a111-111111111111', '20000000-0000-4000-a000-000000000001',
   'ai.confirm_before_chart', 'true'::jsonb,  '20000000-0000-4000-a000-000000000001'),
  ('11111111-1111-4111-a111-111111111111', '20000000-0000-4000-a000-000000000001',
   'ai.daily_summary_email',  'false'::jsonb, '20000000-0000-4000-a000-000000000001')
-- The index predicate is required: org_setting's uniqueness lives in TWO partial indexes (one
-- for hospital defaults, one for personal overrides), and PostgreSQL will only use a partial
-- unique index as a conflict arbiter when the statement repeats its predicate.
ON CONFLICT (organization_id, member_id, key) WHERE member_id IS NOT NULL DO NOTHING;

INSERT INTO public.org_setting (organization_id, member_id, key, value) VALUES
  ('11111111-1111-4111-a111-111111111111', NULL, 'billing.default_currency', '"INR"'::jsonb),
  ('11111111-1111-4111-a111-111111111111', NULL, 'clinic.display_timezone',  '"Asia/Kolkata"'::jsonb)
ON CONFLICT (organization_id, key) WHERE member_id IS NULL DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- OPTIONAL: the rest of the staff directory.
--
-- The mock also names Dr. Tom Reyes (resident), N. Adams RN, Dr. Osei and Dr. Fontaine. Each
-- needs its own Supabase login, because app_user.auth_user_id is a foreign key to auth.users
-- and this file will not invent identities. To add them: create the logins in the dashboard,
-- then run this block with the UIDs filled in.
--
--   INSERT INTO public.app_user (id, auth_user_id, email, full_name, active_organization_id)
--   VALUES ('10000000-0000-4000-a000-000000000004',
--           'PASTE-AUTH-UID-HERE'::uuid, 'nurse@clinic.com', 'N. Adams, RN',
--           '11111111-1111-4111-a111-111111111111')
--   ON CONFLICT (id) DO NOTHING;
--
--   INSERT INTO public.organization_member
--          (id, organization_id, app_user_id, roles, status, job_title)
--   VALUES ('20000000-0000-4000-a000-000000000004',
--           '11111111-1111-4111-a111-111111111111',
--           '10000000-0000-4000-a000-000000000004',
--           ARRAY['nurse']::app.org_role[], 'active', 'Ward 4 nurse')
--   ON CONFLICT (id) DO NOTHING;
--
--   -- and put them on a care team so they can open the chart:
--   INSERT INTO public.care_team_member
--          (organization_id, patient_id, member_id, role, assignment_note, added_by)
--   VALUES ('11111111-1111-4111-a111-111111111111',
--           '30000000-0000-4000-a000-000000000001',
--           '20000000-0000-4000-a000-000000000004', 'nurse', 'Ward 4',
--           '20000000-0000-4000-a000-000000000001')
--   ON CONFLICT DO NOTHING;
--
-- A hospital_admin login is worth adding the same way (roles ARRAY['hospital_admin']) if you
-- want to exercise the admin tier: departments, settings, staff seats and the audit trail.
-- ---------------------------------------------------------------------------------------------


-- =============================================================================================
-- SECTION 4 — PATIENTS
--
-- Rows 01–08 are mock.ts verbatim. Rows 09–13 are the names the reception screens use (queue,
-- billing) — they are patients of the same hospital with no chart, which is exactly what the
-- front desk sees and a good demonstration that reception reach and clinical reach differ.
--
-- Ages are calculated against the day this file was written (Aug 2026) so they match the "71F",
-- "64M" labels in the app. They drift by a year eventually; nothing depends on the exact value.
-- =============================================================================================

INSERT INTO public.patient (id, organization_id, mrn, first_name, last_name, date_of_birth, sex,
                            phone, email, status, portal_member_id, created_by)
VALUES
  ('30000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111', '104-882',
   'Rosa', 'Delgado', DATE '1954-11-02', 'female', '+91 98450 11201', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111', '102-347',
   'James', 'Whitfield', DATE '1962-03-14', 'male', '+91 98450 11202', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  -- Priya is the portal patient: her seat (member 03) is linked below, after the seat exists.
  ('30000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111', '108-921',
   'Priya', 'Nair', DATE '1968-01-27', 'female', '+91 98450 11203', 'patient@gmail.com',
   'active', NULL, '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111', '109-114',
   'Robert', 'Okafor', DATE '1977-05-09', 'male', '+91 98450 11204', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000005', '11111111-1111-4111-a111-111111111111', '101-556',
   'Lena', 'Kovacs', DATE '1981-02-11', 'female', '+91 98450 11205', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000006', '11111111-1111-4111-a111-111111111111', '103-778',
   'Samuel', 'Adeyemi', DATE '1959-06-30', 'male', '+91 98450 11206', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  -- Grace Lin has NO care team on purpose — see §8. She is the patient the doctor can find in
  -- the index and cannot open, which is the second access boundary made visible.
  ('30000000-0000-4000-a000-000000000007', '11111111-1111-4111-a111-111111111111', '110-204',
   'Grace', 'Lin', DATE '1992-04-18', 'female', '+91 98450 11207', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000008', '11111111-1111-4111-a111-111111111111', '107-663',
   'Miguel', 'Santos', DATE '1973-09-05', 'male', '+91 98450 11208', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),

  -- Front-desk-only names (check-in queue and billing screens).
  ('30000000-0000-4000-a000-000000000009', '11111111-1111-4111-a111-111111111111', '111-402',
   'Dana', 'Whitcomb', DATE '1975-07-21', 'female', '+91 98450 11209', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000010', '11111111-1111-4111-a111-111111111111', '112-556',
   'Helen', 'Cho', DATE '1968-12-03', 'female', '+91 98450 11210', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000011', '11111111-1111-4111-a111-111111111111', '113-118',
   'Elif', 'Demir', DATE '1983-10-16', 'female', '+91 98450 11211', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000012', '11111111-1111-4111-a111-111111111111', '114-903',
   'Marcus', 'Bell', DATE '1971-08-08', 'male', '+91 98450 11212', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),
  ('30000000-0000-4000-a000-000000000013', '11111111-1111-4111-a111-111111111111', '115-277',
   'Tom', 'Abara', DATE '1990-02-25', 'male', '+91 98450 11213', NULL, 'active', NULL,
   '10000000-0000-4000-a000-000000000002'),

  -- ---- ORG 2 DECOYS ------------------------------------------------------------------------
  -- Alice deliberately carries MRN 104-882, the SAME number as Rosa Delgado in org 1. Two
  -- hospitals allocate from independent number spaces, so this must be legal — and it is, only
  -- because patient_mrn_uk is UNIQUE (organization_id, upper(mrn)) rather than global. If
  -- someone ever "fixes" that index, this INSERT is what fails.
  ('30000000-0000-4000-a000-000000000051', '22222222-2222-4222-a222-222222222222', '104-882',
   'Alice', 'Fernandes', DATE '1966-03-30', 'female', '+91 99870 55101', NULL, 'active', NULL, NULL),
  ('30000000-0000-4000-a000-000000000052', '22222222-2222-4222-a222-222222222222', '200-115',
   'Bilal', 'Rahman', DATE '1988-11-11', 'male', '+91 99870 55102', NULL, 'active', NULL, NULL)
ON CONFLICT (id) DO NOTHING;

-- Link the portal login to Priya's chart. Done as a separate UPDATE because the composite FK
-- requires the seat to already exist in the same tenant.
UPDATE public.patient
   SET portal_member_id = '20000000-0000-4000-a000-000000000003'
 WHERE id = '30000000-0000-4000-a000-000000000003'
   AND portal_member_id IS DISTINCT FROM '20000000-0000-4000-a000-000000000003';


-- =============================================================================================
-- SECTION 5 — PROBLEM LIST AND ALLERGIES
-- "Primary condition" on the Patients table; "Allergies: penicillin" in Rosa's header.
-- =============================================================================================

INSERT INTO public.patient_condition (id, organization_id, patient_id, name, clinical_status,
                                      is_primary, onset_date, recorded_by)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.patient_id, v.name, 'active', true,
       v.onset, '20000000-0000-4000-a000-000000000001'
  FROM (VALUES
    ('b0000000-0000-4000-a000-000000000001'::uuid, '30000000-0000-4000-a000-000000000001'::uuid,
     'Pneumonia',        current_date - 5),
    ('b0000000-0000-4000-a000-000000000002', '30000000-0000-4000-a000-000000000002',
     'CHF',              current_date - 900),
    ('b0000000-0000-4000-a000-000000000003', '30000000-0000-4000-a000-000000000003',
     'Type 2 diabetes',  current_date - 1600),
    ('b0000000-0000-4000-a000-000000000004', '30000000-0000-4000-a000-000000000004',
     'Post-op (CABG)',   current_date - 21),
    ('b0000000-0000-4000-a000-000000000005', '30000000-0000-4000-a000-000000000005',
     'Arrhythmia',       current_date - 400),
    ('b0000000-0000-4000-a000-000000000006', '30000000-0000-4000-a000-000000000006',
     'COPD',             current_date - 2100),
    ('b0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000007',
     'Hypertension',     current_date - 700),
    ('b0000000-0000-4000-a000-000000000008', '30000000-0000-4000-a000-000000000008',
     'CKD stage 3',      current_date - 1200)
  ) AS v(id, patient_id, name, onset)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.patient_allergy (id, organization_id, patient_id, substance, category,
                                    severity, reaction, noted_on, recorded_by)
VALUES ('b1000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000001', 'Penicillin', 'medication', 'severe',
        'Urticaria and facial swelling, 2019', current_date - 5,
        '20000000-0000-4000-a000-000000000001')
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 6 — ENCOUNTERS
--
-- Three open admissions (the "6 inpatient" figure on the doctor dashboard, scaled to the cast
-- we have), plus closed outpatient visits that give the Patients table its "Last visit" column.
--
-- Every encounter with an attending fires app.ensure_attending_on_care_team(), so care teams
-- appear without a second list to keep in sync. Grace Lin's encounter has NO attending, which
-- is why she has no care team and why her chart stays closed to everyone.
-- =============================================================================================

INSERT INTO public.encounter (id, organization_id, patient_id, class, status, department_id,
                              attending_member_id, room_label, reason, started_at, ended_at,
                              created_by)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.patient_id, v.class::app.encounter_class,
       v.status::app.encounter_status,
       (SELECT d.id FROM public.department d
         WHERE d.organization_id = '11111111-1111-4111-a111-111111111111' AND d.code = v.dept),
       v.attending, v.room, v.reason, v.started, v.ended,
       '20000000-0000-4000-a000-000000000001'
  FROM (VALUES
    -- id, patient, class, status, dept, attending, room, reason, started, ended
    ('40000000-0000-4000-a000-000000000001'::uuid, '30000000-0000-4000-a000-000000000001'::uuid,
     'inpatient', 'in_progress', 'general_medicine',
     '20000000-0000-4000-a000-000000000001'::uuid, 'Rm 412',
     'Community-acquired pneumonia, admitted via ED',
     ((current_date - 4 + time '14:20') AT TIME ZONE 'Asia/Kolkata'), NULL::timestamptz),

    ('40000000-0000-4000-a000-000000000002', '30000000-0000-4000-a000-000000000002',
     'inpatient', 'in_progress', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Rm 407',
     'Decompensated heart failure',
     ((current_date - 2 + time '09:05') AT TIME ZONE 'Asia/Kolkata'), NULL),

    ('40000000-0000-4000-a000-000000000006', '30000000-0000-4000-a000-000000000006',
     'inpatient', 'in_progress', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Rm 415',
     'COPD exacerbation',
     ((current_date - 1 + time '18:40') AT TIME ZONE 'Asia/Kolkata'), NULL),

    -- Closed outpatient visits. "Last visit" on the Patients table is started_at of the most
    -- recent of these.
    ('40000000-0000-4000-a000-000000000003', '30000000-0000-4000-a000-000000000003',
     'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'Diabetes review',
     ((current_date - 5 + time '10:15') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 5 + time '10:45') AT TIME ZONE 'Asia/Kolkata')),

    ('40000000-0000-4000-a000-000000000004', '30000000-0000-4000-a000-000000000004',
     'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'Post-op review, CABG day 21',
     ((current_date - 3 + time '09:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 3 + time '10:00') AT TIME ZONE 'Asia/Kolkata')),

    ('40000000-0000-4000-a000-000000000005', '30000000-0000-4000-a000-000000000005',
     'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'Palpitations follow-up',
     ((current_date - 6 + time '11:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 6 + time '11:20') AT TIME ZONE 'Asia/Kolkata')),

    ('40000000-0000-4000-a000-000000000008', '30000000-0000-4000-a000-000000000008',
     'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 3', 'CKD review',
     ((current_date - 12 + time '15:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 12 + time '15:55') AT TIME ZONE 'Asia/Kolkata')),

    -- NO ATTENDING: nobody is assigned to Grace Lin, so nobody may open her chart.
    ('40000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000007',
     'outpatient', 'discharged', 'general_medicine',
     NULL, 'Clinic 1', 'Blood pressure check',
     ((current_date - 9 + time '08:45') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 9 + time '09:00') AT TIME ZONE 'Asia/Kolkata'))
  ) AS v(id, patient_id, class, status, dept, attending, room, reason, started, ended)
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 7 — VITALS
-- Rosa's four cards: HR 104, BP 96/61, Temp 38.4, SpO₂ 93%. Blood pressure is two columns,
-- never the string "96/61" — the sepsis flag depends on a falling systolic.
-- =============================================================================================

INSERT INTO public.vital_sign (id, organization_id, patient_id, encounter_id, measured_at, source,
                               heart_rate_bpm, systolic_mmhg, diastolic_mmhg, temperature_c,
                               spo2_percent, respiratory_rate_bpm, supplemental_o2, recorded_by)
VALUES
  ('60000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   ((current_date - 1 + time '22:00') AT TIME ZONE 'Asia/Kolkata'), 'clinician_measured',
   92, 108, 68, 38.0, 95, 20, NULL, '20000000-0000-4000-a000-000000000001'),
  ('60000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   ((current_date + time '07:40') AT TIME ZONE 'Asia/Kolkata'), 'clinician_measured',
   104, 96, 61, 38.4, 93, 24, '2L NC', '20000000-0000-4000-a000-000000000001'),
  ('60000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000002', '40000000-0000-4000-a000-000000000002',
   ((current_date + time '08:00') AT TIME ZONE 'Asia/Kolkata'), 'clinician_measured',
   78, 132, 84, 36.8, 94, 18, NULL, '20000000-0000-4000-a000-000000000001'),
  ('60000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000006', '40000000-0000-4000-a000-000000000006',
   ((current_date + time '07:15') AT TIME ZONE 'Asia/Kolkata'), 'clinician_measured',
   88, 128, 76, 37.1, 90, 22, '28% Venturi', '20000000-0000-4000-a000-000000000001')
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 8 — CARE TEAM
--
-- Most rows already exist: app.ensure_attending_on_care_team() created one per encounter that
-- named an attending. The explicit rows below are the ones with no encounter behind them.
--
-- Grace Lin (patient 07) is absent from this table ON PURPOSE. She is the control case for the
-- second access boundary: 010's patient_select lets any clinician find her in the index, and
-- every clinical policy in 020/030 requires patient_id = ANY (app.care_patient_ids()), so her
-- condition, encounter and any future result stay closed. TESTING.md §5 exercises it.
-- =============================================================================================

INSERT INTO public.care_team_member (id, organization_id, patient_id, member_id, role,
                                     assignment_note, started_at, added_by)
VALUES
  -- Miguel's last visit was two weeks ago and his encounter already created an attending row;
  -- this adds the ongoing coordination relationship the care-plan screens assume.
  ('b2000000-0000-4000-a000-000000000008', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000008', '20000000-0000-4000-a000-000000000001',
   'care_coordinator', 'CKD pathway', now() - interval '60 days',
   '20000000-0000-4000-a000-000000000001')
ON CONFLICT DO NOTHING;


-- =============================================================================================
-- SECTION 9 — LABS
--
-- The doctor Labs queue, Rosa's "Recent labs" card and the patient portal's results list, all
-- from the same four tables. Reference ranges come from the lab_test catalogue, copied onto the
-- result at the moment it is reported so a later change to the catalogue cannot silently
-- re-interpret a result somebody already acted on.
-- =============================================================================================

INSERT INTO public.lab_order (id, organization_id, patient_id, encounter_id, panel_id, ordered_by,
                              priority, status, clinical_note, ordered_at, collected_at)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.patient_id, v.encounter_id, p.id,
       '20000000-0000-4000-a000-000000000001', v.priority::app.lab_priority, 'resulted',
       v.note, v.ordered, v.collected
  FROM (VALUES
    ('70000000-0000-4000-a000-000000000001'::uuid, '30000000-0000-4000-a000-000000000001'::uuid,
     '40000000-0000-4000-a000-000000000001'::uuid, 'lactate_repeat', 'stat',
     'Repeat lactate, sepsis screen positive',
     ((current_date + time '05:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '05:50') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000002', '30000000-0000-4000-a000-000000000001',
     '40000000-0000-4000-a000-000000000001', 'sepsis_screen', 'urgent', NULL,
     ((current_date - 1 + time '23:10') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 1 + time '23:30') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000003', '30000000-0000-4000-a000-000000000006',
     '40000000-0000-4000-a000-000000000006', 'abg', 'urgent', 'Rising CO2 on ward round',
     ((current_date + time '06:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '06:45') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000004', '30000000-0000-4000-a000-000000000003',
     '40000000-0000-4000-a000-000000000003', 'hba1c_panel', 'routine', NULL,
     ((current_date - 2 + time '09:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 2 + time '09:20') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000005', '30000000-0000-4000-a000-000000000003',
     '40000000-0000-4000-a000-000000000003', 'lipid_panel', 'routine', NULL,
     ((current_date - 2 + time '09:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 2 + time '09:20') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000006', '30000000-0000-4000-a000-000000000002',
     '40000000-0000-4000-a000-000000000002', 'bnp_renal', 'routine', NULL,
     ((current_date - 1 + time '08:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 1 + time '08:15') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000005',
     '40000000-0000-4000-a000-000000000005', 'echo_report', 'routine', NULL,
     ((current_date - 6 + time '11:05') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 6 + time '11:10') AT TIME ZONE 'Asia/Kolkata')),
    ('70000000-0000-4000-a000-000000000008', '30000000-0000-4000-a000-000000000008',
     '40000000-0000-4000-a000-000000000008', 'renal_electrolyte', 'routine', NULL,
     ((current_date - 12 + time '15:35') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date - 12 + time '15:50') AT TIME ZONE 'Asia/Kolkata'))
  ) AS v(id, patient_id, encounter_id, panel_code, priority, note, ordered, collected)
  JOIN public.lab_panel p
    ON p.organization_id = '11111111-1111-4111-a111-111111111111' AND p.code = v.panel_code
ON CONFLICT (id) DO NOTHING;

-- Results. abnormal_flag is normally left to app.fill_lab_result_flag(), which derives it from
-- the range on the row; where a value is supplied below it is because the LABORATORY sent a
-- flag, and a flag from the lab always beats a range comparison (020 §30). Lactate 3.1 is the
-- case in point: it is outside 0.5–2.2 but under the 4.0 critical threshold, and the lab called
-- it critical on the trajectory. The Labs screen's "Critical ↑" pill is that decision.
INSERT INTO public.lab_result (id, organization_id, lab_order_id, patient_id, lab_test_id,
                               value_numeric, value_text, unit, reference_low, reference_high,
                               reference_note, abnormal_flag, resulted_at, performing_lab,
                               review_status, reviewed_by, reviewed_at, released_to_patient_at)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.order_id, v.patient_id, t.id,
       v.val, NULL, t.default_unit, t.reference_low, t.reference_high, t.reference_note,
       v.flag::app.lab_abnormal_flag, v.resulted, v.lab,
       v.review::app.lab_review_status,
       -- lab_result_reviewed_ck fires DURING the insert, so "reviewed" must carry its reviewer
       -- and timestamp here; a later backfill can never rescue these rows.
       CASE WHEN v.review = 'unreviewed' THEN NULL
            ELSE '20000000-0000-4000-a000-000000000001'::uuid END,
       CASE WHEN v.review = 'unreviewed' THEN NULL
            ELSE v.resulted + interval '90 minutes' END,
       v.released
  FROM (VALUES
    -- Rosa — the sepsis picture
    ('80000000-0000-4000-a000-000000000001'::uuid, '70000000-0000-4000-a000-000000000001'::uuid,
     '30000000-0000-4000-a000-000000000001'::uuid, 'lactate',    3.1::numeric, 'critical_high',
     ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'unreviewed', NULL::timestamptz),
    ('80000000-0000-4000-a000-000000000002', '70000000-0000-4000-a000-000000000002',
     '30000000-0000-4000-a000-000000000001', 'wbc',        14.2, NULL,
     ((current_date - 1 + time '23:55') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'unreviewed', NULL),
    ('80000000-0000-4000-a000-000000000003', '70000000-0000-4000-a000-000000000002',
     '30000000-0000-4000-a000-000000000001', 'crp',        86,   NULL,
     ((current_date - 1 + time '23:55') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'unreviewed', NULL),
    ('80000000-0000-4000-a000-000000000004', '70000000-0000-4000-a000-000000000002',
     '30000000-0000-4000-a000-000000000001', 'creatinine', 1.1,  NULL,
     ((current_date - 1 + time '23:55') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'unreviewed', NULL),

    -- Samuel — the ABG the Labs screen calls "CO₂ retention mild"
    ('80000000-0000-4000-a000-000000000005', '70000000-0000-4000-a000-000000000003',
     '30000000-0000-4000-a000-000000000006', 'paco2',      52,   NULL,
     ((current_date + time '07:02') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s blood gas',
     'unreviewed', NULL),
    ('80000000-0000-4000-a000-000000000006', '70000000-0000-4000-a000-000000000003',
     '30000000-0000-4000-a000-000000000006', 'pao2',       68,   NULL,
     ((current_date + time '07:02') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s blood gas',
     'unreviewed', NULL),

    -- Priya — released to the portal, which is what makes them visible to the patient login
    ('80000000-0000-4000-a000-000000000007', '70000000-0000-4000-a000-000000000004',
     '30000000-0000-4000-a000-000000000003', 'hba1c',      8.9,  NULL,
     ((current_date - 2 + time '16:40') AT TIME ZONE 'Asia/Kolkata'), 'Quest Labs',
     'reviewed', ((current_date - 2 + time '18:00') AT TIME ZONE 'Asia/Kolkata')),
    ('80000000-0000-4000-a000-000000000008', '70000000-0000-4000-a000-000000000005',
     '30000000-0000-4000-a000-000000000003', 'glucose_f',  132,  NULL,
     ((current_date - 2 + time '16:40') AT TIME ZONE 'Asia/Kolkata'), 'Quest Labs',
     'reviewed', ((current_date - 2 + time '18:00') AT TIME ZONE 'Asia/Kolkata')),
    ('80000000-0000-4000-a000-000000000009', '70000000-0000-4000-a000-000000000005',
     '30000000-0000-4000-a000-000000000003', 'ldl',        96,   NULL,
     ((current_date - 2 + time '16:40') AT TIME ZONE 'Asia/Kolkata'), 'Quest Labs',
     'reviewed', ((current_date - 2 + time '18:00') AT TIME ZONE 'Asia/Kolkata')),
    ('80000000-0000-4000-a000-000000000010', '70000000-0000-4000-a000-000000000005',
     '30000000-0000-4000-a000-000000000003', 'egfr',       88,   NULL,
     ((current_date - 2 + time '16:40') AT TIME ZONE 'Asia/Kolkata'), 'Quest Labs',
     'reviewed', ((current_date - 2 + time '18:00') AT TIME ZONE 'Asia/Kolkata')),

    -- James, Lena, Miguel
    ('80000000-0000-4000-a000-000000000011', '70000000-0000-4000-a000-000000000006',
     '30000000-0000-4000-a000-000000000002', 'bnp',        78,   NULL,
     ((current_date - 1 + time '11:20') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'reviewed', NULL),
    ('80000000-0000-4000-a000-000000000012', '70000000-0000-4000-a000-000000000006',
     '30000000-0000-4000-a000-000000000002', 'creatinine', 1.15, NULL,
     ((current_date - 1 + time '11:20') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'reviewed', NULL),
    ('80000000-0000-4000-a000-000000000013', '70000000-0000-4000-a000-000000000007',
     '30000000-0000-4000-a000-000000000005', 'echo_ef',    58,   NULL,
     ((current_date - 6 + time '12:30') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s cardiology',
     'reviewed', NULL),
    -- eGFR 52 in stage-3 CKD is expected but genuinely abnormal, so the derived flag is 'low'.
    -- The mock's Labs screen paints this row "Normal"; that was cosmetic and is not reproduced.
    ('80000000-0000-4000-a000-000000000014', '70000000-0000-4000-a000-000000000008',
     '30000000-0000-4000-a000-000000000008', 'egfr',       52,   NULL,
     ((current_date - 12 + time '17:10') AT TIME ZONE 'Asia/Kolkata'), 'St. Luke''s core lab',
     'reviewed', NULL)
  ) AS v(id, order_id, patient_id, test_code, val, flag, resulted, lab, review, released)
  JOIN public.lab_test t
    ON t.organization_id = '11111111-1111-4111-a111-111111111111' AND t.code = v.test_code
ON CONFLICT (id) DO NOTHING;

-- lab_result_reviewed_ck: who/when are now written inline with the INSERT above, because a CHECK
-- constraint is evaluated per row as it arrives — an UPDATE afterwards is always too late. The
-- statement below stays only to repair any row that some earlier route inserted unreviewed-marked.
UPDATE public.lab_result
   SET reviewed_by = '20000000-0000-4000-a000-000000000001',
       reviewed_at = resulted_at + interval '90 minutes'
 WHERE organization_id = '11111111-1111-4111-a111-111111111111'
   AND review_status = 'reviewed'
   AND reviewed_by IS NULL;


-- =============================================================================================
-- SECTION 10 — TIMELINE NOTES AND MEDICATIONS
-- The Timeline card's prose entries. The lab and admission lines it also shows are assembled by
-- public.v_patient_timeline from the tables above, not copied here.
-- =============================================================================================

INSERT INTO public.clinical_note (id, organization_id, patient_id, encounter_id, author_member_id,
                                  note_type, occurred_at, body, signed_at)
VALUES
  ('90000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001', 'admission',
   ((current_date - 4 + time '14:20') AT TIME ZONE 'Asia/Kolkata'),
   'Admitted via ED — community-acquired pneumonia. RLL consolidation on chest film. '
   'Commenced on IV ceftriaxone and azithromycin per protocol.',
   ((current_date - 4 + time '15:05') AT TIME ZONE 'Asia/Kolkata')),
  ('90000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001', 'progress',
   ((current_date - 1 + time '21:00') AT TIME ZONE 'Asia/Kolkata'),
   'IV ceftriaxone administered per protocol. Afebrile at review; fluids given 8h ago.',
   ((current_date - 1 + time '21:15') AT TIME ZONE 'Asia/Kolkata')),
  ('90000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001', 'nursing',
   ((current_date + time '07:40') AT TIME ZONE 'Asia/Kolkata'),
   'Nursing note: increased work of breathing, O₂ titrated to 2L via nasal cannula. '
   'Observations escalated to the medical team.',
   ((current_date + time '07:50') AT TIME ZONE 'Asia/Kolkata'))
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.medication_order (id, organization_id, patient_id, encounter_id,
                                     prescriber_member_id, drug_name, dose_text, route,
                                     frequency_text, is_prn, status, started_at)
VALUES
  ('a0000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001', 'Ceftriaxone', '1 g', 'intravenous', 'q24h', false,
   'active', ((current_date - 4 + time '15:30') AT TIME ZONE 'Asia/Kolkata')),
  ('a0000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001', 'Azithromycin', '500 mg', 'intravenous', 'q24h', false,
   'active', ((current_date - 4 + time '15:30') AT TIME ZONE 'Asia/Kolkata')),
  ('a0000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', '40000000-0000-4000-a000-000000000001',
   '20000000-0000-4000-a000-000000000001', 'Paracetamol', '1 g', 'oral', 'PRN, max q6h', true,
   'active', ((current_date - 4 + time '15:30') AT TIME ZONE 'Asia/Kolkata')),
  -- Priya's care-plan medication, and the row her portal "Request refill" link writes to.
  ('a0000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000003', NULL,
   '20000000-0000-4000-a000-000000000001', 'Metformin', '500 mg', 'oral', 'with breakfast', false,
   'active', ((current_date - 47 + time '10:30') AT TIME ZONE 'Asia/Kolkata'))
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 11 — SCHEDULE, THE CHECK-IN QUEUE AND THE PORTAL'S NEXT APPOINTMENT
--
-- Everything is on Dr. Mehta except the walk-ins, which carry no provider because the queue's
-- "Triage pending" row is a real state. The mock gives some arrivals to Dr. Osei and Dr.
-- Fontaine; they have no login here (see §3), so rather than inventing identities their patients
-- are seeded as untriaged walk-ins. Add the logins and reassign if you want the fuller day.
--
-- app.guard_appointment() derives duration_minutes and stamps any lifecycle column left NULL for
-- the status being entered. The stamps are supplied explicitly here rather than left to the
-- trigger, because the trigger would write now() — and appointment_order_ck requires
-- done_at >= roomed_at >= checked_in_at, which a seed run before 10:16 local time would violate.
--
-- The queue rows use now()-relative arrival times so the Check-in screen's live "waiting 32 min"
-- is genuinely 32 minutes whenever you look, instead of drifting with the clock.
-- =============================================================================================

INSERT INTO public.appointment (id, organization_id, patient_id, block_title, encounter_id,
                                provider_member_id, department_id, visit_type_id, modality,
                                origin, room_label, scheduled_start, scheduled_end, status,
                                chief_complaint, queue_date, queue_ticket, checked_in_at,
                                roomed_at, done_at, created_by)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.patient_id, v.block_title, NULL,
       v.provider,
       (SELECT d.id FROM public.department d
         WHERE d.organization_id = '11111111-1111-4111-a111-111111111111' AND d.code = v.dept),
       (SELECT t.id FROM public.visit_type t
         WHERE t.organization_id = '11111111-1111-4111-a111-111111111111' AND t.code = v.visit),
       'in_person', v.origin::app.booking_origin, v.room, v.starts, v.ends,
       v.status::app.appointment_status, v.complaint, v.qdate, v.qticket, v.checked_in, v.roomed,
       v.done, '20000000-0000-4000-a000-000000000002'
  FROM (VALUES
    -- ---- Dr. Mehta's day ---------------------------------------------------------------------
    ('50000000-0000-4000-a000-000000000001'::uuid, '30000000-0000-4000-a000-000000000004'::uuid,
     NULL::text, '20000000-0000-4000-a000-000000000001'::uuid, 'cardiology', 'post_op_consult',
     'scheduled', 'Clinic 2',
     ((current_date + time '09:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '10:00') AT TIME ZONE 'Asia/Kolkata'),
     'waiting', 'Post-op follow-up', current_date, 1,
     (now() - interval '4 minutes'), NULL::timestamptz, NULL::timestamptz),

    ('50000000-0000-4000-a000-000000000002', '30000000-0000-4000-a000-000000000003',
     NULL, '20000000-0000-4000-a000-000000000001', 'general_medicine', 'diabetes_follow_up',
     'scheduled', 'Clinic 2',
     ((current_date + time '10:15') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '10:45') AT TIME ZONE 'Asia/Kolkata'),
     'done', 'Diabetes review', NULL, NULL,
     ((current_date + time '10:10') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '10:16') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '10:44') AT TIME ZONE 'Asia/Kolkata')),

    -- Booked time that belongs to no patient: patient_id NULL + a block title.
    ('50000000-0000-4000-a000-000000000003', NULL,
     'Ward rounds — 4th floor', '20000000-0000-4000-a000-000000000001', 'general_medicine', NULL,
     'scheduled', 'Ward 4',
     ((current_date + time '11:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '12:30') AT TIME ZONE 'Asia/Kolkata'),
     'booked', NULL, NULL, NULL, NULL, NULL, NULL),

    ('50000000-0000-4000-a000-000000000004', '30000000-0000-4000-a000-000000000005',
     NULL, '20000000-0000-4000-a000-000000000001', 'cardiology', 'consult',
     'scheduled', 'Clinic 2',
     ((current_date + time '13:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '13:50') AT TIME ZONE 'Asia/Kolkata'),
     'booked', 'Echo results', NULL, NULL, NULL, NULL, NULL),

    ('50000000-0000-4000-a000-000000000005', NULL,
     'MDT case conference', '20000000-0000-4000-a000-000000000001', 'cardiology', NULL,
     'scheduled', 'Conference room B',
     ((current_date + time '15:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '16:00') AT TIME ZONE 'Asia/Kolkata'),
     'booked', NULL, NULL, NULL, NULL, NULL, NULL),

    ('50000000-0000-4000-a000-000000000006', '30000000-0000-4000-a000-000000000012',
     NULL, '20000000-0000-4000-a000-000000000001', 'cardiology', 'consult',
     'scheduled', 'Clinic 2',
     ((current_date + 1 + time '10:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + 1 + time '10:30') AT TIME ZONE 'Asia/Kolkata'),
     'booked', 'Echo + consult follow-up', NULL, NULL, NULL, NULL, NULL),

    -- The patient portal's "Next appointment" card, awaiting the Confirm button.
    ('50000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000003',
     NULL, '20000000-0000-4000-a000-000000000001', 'general_medicine', 'diabetes_follow_up',
     'scheduled', 'Clinic room 2',
     ((current_date + 3 + time '09:00') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + 3 + time '09:30') AT TIME ZONE 'Asia/Kolkata'),
     'booked', 'Diabetes follow-up', NULL, NULL, NULL, NULL, NULL),

    -- ---- the check-in queue: walk-ins, no provider until triage ------------------------------
    ('50000000-0000-4000-a000-000000000008', '30000000-0000-4000-a000-000000000009',
     NULL, NULL, 'general_medicine', 'walk_in', 'walk_in', NULL,
     ((current_date + time '09:45') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '10:00') AT TIME ZONE 'Asia/Kolkata'),
     'waiting', 'Sore throat, fever', current_date, 2,
     (now() - interval '2 minutes'), NULL, NULL),

    -- The amber row: "waiting 32 min".
    ('50000000-0000-4000-a000-000000000009', '30000000-0000-4000-a000-000000000010',
     NULL, NULL, 'general_medicine', 'walk_in', 'walk_in', NULL,
     ((current_date + time '09:10') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '09:25') AT TIME ZONE 'Asia/Kolkata'),
     'waiting', 'Chest tightness on exertion', current_date, 3,
     (now() - interval '32 minutes'), NULL, NULL),

    ('50000000-0000-4000-a000-000000000010', '30000000-0000-4000-a000-000000000011',
     NULL, NULL, 'radiology', 'walk_in', 'walk_in', NULL,
     ((current_date + time '10:30') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '10:45') AT TIME ZONE 'Asia/Kolkata'),
     'waiting', 'CT chest, referred', current_date, 4,
     (now() - interval '5 minutes'), NULL, NULL),

    ('50000000-0000-4000-a000-000000000011', '30000000-0000-4000-a000-000000000013',
     NULL, NULL, 'general_medicine', 'walk_in', 'walk_in', NULL,
     ((current_date + time '10:50') AT TIME ZONE 'Asia/Kolkata'),
     ((current_date + time '11:05') AT TIME ZONE 'Asia/Kolkata'),
     'waiting', 'Registration incomplete — triage pending', current_date, 5,
     (now() - interval '11 minutes'), NULL, NULL)
  ) AS v(id, patient_id, block_title, provider, dept, visit, origin, room,
         starts, ends, status, complaint, qdate, qticket, checked_in, roomed, done)
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 12 — AI: RUNS, SCORES, FACTORS, FINDINGS, CITATIONS
--
-- Rosa's prognosis screen in full. Note what the schema forces and this seed therefore has:
--   * every run names its model AND version AND prompt version — no anonymous predictions;
--   * every finding carries a review state, and nothing is patient_visible unless a clinician
--     accepted it (ai_finding_patient_visible_ck);
--   * the trajectory chart is just ai_risk_score rows ordered by as_of, one run per timepoint.
-- =============================================================================================

-- Seven scheduled prognosis runs: the 72-hour trajectory plus this morning's.
INSERT INTO public.ai_analysis_run (id, organization_id, patient_id, kind, status, triggered_by,
                                    requested_by_member_id, model_provider, model_name,
                                    model_version, prompt_version, config, requested_at,
                                    started_at, completed_at, latency_ms, input_tokens,
                                    output_tokens, cost_micros, cost_currency)
SELECT v.id, '11111111-1111-4111-a111-111111111111', '30000000-0000-4000-a000-000000000001',
       'prognosis', 'succeeded', 'schedule', '20000000-0000-4000-a000-000000000001',
       'prognosify', 'prognosify-risk', 'v4.2', 'p-2026-07-11',
       jsonb_build_object('temperature', 0, 'window_hours', 72),
       v.ts, v.ts, v.ts + interval '4 seconds', 3820, 5100, 420, 47000, 'INR'
  FROM (VALUES
    ('c0000000-0000-4000-a000-000000000001'::uuid,
     ((current_date - 3 + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c0000000-0000-4000-a000-000000000002',
     ((current_date - 3 + time '18:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c0000000-0000-4000-a000-000000000003',
     ((current_date - 2 + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c0000000-0000-4000-a000-000000000004',
     ((current_date - 2 + time '18:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c0000000-0000-4000-a000-000000000005',
     ((current_date - 1 + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c0000000-0000-4000-a000-000000000006',
     ((current_date - 1 + time '18:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c0000000-0000-4000-a000-000000000007',
     ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'))
  ) AS v(id, ts)
ON CONFLICT (id) DO NOTHING;

-- Runs for the other flagged patients on the doctor dashboard.
INSERT INTO public.ai_analysis_run (id, organization_id, patient_id, kind, status, triggered_by,
                                    requested_by_member_id, model_provider, model_name,
                                    model_version, prompt_version, requested_at, started_at,
                                    completed_at, latency_ms, input_tokens, output_tokens,
                                    cost_micros)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.patient_id, 'prognosis', 'succeeded',
       'schedule', '20000000-0000-4000-a000-000000000001',
       'prognosify', 'prognosify-risk', 'v4.2', 'p-2026-07-11',
       ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'),
       ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'),
       ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata') + interval '4 seconds',
       3600, 4800, 390, 44000
  FROM (VALUES
    ('c0000000-0000-4000-a000-000000000011'::uuid, '30000000-0000-4000-a000-000000000002'::uuid),
    ('c0000000-0000-4000-a000-000000000012', '30000000-0000-4000-a000-000000000003'),
    ('c0000000-0000-4000-a000-000000000013', '30000000-0000-4000-a000-000000000004'),
    ('c0000000-0000-4000-a000-000000000014', '30000000-0000-4000-a000-000000000006'),
    ('c0000000-0000-4000-a000-000000000015', '30000000-0000-4000-a000-000000000008'),
    ('c0000000-0000-4000-a000-000000000016', '30000000-0000-4000-a000-000000000005')
  ) AS v(id, patient_id)
ON CONFLICT (id) DO NOTHING;

-- ---- the trajectory: 34 → 40 → 48 → 55 → 70 → 81 → 92 -----------------------------------------
-- One row per run. There is no separate time-series table and no previous_score_id chain: the
-- chart is ORDER BY as_of over exactly these rows.
INSERT INTO public.ai_risk_score (id, organization_id, run_id, patient_id, risk_type, value_kind,
                                  horizon, probability, band, change_points, change_note, as_of)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.run_id,
       '30000000-0000-4000-a000-000000000001', 'sepsis', 'probability', interval '48 hours',
       v.p, v.band::app.ai_risk_band, v.chg, v.note, v.as_of
  FROM (VALUES
    ('c1000000-0000-4000-a000-000000000001'::uuid, 'c0000000-0000-4000-a000-000000000001'::uuid,
     0.3400::numeric, 'medium', NULL::numeric, NULL::text,
     ((current_date - 3 + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c1000000-0000-4000-a000-000000000002', 'c0000000-0000-4000-a000-000000000002',
     0.4000, 'medium', 6,  'in 12h', ((current_date - 3 + time '18:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c1000000-0000-4000-a000-000000000003', 'c0000000-0000-4000-a000-000000000003',
     0.4800, 'medium', 8,  'in 12h', ((current_date - 2 + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c1000000-0000-4000-a000-000000000004', 'c0000000-0000-4000-a000-000000000004',
     0.5500, 'high',   7,  'in 12h', ((current_date - 2 + time '18:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c1000000-0000-4000-a000-000000000005', 'c0000000-0000-4000-a000-000000000005',
     0.7000, 'high',   15, 'in 12h', ((current_date - 1 + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
    ('c1000000-0000-4000-a000-000000000006', 'c0000000-0000-4000-a000-000000000006',
     0.8100, 'high',   11, 'in 12h', ((current_date - 1 + time '18:15') AT TIME ZONE 'Asia/Kolkata')),
    -- The number the whole app is built around: "High · 92%", "↑ 14 pts since admission".
    ('c1000000-0000-4000-a000-000000000007', 'c0000000-0000-4000-a000-000000000007',
     0.9200, 'critical', 14, 'since admission',
     ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'))
  ) AS v(id, run_id, p, band, chg, note, as_of)
ON CONFLICT (id) DO NOTHING;

-- The other two cards on the prognosis screen, both from this morning's run.
INSERT INTO public.ai_risk_score (id, organization_id, run_id, patient_id, risk_type, value_kind,
                                  horizon, probability, range_low, range_high, unit, band,
                                  change_points, change_note, baseline_low, baseline_high,
                                  baseline_label, as_of)
VALUES
  ('c1000000-0000-4000-a000-000000000008', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'icu_transfer', 'probability', interval '72 hours', 0.5400, NULL, NULL, NULL, 'medium',
   8, 'in 24h', NULL, NULL, NULL,
   ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata')),
  -- A range, not a probability: "9–12 days" with no horizon, which the shape CHECK allows only
  -- because value_kind says range. A probability with no horizon would be refused.
  ('c1000000-0000-4000-a000-000000000009', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'length_of_stay', 'range', NULL, NULL, 9.00, 12.00, 'days', 'medium',
   NULL, NULL, 5.00, 7.00, 'vs. 5–7 day cohort median',
   ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'))
ON CONFLICT (id) DO NOTHING;

-- The dashboard's other risk pills.
INSERT INTO public.ai_risk_score (id, organization_id, run_id, patient_id, risk_type, value_kind,
                                  horizon, probability, band, as_of)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.run_id, v.patient_id,
       v.risk_type::app.ai_risk_type, 'probability', v.horizon, v.p, v.band::app.ai_risk_band,
       ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata')
  FROM (VALUES
    ('c1000000-0000-4000-a000-000000000011'::uuid, 'c0000000-0000-4000-a000-000000000011'::uuid,
     '30000000-0000-4000-a000-000000000002'::uuid, 'readmission_30d',
     interval '30 days', 0.8800::numeric, 'high'),
    ('c1000000-0000-4000-a000-000000000012', 'c0000000-0000-4000-a000-000000000012',
     '30000000-0000-4000-a000-000000000003', 'glycemic_control',
     interval '90 days', 0.7600, 'medium'),
    ('c1000000-0000-4000-a000-000000000013', 'c0000000-0000-4000-a000-000000000013',
     '30000000-0000-4000-a000-000000000004', 'post_op_infection',
     interval '14 days', 0.7100, 'medium'),
    ('c1000000-0000-4000-a000-000000000014', 'c0000000-0000-4000-a000-000000000014',
     '30000000-0000-4000-a000-000000000006', 'deterioration_other',
     interval '48 hours', 0.6400, 'medium'),
    ('c1000000-0000-4000-a000-000000000015', 'c0000000-0000-4000-a000-000000000015',
     '30000000-0000-4000-a000-000000000008', 'deterioration_other',
     interval '90 days', 0.5800, 'medium'),
    ('c1000000-0000-4000-a000-000000000016', 'c0000000-0000-4000-a000-000000000016',
     '30000000-0000-4000-a000-000000000005', 'deterioration_other',
     interval '90 days', 0.1800, 'low')
  ) AS v(id, run_id, patient_id, risk_type, horizon, p, band)
ON CONFLICT (id) DO NOTHING;

-- Contributing factors: the five labelled bars, signed weights, ordered.
INSERT INTO public.ai_risk_factor (id, organization_id, risk_score_id, label, weight,
                                   normalized_magnitude, display_order, detail)
VALUES
  ('c2000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   'c1000000-0000-4000-a000-000000000007', 'Lactate 3.1, rising',  0.310, 0.880, 1,
   'Up from 2.2 mmol/L twelve hours ago.'),
  ('c2000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   'c1000000-0000-4000-a000-000000000007', 'HR trend (6h)',        0.240, 0.700, 2,
   'Sustained tachycardia, 92 → 104 bpm.'),
  ('c2000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   'c1000000-0000-4000-a000-000000000007', 'MAP 72, trending down', 0.180, 0.550, 3,
   'Derived from 96/61; falling since midnight.'),
  ('c2000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
   'c1000000-0000-4000-a000-000000000007', 'Age 71 · comorbidities', 0.130, 0.420, 4, NULL),
  -- Negative weight: the screen paints protective factors green. The sign carries meaning, so
  -- the column is signed rather than a magnitude plus a direction flag.
  ('c2000000-0000-4000-a000-000000000005', '11111111-1111-4111-a111-111111111111',
   'c1000000-0000-4000-a000-000000000007', 'Abx response (24h)',  -0.090, 0.250, 5,
   'CRP plateauing since the second dose.')
ON CONFLICT (id) DO NOTHING;

-- Findings: the risk summary, the three recommended actions, the Labs screen's AI note, and one
-- plain-language explanation that has been reviewed and released to the portal.
INSERT INTO public.ai_finding (id, organization_id, run_id, patient_id, kind, severity, title,
                               detail, confidence, display_order, review_state,
                               reviewed_by_member_id, reviewed_at, patient_visible)
VALUES
  ('c3000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'risk_summary', 'critical', 'Sepsis risk rising',
   'Key drivers: rising lactate, HR trend, age, low BP. Recommend sepsis bundle review and '
   'repeat lactate within 2h.', 0.920, 1, 'pending', NULL, NULL, false),
  ('c3000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'recommended_action', 'high', 'Repeat lactate within 2h',
   'Confirm trajectory before escalation decision.', 0.910, 2, 'pending', NULL, NULL, false),
  ('c3000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'recommended_action', 'high', 'Review sepsis bundle compliance',
   'Fluids given 8h ago; reassess volume status.', 0.870, 3, 'pending', NULL, NULL, false),
  ('c3000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'recommended_action', 'medium', 'Notify ICU outreach team',
   'Early heads-up given 54% transfer probability.', 0.780, 4, 'pending', NULL, NULL, false),
  ('c3000000-0000-4000-a000-000000000005', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000007', '30000000-0000-4000-a000-000000000001',
   'lab_note', 'high', 'Drives sepsis flag',
   'Lactate is the largest single contributor to this morning''s score.', 0.900, 5,
   'pending', NULL, NULL, false),
  -- Reviewed AND released: the two conditions ai_finding_patient_visible_ck requires before
  -- anything AI-generated can appear in the portal. Try flipping patient_visible on any of the
  -- pending rows above and the CHECK refuses it.
  ('c3000000-0000-4000-a000-000000000006', '11111111-1111-4111-a111-111111111111',
   'c0000000-0000-4000-a000-000000000012', '30000000-0000-4000-a000-000000000003',
   'plain_language_explanation', 'medium', 'Your HbA1c is above your goal',
   'HbA1c measures your average blood sugar over about three months. Yours is 8.9%, above the '
   '7.5% goal you set with Dr. Mehta. That is a signal to adjust the plan, not an emergency — '
   'you will review it together on Thursday.', 0.880, 1,
   'accepted', '20000000-0000-4000-a000-000000000001',
   ((current_date - 2 + time '17:55') AT TIME ZONE 'Asia/Kolkata'), true)
ON CONFLICT (id) DO NOTHING;

-- Citations. The lactate factor rests on an actual row in 020, recorded as a SOFT reference
-- (source_table + source_row_id) with the value AS DISPLAYED at the time it was cited, so the
-- citation still reads correctly even if the result is later superseded.
INSERT INTO public.ai_citation (id, organization_id, risk_factor_id, finding_id, source_kind,
                                source_table, source_row_id, source_column, observed_value,
                                observed_at, relevance, display_order)
VALUES
  ('c4000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   'c2000000-0000-4000-a000-000000000001', NULL, 'clinical_value',
   'lab_result', '80000000-0000-4000-a000-000000000001', 'value_numeric', '3.1 mmol/L',
   ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'), 0.940, 1),
  ('c4000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   'c2000000-0000-4000-a000-000000000002', NULL, 'clinical_value',
   'vital_sign', '60000000-0000-4000-a000-000000000002', 'heart_rate_bpm', '104 bpm',
   ((current_date + time '07:40') AT TIME ZONE 'Asia/Kolkata'), 0.810, 1),
  ('c4000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   NULL, 'c3000000-0000-4000-a000-000000000005', 'clinical_value',
   'lab_result', '80000000-0000-4000-a000-000000000001', 'value_numeric', '3.1 mmol/L',
   ((current_date + time '06:15') AT TIME ZONE 'Asia/Kolkata'), 0.960, 1)
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 13 — DOCUMENTS
--
-- Two rows, chosen to exercise the parts of 030 that are easy to get wrong:
--   * storage_key is forced to begin with app.storage_prefix(organization_id) by a CHECK, so a
--     key cannot be written that would resolve into another hospital's bucket prefix;
--   * the DICOM row is doc_type = 'radiology_image', which the schema refuses to send to any
--     model for interpretation. TESTING.md §7 runs that attempt and shows it failing.
-- =============================================================================================

INSERT INTO public.document (id, organization_id, patient_id, uploaded_by_member_id, source,
                             file_name, mime_type, byte_size, checksum_sha256,
                             storage_bucket, storage_key, scan_status, scanned_at, scanner,
                             doc_type, doc_type_source, doc_type_confidence,
                             doc_type_confirmed_by_member_id, doc_type_confirmed_at,
                             patient_visible)
VALUES
  ('d0000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000003', '20000000-0000-4000-a000-000000000002',
   'staff_upload', 'consent-diabetes-programme.pdf', 'application/pdf', 184320,
   md5('consent-priya') || md5('consent-priya-2'),
   'phi-documents',
   app.storage_prefix('11111111-1111-4111-a111-111111111111')
     || 'patient/30000000-0000-4000-a000-000000000003/consent-diabetes-programme.pdf',
   'clean', now() - interval '47 days', 'clamav 1.2.1',
   'scanned_document', 'human', NULL,
   '20000000-0000-4000-a000-000000000002', now() - interval '47 days', true),

  ('d0000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000001', NULL,
   'device_feed', 'chest-pa.dcm', 'application/dicom', 12582912,
   md5('rosa-chest-pa') || md5('rosa-chest-pa-2'),
   'phi-documents',
   app.storage_prefix('11111111-1111-4111-a111-111111111111')
     || 'patient/30000000-0000-4000-a000-000000000001/imaging/chest-pa.dcm',
   'clean', now() - interval '4 days', 'clamav 1.2.1',
   'radiology_image', 'model', 0.980, NULL, NULL, false)
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 14 — BILLING
--
-- CURRENCY: the prototype prints '$' on every amount; this schema defaults to INR because the
-- operator is in India. Amounts below carry the mock's NUMBERS as rupees, stored in paise
-- (bigint minor units) — so "$220" becomes ₹220.00 = 22000. One of the two is wrong and it is a
-- product decision, not a schema one; currency is per-invoice, so either answer works.
-- =============================================================================================

INSERT INTO public.payer (id, organization_id, kind, code, name, contact_phone, is_active) VALUES
  ('e0000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   'insurer', 'STARHEALTH', 'Star Health Insurance', '+91 44 2888 0000', true),
  ('e0000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   'self_pay', 'SELFPAY', 'Self-pay', NULL, true),
  ('e0000000-0000-4000-a000-000000000051', '22222222-2222-4222-a222-222222222222',
   'tpa', 'MEDIASSIST', 'Medi Assist TPA', '+91 80 6690 0000', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.patient_coverage (id, organization_id, patient_id, payer_id, priority,
                                     member_number, group_number, plan_name, valid_from,
                                     created_by)
VALUES
  ('e1000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000004', 'e0000000-0000-4000-a000-000000000001',
   'primary', 'SH-4471902', 'GRP-STL-014', 'Family Health Optima', current_date - 400,
   '20000000-0000-4000-a000-000000000002'),
  ('e1000000-0000-4000-a000-000000000011', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000011', 'e0000000-0000-4000-a000-000000000001',
   'primary', 'SH-9920144', 'GRP-STL-014', 'Family Health Optima', current_date - 120,
   '20000000-0000-4000-a000-000000000002')
ON CONFLICT (id) DO NOTHING;
-- member_number and group_number are in audit.redacted_column: a change to them appears in the
-- audit trail as a changed column, but the VALUE is never copied there.

INSERT INTO public.invoice (id, organization_id, patient_id, number, status, currency,
                            total_minor, patient_due_minor, coverage_id, payer_id,
                            prior_auth_required, prior_auth_ref, denial_risk_flag,
                            denial_risk_score, denial_risk_note, denial_model_version,
                            issued_at, due_at, created_by)
VALUES
  ('f0000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000004', 'INV-2241', 'copay_due', 'INR',
   22000, 22000, 'e1000000-0000-4000-a000-000000000004',
   'e0000000-0000-4000-a000-000000000001', false, NULL, false, NULL, NULL, NULL,
   now() - interval '2 days', now() + interval '12 days',
   '20000000-0000-4000-a000-000000000002'),

  -- "Auth missing" means exactly this and the CHECK enforces it: prior authorisation is
  -- required and we do not have a reference.
  ('f0000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000011', 'INV-2238', 'auth_missing', 'INR',
   114000, 114000, 'e1000000-0000-4000-a000-000000000011',
   'e0000000-0000-4000-a000-000000000001', true, NULL, true, 0.780,
   'Imaging without prior authorisation is the top denial reason for this payer.', 'denial-v1.3',
   now() - interval '5 days', now() + interval '9 days',
   '20000000-0000-4000-a000-000000000002'),

  ('f0000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000009', 'INV-2236', 'covered', 'INR',
   45000, 0, NULL, 'e0000000-0000-4000-a000-000000000001', false, NULL, false, NULL, NULL, NULL,
   now() - interval '6 days', now() + interval '8 days',
   '20000000-0000-4000-a000-000000000002'),

  ('f0000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000012', 'INV-2229', 'overdue', 'INR',
   46000, 46000, NULL, 'e0000000-0000-4000-a000-000000000002', false, NULL, false, NULL, NULL,
   NULL, now() - interval '35 days', now() - interval '21 days',
   '20000000-0000-4000-a000-000000000002'),

  ('f0000000-0000-4000-a000-000000000005', '11111111-1111-4111-a111-111111111111',
   '30000000-0000-4000-a000-000000000010', 'INV-2244', 'copay_due', 'INR',
   18000, 18000, NULL, 'e0000000-0000-4000-a000-000000000002', false, NULL, false, NULL, NULL,
   NULL, now(), now() + interval '14 days',
   '20000000-0000-4000-a000-000000000002'),

  -- ORG 2: one bill, so financial isolation has something to fail on if it is broken.
  ('f0000000-0000-4000-a000-000000000051', '22222222-2222-4222-a222-222222222222',
   '30000000-0000-4000-a000-000000000051', 'INV-9001', 'copay_due', 'INR',
   55000, 55000, NULL, 'e0000000-0000-4000-a000-000000000051', false, NULL, false, NULL, NULL,
   NULL, now() - interval '1 day', now() + interval '13 days', NULL)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.invoice_line (id, organization_id, invoice_id, line_no, description,
                                 service_code, code_system, department_id, quantity,
                                 unit_price_minor, amount_minor)
SELECT v.id, v.org, v.invoice_id, 1, v.description, v.code, v.code_system,
       (SELECT d.id FROM public.department d
         WHERE d.organization_id = v.org AND d.code = v.dept),
       1, v.amount, v.amount
  FROM (VALUES
    ('f1000000-0000-4000-a000-000000000001'::uuid, '11111111-1111-4111-a111-111111111111'::uuid,
     'f0000000-0000-4000-a000-000000000001'::uuid, 'Post-op consult', NULL::text, 'local',
     'cardiology', 22000::bigint),
    -- 71260 is a CPT code (a US code set). It comes straight from the mock and should be
    -- re-coded before go-live; code_system is explicit so the mismatch is visible rather than
    -- assumed away.
    ('f1000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
     'f0000000-0000-4000-a000-000000000002', 'CT scan, chest', '71260', 'cpt',
     'radiology', 114000),
    ('f1000000-0000-4000-a000-000000000003', '11111111-1111-4111-a111-111111111111',
     'f0000000-0000-4000-a000-000000000003', 'Annual physical', NULL, 'local',
     'general_medicine', 45000),
    ('f1000000-0000-4000-a000-000000000004', '11111111-1111-4111-a111-111111111111',
     'f0000000-0000-4000-a000-000000000004', 'Echo + consult', NULL, 'local',
     'cardiology', 46000),
    ('f1000000-0000-4000-a000-000000000005', '11111111-1111-4111-a111-111111111111',
     'f0000000-0000-4000-a000-000000000005', 'Consult', NULL, 'local',
     'general_medicine', 18000),
    ('f1000000-0000-4000-a000-000000000051', '22222222-2222-4222-a222-222222222222',
     'f0000000-0000-4000-a000-000000000051', 'Consultation', NULL, 'local',
     'general_medicine', 55000)
  ) AS v(id, org, invoice_id, description, code, code_system, dept, amount)
ON CONFLICT (id) DO NOTHING;

-- "Collected today". Payments are signed: a refund would be a negative row referencing the
-- payment it reverses, so the balance stays one SUM and nothing is ever deleted.
INSERT INTO public.payment (id, organization_id, invoice_id, amount_minor, method, reference,
                            received_at, received_by)
VALUES
  ('f2000000-0000-4000-a000-000000000001', '11111111-1111-4111-a111-111111111111',
   'f0000000-0000-4000-a000-000000000003', 45000, 'insurance', 'STAR-STL-77120',
   now() - interval '3 hours', '20000000-0000-4000-a000-000000000002'),
  ('f2000000-0000-4000-a000-000000000002', '11111111-1111-4111-a111-111111111111',
   'f0000000-0000-4000-a000-000000000004', 20000, 'upi', 'UPI-2291884',
   now() - interval '90 minutes', '20000000-0000-4000-a000-000000000002')
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 15 — ORG 2 ACTIVITY
-- Enough for Meridian to look like a live tenant, and no members at all — a hospital nobody in
-- org 1 has a seat in is the cleanest possible isolation fixture.
-- =============================================================================================

INSERT INTO public.appointment (id, organization_id, patient_id, provider_member_id,
                                department_id, modality, origin, scheduled_start, scheduled_end,
                                status, chief_complaint, queue_date, queue_ticket, checked_in_at)
SELECT '50000000-0000-4000-a000-000000000051', '22222222-2222-4222-a222-222222222222',
       '30000000-0000-4000-a000-000000000052', NULL, d.id, 'in_person', 'walk_in',
       ((current_date + time '11:15') AT TIME ZONE 'Asia/Kolkata'),
       ((current_date + time '11:30') AT TIME ZONE 'Asia/Kolkata'),
       'waiting', 'Follow-up, walk-in', current_date, 1,
       ((current_date + time '11:12') AT TIME ZONE 'Asia/Kolkata')
  FROM public.department d
 WHERE d.organization_id = '22222222-2222-4222-a222-222222222222' AND d.code = 'general_medicine'
ON CONFLICT (id) DO NOTHING;


-- =============================================================================================
-- SECTION 16 — VENDOR DASHBOARD COUNTERS
-- Populate today's usage so app.v_tenant_health is not empty on first look. In production this
-- is scheduled; app.record_usage() is the only writer and only service_role may call it.
-- =============================================================================================

SELECT app.refresh_organization_usage(current_date);


-- =============================================================================================
-- SECTION 17 — WHAT YOU SHOULD SEE
-- =============================================================================================

DO $summary$
DECLARE
  v_org1 uuid := '11111111-1111-4111-a111-111111111111';
  v_org2 uuid := '22222222-2222-4222-a222-222222222222';
  v_p1 int; v_p2 int; v_appt int; v_res int; v_inv int; v_scores int;
BEGIN
  SELECT count(*) INTO v_p1 FROM public.patient WHERE organization_id = v_org1;
  SELECT count(*) INTO v_p2 FROM public.patient WHERE organization_id = v_org2;
  SELECT count(*) INTO v_appt FROM public.appointment WHERE organization_id = v_org1;
  SELECT count(*) INTO v_res FROM public.lab_result WHERE organization_id = v_org1;
  SELECT count(*) INTO v_inv FROM public.invoice WHERE organization_id = v_org1;
  SELECT count(*) INTO v_scores FROM public.ai_risk_score WHERE organization_id = v_org1;

  RAISE NOTICE 'seed complete — St. Luke''s: % patients, % appointments, % lab results, '
               '% invoices, % risk scores. Meridian: % patients.',
               v_p1, v_appt, v_res, v_inv, v_scores, v_p2;
  RAISE NOTICE 'Next: run the queries in TESTING.md. Signing in and seeing an empty screen means '
               'the login is not linked to a member row — that is RLS working, not a bug.';
END
$summary$;

DROP TABLE IF EXISTS _seed_login;
