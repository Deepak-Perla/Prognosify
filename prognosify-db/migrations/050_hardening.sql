-- =============================================================================================
-- 050_hardening.sql — Prognosify security hardening
-- PostgreSQL 15+ / Supabase. Forward-only and idempotent: safe on a fresh install AND on a
-- database where 000–040 have already been applied to live data.
--
-- WHY A NEW FILE RATHER THAN EDITS TO 010–040
--   010–040 may already be applied. Everything here is expressed as CREATE OR REPLACE FUNCTION,
--   DROP POLICY IF EXISTS + CREATE POLICY (adjacent, so no table is ever left policy-less),
--   DROP TRIGGER IF EXISTS + CREATE TRIGGER, and guarded ALTER TABLE. Re-running is a no-op.
--
-- WHAT THIS FILE FIXES — the SQL-fixable, CONFIRMED findings from the two adversarial reviews
--   (security/ATTACK-cross-tenant.md, security/ATTACK-intra-tenant.md).
--
--   B1  CRITICAL  patient.portal_member_id was writable by any receptionist or clinician, so two
--                 ordinary UPDATEs re-pointed one patient's portal seat at another patient's
--                 chart. Now frozen by trigger; linking is two audited RPCs.       §3
--   C1  HIGH      app.allow_clinical_rewrite / app.allow_hard_delete are dotted custom GUCs that
--                 `authenticated` may SET, so the append-only and no-delete guards could be
--                 switched off by the role they constrain. Now also gated on the DB role.   §2
--   C2  HIGH      medication_order, patient_condition, patient_allergy, encounter and lab_order
--                 carried no append-only guard at all.                                     §5
--   C3  HIGH      Fifteen UPDATE policies paired a strong USING with a tenant-only WITH CHECK,
--                 so any updatable row could be retargeted to any patient in the tenant.    §7
--   C4  HIGH      care_team_update let a clinician rewrite their own care-team row into a grant
--                 of chart access for a colleague, and forge added_by.                      §6
--   C4b MEDIUM    app.ensure_attending_on_care_team() granted a care-team seat to any member
--                 named as attending, clinician or not.                                     §6
--   A1  HIGH      public.patient had no column guard: a patient could rewrite mrn, DOB, name,
--                 status, merged_into_patient_id, and detach their own portal link.          §3
--   A4  HIGH      app.enforce_patient_writable_columns() short-circuited on app.is_staff(), so
--                 the guard was simply off for the {patient,nurse} seats the README designs for.
--                 Now scoped on the ROW, not on the caller's roles.                          §4
--   A3  MEDIUM    app.document_before_update() left the attribution columns unguarded, so a
--                 patient could claim a named clinician confirmed their own upload.           §8
--   B2  MEDIUM    document_select published every doc_type = 'other' to the whole front desk —
--                 'other' is the catch-all a clinician can silently reclassify into.          §8
--   C5b MEDIUM    app.ai_finding_before_update() returned NEW unconditionally for a caller with
--                 no membership, so the model worker could rubber-stamp its own output under a
--                 named doctor's seat.                                                        §9
--   B3  MEDIUM    patient_coverage retargeting (closed by §7 plus a column freeze).       §7 §10
--   D1  MEDIUM    audit.set_request_context() let the audited actor declare a role they do not
--                 hold and a fabricated client IP.                                           §11
--   D3  MEDIUM    The alert-column arrays omitted the columns the confirmed exploits rewrite. §12
--   X-CT2 LOW     app.org_has_feature/app.org_feature_limit took an arbitrary organization_id
--                 and were granted to authenticated — cross-tenant commercial metadata.      §10
--   F1  CRITICAL  Deployment control, NOT fixable in SQL. Documented in README "Deployment
--                 prerequisites (security-critical)" and in the comment on
--                 app.current_auth_uid() rewritten in §13.
--
-- HOUSE RULES THIS FILE KEEPS
--   * every tenant policy still opens with `organization_id = app.current_org_id()`;
--   * ENABLE, never FORCE, row level security (010 §8.1 — FORCE + SECURITY DEFINER helpers
--     recurses);
--   * no DELETE policy is added anywhere, and no DELETE privilege is granted;
--   * no `OR app.is_super_admin()` is added to any clinical policy (§90 asserts it).
-- =============================================================================================


-- =============================================================================================
-- SECTION 1 — THE MISSING PRIMITIVE: "is this a trusted maintenance role?"  (C1)
--
-- Every escape hatch in 010/020 was gated on a GUC and nothing else. A dotted custom GUC in an
-- unreserved class can be SET by any role, `authenticated` included, so the hatch was a
-- preference rather than a privilege. This function is the privilege half.
--
-- WHY current_user AND NOT session_user
--   Under PostgREST every request does SET ROLE authenticated, which changes current_user and
--   leaves session_user as the pooler's login role. So current_user is the caller's effective
--   role and is the right thing to test. Note what is DELIBERATELY ABSENT: the
--   `OR current_user = session_user` clause that 030's scan_status guard used. On a direct psql
--   connection opened AS `authenticated` — exactly the F1 scenario — that clause is true, which
--   re-opens the hatch for the one caller it exists to exclude.
--
-- CALL IT ONLY FROM INVOKER-RIGHTS CODE
--   Inside a SECURITY DEFINER function current_user is the function's OWNER, so this returns
--   true there regardless of who called. That is load-bearing in two opposite directions:
--     * it is why app.link_patient_portal() (SECURITY DEFINER, §3) can write the column its own
--       trigger freezes, with no GUC and no special case;
--     * it is why the scan_status guard had to be moved OUT of the SECURITY DEFINER
--       app.document_before_update() into its own invoker-rights trigger (§8). Left where it
--       was, it was a no-op that passed for everybody.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.is_trusted_maintenance()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT current_user IN ('service_role', 'postgres', 'supabase_admin') $$;

COMMENT ON FUNCTION app.is_trusted_maintenance() IS
  'True when the CURRENT effective database role is a trusted server-side role (the migration '
  'owner, or the worker/runbook roles). This is the privilege half of every escape hatch in the '
  'schema: the GUC still records deliberate, greppable, per-transaction intent, and this decides '
  'whether the caller is allowed to have that intent. NEVER true for `authenticated`. Do not '
  'call it from a SECURITY DEFINER function expecting to learn who the caller is — there '
  'current_user is the function owner.';


-- =============================================================================================
-- SECTION 2 — RE-GATE THE THREE ESCAPE HATCHES  (C1, plus the clinical_note freeze from C3)
--
-- Before: `IF current_setting(<guc>) = 'on' THEN RETURN NEW/OLD;` with no privilege check, in
--   app.enforce_append_only()  (app.allow_clinical_rewrite)
--   app.guard_clinical_note()  (app.allow_clinical_rewrite)
--   app.deny_hard_delete()     (app.allow_hard_delete)
-- so `SET LOCAL app.allow_clinical_rewrite = 'on'` let a clinician rewrite a reported lab value
-- or the body of a signed note in place, with no superseding row.
--
-- After: the GUC is kept — a runbook still has to state its intent in a way a reviewer can grep
-- for — and the hatch additionally requires a trusted database role.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.enforce_append_only()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_mutable   text[] := coalesce(TG_ARGV[0], '{}')::text[];
  v_offending text;
BEGIN
  -- C1: intent (the GUC) AND privilege (the role). Either alone is not enough.
  IF app.is_trusted_maintenance()
     AND coalesce(current_setting('app.allow_clinical_rewrite', true), 'off') = 'on' THEN
    RETURN NEW;
  END IF;

  IF (to_jsonb(OLD) - v_mutable) IS DISTINCT FROM (to_jsonb(NEW) - v_mutable) THEN
    -- Only computed on the failure path: naming the column is what makes the error actionable.
    SELECT string_agg(n.key, ', ' ORDER BY n.key) INTO v_offending
      FROM jsonb_each(to_jsonb(NEW)) AS n(key, value)
     WHERE NOT (n.key = ANY (v_mutable))
       AND n.value IS DISTINCT FROM (to_jsonb(OLD) -> n.key);

    RAISE EXCEPTION
      'Clinical facts on % are append-only; % may not be updated in place (only % may).',
      TG_TABLE_NAME, coalesce(v_offending, 'that column'), array_to_string(v_mutable, ', ')
      USING errcode = '42501',
            hint = 'Insert a superseding row and set the old one to record_status = ''amended''.';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.enforce_append_only() IS
  'Freezes every column of a row except the ones named in the trigger argument. The escape '
  'hatch requires BOTH `SET LOCAL app.allow_clinical_rewrite = ''on''` AND a trusted database '
  'role (app.is_trusted_maintenance()). Before 050 the GUC alone was enough, which meant the '
  'append-only invariant could be switched off by the very role it constrains — see C1 in '
  'security/ATTACK-intra-tenant.md.';


CREATE OR REPLACE FUNCTION app.guard_clinical_note()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- ---- C3: the note's SUBJECT is frozen, unconditionally --------------------------------------
  -- USING is evaluated against the OLD row and WITH CHECK against the NEW one, so before 050 a
  -- clinician on patient A's care team could move A's signed note into patient B's chart. §7
  -- repeats the USING in the WITH CHECK, but that is not sufficient on its own: a clinician can
  -- self-assert onto B's care team first (020 §26) and then satisfy it. The column freeze is the
  -- actual close, and it is deliberately ahead of the maintenance hatch below — re-filing a note
  -- is never an in-place edit, in any role.
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.patient_id   IS DISTINCT FROM OLD.patient_id
     OR NEW.encounter_id IS DISTINCT FROM OLD.encounter_id THEN
    RAISE EXCEPTION
      'A clinical note cannot be moved to another tenant, patient or encounter (offending column: %).',
      CASE WHEN NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN 'organization_id'
           WHEN NEW.patient_id      IS DISTINCT FROM OLD.patient_id      THEN 'patient_id'
           ELSE 'encounter_id' END
      USING errcode = '42501',
            hint = 'Write the note in the correct chart and amend this one, so both stay visible.';
  END IF;

  -- ---- C1: the rewrite hatch now needs a privilege as well as an intent -----------------------
  IF app.is_trusted_maintenance()
     AND coalesce(current_setting('app.allow_clinical_rewrite', true), 'off') = 'on' THEN
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
    RAISE EXCEPTION 'Only the author may edit an unsigned note.' USING errcode = '42501';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.guard_clinical_note() IS
  'Freezes a note''s tenant, patient and encounter unconditionally (C3), then — unless a trusted '
  'maintenance role has set app.allow_clinical_rewrite — freezes body, type, occurred_at, '
  'signed_at and author on a SIGNED note, and restricts an unsigned draft to its author.';


CREATE OR REPLACE FUNCTION app.deny_hard_delete()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  -- C1: a lawful erasure request or a retention job runs as a trusted server-side role AND says
  -- so with the GUC. `authenticated` can say so and is still refused.
  IF app.is_trusted_maintenance()
     AND coalesce(current_setting('app.allow_hard_delete', true), 'off') = 'on' THEN
    RETURN OLD;
  END IF;
  RAISE EXCEPTION 'Hard delete is not permitted on %. Amend, void or supersede the row instead.',
                  TG_TABLE_NAME
    USING errcode = '42501',
          hint = 'A deliberate erasure runs as a trusted role and sets app.allow_hard_delete '
                 'for one transaction.';
END;
$$;

COMMENT ON FUNCTION app.deny_hard_delete() IS
  'Refuses DELETE on clinical and identity tables. The erasure hatch requires BOTH '
  '`SET LOCAL app.allow_hard_delete = ''on''` AND a trusted database role — before 050 the GUC '
  'alone was enough, so the guard the README credits was caller-disableable (finding E/C1).';


-- =============================================================================================
-- SECTION 3 — public.patient: THE IDENTITY-MAPPING COLUMN AND THE PATIENT COLUMN GUARD
--             (B1 CRITICAL, A1 HIGH)
--
-- THE ATTACK B1 DESCRIBES, IN TWO STATEMENTS
--   UPDATE public.patient SET portal_member_id = NULL         WHERE mrn = '<victim>';
--   UPDATE public.patient SET portal_member_id = '<their seat>' WHERE mrn = '<target>';
-- patient_portal_member_uk is a PARTIAL unique index, so NULLing the first row frees the seat;
-- patient_portal_member_fk only requires the seat to be in the same organisation; and
-- app.current_patient_id() then resolves that person's login to the TARGET chart. One patient
-- reads another patient's entire record through ordinary policies, and the victim is locked out
-- of their own portal. Reachable by the lowest-privilege staff role in the schema.
--
-- THE FIX IS STRUCTURAL, NOT A POLICY TWEAK
--   portal_member_id stops being writable through the API at all. Linking becomes two RPCs so
--   that re-pointing a seat is always unlink-then-link — two separately audited acts by two
--   different privilege levels — rather than one statement that looks like registration work.
--
-- OPERATIONAL NOTE: seed.sql writes patient.portal_member_id directly (one INSERT, one UPDATE).
--   That keeps working because the seed runs as the migration owner or as service_role, for which
--   app.is_trusted_maintenance() is true. Run it under `set local role authenticated` and it will
--   now fail — correctly, and that is the point.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.guard_patient_identity()
RETURNS trigger LANGUAGE plpgsql          -- INVOKER rights on purpose: see §1
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  -- A1: what a caller acting purely as the patient may change on their OWN chart. Everything
  -- else — mrn, names, date_of_birth, sex, status, merge state — is a staff act.
  v_self_writable CONSTANT text[] := ARRAY['phone', 'email', 'updated_at'];
  v_trusted       boolean  := app.is_trusted_maintenance();
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- B1: registration must never create an already-linked chart, otherwise the same attack
    -- works as free-the-seat + INSERT instead of free-the-seat + UPDATE.
    IF NEW.portal_member_id IS NOT NULL AND NOT v_trusted THEN
      RAISE EXCEPTION 'A patient chart cannot be registered with a portal seat already attached.'
        USING errcode = '42501',
              hint = 'Register the chart, then call app.link_patient_portal(patient_id, member_id).';
    END IF;
    RETURN NEW;
  END IF;

  IF v_trusted THEN
    RETURN NEW;                            -- provisioning, the linking RPCs, a runbook
  END IF;

  -- ---- B1: the column that decides WHICH CHART a portal login resolves to ---------------------
  IF NEW.portal_member_id IS DISTINCT FROM OLD.portal_member_id THEN
    RAISE EXCEPTION 'patient.portal_member_id is not writable (offending column: portal_member_id).'
      USING errcode = '42501',
            hint = 'Use app.link_patient_portal() / app.unlink_patient_portal(). Re-pointing a '
                   'seat is deliberately two separately audited acts.';
  END IF;

  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION 'A patient chart cannot be moved between hospitals '
                    '(offending column: organization_id).'
      USING errcode = '42501';
  END IF;

  -- ---- A1 / B3: the administrative identity columns are hospital_admin only -------------------
  -- A receptionist setting status = 'merged' locks a patient out of the portal for good
  -- (app.current_patient_id() excludes merged charts); rewriting mrn collides two charts'
  -- identifiers. Neither is registration work.
  IF (NEW.mrn IS DISTINCT FROM OLD.mrn
      OR NEW.status IS DISTINCT FROM OLD.status
      OR NEW.merged_into_patient_id IS DISTINCT FROM OLD.merged_into_patient_id)
     AND NOT app.is_hospital_admin() THEN
    RAISE EXCEPTION
      'Only a hospital administrator may change a patient''s identity or merge state '
      '(offending column: %).',
      CASE WHEN NEW.mrn IS DISTINCT FROM OLD.mrn THEN 'mrn'
           WHEN NEW.status IS DISTINCT FROM OLD.status THEN 'status'
           ELSE 'merged_into_patient_id' END
      USING errcode = '42501',
            hint = 'Patient merge is modelled, not implemented (010 open question 2). When it is '
                   'built it belongs in an admin RPC, not in an UPDATE.';
  END IF;

  -- ---- A1: a caller acting as the patient, on their own chart ---------------------------------
  -- Same shape as app.enforce_patient_writable_columns(). NOT gated on app.is_patient(): a
  -- multi-role seat ({patient,nurse}) is staff and is governed by the policies plus the clause
  -- above, which is the four-eyes rule §4 argues for.
  IF app.current_patient_id() = OLD.id AND NOT app.is_staff() THEN
    IF (to_jsonb(OLD) - v_self_writable) IS DISTINCT FROM (to_jsonb(NEW) - v_self_writable) THEN
      RAISE EXCEPTION 'On your own record you may only change (%).',
                      array_to_string(v_self_writable, ', ')
        USING errcode = '42501',
              hint = 'Ask the front desk to correct a name, a date of birth or an MRN.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.guard_patient_identity() IS
  'Column-level authorisation for public.patient, which RLS cannot express. Freezes '
  'portal_member_id and organization_id against every API caller (B1), restricts mrn / status / '
  'merged_into_patient_id to hospital_admin (A1, B3), and limits a patient editing their own '
  'chart to phone and email.';

-- Trigger name sorts before t_touch, so this sees the row as the caller sent it and
-- app.touch_updated_at() still gets the last word on updated_at.
DROP TRIGGER IF EXISTS t_guard_identity ON public.patient;
CREATE TRIGGER t_guard_identity BEFORE INSERT OR UPDATE ON public.patient
  FOR EACH ROW EXECUTE FUNCTION app.guard_patient_identity();


-- ---- 3.1 the two RPCs that replace the UPDATE ------------------------------------------------
-- SECURITY DEFINER and owned by the table owner, so current_user inside them is the owner and
-- app.is_trusted_maintenance() passes naturally: no GUC, no bypass flag, nothing a caller can
-- set. Every precondition B1 relied on being unchecked is checked here.

CREATE OR REPLACE FUNCTION app.link_patient_portal(p_patient_id uuid, p_member_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_org     uuid := app.current_org_id();
  v_current uuid;
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'No active organisation for this session.' USING errcode = '42501';
  END IF;
  IF NOT (app.is_hospital_admin() OR app.is_front_desk()) THEN
    RAISE EXCEPTION 'Only a hospital administrator or the front desk may link a portal account.'
      USING errcode = '42501';
  END IF;

  SELECT p.portal_member_id INTO v_current
    FROM public.patient p
   WHERE p.id = p_patient_id AND p.organization_id = v_org
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No patient % in your organisation.', p_patient_id USING errcode = '42501';
  END IF;

  -- Re-pointing is never one act. This is the statement that made B1 possible.
  IF v_current IS NOT NULL THEN
    RAISE EXCEPTION 'Patient % already has a portal account linked.', p_patient_id
      USING errcode = '42501',
            hint = 'A hospital administrator must call app.unlink_patient_portal() first, so the '
                   'detach and the re-attach are two separate rows in the audit trail.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.organization_member m
     WHERE m.id = p_member_id
       AND m.organization_id = v_org
       AND m.status = 'active'
       AND 'patient'::app.org_role = ANY (m.roles)) THEN
    RAISE EXCEPTION 'Member % is not an active seat carrying the patient role in your organisation.',
                    p_member_id
      USING errcode = '42501';
  END IF;

  IF EXISTS (SELECT 1 FROM public.patient p2 WHERE p2.portal_member_id = p_member_id) THEN
    RAISE EXCEPTION 'Member % is already linked to another chart.', p_member_id
      USING errcode = '42501',
            hint = 'One portal seat resolves to exactly one chart. Unlink the other chart first.';
  END IF;

  UPDATE public.patient
     SET portal_member_id = p_member_id
   WHERE id = p_patient_id AND organization_id = v_org;
END;
$$;

COMMENT ON FUNCTION app.link_patient_portal(uuid, uuid) IS
  'Attach a portal seat to a chart. The only sanctioned writer of patient.portal_member_id. '
  'Requires hospital_admin or front desk, the same tenant for both, an active seat carrying the '
  'patient role, the seat not already linked, and the chart not already linked — the last of '
  'which is what makes re-pointing a seat two audited acts rather than one UPDATE (finding B1).';

CREATE OR REPLACE FUNCTION app.unlink_patient_portal(p_patient_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_org uuid := app.current_org_id();
BEGIN
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'No active organisation for this session.' USING errcode = '42501';
  END IF;
  -- Deliberately narrower than link: detaching a portal account is the half of the exploit that
  -- frees the seat, and it locks a patient out of their own record.
  IF NOT app.is_hospital_admin() THEN
    RAISE EXCEPTION 'Only a hospital administrator may unlink a portal account.'
      USING errcode = '42501';
  END IF;

  UPDATE public.patient
     SET portal_member_id = NULL
   WHERE id = p_patient_id
     AND organization_id = v_org
     AND portal_member_id IS NOT NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No linked patient % in your organisation.', p_patient_id
      USING errcode = '42501';
  END IF;
END;
$$;

COMMENT ON FUNCTION app.unlink_patient_portal(uuid) IS
  'Detach a portal seat from a chart. hospital_admin only — this is the half of finding B1 that '
  'frees a seat, and it locks the patient out of their own portal until it is re-linked.';


-- =============================================================================================
-- SECTION 4 — THE PATIENT COLUMN GUARD, SCOPED ON THE ROW INSTEAD OF THE CALLER  (A4)
--
-- Before: `IF app.current_patient_id() IS NULL OR app.is_staff() THEN RETURN NEW; END IF;`
-- The README designs for multi-role seats explicitly ("a nurse treated at her own hospital is
-- staff AND a patient there", 010 §5). For those seats app.is_staff() is true, so the guard was
-- off — while medication_order_update still admitted the seat through its patient branch. She
-- could rewrite her own prescriptions (drug, dose, route, status, prescriber) at will.
--
-- The report proposed `NOT app.is_patient()`. That is wrong: the guard compares the WHOLE row
-- regardless of which chart it belongs to, so it would also block a nurse-who-is-also-a-patient
-- from doing ordinary clinical work on OTHER patients' rows. The correct scope is the ROW.
--
-- What this makes true: a staff member who is also a patient at the same hospital needs a
-- colleague to make clinical edits to her own chart. That is the same four-eyes rule
-- app.sync_member_identity() already applies to roles and seat status (010 §5).
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.enforce_patient_writable_columns()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_writable  text[] := coalesce(TG_ARGV[0], '{}')::text[];
  v_self      uuid   := app.current_patient_id();
  v_offending text;
BEGIN
  -- No patient identity at all: a staff-only seat, or a trusted server-side worker. The policies
  -- govern those.
  IF v_self IS NULL THEN
    RETURN NEW;
  END IF;

  -- The row is not this caller's own chart, so this guard has nothing to say about it. Read
  -- through to_jsonb so one function still serves every table: appointment.patient_id is
  -- nullable for non-patient calendar blocks, and NULL IS DISTINCT FROM a non-null id is true,
  -- so block rows pass through untouched.
  IF (to_jsonb(NEW) ->> 'patient_id') IS DISTINCT FROM v_self::text THEN
    RETURN NEW;
  END IF;

  -- The caller is writing their OWN chart. The writable list binds regardless of any staff role
  -- the same seat happens to hold (A4).
  IF (to_jsonb(OLD) - v_writable) IS DISTINCT FROM (to_jsonb(NEW) - v_writable) THEN
    SELECT string_agg(n.key, ', ' ORDER BY n.key) INTO v_offending
      FROM jsonb_each(to_jsonb(NEW)) AS n(key, value)
     WHERE NOT (n.key = ANY (v_writable))
       AND n.value IS DISTINCT FROM (to_jsonb(OLD) -> n.key);

    RAISE EXCEPTION 'On your own record you may only change (%) on % — offending column(s): %.',
      array_to_string(v_writable, ', '), TG_TABLE_NAME, coalesce(v_offending, '?')
      USING errcode = '42501',
            hint = 'A colleague must make clinical edits to your own chart. This is deliberate '
                   'four-eyes on self-treatment.';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.enforce_patient_writable_columns() IS
  'Column-level authorisation for "the patient may update THIS column of their own row and '
  'nothing else". Scoped on the ROW (does this row belong to the caller''s own chart?), not on '
  'the caller''s roles — the old app.is_staff() short-circuit turned the guard off entirely for '
  'the {patient,nurse} and {patient,receptionist} seats the README designs for (finding A4).';


-- =============================================================================================
-- SECTION 5 — APPEND-ONLY ON THE FIVE CLINICAL TABLES THAT HAD NO GUARD AT ALL  (C2)
--
-- app.enforce_append_only() was attached only to vital_sign and lab_result; clinical_note has
-- its own guard. medication_order, patient_condition, patient_allergy, encounter and lab_order
-- carried only t_touch / t_patient_columns / t_no_delete — so a clinician on the care team could
-- silently rewrite a drug dose, a recorded allergy, a diagnosis, an admission or a lab order in
-- place. No escape-hatch GUC needed, no amendment row, no superseding record. Dose and allergy
-- are the two most safety-critical values in 020.
--
-- Every mutable list below deliberately OMITS patient_id and organization_id, which also closes
-- the row-retargeting half of C3 on these five tables (§7 explains why repeating the USING in
-- the WITH CHECK is necessary but not sufficient).
--
-- TRIGGER NAME ORDERING: t_append_only fires before t_touch, so updated_at is still the client's
-- value when this runs and must stay in each list. care_team_member (§6) has no updated_at.
-- =============================================================================================

DROP TRIGGER IF EXISTS t_append_only ON public.medication_order;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.medication_order
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only(
    '{status,ended_at,stop_reason,refill_requested_at,record_status,updated_at}');

DROP TRIGGER IF EXISTS t_append_only ON public.patient_condition;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.patient_condition
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only(
    '{clinical_status,resolved_date,is_primary,note,record_status,updated_at}');

-- patient_allergy has no record_status column: an allergy that turns out to be wrong is
-- inactivated with a reason, which is what makes "we removed it" and "it was never recorded"
-- distinguishable afterwards (020 §25).
DROP TRIGGER IF EXISTS t_append_only ON public.patient_allergy;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.patient_allergy
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only(
    '{inactivated_at,inactivated_reason,updated_at}');

DROP TRIGGER IF EXISTS t_append_only ON public.encounter;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.encounter
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only(
    '{status,ended_at,discharge_summary,room_label,department_id,attending_member_id,record_status,updated_at}');

DROP TRIGGER IF EXISTS t_append_only ON public.lab_order;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.lab_order
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only(
    '{status,collected_at,cancelled_at,cancellation_reason,clinical_note,record_status,updated_at}');


-- =============================================================================================
-- SECTION 6 — CARE TEAM: THE CHART-ACCESS GRANT  (C4 HIGH, C4b MEDIUM)
--
-- care_team_member IS the chart-access grant (app.care_patient_ids()), so a write to it is a
-- privilege change. Two bypasses of 020 §26's "a clinician may add themselves, and only
-- themselves" rule:
--
--   C4  care_team_update admitted `member_id = app.current_member_id()` in its USING and checked
--       only the tenant in its WITH CHECK, so one UPDATE rewrote member_id, patient_id, role and
--       added_by — granting a colleague access to any patient in the hospital, under a forged
--       name. A forgeable added_by destroys the whole §26 accountability argument: "it leaves a
--       row with a name and a timestamp" is only a control if the name is not chosen by the
--       person being held accountable.
--
--   C4b app.ensure_attending_on_care_team() is SECURITY DEFINER and inserted a seat for whatever
--       attending_member_id the encounter named. encounter_insert deliberately does not require
--       care-team membership and constrains only created_by, and encounter_attending_fk accepts
--       any member in the org — clinician or not. So one INSERT INTO public.encounter granted an
--       arbitrary member a chart-access seat.
-- =============================================================================================

DROP POLICY IF EXISTS care_team_update ON public.care_team_member;
CREATE POLICY care_team_update ON public.care_team_member FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR member_id = app.current_member_id()))
  WITH CHECK (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR member_id = app.current_member_id()));

-- Ending an assignment is the only legitimate update, so freeze everything else with machinery
-- already in 020. This is what actually stops member_id being rewritten: the WITH CHECK above
-- would still admit a row whose member_id is the caller's, and the exploit's useful direction —
-- retargeting patient_id, or forging added_by — is not a member_id change at all.
-- Columns verified against the table (020 §26): care_team_member has NO updated_at.
DROP TRIGGER IF EXISTS t_append_only ON public.care_team_member;
CREATE TRIGGER t_append_only BEFORE UPDATE ON public.care_team_member
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only('{ended_at,assignment_note}');


CREATE OR REPLACE FUNCTION app.ensure_attending_on_care_team()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.attending_member_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- C4b: this function bypasses care_team_insert entirely, so it must apply the part of that
  -- policy that still makes sense here — the seat it is about to grant must be one that could
  -- hold a chart-access seat in the first place.
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_member m
     WHERE m.id = NEW.attending_member_id
       AND m.organization_id = NEW.organization_id
       AND m.status = 'active'
       AND m.roles && ARRAY['doctor', 'nurse']::app.org_role[]) THEN
    RAISE EXCEPTION 'The attending on an encounter must be an active doctor or nurse.'
      USING errcode = '42501',
            hint = 'Naming a receptionist or an administrator as attending would grant them a '
                   'care-team seat, which is a chart-access grant.';
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

COMMENT ON FUNCTION app.ensure_attending_on_care_team() IS
  'Keeps "responsible clinician" and "may open the chart" from drifting apart. SECURITY DEFINER '
  'because it writes care_team_member on behalf of a caller whose own INSERT policy covers only '
  'themselves. RESIDUAL ACCEPTED RISK (C4b): one clinician naming another as attending still '
  'grants that colleague a care-team seat. That is clinically legitimate — an admission names a '
  'responsible clinician — and since 050 it is audited as an alert (added_by and patient_id are '
  'alert columns on care_team_member). Treat it as an accountability control, not a barrier: '
  '020 §26 should not be read as claiming otherwise.';

COMMENT ON TABLE public.care_team_member IS
  'Who is looking after this patient, and therefore who may open the chart '
  '(app.care_patient_ids()). Ending an assignment sets ended_at; rows are never deleted and, '
  'since 050, nothing else about an existing row may be updated — patient_id, member_id, '
  'added_by, role and started_at are frozen by t_append_only, because a rewritable added_by '
  'makes 020 §26''s accountability argument false (finding C4). A clinician may still add '
  'THEMSELVES to any chart in their own hospital: that is the argued emergency path.';


-- =============================================================================================
-- SECTION 7 — WITH CHECK MUST REPEAT USING  (C3 HIGH, systemic; B3 in part)
--
-- In PostgreSQL, USING is evaluated against the OLD row and WITH CHECK against the NEW one.
-- Fifteen UPDATE policies paired a strong USING with `WITH CHECK (organization_id =
-- app.current_org_id())`, which means: anyone who could update one row could retarget it to any
-- patient in the tenant. Move a signed note into a stranger's chart, fabricate an admission,
-- retarget a coverage row and its member_number onto a different patient.
--
-- SCOPE NOTE, because this is the finding most likely to be mistaken for complete: repeating the
-- USING is NECESSARY BUT NOT SUFFICIENT. A clinician can self-assert onto the target patient's
-- care team first (020 §26) and then satisfy the new WITH CHECK. The real close is the column
-- freeze, and it now exists on every one of these tables:
--     patient                       app.guard_patient_identity()          §3
--     patient_condition/allergy,
--     encounter, lab_order,
--     medication_order              app.enforce_append_only()             §5
--     care_team_member              app.enforce_append_only()             §6
--     vital_sign, lab_result        app.enforce_append_only()      (already in 020)
--     appointment                   app.guard_appointment()        (already in 020)
--     clinical_note                 app.guard_clinical_note()             §2
--     document                      app.document_before_update()          §8
--     ai_finding                    app.ai_output_inherit_scope()  (re-derives org and patient
--                                   from the parent run on every UPDATE — already in 030)
--     patient_coverage              app.freeze_patient_coverage_scope()   below
--
-- The three policies cross-checked as already correct are left alone: organization_update,
-- organization_member_update, app_user_update_self, department/visit_type/lab_panel/lab_test/
-- staff_profile_update, invoice_update, org_setting_write_*, invoice_line_write.
-- =============================================================================================

-- ---- 010 -------------------------------------------------------------------------------------
DROP POLICY IF EXISTS patient_update ON public.patient;
CREATE POLICY patient_update ON public.patient FOR UPDATE
  USING (
    organization_id = app.current_org_id()
    AND (app.is_front_desk() OR app.is_clinician() OR id = app.current_patient_id())
  )
  WITH CHECK (
    organization_id = app.current_org_id()
    AND (app.is_front_desk() OR app.is_clinician() OR id = app.current_patient_id())
  );

-- ---- 020: the chart ---------------------------------------------------------------------------
DROP POLICY IF EXISTS patient_condition_update ON public.patient_condition;
CREATE POLICY patient_condition_update ON public.patient_condition FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS patient_allergy_update ON public.patient_allergy;
CREATE POLICY patient_allergy_update ON public.patient_allergy FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS encounter_update ON public.encounter;
CREATE POLICY encounter_update ON public.encounter FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS vital_sign_update ON public.vital_sign;
CREATE POLICY vital_sign_update ON public.vital_sign FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS lab_order_update ON public.lab_order;
CREATE POLICY lab_order_update ON public.lab_order FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS lab_result_update ON public.lab_result;
CREATE POLICY lab_result_update ON public.lab_result FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS clinical_note_update ON public.clinical_note;
CREATE POLICY clinical_note_update ON public.clinical_note FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id() AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

-- The patient branch exists only for "Request refill"; app.enforce_patient_writable_columns()
-- (§4) limits it to that column, and §5's append-only trigger freezes drug, dose, route and
-- prescriber against everyone.
DROP POLICY IF EXISTS medication_order_update ON public.medication_order;
CREATE POLICY medication_order_update ON public.medication_order FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND ((app.has_role('doctor') AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()))
  WITH CHECK (organization_id = app.current_org_id()
         AND ((app.has_role('doctor') AND patient_id = ANY (app.care_patient_ids()))
              OR patient_id = app.current_patient_id()));

DROP POLICY IF EXISTS appointment_update ON public.appointment;
CREATE POLICY appointment_update ON public.appointment FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_front_desk() OR app.is_clinician()
              OR (patient_id IS NOT NULL AND patient_id = app.current_patient_id())))
  WITH CHECK (organization_id = app.current_org_id()
         AND (app.is_front_desk() OR app.is_clinician()
              OR (patient_id IS NOT NULL AND patient_id = app.current_patient_id())));

-- ---- 030 -------------------------------------------------------------------------------------
DROP POLICY IF EXISTS document_update ON public.document;
CREATE POLICY document_update ON public.document FOR UPDATE
  USING (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
      OR uploaded_by_member_id = app.current_member_id()
    )
  )
  WITH CHECK (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
      OR uploaded_by_member_id = app.current_member_id()
    )
  );

DROP POLICY IF EXISTS ai_finding_update ON public.ai_finding;
CREATE POLICY ai_finding_update ON public.ai_finding FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND app.is_clinician() AND patient_id IS NOT NULL
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id()
         AND app.is_clinician() AND patient_id IS NOT NULL
         AND patient_id = ANY (app.care_patient_ids()));

-- ---- 040 -------------------------------------------------------------------------------------
DROP POLICY IF EXISTS payer_update ON public.payer;
CREATE POLICY payer_update ON public.payer FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR app.is_front_desk()))
  WITH CHECK (organization_id = app.current_org_id()
         AND (app.is_hospital_admin() OR app.is_front_desk()));

DROP POLICY IF EXISTS patient_coverage_update ON public.patient_coverage;
CREATE POLICY patient_coverage_update ON public.patient_coverage FOR UPDATE
  USING (organization_id = app.current_org_id() AND app.is_front_desk())
  WITH CHECK (organization_id = app.current_org_id() AND app.is_front_desk());

-- B3 / C3(b): the WITH CHECK above does NOT stop retargeting on this table, because a
-- receptionist legitimately reaches every coverage row in the tenant — so the new predicate is
-- satisfied by the retargeted row too. member_number is a credential-grade identifier (040 §3);
-- moving it to another patient is the exploit.
CREATE OR REPLACE FUNCTION app.freeze_patient_coverage_scope()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.patient_id IS DISTINCT FROM OLD.patient_id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION
      'A coverage row cannot be moved to another patient or tenant (offending column: %).',
      CASE WHEN NEW.patient_id IS DISTINCT FROM OLD.patient_id
           THEN 'patient_id' ELSE 'organization_id' END
      USING errcode = '42501',
            hint = 'End this coverage (is_active = false) and record a new row against the '
                   'correct patient, so the bill raised while it was live still explains itself.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_freeze_scope ON public.patient_coverage;
CREATE TRIGGER t_freeze_scope BEFORE UPDATE ON public.patient_coverage
  FOR EACH ROW EXECUTE FUNCTION app.freeze_patient_coverage_scope();


-- =============================================================================================
-- SECTION 8 — DOCUMENTS  (A3 MEDIUM, B2 MEDIUM, and the vacuous scan_status gate)
--
-- A3  app.document_before_update() froze the stored object, the patient and the tenant, and
--     blocked reclassification to radiology_image/NULL — and left doc_type_confirmed_by_member_id,
--     doc_type_confirmed_at, doc_type_source, retracted_by_member_id, patient_visible, file_name
--     and uploaded_by_member_id wide open. document_update admits `uploaded_by_member_id =
--     app.current_member_id()`, document_insert permits source = 'patient_upload' by the patient,
--     document_confirmer_fk accepts any member in the org, and organization_member_select lets a
--     patient read every staff seat — so a patient could make their own portal upload claim that
--     a named clinician confirmed its classification.
--
-- B2  Combined with `doc_type IN ('scanned_document','other')` in document_select, setting
--     doc_type = 'other' published the file to every receptionist in the hospital. 'other' is
--     the catch-all, and a clinician may reclassify a lab_report into it (only NULL and
--     radiology_image are guarded destinations). It must not be a front-desk publication channel.
--
-- ALSO FIXED HERE, found while verifying C1: the scan_status gate at 030 §5 was a no-op.
--     `IF NEW.scan_status IS DISTINCT FROM OLD.scan_status AND NOT (current_user IN
--      ('service_role','postgres') OR current_user = session_user)` sits inside
--     app.document_before_update(), which is SECURITY DEFINER — so current_user is the FUNCTION
--     OWNER, the first disjunct is always true, and any clinician with UPDATE could mark their
--     own upload clean and unlock processing. The check has to run with invoker rights, so it
--     moves into its own trigger below.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.document_guard_scan_status()
RETURNS trigger LANGUAGE plpgsql          -- INVOKER rights, deliberately and load-bearingly
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.scan_status IS DISTINCT FROM OLD.scan_status
     AND NOT app.is_trusted_maintenance() THEN
    RAISE EXCEPTION 'Only the malware scanner may change scan_status (current role: %).',
                    current_user
      USING errcode = '42501';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.document_guard_scan_status() IS
  'scan_status belongs to the scanner, which runs as a trusted server-side role. Deliberately '
  'NOT part of app.document_before_update(): that function is SECURITY DEFINER, where '
  'current_user is the owner rather than the caller, which made the original check pass for '
  'everybody. Keep this one invoker-rights.';

-- Sorts before t_guard_update and t_touch, so it sees scan_status exactly as the caller sent it.
DROP TRIGGER IF EXISTS t_guard_scan_status ON public.document;
CREATE TRIGGER t_guard_scan_status BEFORE UPDATE ON public.document
  FOR EACH ROW EXECUTE FUNCTION app.document_guard_scan_status();


CREATE OR REPLACE FUNCTION app.document_before_update()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_offending uuid;
  v_kind      app.ai_analysis_kind;
  v_member    uuid := app.current_member_id();
  -- A3(c): a patient may rename or retract their own upload. Nothing else: not the type, not the
  -- confidence, not who confirmed it, and above all not patient_visible.
  v_patient_writable CONSTANT text[] :=
    ARRAY['file_name', 'retracted_at', 'retracted_reason', 'retracted_by_member_id', 'updated_at'];
BEGIN
  -- ---- 1. Immutable facts about the stored object ---------------------------------------------
  -- Re-pointing a document row at different bytes, or at a different patient, is how one
  -- patient's scan ends up displayed under another's name. A3(a) adds uploaded_by_member_id:
  -- document_update's own USING is `uploaded_by_member_id = app.current_member_id()`, so a
  -- writable uploader column is a writable access-control predicate.
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.patient_id     IS DISTINCT FROM OLD.patient_id
     OR NEW.storage_bucket IS DISTINCT FROM OLD.storage_bucket
     OR NEW.storage_key    IS DISTINCT FROM OLD.storage_key
     OR NEW.checksum_sha256 IS DISTINCT FROM OLD.checksum_sha256
     OR NEW.byte_size      IS DISTINCT FROM OLD.byte_size
     OR NEW.mime_type      IS DISTINCT FROM OLD.mime_type
     OR NEW.source         IS DISTINCT FROM OLD.source
     OR NEW.uploaded_by_member_id IS DISTINCT FROM OLD.uploaded_by_member_id THEN
    RAISE EXCEPTION 'The stored object, its patient, its tenant and its uploader are immutable '
                    'on a document.'
      USING errcode = '42501',
            hint = 'Upload a new document and retract this one, so both are visible in history.';
  END IF;

  -- ---- 2. scan_status: see app.document_guard_scan_status() -----------------------------------
  -- Not checked here on purpose. current_user inside this SECURITY DEFINER function is the
  -- function owner, so any role test written here is a no-op.

  -- ---- 3. A3(c): a patient acting on their own upload -----------------------------------------
  IF v_member IS NOT NULL
     AND NOT app.is_staff()
     AND app.current_patient_id() IS NOT NULL
     AND OLD.patient_id = app.current_patient_id() THEN
    IF (to_jsonb(OLD) - v_patient_writable) IS DISTINCT FROM (to_jsonb(NEW) - v_patient_writable) THEN
      RAISE EXCEPTION 'On your own upload you may only change (%).',
                      array_to_string(v_patient_writable, ', ')
        USING errcode = '42501',
              hint = 'Classification, portal release and clinical confirmation are staff acts.';
    END IF;
  END IF;

  -- ---- 4. A3(b): attribution is STAMPED, never declared ---------------------------------------
  -- Same pattern as app.ai_finding_before_update(): the server decides who put their name to
  -- this, because document_confirmer_fk only checks that the named seat exists in the tenant and
  -- a patient can read every staff seat in the directory. Guarded on v_member IS NOT NULL so a
  -- trusted worker (the classifier, the scanner) still passes through.
  IF v_member IS NOT NULL THEN
    IF NEW.doc_type        IS DISTINCT FROM OLD.doc_type
       OR NEW.doc_type_source IS DISTINCT FROM OLD.doc_type_source
       OR NEW.doc_type_confirmed_by_member_id IS DISTINCT FROM OLD.doc_type_confirmed_by_member_id
       OR NEW.doc_type_confirmed_at IS DISTINCT FROM OLD.doc_type_confirmed_at THEN
      IF NOT app.is_staff() THEN
        RAISE EXCEPTION 'Only staff may classify or confirm the type of a document.'
          USING errcode = '42501';
      END IF;
      NEW.doc_type_confirmed_by_member_id := v_member;
      NEW.doc_type_confirmed_at           := now();
    END IF;

    IF OLD.retracted_at IS NULL AND NEW.retracted_at IS NOT NULL THEN
      NEW.retracted_by_member_id := v_member;
      NEW.retracted_at           := now();
    ELSIF OLD.retracted_at IS NOT NULL AND NEW.retracted_at IS NULL THEN
      RAISE EXCEPTION 'A retraction is not reversible (offending column: retracted_at).'
        USING errcode = '42501',
              hint = 'Upload the document again if it was retracted in error.';
    ELSIF NEW.retracted_by_member_id IS DISTINCT FROM OLD.retracted_by_member_id THEN
      RAISE EXCEPTION 'retracted_by_member_id records who retracted the document; it is stamped, '
                      'not written.'
        USING errcode = '42501';
    END IF;
  END IF;

  -- ---- 5. LAYER 3 OF THE SAFETY GATE: reclassification ---------------------------------------
  IF NEW.doc_type IS DISTINCT FROM OLD.doc_type THEN
    IF NEW.doc_type IS NULL OR NEW.doc_type = 'radiology_image' THEN
      SELECT r.id, r.kind INTO v_offending, v_kind
        FROM public.ai_analysis_run r
       WHERE r.document_id = NEW.id
         AND r.kind <> 'metadata_index'
       LIMIT 1;

      IF v_offending IS NOT NULL THEN
        RAISE EXCEPTION
          'Document % cannot be reclassified to %: analysis run % of kind % already read it.',
          NEW.id, coalesce(NEW.doc_type::text, 'unclassified'), v_offending, v_kind
          USING errcode = '42501',
                hint = 'The interpretation on record was made against the previous '
                       'classification. Resolve that run first — this is the reclassification '
                       'hole the image ban would otherwise have.';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.document_before_update() IS
  'Guards the columns RLS cannot. Frozen: the stored object, its patient, its tenant and its '
  'uploader. Stamped rather than trusted: doc_type_confirmed_by_member_id / _at and '
  'retracted_by_member_id / retracted_at, because a client-supplied confirmer is a forged '
  'clinical signature (finding A3). A patient acting on their own upload may only rename or '
  'retract it. Un-retraction is refused. Layer 3 of the radiology-image gate still applies. '
  'scan_status is enforced separately by app.document_guard_scan_status(), which must keep '
  'invoker rights.';


-- B2: 'other' is the catch-all doc_type and must not be a front-desk publication channel. The
-- front desk keeps 'scanned_document' (consent forms, insurance cards — the reason the branch
-- exists) and keeps unrestricted sight of its OWN uploads through the clause above it.
DROP POLICY IF EXISTS document_select ON public.document;
CREATE POLICY document_select ON public.document FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
      OR uploaded_by_member_id = app.current_member_id()
      OR (app.is_front_desk() AND doc_type = 'scanned_document')
      OR (patient_id = app.current_patient_id()
          AND (source = 'patient_upload' OR patient_visible))
    )
  );

COMMENT ON POLICY document_select ON public.document IS
  'Clinicians on the care team, your own uploads, the front desk''s administrative scans, and '
  'the patient''s own uploads plus what was deliberately released to them. doc_type = ''other'' '
  'was removed from the front-desk branch in 050: it is the catch-all type, a clinician may '
  'reclassify a lab_report into it, and combined with finding A3 that made it a silent '
  'publication channel to the whole reception desk (finding B2).';


-- =============================================================================================
-- SECTION 9 — THE MODEL WORKER MAY NOT REVIEW ITS OWN OUTPUT  (C5b MEDIUM)
--
-- Before: `v_member := app.current_member_id(); IF v_member IS NULL THEN RETURN NEW;` — the
-- whole guard off. The model worker holds UPDATE ON public.ai_finding and BYPASSRLS and has no
-- membership, so it could set review_state = 'accepted', a named doctor's seat in
-- reviewed_by_member_id, and chart_committed_*, in one statement. ai_finding_review_pair_ck only
-- requires both review columns to be non-null, so the resulting row is indistinguishable from a
-- real clinical review of the AI's own output. actor_db_role = 'service_role' on the audit row
-- was the only tell.
--
-- After: a membership-less caller may still COMPLETE a run's output — that is what the worker is
-- for — but never perform a human act.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.ai_finding_before_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_member uuid := app.current_member_id();
BEGIN
  IF v_member IS NULL THEN
    -- C5b: no membership means no clinician seat, and a review names a clinician seat.
    IF NEW.review_state IS DISTINCT FROM OLD.review_state
       OR NEW.reviewed_by_member_id IS DISTINCT FROM OLD.reviewed_by_member_id
       OR NEW.reviewed_at IS DISTINCT FROM OLD.reviewed_at
       OR NEW.chart_committed_at IS DISTINCT FROM OLD.chart_committed_at
       OR NEW.chart_committed_by_member_id IS DISTINCT FROM OLD.chart_committed_by_member_id
       OR NEW.patient_visible IS DISTINCT FROM OLD.patient_visible THEN
      RAISE EXCEPTION 'A review names a clinician seat; database role % holds no membership.',
                      current_user
        USING errcode = '42501',
              hint = 'Review and chart commitment are web-session acts. A worker may only '
                     'complete model output.';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.run_id IS DISTINCT FROM OLD.run_id
     OR NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.patient_id  IS DISTINCT FROM OLD.patient_id
     OR NEW.kind        IS DISTINCT FROM OLD.kind
     OR NEW.title       IS DISTINCT FROM OLD.title
     OR NEW.detail      IS DISTINCT FROM OLD.detail
     OR NEW.confidence  IS DISTINCT FROM OLD.confidence
     OR NEW.severity    IS DISTINCT FROM OLD.severity
     OR NEW.display_order IS DISTINCT FROM OLD.display_order THEN
    RAISE EXCEPTION 'What the model said is not editable. Review it instead.'
      USING errcode = '42501',
            hint = 'Reject it, or accept with review_state = ''amended'' and put your own '
                   'wording in amended_text — both versions then stay on the record.';
  END IF;

  IF NEW.review_state IS DISTINCT FROM OLD.review_state THEN
    IF NEW.review_state = 'pending' THEN
      RAISE EXCEPTION 'A reviewed finding cannot be returned to pending.'
        USING errcode = '42501';
    END IF;
    IF NOT app.is_clinician() THEN
      RAISE EXCEPTION 'Only a doctor or nurse may review AI output.' USING errcode = '42501';
    END IF;
    NEW.reviewed_by_member_id := v_member;
    NEW.reviewed_at           := now();
  END IF;

  IF NEW.chart_committed_at IS DISTINCT FROM OLD.chart_committed_at THEN
    IF OLD.chart_committed_at IS NOT NULL THEN
      RAISE EXCEPTION 'A finding is written to the chart once; it is not un-written.'
        USING errcode = '42501',
              hint = 'File a correction in the chart itself — that is 020''s amendment path.';
    END IF;
    IF NOT app.is_clinician() THEN
      RAISE EXCEPTION 'Only a doctor or nurse may write AI output into a chart.'
        USING errcode = '42501';
    END IF;
    NEW.chart_committed_at           := now();
    NEW.chart_committed_by_member_id := v_member;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.ai_finding_before_update() IS
  'Column-level guard for the one AI table a web session may write. The model''s own words, '
  'confidence and severity are frozen; review and chart-commitment stamp the acting member and '
  'the server clock rather than trusting values from the client. CORRECTION TO 030 §6: this gate '
  'is NOT unconditional for a caller with no membership — before 050 such a caller (the model '
  'worker, which holds UPDATE and BYPASSRLS) skipped the whole function and could accept its own '
  'output under a named doctor''s seat. It may now complete model output and nothing else '
  '(finding C5b). The operational half — giving the generating worker INSERT only and putting '
  'UPDATE ON public.ai_finding behind a separate role — is a deployment follow-up recorded in '
  'the README.';


-- =============================================================================================
-- SECTION 10 — CROSS-TENANT COMMERCIAL METADATA  (X-CT2 LOW)
--
-- app.org_has_feature(uuid,text) and app.org_feature_limit(uuid,text) are SECURITY DEFINER, take
-- an arbitrary organization_id, and are granted to authenticated — so a Hospital A user could
-- read Hospital B's plan flags and seat limits. No PHI, but a real boundary crossing.
--
-- NOT fixed by revoking EXECUTE: app.has_feature(text) is plain STABLE and calls org_has_feature
-- as the caller, and app.v_effective_entitlement is security_invoker and calls it per row. Both
-- would break. So the check goes INSIDE, and returns the closed answer (false / NULL) rather
-- than raising, so the view still renders.
--
-- The `app.current_auth_uid() IS NULL` disjunct is required and deliberate: it keeps
-- app.enforce_staff_seat_limit() working when service_role provisions a tenant, and
-- app.v_tenant_health working for the vendor dashboard, both of which run without a JWT identity.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.org_has_feature(p_organization_id uuid, p_feature_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  -- Each comparison is coalesce()d to false on purpose: app.current_org_id() and
  -- app.support_org_id() are NULL for most callers, `x = NULL` is NULL, and `NOT (NULL OR false)`
  -- is NULL — which would fall through a naive CASE and disclose. Fail closed instead.
  SELECT CASE
    WHEN coalesce(p_organization_id = app.current_org_id(), false)
         OR app.is_super_admin()
         OR coalesce(p_organization_id = app.support_org_id(), false)
         OR app.current_auth_uid() IS NULL
    THEN coalesce(
      (SELECT e.enabled FROM public.organization_entitlement e
        WHERE e.organization_id = p_organization_id
          AND e.feature_key = p_feature_key
          AND e.effective_from <= now()
          AND (e.effective_to IS NULL OR e.effective_to > now())),
      (SELECT pf.enabled FROM public.organization o
         JOIN public.plan_feature pf ON pf.plan_id = o.plan_id
        WHERE o.id = p_organization_id AND pf.feature_key = p_feature_key),
      false)
    ELSE false
  END;
$$;

COMMENT ON FUNCTION app.org_has_feature(uuid, text) IS
  'Resolved entitlement for one organisation: override within its window beats plan default, '
  'absent means off. Since 050 it answers `false` for an organisation the caller has no '
  'relationship with rather than disclosing another tenant''s plan flags (finding X-CT2). '
  'Callers without a JWT identity at all (service_role provisioning, the vendor dashboard '
  'collector) are permitted, which is what keeps app.enforce_staff_seat_limit() working.';

CREATE OR REPLACE FUNCTION app.org_feature_limit(p_organization_id uuid, p_feature_key text)
RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  -- Same coalesce discipline as app.org_has_feature(): the permission test must never evaluate
  -- to NULL, because NULL is not "no" in a CASE.
  SELECT CASE
    WHEN coalesce(p_organization_id = app.current_org_id(), false)
         OR app.is_super_admin()
         OR coalesce(p_organization_id = app.support_org_id(), false)
         OR app.current_auth_uid() IS NULL
    THEN coalesce(
      (SELECT e.limit_value FROM public.organization_entitlement e
        WHERE e.organization_id = p_organization_id
          AND e.feature_key = p_feature_key
          AND e.enabled
          AND e.effective_from <= now()
          AND (e.effective_to IS NULL OR e.effective_to > now())),
      (SELECT pf.limit_value FROM public.organization o
         JOIN public.plan_feature pf ON pf.plan_id = o.plan_id
        WHERE o.id = p_organization_id AND pf.feature_key = p_feature_key AND pf.enabled))
    ELSE NULL::integer
  END;
$$;

COMMENT ON FUNCTION app.org_feature_limit(uuid, text) IS
  'The org-scoped sibling of app.feature_limit(). Since 050 it returns NULL — which every caller '
  'already reads as "unlimited or not applicable" — for an organisation the caller has no '
  'relationship with, rather than disclosing another tenant''s seat limit (finding X-CT2).';


-- =============================================================================================
-- SECTION 11 — THE AUDIT TRAIL'S DECLARED CONTEXT  (D1 MEDIUM)
--
-- audit.set_request_context() is granted to authenticated and audit.fn_row_audit() copied its
-- GUCs verbatim into the event, so the actor being audited could label their own writes with a
-- role they do not hold, a purpose they do not have and a fabricated client IP.
--
-- The identity half was and is genuinely safe: actor_app_user_id, actor_auth_uid, actor_org_id,
-- actor_roles and actor_db_role are all server-derived, and audit.log_read() takes
-- organization_id from app.current_org_id() rather than from an argument. So the failure mode is
-- POISONING, not concealment. Two fixes:
--   1. audit.acting_role() validates the claim against app.current_roles() instead of echoing
--      it, and a rejected claim raises the event's severity to 'alert' — a false declaration is
--      now itself a finding rather than a quiet lie on the row.
--   2. audit.event gains client_ip_observed, recorded beside the declared client_ip. The
--      database cannot know the true end-client address behind a proxy; it can stop the declared
--      value being the only one on the row.
-- =============================================================================================

-- Validated, not echoed. Note there is no cast of untrusted text to app.org_role anywhere here:
-- a garbage declaration must land as "false claim → alert", not as an invalid-input error that
-- fails the clinical write the trigger is auditing.
CREATE OR REPLACE FUNCTION audit.acting_role()
RETURNS app.org_role LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT held.r
    FROM (SELECT unnest(coalesce(app.current_roles(), ARRAY[]::app.org_role[])) AS r) held
   WHERE held.r::text = audit.ctx('acting_role')
   LIMIT 1;
$$;

COMMENT ON FUNCTION audit.acting_role() IS
  'Which hat the application declared it was acting under, VALIDATED against the roles the seat '
  'actually holds. NULL means the app did not say, said something the caller does not hold, or '
  'said something that is not a role at all. Before 050 the declaration was echoed onto the '
  'event unchecked, so a patient seat could record acting_role = ''doctor'' (finding D1). A '
  'rejected declaration is reported by audit.acting_role_is_false() and lands as '
  'severity = ''alert''.';

CREATE OR REPLACE FUNCTION audit.acting_role_is_false()
RETURNS boolean LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT audit.ctx('acting_role') IS NOT NULL AND audit.acting_role() IS NULL;
$$;

COMMENT ON FUNCTION audit.acting_role_is_false() IS
  'True when the request declared an acting role that the caller does not hold. Wired into the '
  'severity computation in audit.fn_row_audit() and audit.log_read(), so attributable poisoning '
  'of the trail is itself an alert.';

COMMENT ON FUNCTION audit.set_request_context(uuid, inet, text, text, audit.purpose, app.org_role) IS
  'Call once at the start of every request transaction. The declared fields are VALIDATED where '
  'validation is possible: acting_role is accepted only if the caller actually holds that role, '
  'and a rejected claim raises the event''s severity to ''alert''. client_ip cannot be validated '
  '— the database cannot see past a proxy — so audit.event records the declared value alongside '
  'the connection address it observed (client_ip_observed). purpose and route remain '
  'app-declared and unverifiable by construction: treat them as the application''s statement of '
  'intent, not as evidence.';

-- The observed address, beside the declared one.
--
-- TWO DELIBERATE DEVIATIONS FROM THE TRIAGE NOTE, both about not breaking a write:
--   * NULLABLE, not NOT NULL. inet_client_addr() returns NULL over a Unix-domain socket, so
--     NOT NULL would make every migration-time and local-runbook write fail its own audit
--     trigger — and a failing audit trigger fails the parent write.
--   * ADD COLUMN first, SET DEFAULT second. `ADD COLUMN ... DEFAULT inet_client_addr()` would
--     evaluate that STABLE function once at ALTER time and stamp the address of whoever ran the
--     migration onto every pre-existing audit row — a fabricated observation, which is the exact
--     failure this column exists to prevent. Splitting it leaves history NULL, as it should be.
DO $add_observed_ip$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute a
     WHERE a.attrelid = 'audit.event'::regclass
       AND a.attname = 'client_ip_observed'
       AND a.attnum > 0 AND NOT a.attisdropped) THEN
    ALTER TABLE audit.event ADD COLUMN client_ip_observed inet NULL;
    ALTER TABLE audit.event ALTER COLUMN client_ip_observed SET DEFAULT inet_client_addr();
    RAISE NOTICE 'prognosify/050: audit.event.client_ip_observed added (NULL for rows written '
                 'before this migration).';
  END IF;
END
$add_observed_ip$;

COMMENT ON COLUMN audit.event.client_ip_observed IS
  'The connection address PostgreSQL actually saw (inet_client_addr()). Behind PostgREST and a '
  'pooler this is the application tier, not the end client — which is exactly why client_ip is '
  'app-declared. Recording both means the declared value is no longer the only one on the row '
  '(finding D1). NULL over a Unix-domain socket.';

COMMENT ON COLUMN audit.event.acting_role IS
  'Which hat, as declared by the application AND validated against the seat''s actual roles by '
  'audit.acting_role(). NULL means the app did not say, or said something the caller does not '
  'hold — in the latter case the event is severity = ''alert''. It is never inferred from '
  'actor_roles, because for a multi-role seat any inference would be a guess recorded as a fact.';

COMMENT ON COLUMN audit.event.client_ip IS
  'The client address as DECLARED by the application. Unverifiable by the database, so it is '
  'recorded next to client_ip_observed rather than instead of it.';


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

    IF v_changed IS NULL THEN
      RETURN NULL;
    END IF;

    v_old := (SELECT jsonb_object_agg(k, v_old -> k) FROM unnest(v_changed) AS k);
    v_new := (SELECT jsonb_object_agg(k, v_new -> k) FROM unnest(v_changed) AS k);
  END IF;

  v_row     := nullif(v_full ->> 'id', '')::uuid;
  v_org     := nullif(v_full ->> 'organization_id', '')::uuid;
  v_patient := nullif(v_full ->> 'patient_id', '')::uuid;
  IF v_patient IS NULL AND TG_TABLE_NAME = 'patient' THEN
    v_patient := v_row;
  END IF;
  IF v_org IS NULL AND TG_TABLE_NAME = 'organization' THEN
    v_org := v_row;
  END IF;

  -- Sensitive columns named by the trigger definition (see §12 for the corrected lists).
  IF TG_NARGS > 0 AND (TG_OP <> 'UPDATE' OR v_changed && TG_ARGV::text[]) THEN
    v_severity := 'alert';
  END IF;

  -- THE ONE THAT MUST NEVER BE MISSED: a vendor account touching tenant data.
  IF v_vendor AND v_org IS NOT NULL THEN
    v_severity := 'alert';
  END IF;

  -- D1: the actor declared a role they do not hold. Poisoning the trail is itself an event.
  IF audit.acting_role_is_false() THEN
    v_severity := 'alert';
  END IF;

  INSERT INTO audit.event (
      actor_app_user_id, actor_auth_uid, actor_org_id, actor_roles, acting_role,
      actor_is_vendor, support_session_id,
      action, severity, purpose, table_schema, table_name, row_id,
      organization_id, patient_id, changed_columns, old_values, new_values,
      request_id, client_ip, client_ip_observed, user_agent, route)
  VALUES (
      app.current_user_id(), app.current_auth_uid(), v_actor_org, app.current_roles(),
      audit.acting_role(), v_vendor, v_support,
      v_action, v_severity, audit.ctx('purpose')::audit.purpose,
      TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row,
      v_org, v_patient, v_changed,
      audit.redact(v_old, TG_TABLE_SCHEMA, TG_TABLE_NAME),
      audit.redact(v_new, TG_TABLE_SCHEMA, TG_TABLE_NAME),
      audit.ctx('request_id')::uuid, audit.ctx('client_ip')::inet, inet_client_addr(),
      audit.ctx('user_agent'), audit.ctx('route'));

  RETURN NULL;   -- AFTER trigger: the return value is discarded
END;
$$;


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
DECLARE
  v_vendor boolean := app.is_super_admin();
  v_false  boolean := audit.acting_role_is_false();     -- D1
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
      request_id, client_ip, client_ip_observed, user_agent, route)
  VALUES (
      app.current_user_id(), app.current_auth_uid(), app.current_org_id(), app.current_roles(),
      audit.acting_role(), v_vendor, app.current_support_session_id(),
      p_action,
      CASE WHEN v_vendor OR v_false THEN 'alert'
           WHEN p_action = 'export' THEN 'sensitive'
           WHEN p_patient_id IS NOT NULL THEN 'sensitive'
           ELSE 'normal' END,
      coalesce(p_purpose, audit.ctx('purpose')::audit.purpose),
      'public', p_table, p_row_id,
      app.current_org_id(), p_patient_id, p_detail,
      audit.ctx('request_id')::uuid, audit.ctx('client_ip')::inet, inet_client_addr(),
      audit.ctx('user_agent'), audit.ctx('route'));
END;
$$;

COMMENT ON FUNCTION audit.log_read(name, uuid, uuid, audit.purpose, audit.action, jsonb) IS
  'App-reported read. organization_id is taken from app.current_org_id(), never from an '
  'argument, so a caller cannot attribute their read to somebody else''s tenant. A malicious '
  'client can log reads that did not happen (noise) but cannot suppress the ones it does '
  'report. Since 050, a read reported under a role the caller does not hold is recorded as '
  'severity = ''alert'' rather than accepted at face value (finding D1).';


-- =============================================================================================
-- SECTION 12 — ALERT COLUMNS: DETECTION FOR THE WRITES THE EXPLOITS ACTUALLY MAKE  (D3 MEDIUM)
--
-- audit.fn_row_audit() raises severity to 'alert' when a changed column appears in the trigger's
-- argument list. The arrays 040 §8 shipped omitted the columns every confirmed exploit above
-- rewrites, so the most identity- and safety-critical writes in the schema recorded
-- severity = 'normal' and never reached audit.v_alerts:
--   patient.portal_member_id  — the B1 exploit, and the single most identity-critical write here
--   care_team_member.patient_id / added_by — the C4 exploit, on the chart-ACCESS-GRANT table
--   medication_order.dose_text / drug_name / route — a dose rewrite (C2, A4)
--   document.doc_type_confirmed_by_member_id / uploaded_by_member_id — the A3 forgery
--   patient_coverage.patient_id — the B3 retargeting
--
-- Detection is not prevention. Every one of these is a control the schema already claimed to
-- have. Re-attaching in one block keeps the whole list reviewable in one screen.
-- =============================================================================================

DO $reattach$
BEGIN
  PERFORM audit.attach('public', 'patient',
    ARRAY['status', 'merged_into_patient_id', 'portal_member_id', 'mrn']);

  PERFORM audit.attach('public', 'care_team_member',
    ARRAY['member_id', 'ended_at', 'patient_id', 'added_by', 'role']);

  PERFORM audit.attach('public', 'medication_order',
    ARRAY['status', 'drug_name', 'dose_text', 'route', 'frequency_text', 'prescriber_member_id']);

  PERFORM audit.attach('public', 'document',
    ARRAY['doc_type', 'patient_visible', 'scan_status', 'retracted_at',
          'doc_type_confirmed_by_member_id', 'uploaded_by_member_id']);

  PERFORM audit.attach('public', 'patient_coverage',
    ARRAY['member_number', 'is_active', 'patient_id']);

  RAISE NOTICE 'prognosify/050: audit alert columns widened on patient, care_team_member, '
               'medication_order, document, patient_coverage.';
END
$reattach$;


-- =============================================================================================
-- SECTION 13 — F1: THE IDENTITY SEAM IS A DEPLOYMENT CONTROL, AND IT IS NOT FIXABLE HERE
--
-- Restated on the function itself, because that is where a reader of the schema meets it.
-- The full statement of the prerequisite is in README, "Deployment prerequisites
-- (security-critical)".
-- =============================================================================================

COMMENT ON FUNCTION app.current_auth_uid() IS
  'The authenticated subject (auth.users.id on Supabase). The single value this schema takes on '
  'trust from the host, and therefore the whole tenant boundary: current_org_id(), '
  'current_member_id(), current_patient_id(), care_patient_ids() and is_super_admin() all derive '
  'from it and nothing else. '
  'HARD DEPLOYMENT PREREQUISITE (finding F1, CRITICAL): it reads the request.jwt.claim.sub / '
  'request.jwt.claims placeholder GUCs. `request.*` is an unreserved placeholder class that ANY '
  'role — `authenticated` included — may set with set_config(), and PostgreSQL gives a migration '
  'no way to reserve it. So this value is trustworthy ONLY because PostgREST (or an equivalent) '
  'verifies the JWT signature and sets `sub` from the verified payload alone. If any end-user '
  'connection can reach this database as `authenticated` without that in front of it, two '
  'set_config() calls impersonate any subject in any hospital and every policy in the schema '
  'collapses. Do not attempt a SQL mitigation — there is none. Prove it in a deployment test '
  'instead, and note that because PostgreSQL has no SELECT trigger and read auditing is '
  'app-reported (040 §5.1), a cross-tenant READ through this path would leave no trace at all.';


-- =============================================================================================
-- SECTION 14 — GRANTS
--
-- Targeted rather than blanket: this file adds functions to schemas whose existing ACLs were set
-- deliberately by 010–040, and a `REVOKE ... ON ALL FUNCTIONS` here would be a wider change than
-- the one being made. New functions arrive with EXECUTE granted to PUBLIC, so each is revoked
-- and then handed out.
--
-- CREATE OR REPLACE FUNCTION does not reset a function's ACL, so every function this file
-- replaced keeps the grants 010–040 gave it. Nothing needs re-granting for those.
-- >>> BEGIN SUPABASE-SPECIFIC: role names are the PostgREST convention <<<
-- =============================================================================================

DO $grants$
BEGIN
  EXECUTE 'REVOKE EXECUTE ON FUNCTION
             app.is_trusted_maintenance(),
             app.guard_patient_identity(),
             app.link_patient_portal(uuid, uuid),
             app.unlink_patient_portal(uuid),
             app.document_guard_scan_status(),
             app.freeze_patient_coverage_scope(),
             audit.acting_role_is_false()
           FROM PUBLIC';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    -- app.is_trusted_maintenance() is called from INVOKER-rights trigger functions
    -- (app.enforce_append_only, app.guard_clinical_note, app.deny_hard_delete,
    -- app.guard_patient_identity, app.document_guard_scan_status), so EXECUTE is checked against
    -- the CALLER at runtime. Without this grant every guarded write fails with a permission
    -- error instead of a policy decision.
    EXECUTE 'GRANT EXECUTE ON FUNCTION app.is_trusted_maintenance() TO authenticated';

    -- The RPCs that replace UPDATE ON patient.portal_member_id. They do their own
    -- authorisation (hospital_admin / front desk) inside.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.link_patient_portal(uuid, uuid), app.unlink_patient_portal(uuid)
             TO authenticated';

    -- Trigger functions. Postgres checks EXECUTE when the trigger is CREATED rather than when it
    -- fires, so this is belt-and-braces, exactly as in 010 §11 / 020 §60. Calling any of them
    -- directly just raises.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.guard_patient_identity(), app.document_guard_scan_status(),
               app.freeze_patient_coverage_scope()
             TO authenticated';

    EXECUTE 'GRANT EXECUTE ON FUNCTION audit.acting_role_is_false() TO authenticated';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO service_role';
    EXECUTE 'GRANT EXECUTE ON FUNCTION audit.acting_role_is_false() TO service_role';
  END IF;

  -- No new table privileges, and no DELETE anywhere. Nothing in this file widens reach.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon';
  END IF;
END
$grants$;
-- >>> END SUPABASE-SPECIFIC <<< ----------------------------------------------------------------


-- =============================================================================================
-- SECTION 90 — SELF-CHECKS
--
-- Re-runs the schema's own CI gates plus one gate per finding class fixed above. If any of these
-- fires the migration fails, so the database is never left half-hardened.
-- =============================================================================================

-- 90.1 010's gate: no table carries organization_id without row level security.
DO $rls_gap$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s.%s', schema_name, table_name), ', ') INTO v_bad
    FROM app.v_tenant_rls_gaps;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tables carry organization_id but have no row level security: %', v_bad
      USING errcode = '42501';
  END IF;
END
$rls_gap$;

-- 90.2 010's gate: no blanket vendor access on any PHI or financial table. Called with the full
--      list across 010/020/030/040 — the policies rewritten above must not have introduced one.
SELECT app.assert_no_vendor_phi_policies(ARRAY[
  'patient', 'patient_condition', 'patient_allergy', 'care_team_member', 'encounter',
  'appointment', 'vital_sign', 'lab_order', 'lab_result', 'clinical_note', 'medication_order',
  'document', 'document_text', 'ai_analysis_run', 'ai_finding', 'ai_risk_score',
  'ai_risk_factor', 'ai_citation',
  'patient_coverage', 'invoice', 'invoice_line', 'payment'
]);

-- 90.3 C3's standing gate. USING is checked against the OLD row and WITH CHECK against the NEW
--      one, so an UPDATE policy whose with_check differs from its qual can let a row be mutated
--      out of the caller's own scope. A WARNING rather than an EXCEPTION: a deliberate asymmetry
--      is conceivable, but it must be a decision somebody names in review, not an oversight.
DO $with_check_gate$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(format('%s.%s.%s', schemaname, tablename, policyname), ', '
                    ORDER BY schemaname, tablename, policyname)
    INTO v_bad
    FROM pg_policies
   WHERE cmd = 'UPDATE'
     AND qual IS NOT NULL
     AND with_check IS NOT NULL
     AND with_check <> qual;
  IF v_bad IS NOT NULL THEN
    RAISE WARNING 'prognosify/050: UPDATE policies whose WITH CHECK differs from their USING: %. '
                  'Each one lets a row be retargeted out of the caller''s scope unless a column '
                  'freeze covers it. Review every entry (finding C3).', v_bad;
  ELSE
    RAISE NOTICE 'prognosify/050: every UPDATE policy repeats its USING in its WITH CHECK.';
  END IF;
END
$with_check_gate$;

-- 90.4 C1: none of the three escape hatches may be reachable on the GUC alone.
DO $hatch_gate$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(p.proname::text, ', ' ORDER BY p.proname::text) INTO v_bad
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'app'
     AND p.proname IN ('enforce_append_only', 'guard_clinical_note', 'deny_hard_delete')
     AND p.prosrc NOT LIKE '%is_trusted_maintenance%';
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Escape hatch is gated on a settable GUC alone in: % — `authenticated` can '
                    'switch off the guard it is constrained by (finding C1).', v_bad
      USING errcode = '42501';
  END IF;
END
$hatch_gate$;

-- 90.5 B1/A1/C2/C4/B3: the column freezes must actually be attached. A dropped trigger is how a
--      guard silently stops existing.
DO $trigger_gate$
DECLARE
  v_expected CONSTANT text[][] := ARRAY[
    ARRAY['patient',           't_guard_identity'],     -- B1, A1
    ARRAY['medication_order',  't_append_only'],        -- C2
    ARRAY['patient_condition', 't_append_only'],        -- C2
    ARRAY['patient_allergy',   't_append_only'],        -- C2
    ARRAY['encounter',         't_append_only'],        -- C2
    ARRAY['lab_order',         't_append_only'],        -- C2
    ARRAY['care_team_member',  't_append_only'],        -- C4
    ARRAY['vital_sign',        't_append_only'],        -- 020
    ARRAY['lab_result',        't_append_only'],        -- 020
    ARRAY['clinical_note',     't_guard'],              -- C3(a)
    ARRAY['appointment',       't_guard'],              -- 020
    ARRAY['document',          't_guard_update'],       -- A3
    ARRAY['document',          't_guard_scan_status'],  -- §8
    ARRAY['patient_coverage',  't_freeze_scope'],       -- C3(b), B3
    ARRAY['ai_finding',        't_guard_update'],       -- C5b
    ARRAY['ai_finding',        't_inherit_scope']       -- C3, re-derives org and patient
  ];
  v_row text[];
  v_bad text := NULL;
BEGIN
  FOREACH v_row SLICE 1 IN ARRAY v_expected LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = v_row[1]
         AND t.tgname = v_row[2] AND NOT t.tgisinternal) THEN
      v_bad := concat_ws(', ', v_bad, format('%s.%s', v_row[1], v_row[2]));
    END IF;
  END LOOP;
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Column-freeze triggers missing: %', v_bad USING errcode = '42501';
  END IF;
END
$trigger_gate$;

-- 90.6 D3: the alert columns that every confirmed exploit rewrites must be armed.
DO $alert_gate$
DECLARE
  v_expected CONSTANT text[][] := ARRAY[
    ARRAY['patient',          'portal_member_id'],
    ARRAY['patient',          'mrn'],
    ARRAY['care_team_member', 'patient_id'],
    ARRAY['care_team_member', 'added_by'],
    ARRAY['medication_order', 'dose_text'],
    ARRAY['medication_order', 'prescriber_member_id'],
    ARRAY['document',         'doc_type_confirmed_by_member_id'],
    ARRAY['document',         'uploaded_by_member_id'],
    ARRAY['patient_coverage', 'patient_id']
  ];
  v_row text[];
  v_bad text := NULL;
BEGIN
  FOREACH v_row SLICE 1 IN ARRAY v_expected LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = v_row[1]
         AND t.tgname = 'z_audit' AND NOT t.tgisinternal
         AND encode(t.tgargs, 'escape') LIKE '%' || v_row[2] || '%') THEN
      v_bad := concat_ws(', ', v_bad, format('%s.%s', v_row[1], v_row[2]));
    END IF;
  END LOOP;
  IF v_bad IS NOT NULL THEN
    RAISE WARNING 'prognosify/050: not an audit alert column: %. These writes will record '
                  'severity = ''normal'' and never reach audit.v_alerts (finding D3).', v_bad;
  END IF;
END
$alert_gate$;

-- 90.7 The tables this file touched must still each carry at least one policy: RLS with no
--      policy denies everything, which fails safe and also fails the product.
DO $policy_gap$
DECLARE
  v_tables CONSTANT text[] := ARRAY['patient','patient_condition','patient_allergy',
                                    'care_team_member','encounter','vital_sign','lab_order',
                                    'lab_result','clinical_note','medication_order','appointment',
                                    'document','ai_finding','payer','patient_coverage'];
  v_bad text;
BEGIN
  SELECT string_agg(t, ', ') INTO v_bad
    FROM unnest(v_tables) AS t
   WHERE NOT EXISTS (SELECT 1 FROM pg_policies p
                      WHERE p.schemaname = 'public' AND p.tablename = t);
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'Tables have RLS enabled but no policy: %', v_bad USING errcode = '42501';
  END IF;
END
$policy_gap$;

-- 90.8 040's lock: the audit trail must still have no UPDATE or DELETE policy.
DO $audit_lock$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(policyname, ', ') INTO v_bad
    FROM pg_policies
   WHERE schemaname = 'audit' AND tablename = 'event' AND cmd IN ('UPDATE', 'DELETE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'audit.event has mutation policies (%) — it is meant to be append-only.',
                    v_bad USING errcode = '42501';
  END IF;
END
$audit_lock$;

DO $done$
BEGIN
  RAISE NOTICE 'prognosify/050: hardening applied — B1 A1 A3 A4 B2 B3 C1 C2 C3 C4 C4b C5b D1 D3 '
               'X-CT2. F1 is a DEPLOYMENT control: read the README section '
               '"Deployment prerequisites (security-critical)" before this database is exposed '
               'to any end-user traffic.';
END
$done$;


-- =============================================================================================
-- WHAT THIS FILE DELIBERATELY DOES NOT DO
--
-- 1. F1 (CRITICAL) — no SQL mitigation is attempted. `request.*` is an unreserved GUC class that
--    any role may set and no migration can reserve. See §13 and the README.
--
-- 2. The break-glass path stays open. A clinician may still add THEMSELVES to any care team in
--    their own hospital (020 §26), and app.ensure_attending_on_care_team() still grants a seat to
--    a colleague named as attending. Both are argued clinical needs; both are now alerts rather
--    than silent (§12). They are accountability controls, not barriers, and 020 §26 should be
--    read that way.
--
-- 3. audit.event partitions still carry no RLS of their own (finding D2, THEORETICAL). Nothing
--    grants `authenticated` anything on a partition today, so the isolation of the trail rests on
--    that absence. Adding ENABLE/FORCE RLS inside audit.ensure_partitions() is the fix; it is
--    left out here because it changes a function 040 owns and schedules, and it deserves its own
--    migration with its own CI assertion that every audit.event_* partition carries
--    relrowsecurity AND relforcerowsecurity.
--
-- 4. Patient merge is still modelled, not implemented (010 open question 2). §3 restricts
--    status / merged_into_patient_id to hospital_admin; the operation itself belongs in an RPC
--    that decides what happens to the loser's clinical rows.
--
-- 5. Reception's real reach is documented, not narrowed. care_team_select and invoice_line_select
--    stay as they are — both are load-bearing for real front-desk screens. Only doc_type =
--    'other' was withdrawn (§8); the rest of finding B2 is a documentation defect and is fixed in
--    the README, not here.
-- =============================================================================================
