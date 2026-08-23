-- =============================================================================================
-- demo-cast.sql — extra staff and patients for St. Luke's
--
-- Run AFTER seed.sql. Idempotent: fixed uuids + ON CONFLICT DO NOTHING + existence guards, so
-- re-running changes nothing.
--
-- WHAT IT ADDS
--   4 doctors — their logins must ALREADY exist in Authentication → Users (Auto Confirm):
--     dr.iyer@clinic.com        Dr. Rajesh Iyer        Cardiology      Clinic 1
--     dr.thomas@clinic.com      Dr. Sarah Thomas       Gen. medicine   Clinic 3
--     dr.deshpande@clinic.com   Dr. Vikram Deshpande   Pediatrics      Clinic 4
--     dr.kulkarni@clinic.com    Dr. Neha Kulkarni      Radiology       Imaging
--   22 patients (St. Luke's total becomes 35), each with one encounter and a primary condition,
--   spread across the five attendings so every doctor login has a panel to open.
--
-- PREREQUISITE: the four doctor emails above must exist in auth.users BEFORE running this file;
-- §1 stops with an explicit message if any is missing.
-- =============================================================================================

DO $preflight$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(e, ', ') INTO v_missing
    FROM unnest(ARRAY[
      'dr.iyer@clinic.com',
      'dr.thomas@clinic.com',
      'dr.deshpande@clinic.com',
      'dr.kulkarni@clinic.com'
    ]) AS e
   WHERE NOT EXISTS (SELECT 1 FROM auth.users u WHERE lower(u.email) = e);

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'No Supabase auth user for: %. Create them first (Authentication → Users → '
                    'Add user → Auto Confirm User), then re-run this file.', v_missing
      USING errcode = '23503';
  END IF;
END
$preflight$;


-- ---------------------------------------------------------------------------------------------
-- §1 THE FOUR DOCTOR SEATS
--
-- app_user.auth_user_id is NOT NULL with an FK to auth.users: this schema binds every staff
-- member to a real GoTrue identity, so there is no such thing as a directory-only seat here.
-- Emails are resolved by lookup, the same way seed.sql §1 resolves its logins.
-- ---------------------------------------------------------------------------------------------

INSERT INTO public.app_user (id, auth_user_id, email, full_name, status, active_organization_id)
SELECT v.id, u.id, lower(u.email), v.full_name,
       'active'::app.user_status,
       '11111111-1111-4111-a111-111111111111'::uuid
  FROM (VALUES
    ('dr.iyer@clinic.com',      'Dr. Rajesh Iyer',      '10000000-0000-4000-a000-000000000004'::uuid),
    ('dr.thomas@clinic.com',    'Dr. Sarah Thomas',     '10000000-0000-4000-a000-000000000005'::uuid),
    ('dr.deshpande@clinic.com', 'Dr. Vikram Deshpande', '10000000-0000-4000-a000-000000000006'::uuid),
    ('dr.kulkarni@clinic.com',  'Dr. Neha Kulkarni',    '10000000-0000-4000-a000-000000000007'::uuid)
  ) AS v(email, full_name, id)
  JOIN auth.users u ON lower(u.email) = v.email
  -- Email is unique on app_user too; skip when this file ran before.
  WHERE NOT EXISTS (SELECT 1 FROM public.app_user a WHERE a.id = v.id)
ON CONFLICT DO NOTHING;

INSERT INTO public.organization_member
       (id, organization_id, app_user_id, auth_user_id, roles, status, job_title, license_number)
SELECT v.id,
       '11111111-1111-4111-a111-111111111111',
       a.id, a.auth_user_id,
       ARRAY['doctor']::app.org_role[],
       'active'::app.member_status,
       v.title, v.license
  FROM (VALUES
    ('dr.iyer@clinic.com',      'Consultant cardiologist',  'MCI-2014-51823',
     '20000000-0000-4000-a000-000000000011'::uuid),
    ('dr.thomas@clinic.com',    'Consultant physician',     'MCI-2016-60214',
     '20000000-0000-4000-a000-000000000012'::uuid),
    ('dr.deshpande@clinic.com', 'Consultant paediatrician', 'MCI-2018-77341',
     '20000000-0000-4000-a000-000000000013'::uuid),
    ('dr.kulkarni@clinic.com',  'Consultant radiologist',   'MCI-2015-44902',
     '20000000-0000-4000-a000-000000000014'::uuid)
  ) AS v(email, title, license, id)
  JOIN public.app_user a ON lower(a.email) = v.email
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.staff_profile (member_id, organization_id, department_id, specialty,
                                  default_room, accepts_bookings)
SELECT m.id, m.organization_id, d.id, v.specialty, v.room, true
  FROM (VALUES
    ('20000000-0000-4000-a000-000000000011'::uuid, 'cardiology',       'Cardiology',         'Clinic 1'),
    ('20000000-0000-4000-a000-000000000012'::uuid, 'general_medicine', 'Internal medicine',  'Clinic 3'),
    ('20000000-0000-4000-a000-000000000013'::uuid, 'pediatrics',       'Paediatrics',        'Clinic 4'),
    ('20000000-0000-4000-a000-000000000014'::uuid, 'radiology',        'Imaging',            'Imaging')
  ) AS v(member_id, dept, specialty, room)
  JOIN public.organization_member m ON m.id = v.member_id
  JOIN public.department d
    ON d.organization_id = m.organization_id AND d.code = v.dept
ON CONFLICT (member_id) DO NOTHING;


-- ---------------------------------------------------------------------------------------------
-- §2 TWENTY-TWO NEW PATIENTS (30… rows 20–41; St. Luke's total becomes 35)
--
-- MRNs are from a fresh 2xx series that cannot collide with seed.sql's 1xx allocations.
-- created_by points at the receptionist's app_user, as if she registered them at the desk.
-- ---------------------------------------------------------------------------------------------

INSERT INTO public.patient (id, organization_id, mrn, first_name, last_name, date_of_birth, sex,
                            phone, status, created_by)
SELECT v.id, '11111111-1111-4111-a111-111111111111', v.mrn, v.first_name, v.last_name,
       v.dob, v.sex::app.sex, v.phone, 'active'::app.patient_status,
       '10000000-0000-4000-a000-000000000002'
  FROM (VALUES
    ('30000000-0000-4000-a000-000000000020'::uuid, '201-104', 'Aarav',   'Sharma',   DATE '1982-03-14', 'male',   '+91 98200 11001'),
    ('30000000-0000-4000-a000-000000000021', '202-318', 'Kavya',   'Menon',    DATE '1975-11-02', 'female', '+91 98200 11002'),
    ('30000000-0000-4000-a000-000000000022', '203-442', 'Rohit',   'Verma',    DATE '1968-06-27', 'male',   '+91 98200 11003'),
    ('30000000-0000-4000-a000-000000000023', '204-517', 'Sneha',   'Patil',    DATE '1990-01-19', 'female', '+91 98200 11004'),
    ('30000000-0000-4000-a000-000000000024', '205-633', 'Arjun',   'Nair',     DATE '1959-09-08', 'male',   '+91 98200 11005'),
    ('30000000-0000-4000-a000-000000000025', '206-748', 'Meera',   'Iyengar',  DATE '1971-04-23', 'female', '+91 98200 11006'),
    ('30000000-0000-4000-a000-000000000026', '207-859', 'Farhan',  'Sheikh',   DATE '1986-12-05', 'male',   '+91 98200 11007'),
    ('30000000-0000-4000-a000-000000000027', '208-964', 'Lakshmi', 'Rao',      DATE '1954-07-30', 'female', '+91 98200 11008'),
    ('30000000-0000-4000-a000-000000000028', '209-175', 'Devika',  'Joshi',    DATE '1995-02-11', 'female', '+91 98200 11009'),
    ('30000000-0000-4000-a000-000000000029', '210-286', 'Imran',   'Qureshi',  DATE '1978-08-16', 'male',   '+91 98200 11010'),
    ('30000000-0000-4000-a000-000000000030', '211-397', 'Tanvi',   'Deshmukh', DATE '1989-05-21', 'female', '+91 98200 11011'),
    ('30000000-0000-4000-a000-000000000031', '212-508', 'Harish',  'Gowda',    DATE '1963-10-09', 'male',   '+91 98200 11012'),
    ('30000000-0000-4000-a000-000000000032', '213-619', 'Nandini', 'Bhat',     DATE '1980-02-28', 'female', '+91 98200 11013'),
    ('30000000-0000-4000-a000-000000000033', '214-720', 'Aditya',  'Reddy',    DATE '1973-12-17', 'male',   '+91 98200 11014'),
    ('30000000-0000-4000-a000-000000000034', '215-831', 'Ritika',  'Chopra',   DATE '1993-03-06', 'female', '+91 98200 11015'),
    ('30000000-0000-4000-a000-000000000035', '216-942', 'Sanjay',  'Pillai',   DATE '1956-05-25', 'male',   '+91 98200 11016'),
    ('30000000-0000-4000-a000-000000000036', '217-153', 'Ananya',  'Krishnan', DATE '2016-09-12', 'female', '+91 98200 11017'),
    ('30000000-0000-4000-a000-000000000037', '218-264', 'Vihaan',  'Sinha',    DATE '2019-01-31', 'male',   '+91 98200 11018'),
    ('30000000-0000-4000-a000-000000000038', '219-375', 'Pooja',   'Naik',     DATE '1984-07-07', 'female', '+91 98200 11019'),
    ('30000000-0000-4000-a000-000000000039', '220-486', 'Sameer',  'Fakhri',   DATE '1966-11-29', 'male',   '+91 98200 11020'),
    ('30000000-0000-4000-a000-000000000040', '221-597', 'Divya',   'Kamath',   DATE '1991-06-18', 'female', '+91 98200 11021'),
    ('30000000-0000-4000-a000-000000000041', '222-608', 'Manoj',   'Tiwari',   DATE '1952-04-04', 'male',   '+91 98200 11022')
  ) AS v(id, mrn, first_name, last_name, dob, sex, phone)
ON CONFLICT (id) DO NOTHING;

-- One encounter per visit. Attending auto-adds the doctor to the care team (020's
-- ensure_attending_on_care_team trigger), which is what makes each chart visible to its
-- doctor under RLS. Discharged visits carry ended_at (encounter_closed_ck requires it).
-- Patient …039 deliberately appears twice: once under Dr. Thomas, once under Dr. Kulkarni —
-- two doctors, two visits, which is ordinary outpatients.
INSERT INTO public.encounter (id, organization_id, patient_id, class, status, department_id,
                              attending_member_id, room_label, reason, started_at, ended_at,
                              created_by)
SELECT v.id,
       '11111111-1111-4111-a111-111111111111',
       v.patient_id::uuid,
       v.class::app.encounter_class,
       v.status::app.encounter_status,
       d.id,
       v.attending,
       v.room,
       v.reason,
       ((current_date - v.days_ago + time '10:00') AT TIME ZONE 'Asia/Kolkata'),
       CASE WHEN v.status = 'discharged'
            THEN ((current_date - v.days_ago + (time '10:00' + interval '30 minutes'))
                  AT TIME ZONE 'Asia/Kolkata')
       END,
       v.attending
  FROM (VALUES
    -- Dr. Mehta: 10 more outpatients + 2 inpatients
    ('40000000-0000-4000-a000-000000000021'::uuid, '30000000-0000-4000-a000-000000000020', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001'::uuid, 'Clinic 2', 'Chest pain, atypical',           38),
    ('40000000-0000-4000-a000-000000000022', '30000000-0000-4000-a000-000000000021', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'Palpitations, Holter advised',   26),
    ('40000000-0000-4000-a000-000000000023', '30000000-0000-4000-a000-000000000022', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 3', 'Type 2 diabetes review',         19),
    ('40000000-0000-4000-a000-000000000024', '30000000-0000-4000-a000-000000000023', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 3', 'Hypertension follow-up',          9),
    ('40000000-0000-4000-a000-000000000025', '30000000-0000-4000-a000-000000000024', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 3', 'Dyslipidaemia, statin review',   33),
    ('40000000-0000-4000-a000-000000000026', '30000000-0000-4000-a000-000000000025', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'AF rate control check',          14),
    ('40000000-0000-4000-a000-000000000027', '30000000-0000-4000-a000-000000000026', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 3', 'Hypothyroid review',              6),
    ('40000000-0000-4000-a000-000000000028', '30000000-0000-4000-a000-000000000027', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'Post-MI review, month 3',        41),
    ('40000000-0000-4000-a000-000000000029', '30000000-0000-4000-a000-000000000028', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Clinic 3', 'Anaemia work-up',                 3),
    ('40000000-0000-4000-a000-000000000030', '30000000-0000-4000-a000-000000000029', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Clinic 2', 'Echo follow-up',                  8),
    ('40000000-0000-4000-a000-000000000031', '30000000-0000-4000-a000-000000000030', 'inpatient', 'in_progress', 'general_medicine',
     '20000000-0000-4000-a000-000000000001', 'Rm 418', 'Cellulitis, IV antibiotics',       2),
    ('40000000-0000-4000-a000-000000000032', '30000000-0000-4000-a000-000000000031', 'inpatient', 'in_progress', 'cardiology',
     '20000000-0000-4000-a000-000000000001', 'Rm 421', 'Unstable angina, monitor',         1),

    -- Dr. Iyer (cardiology): 3 outpatients
    ('40000000-0000-4000-a000-000000000033', '30000000-0000-4000-a000-000000000032', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000011', 'Clinic 1', 'Valve surveillance',             22),
    ('40000000-0000-4000-a000-000000000034', '30000000-0000-4000-a000-000000000033', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000011', 'Clinic 1', 'Cardiac risk assessment',       15),
    ('40000000-0000-4000-a000-000000000035', '30000000-0000-4000-a000-000000000034', 'outpatient', 'discharged', 'cardiology',
     '20000000-0000-4000-a000-000000000011', 'Clinic 1', 'BP optimisation',                 5),

    -- Dr. Thomas (gen. medicine): 3 outpatients
    ('40000000-0000-4000-a000-000000000036', '30000000-0000-4000-a000-000000000035', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000012', 'Clinic 3', 'Osteoarthritis, knee',           28),
    ('40000000-0000-4000-a000-000000000037', '30000000-0000-4000-a000-000000000038', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000012', 'Clinic 3', 'GERD review',                    12),
    ('40000000-0000-4000-a000-000000000038', '30000000-0000-4000-a000-000000000039', 'outpatient', 'discharged', 'general_medicine',
     '20000000-0000-4000-a000-000000000012', 'Clinic 3', 'CKD stage 2 monitoring',          4),

    -- Dr. Deshpande (paediatrics): 2 outpatients
    ('40000000-0000-4000-a000-000000000039', '30000000-0000-4000-a000-000000000036', 'outpatient', 'discharged', 'pediatrics',
     '20000000-0000-4000-a000-000000000013', 'Clinic 4', 'Recurrent tonsillitis',           7),
    ('40000000-0000-4000-a000-000000000040', '30000000-0000-4000-a000-000000000037', 'outpatient', 'discharged', 'pediatrics',
     '20000000-0000-4000-a000-000000000013', 'Clinic 4', 'Asthma review, child',           18),

    -- Dr. Kulkarni (radiology): 2 imaging follow-ups
    ('40000000-0000-4000-a000-000000000041', '30000000-0000-4000-a000-000000000040', 'outpatient', 'discharged', 'radiology',
     '20000000-0000-4000-a000-000000000014', 'Imaging', 'CT abdomen follow-up',            10),
    ('40000000-0000-4000-a000-000000000042', '30000000-0000-4000-a000-000000000039', 'outpatient', 'discharged', 'radiology',
     '20000000-0000-4000-a000-000000000014', 'Imaging', 'Ultrasound guidance review',     20)
  ) AS v(id, patient_id, class, status, dept, attending, room, reason, days_ago)
  JOIN public.department d
    ON d.organization_id = '11111111-1111-4111-a111-111111111111' AND d.code = v.dept
ON CONFLICT (id) DO NOTHING;

-- Primary condition per patient, recorded by the doctor who saw them. The join picks the
-- encounter by BOTH patient and attending, because patient …039 legitimately has two.
INSERT INTO public.patient_condition (id, organization_id, patient_id, name, clinical_status,
                                      is_primary, onset_date, recorded_by)
SELECT v.id,
       '11111111-1111-4111-a111-111111111111',
       v.patient_id::uuid,
       v.name,
       'active'::app.condition_status,
       -- Exactly one ACTIVE PRIMARY per patient (patient_condition_primary_uk). Patient …039
       -- carries two findings here; only the CKD rides as primary, the renal cyst follows it.
       (v.id <> 'b0000000-0000-4000-a000-000000000064'::uuid),
       current_date - v.onset_days,
       e.attending_member_id
  FROM (VALUES
    ('b0000000-0000-4000-a000-000000000043'::uuid, '30000000-0000-4000-a000-000000000020', 'Non-cardiac chest pain',            800),
    ('b0000000-0000-4000-a000-000000000044', '30000000-0000-4000-a000-000000000021', 'Paroxysmal atrial fibrillation',    700),
    ('b0000000-0000-4000-a000-000000000045', '30000000-0000-4000-a000-000000000022', 'Type 2 diabetes',                  2400),
    ('b0000000-0000-4000-a000-000000000046', '30000000-0000-4000-a000-000000000023', 'Essential hypertension',           1300),
    ('b0000000-0000-4000-a000-000000000047', '30000000-0000-4000-a000-000000000024', 'Dyslipidaemia',                    1500),
    ('b0000000-0000-4000-a000-000000000048', '30000000-0000-4000-a000-000000000025', 'Atrial fibrillation',               900),
    ('b0000000-0000-4000-a000-000000000049', '30000000-0000-4000-a000-000000000026', 'Hypothyroidism',                   1100),
    ('b0000000-0000-4000-a000-000000000050', '30000000-0000-4000-a000-000000000027', 'Ischaemic heart disease',          1200),
    ('b0000000-0000-4000-a000-000000000051', '30000000-0000-4000-a000-000000000028', 'Iron-deficiency anaemia',           180),
    ('b0000000-0000-4000-a000-000000000052', '30000000-0000-4000-a000-000000000029', 'Mitral valve prolapse',            2000),
    ('b0000000-0000-4000-a000-000000000053', '30000000-0000-4000-a000-000000000030', 'Cellulitis, right leg',              14),
    ('b0000000-0000-4000-a000-000000000054', '30000000-0000-4000-a000-000000000031', 'Unstable angina',                     7),
    ('b0000000-0000-4000-a000-000000000055', '30000000-0000-4000-a000-000000000032', 'Aortic stenosis, mild',            2600),
    ('b0000000-0000-4000-a000-000000000056', '30000000-0000-4000-a000-000000000033', 'Dyslipidaemia',                    1000),
    ('b0000000-0000-4000-a000-000000000057', '30000000-0000-4000-a000-000000000034', 'Essential hypertension',            500),
    ('b0000000-0000-4000-a000-000000000058', '30000000-0000-4000-a000-000000000035', 'Osteoarthritis, knee',             1900),
    ('b0000000-0000-4000-a000-000000000059', '30000000-0000-4000-a000-000000000038', 'Gastro-oesophageal reflux',         600),
    ('b0000000-0000-4000-a000-000000000060', '30000000-0000-4000-a000-000000000039', 'Chronic kidney disease stage 2',    900),
    ('b0000000-0000-4000-a000-000000000061', '30000000-0000-4000-a000-000000000036', 'Recurrent tonsillitis',             300),
    ('b0000000-0000-4000-a000-000000000062', '30000000-0000-4000-a000-000000000037', 'Childhood asthma',                  500),
    ('b0000000-0000-4000-a000-000000000063', '30000000-0000-4000-a000-000000000040', 'Colonic polyp surveillance',        400),
    ('b0000000-0000-4000-a000-000000000064', '30000000-0000-4000-a000-000000000039', 'Renal cyst',                        350)
  ) AS v(id, patient_id, name, onset_days)
  JOIN public.encounter e
    ON e.organization_id = '11111111-1111-4111-a111-111111111111'
   AND e.patient_id = v.patient_id::uuid
   -- Patient …039 has TWO encounters (one under Dr. Thomas, one under Dr. Kulkarni); every
   -- other new patient has exactly one. This picks the right one for the two ambiguous rows:
   AND (v.id NOT IN ('b0000000-0000-4000-a000-000000000060'::uuid,
                     'b0000000-0000-4000-a000-000000000064'::uuid)
        OR e.attending_member_id =
             CASE WHEN v.id = 'b0000000-0000-4000-a000-000000000060'::uuid
                  THEN '20000000-0000-4000-a000-000000000012'::uuid  -- Dr. Thomas
                  ELSE '20000000-0000-4000-a000-000000000014'::uuid  -- Dr. Kulkarni
             END)
ON CONFLICT (id) DO NOTHING;


-- ---------------------------------------------------------------------------------------------
-- §3 HOW TO ADD MORE PATIENTS LATER
--
-- Two ways, both real:
--   1. Reception portal → Register — inserts a live patient and allocates the MRN itself.
--   2. Copy a triple below for seed-style bulk additions. Keep the id prefixes on-series
--      (30… patient / 40… encounter / b0… condition) and pick fresh MRNs.
--
-- TEMPLATE (fill the four <...> spots, paste after this line):
-- INSERT INTO public.patient (id, organization_id, mrn, first_name, last_name, date_of_birth,
--                             sex, phone, status)
-- VALUES ('30000000-0000-4000-a000-<000000000042>'::uuid, '11111111-1111-4111-a111-111111111111',
--         '<NNN-NNN>', '<First>', '<Last>', DATE '<YYYY-MM-DD>', '<male|female|other>', NULL,
--         'active') ON CONFLICT (id) DO NOTHING;
--
-- INSERT INTO public.encounter (id, organization_id, patient_id, class, status, department_id,
--                               attending_member_id, room_label, reason, started_at, ended_at,
--                               created_by)
-- VALUES ('40000000-0000-4000-a000-<000000000043>'::uuid,
--         '11111111-1111-4111-a111-111111111111',
--         '30000000-0000-4000-a000-<000000000042>', 'outpatient', 'discharged',
--         (SELECT id FROM public.department WHERE code = 'general_medicine'
--            AND organization_id = '11111111-1111-4111-a111-111111111111'),
--         '<member uuid, e.g. 20000000-...-0001 for Dr. Mehta>', 'Clinic 3', '<Reason>',
--         now() - interval '10 days', now() - interval '10 days' + interval '30 minutes',
--         '<same member uuid>') ON CONFLICT (id) DO NOTHING;
--
-- INSERT INTO public.patient_condition (id, organization_id, patient_id, name, clinical_status,
--                                       is_primary, onset_date, recorded_by)
-- VALUES ('b0000000-0000-4000-a000-<000000000065>'::uuid,
--         '11111111-1111-4111-a111-111111111111',
--         '30000000-0000-4000-a000-<000000000042>', '<Condition>', 'active', true,
--         current_date - 365, '<same member uuid>') ON CONFLICT (id) DO NOTHING;
-- ---------------------------------------------------------------------------------------------
