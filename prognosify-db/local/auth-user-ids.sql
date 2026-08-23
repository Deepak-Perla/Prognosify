-- ─────────────────────────────────────────────────────────────────────────────
--  Supabase auth user IDs for the three test logins.
--
--  These come from Authentication → Users in the Prognosify Supabase project
--  (ref: rcwjxzhwzvdluwohnloh, region ap-south-1).
--
--  These are IDENTIFIERS, not secrets — but they are specific to this one
--  Supabase project, so anyone running this schema elsewhere must substitute
--  their own. No passwords are stored here, and none should ever be added.
--
--  Run this AFTER the migrations and seed.sql, to attach each login to a
--  hospital and a role. Until that link exists, signing in succeeds but every
--  screen comes back empty — Row Level Security correctly shows nothing to a
--  user with no organisation. That is working as intended, not a bug.
-- ─────────────────────────────────────────────────────────────────────────────

-- Convenience handles used by the linking statements below.
-- (The final column/table names are filled in once the schema is assembled;
--  this file holds the IDs so nothing is lost in the meantime.)

create temporary table if not exists _test_logins (
  email        text primary key,
  auth_user_id uuid not null,
  intended_role text not null
);

insert into _test_logins (email, auth_user_id, intended_role) values
  ('doctor@clinic.com',       '71b879c2-d260-46dd-9876-824c0b60bbfe', 'doctor'),
  ('patient@gmail.com',       '3ee4483d-a21a-4511-afa4-f220fb4759cb', 'patient'),
  ('receptionist@clinic.com', '83d01655-0329-4c8c-8e82-f80a7e4b6fec', 'receptionist')
on conflict (email) do update
  set auth_user_id  = excluded.auth_user_id,
      intended_role = excluded.intended_role;

-- All three belong to the FIRST seeded hospital. The second seeded hospital is
-- deliberately left with no linked login: it exists so that isolation can be
-- tested — the doctor above must never be able to read its patients.
