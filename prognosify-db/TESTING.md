# Proving isolation

Copy-pasteable SQL for the Supabase SQL Editor (or `psql`). Every block is self-contained and
wrapped in `begin … rollback`, so nothing you run here changes the database.

Run these **after** `000 → 010 → 020 → 030 → 040` and `seed.sql`.

---

## 0. How the impersonation works

Three separate mechanisms have to line up, and understanding which one does what is the whole
point of this file.

**1. `set local role authenticated` — this is what turns RLS on for you.**
The SQL Editor connects as `postgres`, which **owns** every table. A table owner is not subject
to its own row-level security unless the table is declared `force row level security` (only
`audit.event` is). So if you test policies as `postgres` you will see everything and conclude
the model works. Switching to `authenticated` — the role PostgREST uses for a signed-in browser
request — is what makes the policies apply at all.

**2. `request.jwt.claims` — this is what tells the database *who* you are.**
In production Supabase's PostgREST verifies the JWT signature and sets this GUC from the verified
payload. `app.current_auth_uid()` reads it (rebound to `auth.uid()` on Supabase, which reads the
same setting). Setting it by hand is exactly what PostgREST does, minus the signature check —
which is why you must be `postgres` to set it, and why a browser can never forge it.

**3. Everything else is read from tables, on every statement.**
The claim carries *identity* only. Which hospital you are acting in, which roles you hold and
whether your seat is still active are resolved from `organization_member` by
`app.current_org_id()` / `app.current_roles()` each time. That is deliberate (010 §8.2): a
revoked seat or a suspended tenant stops working on the next statement instead of when the token
expires. It also means these tests exercise the real path, not a shortcut.

`set local` scopes all of it to the transaction, so `rollback` restores your own session.

### One mechanical note about the blocks that expect errors

In PostgreSQL a failed statement aborts the whole transaction: everything after it returns
`current transaction is aborted, commands ignored until end of transaction block`. Sections 4, 7
and 8 below expect *several* errors in a row, so each expected failure is wrapped in a savepoint:

```sql
savepoint s;  <the statement that must fail>  rollback to savepoint s;
```

That contains the abort to the savepoint and leaves the session usable for the next case. Keep the
savepoints if you paste a whole block; drop them if you run one statement at a time.

### The helper you will paste at the top of every block

```sql
-- Impersonate a seeded login. Run these two lines BEFORE `set local role`, while you are still
-- postgres — after the role switch, reading app_user is itself subject to RLS.
select set_config(
         'request.jwt.claims',
         json_build_object(
           'sub',  (select auth_user_id from public.app_user where email = 'patient@gmail.com'),
           'role', 'authenticated')::text,
         true) as claims_set;

select set_config(
         'request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'patient@gmail.com'),
         true) as sub_set;   -- older Supabase auth.uid() reads this one

set local role authenticated;
```

Swap the email for `doctor@clinic.com` or `receptionist@clinic.com` to change persona.

### Sanity check first — is the session actually who you think?

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'doctor@clinic.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'doctor@clinic.com'), true);
set local role authenticated;

select current_user                    as db_role,
       app.current_auth_uid()          as auth_uid,
       app.current_user_id()           as app_user_id,
       app.current_org_id()            as org_id,
       app.current_member_id()         as member_id,
       app.current_roles()             as roles,
       app.is_clinician()              as is_clinician,
       app.current_patient_id()        as own_chart,
       cardinality(app.care_patient_ids()) as patients_on_my_care_team;
rollback;
```

Expect `db_role = authenticated`, a non-null `org_id`, `roles = {doctor}`, `is_clinician = t`,
`own_chart` null, and 7 patients on the care team.

**If `org_id` comes back null, stop and fix that first.** Every policy in the database begins
with `organization_id = app.current_org_id()`, and `x = NULL` is never true — so a null org means
every query returns zero rows and every test below "passes" for the wrong reason. Causes, in
order of likelihood: the login is not linked to an `organization_member` row; the seat's status
is not `active`; the tenant's status is not `trial`/`active`; the person holds seats in two
hospitals and has not chosen one (`select app.set_active_organization('…')`).

---

## 1. The ground truth (as `postgres`, no RLS)

Establish that there really is something to leak. Every test after this is meaningless without it.

```sql
select o.slug, count(p.*) as patients
  from public.organization o
  left join public.patient p on p.organization_id = o.id
 group by o.slug order by o.slug;
```

| slug | patients |
|---|---|
| `meridian-health` | 2 |
| `st-lukes` | 13 |

And the sharpest fixture in the seed — **the same MRN in two hospitals**:

```sql
select o.slug, p.mrn, p.first_name || ' ' || p.last_name as name
  from public.patient p join public.organization o on o.id = p.organization_id
 where p.mrn = '104-882' order by o.slug;
```

Two rows: Alice Fernandes at Meridian and Rosa Delgado at St. Luke's. This is legal *only*
because `patient_mrn_uk` is `unique (organization_id, upper(mrn))`. A global unique index would
have rejected the second registration — and the rejection itself would have told Meridian's front
desk that some other hospital already used that number, which is a cross-tenant disclosure with
no query and no policy involved.

---

## 2. A patient cannot see another hospital's patients

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'patient@gmail.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'patient@gmail.com'), true);
set local role authenticated;

-- (a) everything this session can see in public.patient
select mrn, first_name, last_name from public.patient order by mrn;
--> EXACTLY ONE ROW: 108-921 Priya Nair. Not the other 12 St. Luke's patients, and not Meridian's.

-- (b) named directly, by primary key — the id is right there in seed.sql, so this is not
--     security through obscurity
select * from public.patient where id = '30000000-0000-4000-a000-000000000051';
--> 0 rows (Alice Fernandes, Meridian)

-- (c) the same MRN as her own hospital's Rosa Delgado
select * from public.patient where mrn = '104-882';
--> 0 rows

-- (d) counts, which is how a leak usually shows up first
select count(*) as visible_patients from public.patient;
--> 1
rollback;
```

The mechanism: `patient_select` is
`organization_id = app.current_org_id() and (app.is_clinician() or app.is_front_desk() or id = app.current_patient_id())`.
Priya's org matches, but she is neither clinician nor front desk, so the only row that survives is
her own chart. Meridian fails at the first conjunct and would fail there for **every** role,
including a doctor, an admin, or the vendor.

---

## 3. A patient cannot see another patient's labs

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'patient@gmail.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'patient@gmail.com'), true);
set local role authenticated;

-- (a) her own released results — 4 rows (HbA1c, fasting glucose, LDL, eGFR)
select t.name, r.value_numeric, r.unit, r.abnormal_flag, r.released_to_patient_at
  from public.lab_result r join public.lab_test t on t.id = r.lab_test_id
 order by t.name;

-- (b) Rosa Delgado's critical lactate, named by primary key
select * from public.lab_result where id = '80000000-0000-4000-a000-000000000001';
--> 0 rows

-- (c) anything at all belonging to another patient
select count(*) as other_patients_results
  from public.lab_result
 where patient_id <> app.current_patient_id();
--> 0

-- (d) the wider chart: vitals, notes, medications, risk scores
select (select count(*) from public.vital_sign)      as vitals,
       (select count(*) from public.clinical_note)   as notes,
       (select count(*) from public.medication_order) as meds,
       (select count(*) from public.ai_risk_score)   as risk_scores,
       (select count(*) from public.lab_order)       as lab_orders;
--> vitals 0 · notes 0 · meds 1 (her Metformin) · risk_scores 0 · lab_orders 0
rollback;
```

Three separate decisions show up in that last row, and each is argued in the migration that made
it:

- **notes 0** — `clinical_note` is the one clinical table a patient cannot read at all, because a
  note routinely carries third-party information and provisional reasoning (020 §33.3). Access
  requests are served through a mediated export, not a policy line.
- **risk_scores 0** — "sepsis 92%" arriving unmediated on a phone is the failure mode the portal's
  design exists to prevent. What a patient gets is a *reviewed* plain-language finding:

  ```sql
  select title, left(detail, 60) || '…' as detail, review_state, patient_visible
    from public.ai_finding;
  --> 1 row: "Your HbA1c is above your goal", accepted, true
  ```

  `ai_finding_patient_visible_ck` is what makes that safe: nothing can be `patient_visible`
  unless `review_state` is `accepted` or `amended`.
- **lab_orders 0** — a result is released deliberately, per row; an order in flight is a clinical
  intention. Showing a patient "sepsis workup ordered" before anyone has spoken to them is a
  conversation nobody planned.

---

## 4. A patient cannot write data attributed to someone else

Each of these should fail. If any of them succeeds, that is a real finding.

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'patient@gmail.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'patient@gmail.com'), true);
set local role authenticated;

-- (a) chart a vital sign on Rosa Delgado
savepoint a;
insert into public.vital_sign (organization_id, patient_id, heart_rate_bpm)
values ('11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000001', 60);
--> ERROR: new row violates row-level security policy for table "vital_sign"
--    (vital_sign_insert requires app.is_clinician() and a care-team relationship)
rollback to savepoint a;

-- (b) chart one on herself
savepoint b;
insert into public.vital_sign (organization_id, patient_id, heart_rate_bpm)
values ('11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000003', 60);
--> ERROR: same. Being the subject of a record is not authority to write it.
rollback to savepoint b;

-- (c) register a patient into the OTHER hospital
savepoint c;
insert into public.patient (organization_id, mrn, first_name, last_name, date_of_birth)
values ('22222222-2222-4222-a222-222222222222', '999-001', 'Mallory', 'Test', date '1990-01-01');
--> ERROR: new row violates row-level security policy for table "patient"
rollback to savepoint c;

-- (d) request a refill on someone else's prescription
update public.medication_order set refill_requested_at = now()
 where patient_id = '30000000-0000-4000-a000-000000000001';
--> UPDATE 0  (no error: the row is simply not visible, so there is nothing to update)

-- (e) request a refill on her OWN prescription — the one thing she MAY do
update public.medication_order set refill_requested_at = now()
 where patient_id = app.current_patient_id() and drug_name = 'Metformin';
--> UPDATE 1

-- (f) but not change anything else on that same row
savepoint f;
update public.medication_order set dose_text = '1000 mg'
 where patient_id = app.current_patient_id() and drug_name = 'Metformin';
--> ERROR: As a patient you may only change (refill_requested_at, updated_at) on medication_order.
--    RLS is row-level; this is app.enforce_patient_writable_columns() doing the column half.
rollback to savepoint f;

-- (g) grant herself a care-team seat on Rosa's chart
savepoint g;
insert into public.care_team_member (organization_id, patient_id, member_id, role, added_by)
values ('11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000001',
        app.current_member_id(), 'attending', app.current_member_id());
--> ERROR: violates row-level security policy (care_team_insert requires app.is_clinician())
rollback to savepoint g;
rollback;
```

Note the difference between **(d)** and **(f)**. An invisible row produces `UPDATE 0` — RLS
filters rather than raises, which is correct: an error would confirm the row exists. A visible row
with a forbidden column produces an exception, because at that point you already know the row is
there and the question is what you may do to it.

---

## 5. Two boundaries, not one: the doctor and Grace Lin

Tenant isolation is the primary boundary. It is not the only one. The seed leaves **Grace Lin
(MRN 110-204) with no care team**, and she is the control case.

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'doctor@clinic.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'doctor@clinic.com'), true);
set local role authenticated;

-- (a) the patient INDEX is open to clinicians: all 13 St. Luke's patients, Grace included
select count(*) as findable_patients from public.patient;
--> 13

-- (b) the CHART is not. Grace is not on the care team, so her clinical rows are closed.
select p.mrn, p.last_name, c.name as primary_condition
  from public.patient p
  left join public.patient_condition c on c.patient_id = p.id
 where p.mrn in ('104-882', '110-204');
--> 104-882 Delgado | Pneumonia
--> 110-204 Lin     | NULL       ← the LEFT JOIN keeps the row; the condition is filtered away

-- (c) named directly
select * from public.patient_condition
 where patient_id = '30000000-0000-4000-a000-000000000007';
--> 0 rows

-- (d) and the same for her encounter and any AI output
select (select count(*) from public.encounter
         where patient_id = '30000000-0000-4000-a000-000000000007') as encounters,
       (select count(*) from public.ai_risk_score
         where patient_id = '30000000-0000-4000-a000-000000000007') as scores;
--> 0 · 0

-- (e) the emergency path, which is deliberate and leaves a name and a timestamp
insert into public.care_team_member (organization_id, patient_id, member_id, role,
                                     assignment_note, added_by)
values ('11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000007',
        app.current_member_id(), 'attending', 'cross-cover, ward call',
        app.current_member_id());
--> INSERT 0 1

select * from public.patient_condition
 where patient_id = '30000000-0000-4000-a000-000000000007';
--> 1 row — assuming care is what opens the chart
rollback;   -- undoes the assignment
```

**(e) is not a hole; it is the design, and 020 §26 argues it.** A clinician may add *themselves*
to a care team in their own hospital, because a doctor covering a colleague's ward at 3am cannot
wait for an administrator, and a system that makes them wait gets a shared login instead. What it
is not: a route into another hospital, a route for reception or `hospital_admin`
(`app.is_clinician()` only), or a way to add somebody *else* to a team. An accountability control
does not prevent the act — it makes it undeniable. Which is only true if somebody reads the trail:

```sql
select occurred_at, action, table_name, actor_roles, changed_columns
  from audit.event
 where table_name = 'care_team_member'
 order by occurred_at desc limit 5;
```

---

## 6. Reception sees the day, not the chart

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'receptionist@clinic.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user
           where email = 'receptionist@clinic.com'), true);
set local role authenticated;

-- the check-in queue, with live waiting time — 5 rows, Helen Cho at ~32 min
select queue_ticket, patient_name, provider_name, department_name, status, waiting_minutes
  from public.v_checkin_queue
 where queue_date = current_date
 order by queue_ticket;

-- the billing worklist — 5 invoices, INR minor units
select number, status, total_minor, patient_due_minor, balance_minor, days_overdue
  from app.v_invoice_balance order by number;

-- but no clinical rows at all
select (select count(*) from public.lab_result)        as labs,
       (select count(*) from public.vital_sign)        as vitals,
       (select count(*) from public.clinical_note)     as notes,
       (select count(*) from public.ai_risk_score)     as risk_scores,
       (select count(*) from public.patient_condition) as conditions;
--> 0 · 0 · 0 · 0 · 0

-- and nothing from the other hospital, including its one invoice
select count(*) as meridian_invoices from public.invoice
 where organization_id = '22222222-2222-4222-a222-222222222222';
--> 0
rollback;
```

Reception reaches `patient`, `appointment`, `patient_coverage`, `invoice`, `invoice_line` and
`payment` — and nothing on the chart. Note that `v_checkin_queue` and `app.v_invoice_balance` are
declared `with (security_invoker = true)`. Without that flag a view runs as its **owner** and
reads straight through RLS, which is the easiest way to build a correct isolation model and then
leak through a convenience view. There is a standing check for it in §10 below.

---

## 7. Constraints beat policies: the radiology-image ban

RLS is bypassable by anything holding `service_role` or `BYPASSRLS`. A `CHECK` constraint is not:
it binds the web session, the model worker, a migration and a superuser at `psql` alike. The
radiology-image rule is therefore a constraint, not a policy.

```sql
begin;
set local row_security = off;   -- makes no difference whatsoever

-- Rosa's chest DICOM, seeded as doc_type = 'radiology_image'
savepoint banned;
insert into public.ai_analysis_run
       (organization_id, document_id, kind, model_provider, model_name, model_version,
        prompt_version, status, started_at, completed_at)
values ('11111111-1111-4111-a111-111111111111',
        'd0000000-0000-4000-a000-000000000002',
        'interpretation', 'acme', 'acme-vision', '4.2', 'p-11',
        'succeeded', now(), now());
--> ERROR: Radiology images are stored and displayed only: document … cannot be sent to a model
--         for interpretation.
--    HINT: Analyse the radiologist's REPORT (document type radiology_report) instead.
rollback to savepoint banned;

-- the one kind that IS permitted over an image: headers and checksums, never pixels
insert into public.ai_analysis_run
       (organization_id, document_id, kind, model_provider, model_name, model_version,
        prompt_version, status, started_at, completed_at)
values ('11111111-1111-4111-a111-111111111111',
        'd0000000-0000-4000-a000-000000000002',
        'metadata_index', 'acme', 'acme-index', '1.0', 'p-11',
        'succeeded', now(), now());
--> INSERT 0 1
rollback;
```

Two more constraints worth confirming, both in the same spirit:

```sql
begin;
-- (a) an AI finding cannot reach the patient portal unreviewed
savepoint a;
update public.ai_finding set patient_visible = true
 where id = 'c3000000-0000-4000-a000-000000000001';   -- review_state = 'pending'
--> ERROR: violates check constraint "ai_finding_patient_visible_ck"
rollback to savepoint a;

-- (b) a storage key cannot be written under another tenant's prefix
savepoint b;
insert into public.document (organization_id, patient_id, source, file_name, mime_type,
                             byte_size, checksum_sha256, storage_key)
values ('11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000001', 'staff_upload', 'x.pdf', 'application/pdf',
        1024, repeat('a', 64),
        'org/22222222-2222-4222-a222-222222222222/stolen.pdf');
--> ERROR: violates check constraint "document_storage_key_tenant_ck"
rollback to savepoint b;
rollback;
```

**(b) is only half of rule 3, and the database cannot do the other half.** It refuses to *record*
a cross-tenant key and refuses to *analyse* a document that is not `scan_status = 'clean'`. It
cannot refuse to **serve** one, because it does not sign URLs. Whatever signs download URLs must
check both `scan_status = 'clean'` and that the key prefix matches the caller's organisation
(`app.storage_prefix`). That belongs in the API test suite.

---

## 8. Cross-tenant references are foreign-key violations

The house rule "FK to `(parent_id, organization_id)`, never to `parent_id` alone" is what turns a
cross-tenant reference from a code-review finding into an error.

```sql
begin;
-- Rosa belongs to org 1. Claiming her for Meridian means pointing at a (patient, organization)
-- pair that does not exist — which is a foreign-key violation, not a policy decision.
savepoint a;
insert into public.vital_sign (organization_id, patient_id, heart_rate_bpm)
values ('22222222-2222-4222-a222-222222222222',
        '30000000-0000-4000-a000-000000000001', 80);
--> ERROR: insert or update on table "vital_sign" violates foreign key constraint
--         "vital_sign_patient_fk"
rollback to savepoint a;

-- an appointment for Meridian's Bilal with St. Luke's Dr. Mehta as provider
savepoint b;
insert into public.appointment (organization_id, patient_id, provider_member_id,
                                scheduled_start, scheduled_end)
values ('22222222-2222-4222-a222-222222222222',
        '30000000-0000-4000-a000-000000000052',
        '20000000-0000-4000-a000-000000000001',
        now(), now() + interval '30 minutes');
--> ERROR: violates foreign key constraint "appointment_provider_fk"
rollback to savepoint b;
rollback;
```

And the other structural guards:

```sql
begin;
-- clinical history is never hard-deleted
savepoint a;
delete from public.lab_result where id = '80000000-0000-4000-a000-000000000001';
--> ERROR: Hard delete is not permitted on lab_result. Amend, void or supersede the row instead.
rollback to savepoint a;

-- a reported value is frozen; only the review and release decisions move
savepoint b;
update public.lab_result set value_numeric = 1.0
 where id = '80000000-0000-4000-a000-000000000001';
--> ERROR: Clinical facts on lab_result are append-only; only
--         (review_status, reviewed_by, reviewed_at, review_note, released_to_patient_at,
--          record_status, updated_at) may be updated in place.
rollback to savepoint b;

-- the audit trail cannot be edited, even by the owner (this is the one FORCE RLS table)
savepoint c;
update audit.event set action = 'read' where true;
--> ERROR: audit.event is append-only: UPDATE is not permitted.
rollback to savepoint c;

-- one provider cannot be in two rooms at once: Dr. Mehta already has 09:30–10:00 today
savepoint d;
insert into public.appointment (organization_id, patient_id, provider_member_id,
                                scheduled_start, scheduled_end)
values ('11111111-1111-4111-a111-111111111111',
        '30000000-0000-4000-a000-000000000005',
        '20000000-0000-4000-a000-000000000001',
        (current_date + time '09:45') at time zone 'Asia/Kolkata',
        (current_date + time '10:15') at time zone 'Asia/Kolkata');
--> ERROR: conflicting key value violates exclusion constraint
--         "appointment_no_double_book_ck"
rollback to savepoint d;
rollback;
```

> If the last one **succeeds**, `btree_gist` was not available when 020 ran and the constraint was
> never created. Run `000_extensions.sql`, then re-run `020_clinical.sql`, then re-test. Until it
> exists, double-booking is prevented by nothing but the booking service.

---

## 9. Vendor containment

There is no `platform_admin` in the seed, deliberately — vendor accounts are minted out of band
via `service_role`, never by a migration or a web session. What you can verify without one is that
containment is **structural** rather than a rule someone remembered to write.

`app.current_org_id()` derives the tenant from `organization_member` only. A platform admin holds
no membership anywhere, so it returns null for them, so every policy written to the house rule
(`organization_id = app.current_org_id()`) yields zero rows. Vendor containment is therefore the
*default*, and it holds even for a migration whose author never thought about `super_admin`.

```sql
-- Every policy in the database that reaches across the tenant boundary. This list should be
-- short, and every entry on it should be a decision someone can name out loud.
select tablename, policyname, cmd from app.v_super_admin_policy_review order by tablename;
```

Expect, and nothing else:

| table | why it is on the list |
|---|---|
| `organization`, `subscription_plan`, `feature`, `plan_feature`, `organization_entitlement` | commercial metadata — no personal data in any of it |
| `usage_metric`, `organization_usage_daily` | counts only; `metric_value` is a `bigint`, so it cannot hold a name |
| `support_session`, `platform_admin` | the vendor-access log itself |
| `app_user`, `organization_member`, `department`, `payer` | reached via `app.support_org_id()` — one named tenant, time-boxed, expiring, and visible to that customer in `public.support_session` |

Nothing clinical is on that list, and nothing financial. `patient`, every table in 020 and 030,
and `patient_coverage` / `invoice` / `invoice_line` / `payment` do not mention the vendor at all.

The gate that keeps it that way, and which every migration runs at the end of itself:

```sql
select app.assert_no_vendor_phi_policies(array[
  'patient','patient_condition','patient_allergy','care_team_member','encounter','appointment',
  'vital_sign','lab_order','lab_result','clinical_note','medication_order',
  'document','document_text','ai_analysis_run','ai_finding','ai_risk_score','ai_risk_factor',
  'ai_citation','patient_coverage','invoice','invoice_line','payment']);
--> returns void, silently. Raises if anyone adds `OR app.is_super_admin()` to any of them.
```

Note what is **not** vendor-readable: `audit.event`. The trail carries the clinical and financial
values 010 spent a section keeping away from the vendor, and one compromised vendor account
reading every hospital's trail would be a worse breach than reading one hospital's charts.

---

## 10. The standing audit — run this in CI

Four queries. All four must come back empty (or as noted). They are the cheapest review you will
get, and each has caught a real class of mistake.

```sql
-- 1. A table carries organization_id and forgot to switch RLS on.
select * from app.v_tenant_rls_gaps;
--> 0 rows

-- 2. RLS is on but nobody wrote a policy. This denies everything, which fails safe and also
--    fails the product — so it is worth telling apart from a real gap.
select n.nspname || '.' || c.relname as table_without_policy
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname in ('public', 'audit') and c.relkind = 'r' and c.relrowsecurity
   and not exists (select 1 from pg_policies p
                    where p.schemaname = n.nspname and p.tablename = c.relname)
 order by 1;
--> 0 rows
--   (audit.event's partitions do not appear: RLS is declared on the partitioned parent, which is
--    where it is enforced for any query routed through it, and the partitions carry no grants.)

-- 3. A view that is not security_invoker runs as its OWNER, and the owner is not subject to RLS.
--    That is the easiest way to build a correct isolation model and then leak straight through a
--    convenience view. The three exclusions read only pg_catalog — they list tables and policies,
--    never rows — so the flag would buy nothing there; every view that touches tenant data must
--    have it.
select n.nspname || '.' || c.relname as leaky_view
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind = 'v' and n.nspname in ('public', 'app', 'audit')
   and c.relname not in ('v_tenant_rls_gaps',            -- pg_catalog only
                         'v_super_admin_policy_review',  -- pg_catalog only
                         'v_unaudited_tenant_tables')    -- pg_catalog only
   and not coalesce((select option_value = 'true'
                       from pg_options_to_table(c.reloptions)
                      where option_name = 'security_invoker'), false)
 order by 1;
--> 0 rows

-- 4. A tenant table with no audit trigger. organization_usage_daily is exempt by design
--    (derived counters, rewritten daily).
select * from audit.v_unaudited_tenant_tables;
--> 0 rows
```

A fifth, which is a number to watch rather than a pass/fail: whether the **application** is
holding up its half of read auditing. The database records every write; it cannot record a read
that nobody reports.

```sql
select * from audit.v_read_coverage;
-- Empty on a fresh seed. A clinical table missing from this list is not evidence that nobody
-- read it — it is evidence that nobody is reporting it. Call app.log_chart_open(patient_id) when
-- a chart, prognosis report or results page opens.
```

And the alert this whole design exists to make unmissable:

```sql
select * from audit.v_cross_tenant_access limit 20;
-- For an ordinary user this must be EMPTY: 010's policies make it structurally impossible.
-- Vendor rows appear here legitimately (raising an entitlement, opening a support session).
-- What deserves a human is a row where explained_by_support_session is false and the table is
-- not commercial metadata.
```

---

## 11. What these tests do not prove

Worth stating plainly, because a green test suite is exactly when a wrong conclusion gets drawn.

- **`service_role` defeats every policy here.** It holds `BYPASSRLS`. Nothing in this file
  constrains it, and nothing in the database can. Keep it server-side, never on a request
  carrying an end user's identity, and note that `VITE_*` variables ship to every browser — the
  app's own `src/lib/supabase.ts` refuses to start if a `service_role` key is pasted into the
  anon slot, which is the right instinct and not a substitute for care.
- **Superuser defeats the append-only triggers.** In-database immutability is a strong control
  against application compromise and human error. It is not a control against whoever holds
  superuser. If that is in the threat model, stream audit events off-box and reconcile counts.
- **Read auditing is only as good as the app** (§10, fifth query).
- **The tests run against seeded data.** They prove the policies behave on these rows. They do not
  prove the *app* only ever asks for rows it should — that needs API-level tests, particularly
  around signed storage URLs (§7).
- **Timing and error-message differences can still leak existence.** `UPDATE 0` versus an
  exception is a signal, as §4 notes. This schema does not attempt to be constant-time.
