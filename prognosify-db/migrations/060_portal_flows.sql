-- =============================================================================================
-- 060_portal_flows.sql  — patient-portal messaging, care plan and self-service booking
--
-- Adds the last backing stores the portals need:
--   public.message          secure patient <-> care-team threads
--   public.care_goal        measurable goals behind the portal's progress bars
--   public.care_plan_task   the daily checklist on the portal's care-plan screen
--   v_portal_me             the signed-in patient's own chart identity (security_invoker)
--   v_portal_care_team      the humans looking after them (names for Messages)
--   app.portal_available_slots / app.portal_book_appointment
--                           patients cannot SELECT other people's appointments (by design),
--                           so availability is answered by a SECURITY DEFINER function that
--                           returns free slots without leaking anyone else's data, and
--                           booking goes through a definer INSERT guarded to patient seats.
--
-- Follows house style: composite FKs on (parent_id, organization_id), RLS everywhere,
-- no hard deletes, pinned search_path on DEFINER functions, idempotent throughout.
-- =============================================================================================

-- ---------------------------------------------------------------------------------------------
-- §1 MESSAGE
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.message (
    id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid              NOT NULL REFERENCES public.organization (id)
                                        ON UPDATE CASCADE ON DELETE RESTRICT,
    patient_id       uuid              NOT NULL,

    -- The staff author, when a human on the care team wrote it. NULL ⇔ the patient wrote it
    -- (enforced below), so "who said this" always has exactly one answer.
    sender_member_id uuid              NULL,

    sent_by_patient  boolean           NOT NULL DEFAULT false,
    body             text              NOT NULL,
    created_at       timestamptz       NOT NULL DEFAULT now(),
    read_at          timestamptz       NULL,

    CONSTRAINT message_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT message_body_ck CHECK (btrim(body) <> ''),
    CONSTRAINT message_sender_shape_ck CHECK (sent_by_patient = (sender_member_id IS NULL)),
    CONSTRAINT message_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT message_sender_fk
      FOREIGN KEY (sender_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS message_thread_ix
  ON public.message (organization_id, patient_id, created_at);

DROP TRIGGER IF EXISTS t_no_delete ON public.message;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.message
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

ALTER TABLE public.message ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS message_select ON public.message;
CREATE POLICY message_select ON public.message FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (patient_id = app.current_patient_id()
              OR (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))));

DROP POLICY IF EXISTS message_insert_staff ON public.message;
CREATE POLICY message_insert_staff ON public.message FOR INSERT
  WITH CHECK (organization_id = app.current_org_id()
              AND NOT sent_by_patient
              AND sender_member_id = app.current_member_id()
              AND app.is_clinician()
              AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS message_insert_patient ON public.message;
CREATE POLICY message_insert_patient ON public.message FOR INSERT
  WITH CHECK (organization_id = app.current_org_id()
              AND sent_by_patient
              AND sender_member_id IS NULL
              AND patient_id = app.current_patient_id());

-- Both sides may mark their thread read; nothing else about a delivered message may change.
DROP POLICY IF EXISTS message_update ON public.message;
CREATE POLICY message_update ON public.message FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND (patient_id = app.current_patient_id()
              OR (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))))
  WITH CHECK (organization_id = app.current_org_id());

DROP TRIGGER IF EXISTS t_message_read_only ON public.message;
CREATE TRIGGER t_message_read_only BEFORE UPDATE ON public.message
  FOR EACH ROW EXECUTE FUNCTION app.enforce_append_only('{read_at,updated_at}');

-- ---------------------------------------------------------------------------------------------
-- §2 CARE GOAL + CARE PLAN TASK
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.care_goal (
    id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid              NOT NULL REFERENCES public.organization (id)
                                        ON UPDATE CASCADE ON DELETE RESTRICT,
    patient_id       uuid              NOT NULL,
    label            text              NOT NULL,
    target_label     text              NULL,           -- "8.9 → 7.5", "4 of 5 this week"
    progress_pct     smallint          NOT NULL DEFAULT 0
                                       CHECK (progress_pct BETWEEN 0 AND 100),
    created_by       uuid              NOT NULL,
    created_at       timestamptz       NOT NULL DEFAULT now(),

    CONSTRAINT care_goal_label_ck CHECK (btrim(label) <> ''),
    CONSTRAINT care_goal_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT care_goal_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT care_goal_creator_fk
      FOREIGN KEY (created_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE TABLE IF NOT EXISTS public.care_plan_task (
    id               uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid              NOT NULL REFERENCES public.organization (id)
                                        ON UPDATE CASCADE ON DELETE RESTRICT,
    patient_id       uuid              NOT NULL,
    title            text              NOT NULL,
    detail           text              NULL,            -- "118 mg/dL", "any time today"
    schedule_text    text              NULL,            -- "with breakfast", "around 8 PM"
    daily            boolean           NOT NULL DEFAULT true,
    last_done_at     timestamptz       NULL,            -- today's completion marker
    sort_order       integer           NOT NULL DEFAULT 0,
    created_by       uuid              NOT NULL,
    created_at       timestamptz       NOT NULL DEFAULT now(),

    CONSTRAINT care_plan_task_title_ck CHECK (btrim(title) <> ''),
    CONSTRAINT care_plan_task_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT care_plan_task_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT care_plan_task_creator_fk
      FOREIGN KEY (created_by, organization_id)
      REFERENCES public.organization_member (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS care_plan_task_patient_ix
  ON public.care_plan_task (organization_id, patient_id, sort_order);

DO $guards$
BEGIN
  IF to_regprocedure('app.deny_hard_delete()') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS t_no_delete ON public.care_goal';
    EXECUTE 'CREATE TRIGGER t_no_delete BEFORE DELETE ON public.care_goal
               FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete()';
    EXECUTE 'DROP TRIGGER IF EXISTS t_no_delete ON public.care_plan_task';
    EXECUTE 'CREATE TRIGGER t_no_delete BEFORE DELETE ON public.care_plan_task
               FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete()';
  END IF;
END $guards$;

ALTER TABLE public.care_goal ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.care_plan_task ENABLE ROW LEVEL SECURITY;

-- Goals: the care team writes, the patient reads.
DROP POLICY IF EXISTS care_goal_select ON public.care_goal;
CREATE POLICY care_goal_select ON public.care_goal FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (patient_id = app.current_patient_id()
              OR (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))));

DROP POLICY IF EXISTS care_goal_write ON public.care_goal;
CREATE POLICY care_goal_write ON public.care_goal FOR ALL
  USING (organization_id = app.current_org_id()
         AND app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id()
              AND app.is_clinician() AND patient_id = ANY (app.care_patient_ids())
              AND created_by = app.current_member_id());

-- Tasks: both read; the patient may tick items off (last_done_at), the care team manages.
DROP POLICY IF EXISTS care_plan_task_select ON public.care_plan_task;
CREATE POLICY care_plan_task_select ON public.care_plan_task FOR SELECT
  USING (organization_id = app.current_org_id()
         AND (patient_id = app.current_patient_id()
              OR (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))));

DROP POLICY IF EXISTS care_plan_task_write_staff ON public.care_plan_task;
CREATE POLICY care_plan_task_write_staff ON public.care_plan_task FOR ALL
  USING (organization_id = app.current_org_id()
         AND app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id()
              AND app.is_clinician() AND patient_id = ANY (app.care_patient_ids()));

DROP POLICY IF EXISTS care_plan_task_update_patient ON public.care_plan_task;
CREATE POLICY care_plan_task_update_patient ON public.care_plan_task FOR UPDATE
  USING (organization_id = app.current_org_id() AND patient_id = app.current_patient_id())
  WITH CHECK (organization_id = app.current_org_id() AND patient_id = app.current_patient_id());

-- The patient ticks items off; every other column is frozen for them.
DROP TRIGGER IF EXISTS t_task_patient_columns ON public.care_plan_task;
CREATE TRIGGER t_task_patient_columns BEFORE UPDATE ON public.care_plan_task
  FOR EACH ROW EXECUTE FUNCTION app.enforce_patient_writable_columns('{last_done_at,updated_at}');

-- ---------------------------------------------------------------------------------------------
-- §3 PORTAL IDENTITY + CARE-TEAM VIEWS
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_portal_me
WITH (security_invoker = true) AS
SELECT p.id   AS patient_id,
       p.mrn,
       p.first_name || ' ' || p.last_name AS full_name
  FROM public.patient p
 WHERE p.id = app.current_patient_id();

CREATE OR REPLACE VIEW public.v_portal_care_team
WITH (security_invoker = true) AS
SELECT ct.patient_id,
       m.id      AS member_id,
       au.full_name,
       ct.role::text AS role,
       ct.assignment_note,
       sp.specialty,
       sp.default_room
  FROM public.care_team_member ct
  JOIN public.organization_member m ON m.id = ct.member_id
  JOIN public.app_user au ON au.id = m.app_user_id
  LEFT JOIN public.staff_profile sp ON sp.member_id = m.id
 WHERE ct.ended_at IS NULL
   AND ct.patient_id = app.current_patient_id();

GRANT SELECT ON public.v_portal_me TO authenticated;
GRANT SELECT ON public.v_portal_care_team TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- §4 SELF-SERVICE BOOKING
--
-- Patients must not enumerate other patients' appointments (appointment_select denies it), so
-- availability comes from this definer function: fixed clinic times over working days minus
-- taken slots. It reveals WHEN a provider is free — never WHO else is booked.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.portal_available_slots(
    p_provider uuid,
    p_from     date DEFAULT current_date,
    p_days     int  DEFAULT 10)
RETURNS TABLE (slot_start timestamptz, slot_end timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  WITH RECURSIVE day(n) AS (
    SELECT 0 UNION ALL SELECT n + 1 FROM day WHERE n < p_days - 1),
  slots AS (
    SELECT ((p_from + day.n)::text || ' ' || t.slot::text) AS wall
      FROM day,
           LATERAL (VALUES ('09:00'::time), ('10:15'::time), ('11:30'::time),
                            ('14:00'::time), ('16:15'::time)) t(slot)
     WHERE extract(dow FROM p_from + day.n) <> 0)          -- Sundays closed
  SELECT (s.wall || '+05:30')::timestamptz                    AS slot_start,
         (s.wall || '+05:30')::timestamptz + interval '30 minutes' AS slot_end
    FROM slots s
   WHERE (s.wall || '+05:30')::timestamptz > now()
     AND NOT EXISTS (SELECT 1
                       FROM public.appointment a
                      WHERE a.provider_member_id = p_provider
                        AND a.status <> 'cancelled'
                        AND a.scheduled_start < (s.wall || '+05:30')::timestamptz + interval '30 minutes'
                        AND a.scheduled_end   > (s.wall || '+05:30')::timestamptz)
   ORDER BY 1;
$$;

COMMENT ON FUNCTION app.portal_available_slots(uuid, date, int) IS
  'Free booking times for one provider. Reveals availability only — never who holds the '
  'taken slots. Patients reach this through PostgREST rpc(); they hold no SELECT on '
  'appointments that are not their own.';

CREATE OR REPLACE FUNCTION app.portal_book_appointment(
    p_provider   uuid,
    p_visit_type uuid,
    p_start      timestamptz)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_org     uuid := app.current_org_id();
  v_patient uuid := app.current_patient_id();
  v_minutes int;
  v_dept    uuid;
BEGIN
  IF v_patient IS NULL THEN
    RAISE EXCEPTION 'Booking is only available to a signed-in patient of this hospital.'
      USING errcode = '42501';
  END IF;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'No active organisation for this account.' USING errcode = '42501';
  END IF;

  SELECT coalesce(vt.default_duration_minutes, 30) INTO v_minutes
    FROM public.visit_type vt WHERE vt.id = p_visit_type AND vt.organization_id = v_org;
  IF v_minutes IS NULL THEN
    RAISE EXCEPTION 'Unknown visit type.' USING errcode = '23503';
  END IF;

  SELECT sp.department_id INTO v_dept
    FROM public.staff_profile sp WHERE sp.member_id = p_provider;

  -- Slot still free? (the grid can go stale between render and confirm)
  IF EXISTS (SELECT 1 FROM public.appointment a
              WHERE a.provider_member_id = p_provider
                AND a.status <> 'cancelled'
                AND a.scheduled_start < p_start + make_interval(mins => v_minutes)
                AND a.scheduled_end   > p_start)
     OR EXISTS (SELECT 1 FROM public.appointment a
                 WHERE a.patient_id = v_patient
                   AND a.status IN ('booked', 'waiting', 'in_room')
                   AND a.scheduled_start < p_start + make_interval(mins => v_minutes)
                   AND a.scheduled_end   > p_start) THEN
    RAISE EXCEPTION 'That slot was just taken — pick another time.'
      USING errcode = '23P01';
  END IF;

  DECLARE
    v_id uuid;
  BEGIN
    INSERT INTO public.appointment (organization_id, patient_id, provider_member_id,
                                    department_id, visit_type_id, modality, origin, status,
                                    scheduled_start, scheduled_end, created_by)
    VALUES (v_org, v_patient, p_provider, v_dept, p_visit_type, 'in_person', 'scheduled',
            'booked', p_start, p_start + make_interval(mins => v_minutes), p_provider)
    RETURNING id INTO v_id;
    RETURN v_id;
  END;
END;
$$;

COMMENT ON FUNCTION app.portal_book_appointment(uuid, uuid, timestamptz) IS
  'The portal Confirm button. Definer INSERT so a patient can create their own appointment '
  'without holding appointment_INSERT (which belongs to the desk and clinicians only); the '
  'body refuses any caller without a patient seat and re-checks collisions server-side.';

GRANT EXECUTE ON FUNCTION app.portal_available_slots(uuid, date, int) TO authenticated;
GRANT EXECUTE ON FUNCTION app.portal_book_appointment(uuid, uuid, timestamptz) TO authenticated;

-- ---------------------------------------------------------------------------------------------
-- §5 AUDIT COVERAGE for the new tables (same convention as 040/050)
-- ---------------------------------------------------------------------------------------------
DO $attach$
BEGIN
  IF to_regprocedure('audit.attach(text,text,text[])') IS NOT NULL THEN
    PERFORM audit.attach('public', 'message',        ARRAY['body']);
    PERFORM audit.attach('public', 'care_goal',      ARRAY['progress_pct']);
    PERFORM audit.attach('public', 'care_plan_task', ARRAY['last_done_at']);
  ELSE
    RAISE NOTICE 'prognosify/060: audit.attach unavailable — audit triggers not attached.';
  END IF;
END
$attach$;
