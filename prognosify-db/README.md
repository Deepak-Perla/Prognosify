# Prognosify database

Multi-tenant PostgreSQL schema for the Prognosify hospital dashboard. Targets **PostgreSQL 15+ on
Supabase** (region `ap-south-1`), with the Supabase-specific parts confined to clearly marked
blocks so the schema can move to RDS or Neon.

Prognosify is sold to **many hospitals**. Each hospital is one `organization`, and tenant
isolation is the primary security boundary in this schema — above per-patient access, above role
checks, above everything. A bug there leaks one hospital's patients to another hospital, which is
the worst outcome this system can produce.

---

## RLS audit: every table is protected

**No gaps.** All 43 tables carry row-level security with at least one real policy (42 if pgvector
is unavailable, in which case `document_text_chunk` is not created at all). Verified table
by table below; the four standing checks that keep it that way are in
[TESTING.md §10](TESTING.md#10-the-standing-audit--run-this-in-ci) and every migration runs them
against itself before it finishes.

Five things are worth flagging anyway, because "RLS is on" is not the same as "you are safe":

0. **Every policy in this schema trusts `app.current_auth_uid()`, and that is only trustworthy
   because PostgREST verifies the JWT signature.** If an end-user connection can reach this
   database as the `authenticated` role without that in front of it, two `set_config()` calls
   impersonate any subject in any hospital and the entire isolation model collapses. This is a
   **deployment prerequisite, not a schema property** — see
   [Deployment prerequisites (security-critical)](#deployment-prerequisites-security-critical).
   It is exactly as load-bearing as item 1.
1. **`service_role` holds `BYPASSRLS` and defeats every policy in this schema.** Nothing in the
   database can constrain it. It is for migrations, the model worker, the lab ETL and the usage
   collector — never on a request carrying an end user's identity. `VITE_*` variables are compiled
   into the browser bundle, so a `service_role` key in `.env.local` would publish the whole
   database; the app refuses to start if one is pasted into the anon slot.
2. **Read auditing depends on the application.** Writes are captured by triggers. A read leaves no
   trace unless the app calls `app.log_chart_open()` / `audit.log_read()`.
   `audit.v_read_coverage` is the honest measure of how much is actually being reported.
3. **Serving bytes is outside the database.** It refuses to record a cross-tenant storage key and
   refuses to analyse an unscanned file, but it cannot refuse to *serve* one — it does not sign
   URLs. See [Object storage](#object-storage-keys).
4. **Three views deliberately lack `security_invoker`** — `app.v_tenant_rls_gaps`,
   `app.v_super_admin_policy_review`, `audit.v_unaudited_tenant_tables`. They read `pg_catalog`
   only, listing tables and policies rather than rows. Every view that touches tenant data has the
   flag, and the CI query in TESTING.md §10 enforces it.

---

## Deployment prerequisites (security-critical)

**Read this before any end-user traffic reaches this database.** Everything below is a control the
schema **cannot** enforce. Each one is as load-bearing as the `service_role` warning above, and
none of them is a policy, a trigger or a constraint you can grep for — which is precisely why they
are stated here.

### 1. `authenticated` must never be reachable on a directly-connectable endpoint

Every policy in this database ultimately trusts `app.current_auth_uid()`. So do
`app.current_org_id()`, `app.current_member_id()`, `app.current_patient_id()`,
`app.care_patient_ids()` and `app.is_super_admin()` — they derive from it and from nothing else.
That function reads the `request.jwt.claim.sub` / `request.jwt.claims` placeholder GUCs.

`request.*` is an **unreserved placeholder class**. In stock PostgreSQL *any* role — including
`authenticated` — may set such a GUC with `set_config()`, and PostgreSQL offers a migration **no
way to reserve it**. There is no `ALTER ROLE ... SET`, no event trigger and no GUC hardening
anywhere in `000`–`050`, because none is possible. So:

```sql
-- on a raw `authenticated` connection, this is total cross-tenant compromise
select set_config('request.jwt.claims',
  json_build_object('sub','<any other hospital''s member auth_user_id>')::text, true);
select set_config('request.jwt.claim.sub', '<same uuid>', true);
select * from public.patient;     -- now returns that hospital's charts
```

What actually closes this door is **PostgREST** (or an equivalent gateway): it verifies the JWT
signature and sets `sub` **only** from the verified payload, so a browser cannot forge it. That
makes the identity seam a **deployment property, not a schema property**. Three hard requirements
follow:

- **(a)** All end-user traffic traverses PostgREST or an equivalent that verifies the JWT
  signature and populates the claim GUCs solely from the verified payload. The `authenticated`
  role must not be reachable on any directly-connectable endpoint — no pooler port, no bastion, no
  "temporary" psql access for support.
- **(b)** **Direct `authenticated` credentials must not exist.** There is no password to leak if
  no password was ever issued. The role is reached by `SET ROLE` from the gateway's own
  authenticator login and by nothing else.
- **(c)** A **deployment test must prove** that an `authenticated` session cannot alter
  `request.jwt.claim.sub` — i.e. that the impersonation above fails. Run it against every
  environment that holds real data, and re-run it after any change to networking, pooling or the
  API gateway. Treat a pass as expiring.

Note the second half of this, which is worse than it first looks: because PostgreSQL has **no
SELECT trigger** and read auditing in this schema is app-reported (040 §5.1), a cross-tenant
**read** through this path would leave **no trace at all**. There would be nothing in
`audit.event`, nothing in `audit.v_cross_tenant_access`, and nothing to find afterwards. The
control has to be preventive because there is no detective control behind it.

### 2. `service_role` is a break-glass credential, not a service account for requests

Restating item 1 of the list above because it belongs in this section too: `service_role` holds
`BYPASSRLS` and defeats every policy here. It is for migrations, the model worker, the lab ETL and
the usage collector. It must never sit on a request carrying an end user's identity, and its key
must not live in a `.env` file on a laptop or anywhere a `VITE_*` build could inline it.

Two related credential splits are **follow-ups, not done**:

- **The model worker should not hold `UPDATE ON public.ai_finding`.** As of
  `050_hardening.sql` the database refuses a membership-less caller any review or
  chart-commitment write, so the worker can no longer rubber-stamp its own output under a named
  clinician's seat (finding C5b). The operational half is still outstanding: give the generating
  worker `INSERT` only, and put `UPDATE ON public.ai_finding` behind a separate role used by
  nothing that generates findings.
- **The malware scanner is the only writer of `document.scan_status`.** The database enforces
  this by database role (`app.document_guard_scan_status()`), so the scanner must run as a trusted
  server-side role and nothing else may.

### 3. Whatever signs download URLs must enforce two things the database cannot

Bytes never live in a column. The database refuses to *record* a cross-tenant storage key
(`app.storage_key_belongs_to()` in a CHECK) and refuses to *analyse* an unscanned document — but
it cannot refuse to **serve** one, because it does not sign URLs. The signer must check
`document.scan_status = 'clean'` **and** that the key prefix matches the caller's own organisation.
The tenant-first key layout is the only thing separating hospitals in object storage; a
misconfigured bucket policy is a cross-tenant leak that no migration in this repository can
prevent. Put an explicit test for both in the API suite.

### 4. Step-up authentication before a vendor opens a support session

Cannot be expressed in SQL; it needs a recent-MFA claim from an auth hook. Until it exists, a
stolen vendor session can open an `operational` (not clinical) support session. `phi` scope still
requires a `hospital_admin` of that tenant to approve.

### 5. Access-token TTL

A project setting, not schema. The staleness argument in 010 §8.2 assumes it is set to the
shortest value the project allows.

---

### Table by table

`T` = carries `organization_id`. Read the policy column as: tenant, then purpose, then row.

| # | Table | T | RLS | Policies |
|---|---|:-:|:-:|---|
| **010 — tenancy and identity** ||||
| 1 | `subscription_plan` | – | ✔ | select (any signed-in user) · write (vendor) |
| 2 | `feature` | – | ✔ | select · write (vendor) |
| 3 | `plan_feature` | – | ✔ | select · write (vendor) |
| 4 | `organization` | *is* | ✔ | select (own tenant or vendor) · insert (vendor) · update (vendor, or hospital_admin for presentation columns only, enforced by trigger) |
| 5 | `organization_entitlement` | ✔ | ✔ | select (own tenant or vendor) · write (vendor only) |
| 6 | `app_user` | – | ✔ | select (self, or shares your tenant, or an open support session) · update (self) · insert (admin) |
| 7 | `organization_member` | ✔ | ✔ | select (staff see colleagues; a patient sees only their own patient row) · insert/update (hospital_admin or self; self-edits of roles blocked by trigger) |
| 8 | `platform_admin` | – | ✔ | select (vendor only). **No write policy at all** — minted out of band |
| 9 | `patient` | ✔ | ✔ | select/insert/update (clinician, front desk, or the patient themselves). No vendor clause |
| 10 | `support_session` | ✔ | ✔ | select (the customer's own hospital_admin, or vendor). Writes via RPC only |
| **020 — clinical** ||||
| 11 | `department` | ✔ | ✔ | select (everyone in the tenant) · insert/update (hospital_admin) · + `department_select_support` from 040 |
| 12 | `visit_type` | ✔ | ✔ | select (tenant) · insert/update (hospital_admin) |
| 13 | `staff_profile` | ✔ | ✔ | select (tenant) · insert (hospital_admin) · update (hospital_admin or the person) |
| 14 | `patient_condition` | ✔ | ✔ | select/insert/update (clinician **on the care team**, or the patient) |
| 15 | `patient_allergy` | ✔ | ✔ | same shape |
| 16 | `care_team_member` | ✔ | ✔ | select (staff, or the patient) · insert (clinician, **for themselves only**) · update (hospital_admin or self) |
| 17 | `encounter` | ✔ | ✔ | select (care team, or the patient) · insert (clinician, self as author) · update (care team) |
| 18 | `appointment` | ✔ | ✔ | select/insert/update (front desk or clinician, org-wide; the patient for their own) |
| 19 | `vital_sign` | ✔ | ✔ | select/insert/update (care team, or the patient) |
| 20 | `lab_panel` | ✔ | ✔ | select (staff) · insert/update (hospital_admin) |
| 21 | `lab_test` | ✔ | ✔ | select (tenant — the portal needs the range to explain a result) · insert/update (hospital_admin) |
| 22 | `lab_order` | ✔ | ✔ | select/insert/update (care team). **Not** the patient |
| 23 | `lab_result` | ✔ | ✔ | select (care team, or the patient **if released**) · insert/update (care team) |
| 24 | `clinical_note` | ✔ | ✔ | select/insert/update (care team). **Not** the patient — third-party content |
| 25 | `medication_order` | ✔ | ✔ | select (care team, or the patient) · insert (doctor only) · update (doctor, or the patient for `refill_requested_at` only) |
| **030 — documents and AI** ||||
| 26 | `document` | ✔ | ✔ | select (care team; your own uploads; front desk for administrative types; the patient for their own uploads and released files) · insert/update |
| 27 | `document_text` | ✔ | ✔ | select (care team). No write policy — written by the extraction worker |
| 28 | `ai_analysis_run` | ✔ | ✔ | select (care team; or your own panel brief). No write policy — model output is unforgeable from a browser |
| 29 | `ai_finding` | ✔ | ✔ | select (care team; or the patient if reviewed **and** released) · update (care team — the review decision, the only AI write a session may make) |
| 30 | `ai_risk_score` | ✔ | ✔ | select (care team). Never the patient |
| 31 | `ai_risk_factor` | ✔ | ✔ | select, scoped through `EXISTS` on the parent score |
| 32 | `ai_citation` | ✔ | ✔ | select, scoped through `EXISTS` on its subject |
| 33 | `document_text_chunk` | ✔ | ✔ | select (care team). Created only if pgvector is available |
| **040 — admin, billing, audit** ||||
| 34 | `org_setting` | ✔ | ✔ | select (hospital defaults, your own overrides, or hospital_admin) · write admin (defaults) · write self (your own) |
| 35 | `payer` | ✔ | ✔ | select (front desk, clinician, hospital_admin, or support session) · insert/update (hospital_admin or front desk) |
| 36 | `patient_coverage` | ✔ | ✔ | select (front desk, clinician, or the patient) · insert/update (front desk). **No vendor route of any kind** |
| 37 | `invoice` | ✔ | ✔ | select (front desk, or the patient's own bill) · insert/update (front desk). Not hospital_admin, not clinicians |
| 38 | `invoice_line` | ✔ | ✔ | select (narrower than the header — "CT scan, chest" is diagnosis-shaped) · write (front desk) |
| 39 | `payment` | ✔ | ✔ | select · insert. **No update, no delete policy** |
| 40 | `usage_metric` | – | ✔ | select (any signed-in user) · write (vendor) |
| 41 | `organization_usage_daily` | ✔ | ✔ | select (own hospital_admin, or vendor). **No insert/update policy** — `app.record_usage()` is the only writer |
| 42 | `audit.event` | ✔ | ✔ **+FORCE** | insert (true — no app role holds the privilege) · select (own hospital_admin; your own actions; a patient's own events). **No vendor clause, no update, no delete** |
| 43 | `audit.redacted_column` | – | ✔ | select (anyone signed in, so what is withheld is verifiable). Writable by nobody through the API |

`audit.event` is the only table with `FORCE ROW LEVEL SECURITY`, which subjects the owner to its
own policies too. Everything else uses plain `ENABLE`, and that is not laziness: the `app.*`
helpers are `SECURITY DEFINER` functions owned by the table owner and they read the very tables
whose policies call them. `FORCE` there would make the policies call the functions that are
reading the table — infinite recursion, failing closed at the worst possible moment. No policy on
`audit.event` reads `audit.event`, so the cycle does not exist and `FORCE` buys real protection.

---

## Applying the migrations

Supabase dashboard → **SQL Editor** → New query. Paste one file, run it, read the `NOTICE` output,
then move to the next. **Order matters and the files enforce it** — each refuses to run if its
predecessors have not.

| Order | File | Size | What it creates |
|---|---|---|---|
| 1 | `migrations/000_extensions.sql` | 9 KB | `pgcrypto`, `btree_gist`, optional `pgvector`; version floor; refuses to proceed if the retired 001–004 drafts are installed |
| 2 | `migrations/010_tenancy_identity.sql` | 83 KB | schema `app`, tenants, plans, entitlements, identity, membership, `platform_admin`, `public.patient`, support sessions, **the session-helper API every later policy is built on** |
| 3 | `migrations/020_clinical.sql` | 133 KB | departments, visit types, staff profile, care teams, encounters, appointments, vitals, labs, notes, medications, 5 read views |
| 4 | `migrations/030_documents_ai.sql` | 113 KB | documents, extracted text, AI runs/findings/scores/factors/citations, optional pgvector chunks |
| 5 | `migrations/040_admin_billing_audit.sql` | 117 KB | org settings, billing, vendor usage counters, schema `audit` (partitioned append-only trail) |
| 6 | `migrations/050_hardening.sql` | — | **security fixes from the two adversarial reviews in `security/`**: freezes `patient.portal_member_id` behind two RPCs, re-gates the append-only and no-delete escape hatches on the database role, adds append-only to five clinical tables, makes every UPDATE policy's `WITH CHECK` repeat its `USING`, stamps document and AI attribution server-side, validates the declared audit context, and widens the audit alert columns |
| 7 | `seed.sql` | 84 KB | two hospitals and the app's demo cast |

`seed.sql` calls `app.refresh_organization_usage(current_date)` itself, and 040 creates the audit
`DEFAULT` partition plus six months of monthly ones as it runs, so nothing else is needed to get a
working database. Two things should be **scheduled** thereafter (pg_cron, or any external scheduler
running as `service_role` — neither is granted to `authenticated`):

```sql
select audit.ensure_partitions(3);                     -- monthly
select app.refresh_organization_usage(current_date);   -- daily
```

Forgetting `ensure_partitions` degrades performance but never correctness: the `DEFAULT` partition
catches anything, because an audit write must never be the reason a clinical write fails.

**The files are idempotent.** Re-running any of them is safe. If one fails halfway, fix the cause
and run the whole file again rather than the remainder.

**Watch the NOTICEs.** They are where the conditional decisions announce themselves — whether
`btree_gist` was found and the double-booking constraint created, whether pgvector is available,
which tables the audit trigger could not attach to.

### The 001–004 drafts are gone

`001_core_clinical.sql`, `002_documents_ai.sql`, `003_identity_access.sql` and `004_audit.sql` were
a single-tenant first pass. **They have been deleted from this directory**, and they must not be
restored into the migration path. They defined a conflicting `public.patient` and an
`app.has_role(text)` that would sit beside 010's `app.has_role(app.org_role)` as an *overload* —
after which `app.has_role('doctor')` cannot resolve and every policy in the database fails at
query time. 000, 020 and 040 each refuse to run if they detect that overload.

---

## The entity model in brief

Five layers. Each one only knows about the layers above it.

```
TENANCY      organization ── subscription_plan ── plan_feature ── feature
                 │                                    │
                 │                    organization_entitlement (per-tenant override, windowed)
                 │
IDENTITY     app_user (one per human, tenant-agnostic)
                 └── organization_member (a seat in ONE hospital; roles[]; this IS "staff_id")
                        ├── staff_profile (department, specialty, room, takes bookings)
                        └── platform_admin  ← vendor side, NO organization, ever
                                 └── support_session (time-boxed, reason-bearing vendor access)

PATIENT      patient (tenant-scoped chart: MRN, demographics, portal link)
                 ├── patient_condition · patient_allergy · patient_coverage
                 ├── care_team_member  ← who may open this chart
                 ├── encounter (an episode that HAPPENED) ── appointment (an intention)
                 ├── vital_sign · lab_order ── lab_result · clinical_note · medication_order
                 └── invoice ── invoice_line · payment

DOCUMENTS    document (metadata + tenant-scoped storage key) ── document_text ── (chunks)

AI           ai_analysis_run (model, VERSION, prompt version, cost)
                 ├── ai_finding    (+ mandatory human review state)
                 ├── ai_risk_score (+ ai_risk_factor)
                 └── ai_citation   (what any of the above rests on)

AUDIT        audit.event (append-only, monthly partitions) · audit.redacted_column
```

See [ERD.md](ERD.md) for the full diagram with cardinalities.

Six choices worth knowing before you read any SQL:

- **`organization_member.id` is "staff_id" everywhere.** There is no second staff table. Roles,
  job title and licence number live on the membership row; practice attributes live on
  `staff_profile`.
- **One human can hold seats at two hospitals.** `app_user` is a person; `organization_member` is
  a seat. A locum has one login and two seats. The cost is that "which hospital is this request
  for?" stops being obvious, which is why every session has an active organisation and why audit
  entries record the *acting* organisation, not just the actor.
- **The same person treated at two hospitals is two unrelated charts.** Deliberately not linked:
  there is no consent mechanism in this product for one hospital to learn its patient is treated
  elsewhere, and a cross-tenant master patient index would quietly create the exact leak tenant
  isolation exists to prevent.
- **MRN is unique per hospital, never globally.** `unique (organization_id, upper(mrn))`. Both
  seeded hospitals have a patient `104-882`, and that is correct.
- **Clinical rows are never deleted, and reported values are never edited.** A correction is a new
  row with `supersedes_id` and the old one becomes `record_status = 'amended'`. Enforced by
  `app.deny_hard_delete()` and `app.enforce_append_only()`, and by `app.guard_clinical_note()` for
  a signed note. Each has one escape hatch, for a data-fix runbook or a lawful erasure job, and
  since `050_hardening.sql` that hatch requires **both** a deliberate per-transaction GUC
  (`SET LOCAL app.allow_clinical_rewrite = 'on'` / `app.allow_hard_delete = 'on'`) **and** a
  trusted database role (`app.is_trusted_maintenance()`). Before 050 the GUC alone was enough,
  which meant the invariant could be switched off by the very role it constrains — the GUC class
  is unreserved and `authenticated` may set it. Money follows the same rule: a correction is a
  negative line, a refund is a negative payment.
- **Money is `bigint` minor units with an explicit currency per invoice.** Never float.

### What is deliberately *not* modelled

Named here because a reviewer needs to see the omissions as clearly as the inclusions:

no bed/location inventory (a room is a text label — nothing in the app books one) · no drug master
or eMAR · no panel↔test membership · no `claim` table (the Billing screen derives its three tabs
from invoice status) · no vendor subscription billing (`public.invoice` is the hospital billing its
patients; what you charge each hospital lives in Razorpay/Stripe/a spreadsheet) · no reception-side
AI surfaces (no-show risk, triage chip) · no finance role.

---

## Tenancy and RLS: how it works

### One function is the whole boundary

```sql
app.current_org_id()
```

Every policy on tenant data begins with `organization_id = app.current_org_id()`. It resolves the
caller's active organisation **from `organization_member`**, and returns `NULL` when there isn't
one. Since `x = NULL` is never true, a null org means every tenant policy denies. That happens for
an anonymous caller, a revoked seat, a suspended or closed tenant, **a vendor admin**, and a
multi-hospital user who has not chosen. Fail-closed in all five cases.

That is also how `super_admin` is contained: a platform admin holds no membership anywhere, so
`app.current_org_id()` is null for them and every policy written to the house rule returns them
zero rows. **Vendor containment is the default**, and it holds even in a migration whose author
never thought about the vendor at all. The only way to break it is to deliberately add
`OR app.is_super_admin()` to a clinical policy — which
`app.assert_no_vendor_phi_policies()` fails CI on, and `app.v_super_admin_policy_review` lists.

### What is trusted, and what is not

The JWT is trusted for **identity** (`sub`) — it is signature-verified and identity does not change
mid-session. It is trusted as a **hint** for which organisation the client wants. It is **never**
trusted for what the caller may do: roles, seat status and tenant status are read from tables on
every statement.

The cost is one index-only probe of `organization_member_session_ix` per statement. What it buys is
that a fired doctor, a revoked seat or a non-paying tenant stops working on the **next statement**
rather than up to an hour later when an access token expires. For a system holding health records
that window matters, and "sign them out everywhere" is not reliably available.

Because the helpers are argument-free and `STABLE`, PostgreSQL folds them into an InitPlan and runs
them **once per statement, not once per row**. Listing 42 patients costs one probe, not 42.

### Two boundaries, not one

| | tenant isolation | per-patient scope |
|---|---|---|
| enforced by | `organization_id = app.current_org_id()` | `patient_id = ANY (app.care_patient_ids())` |
| what it stops | one hospital reading another's | a clinician reading a chart they have no relationship with |
| exceptions | none, anywhere | the patient index (`public.patient`) stays findable by any clinician or receptionist; reception's own document uploads |

`app.care_patient_ids()` returns the patients the caller holds an open `care_team_member` row for.
A clinician may add **themselves** to a care team within their own hospital — the emergency path,
argued at length in 020 §26. It leaves a row with a name and a timestamp, which is what makes it an
accountability control rather than a hole. It is not a route into another hospital, not available to
reception or `hospital_admin`, and not a way to add somebody else.

**If you want the patient index narrowed too** — so a doctor cannot even confirm that a given
person is a patient here unless they are on the care team — 020 §91 has the ready-to-run
`RESTRICTIVE` policy. It is written down rather than applied because it costs every referral and
every cross-cover shift an assignment step first, and that is a hospital workflow decision.

### Roles

Five inside a hospital, one outside it.

| role | reach |
|---|---|
| `doctor` | charts of patients on their care team; prescribing; scheduling; labs |
| `nurse` | the same charts, minus prescribing |
| `receptionist` | patients (administrative columns), appointments **including `chief_complaint`, org-wide**, the queue, coverage, billing **including invoice line descriptions ("CT scan, chest")**, care-team composition, and documents classified `scanned_document`. **No clinical results** — no lab result, lab order, note, vital, extracted text or AI row |
| `patient` | their own chart, their own released results, their own bills, their own appointments |
| `hospital_admin` | staff seats, departments, settings, their own hospital's audit trail. **No charts, no invoices** — administering a hospital is not a treatment purpose |
| `super_admin` | tenants, plans, entitlements, usage **counts**. Personal data only through an open, time-boxed, customer-visible support session. Clinical data only with a `phi`-scoped session that a `hospital_admin` of that hospital approved — and no policy in this schema grants it today |

**Reception's row above used to say "No clinical rows at all". That was wrong**, and it is worth
being precise because the sentence was doing work it could not support. RLS genuinely walls the
front desk off from every clinical *result* — `lab_result`, `lab_order`, `clinical_note`,
`vital_sign`, `document_text` and every `ai_*` table each require `app.is_clinician()` or the
patient themselves, and `app.is_staff()` is correctly avoided on all of them. But reception does
read `invoice_line.description` (040's own comment calls it "diagnosis-shaped"),
`appointment.chief_complaint` org-wide, and every `care_team_member` row — which, joined to the
tenant-readable `staff_profile.specialty`, yields "this patient is under the oncology consultant".
Those are clinical *inferences* with no clinical row, and all three are load-bearing for real
front-desk screens, so they stay. What did change in `050_hardening.sql` is that `doc_type =
'other'` was withdrawn from the front-desk document branch: `'other'` is the catch-all type, a
clinician may reclassify a `lab_report` into it, and that made it a silent publication channel to
the whole desk.

A seat holds an **array** of roles, because small clinics really do have an owner who is both
`hospital_admin` and `doctor`, and a nurse treated at her own hospital is staff *and* a patient
there. Since `050_hardening.sql` that combination carries a **four-eyes rule on self-treatment**:
`app.enforce_patient_writable_columns()` is scoped on the row rather than on the caller's roles,
so a nurse who is also a patient here needs a colleague to make clinical edits to *her own* chart,
while her work on everyone else's charts is unaffected. Before 050 the guard short-circuited on
`app.is_staff()`, which turned it off entirely for exactly the seats this design invites. The consequence is that "which hat were they wearing" is not answerable from the row, which
is why `audit.event.acting_role` is declared by the application and is `NULL` when the app did not
say. `NULL` is honest; a guess recorded as a fact is not.

**There is no finance role.** If a customer needs a billing manager who is not a receptionist, the
fix is a new value in `app.org_role` — an `ALTER TYPE` in a deliberate migration, not a policy
widening.

---

## Create the three test logins

The seed contains **no auth users and no passwords**. Create the logins by hand, then run the seed,
which finds them by email.

1. Supabase dashboard → **Authentication → Users → Add user → Create new user**.
2. Create these three. Tick **Auto Confirm User** so you can sign in immediately.

   | email | becomes | roles |
   |---|---|---|
   | `doctor@clinic.com` | Dr. Anita Mehta, Cardiology, Clinic 2 | `{doctor}` |
   | `receptionist@clinic.com` | Jordan Cole, front desk | `{receptionist}` |
   | `patient@gmail.com` | **Priya Nair** — patient 108-921 | `{patient}` |

   Pick your own passwords. Nothing in this repository stores or should store them.
3. Run `seed.sql`. It resolves each login by email, creates the matching `app_user` and
   `organization_member` rows in St. Luke's, and links `patient@gmail.com` to Priya Nair's chart
   via `patient.portal_member_id`.

If you would rather paste the UUIDs than rely on the email lookup, §1 of `seed.sql` has a
clearly-marked block for exactly that — copy each user's **UID** from Authentication → Users. Those
are identifiers, not secrets, but they are specific to one Supabase project.

> **Order matters.** `public.app_user.auth_user_id` has a foreign key to `auth.users`, so the seed
> cannot invent identities. If none of the three emails exists yet, `seed.sql` stops with an
> explicit message rather than half-loading.

### "I signed in and every screen is empty"

That is RLS working, not a bug. Diagnose in order:

```sql
select u.email, m.id as member_id, m.roles, m.status as seat, o.slug, o.status as tenant
  from public.app_user u
  left join public.organization_member m on m.app_user_id = u.id
  left join public.organization o on o.id = m.organization_id
 where u.email in ('doctor@clinic.com','receptionist@clinic.com','patient@gmail.com');
```

- **No `member_id`** → the login is not linked to a seat. Re-run `seed.sql`.
- **`seat` is not `active`** → `app.current_org_id()` returns null.
- **`tenant` is not `trial`/`active`** → same, by design: non-payment locks a tenant out on the
  next statement.
- **Two seats and no choice made** → `select app.set_active_organization('<org uuid>');`
- **`patient@gmail.com` sees nothing at all** → check the portal link:
  `select mrn, portal_member_id from public.patient where mrn = '108-921';`

Adding the rest of the cast (Dr. Reyes, Nurse Adams, Dr. Osei, Dr. Fontaine, a `hospital_admin`)
works the same way: create the login, then run the commented block at the end of `seed.sql` §3
with the new UID.

---

## Object storage keys

Binary content — PDFs, DICOM, images — **never** lives in a table column. Object storage holds the
bytes; the database holds metadata and a key.

**The key is tenant-first, and that is enforced by a `CHECK`, not by convention:**

```
org/<organization_id>/patient/<patient_id>/<...>/<filename>
```

`app.storage_prefix(organization_id)` produces the `org/<uuid>/` prefix, and
`app.storage_key_belongs_to(key, organization_id)` is `IMMUTABLE` so it can be used directly in a
constraint. `document.storage_key` and `invoice.pdf_storage_key` both carry it. A key that would
resolve into another hospital's namespace is a constraint violation at write time, not something a
reviewer has to notice. `unique (storage_bucket, storage_key)` on top means two rows cannot claim
one object — which would otherwise end with one document serving the other's PHI.

Bucket: `phi-documents` (private). Create it in Storage → New bucket, **not public**, and write the
bucket policy as a prefix match on `org/<the caller's organization_id>/`.

**Two checks the database cannot do for you.** Whatever signs a download URL must verify:

1. `document.scan_status = 'clean'` — the schema refuses to *analyse* an unscanned or quarantined
   file, but it cannot refuse to *serve* one, because it does not sign URLs.
2. the key prefix matches the caller's organisation.

Both belong in the API test suite. This is the one half of the no-binaries-in-columns rule that
lives outside this directory, and `030` raises a `NOTICE` saying so on every run.

---

## Testing isolation

[TESTING.md](TESTING.md) has the full copy-pasteable suite. The short version: switch to the
`authenticated` role and set the JWT claim by hand.

```sql
begin;
select set_config('request.jwt.claims',
         json_build_object('sub', (select auth_user_id from public.app_user
                                    where email = 'patient@gmail.com'),
                           'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub',
         (select auth_user_id::text from public.app_user where email = 'patient@gmail.com'), true);
set local role authenticated;

select count(*) as visible_patients from public.patient;   --> 1, her own chart only
select * from public.patient where mrn = '104-882';        --> 0 rows (Meridian's Alice, and
                                                           --   St. Luke's Rosa)
rollback;
```

`set local role authenticated` is the important line: the SQL Editor runs as `postgres`, which
**owns** every table and is therefore not subject to its own RLS. Testing policies as `postgres`
shows you everything and proves nothing.

TESTING.md covers: cross-tenant reads (§2), cross-patient reads (§3), writes attributed to someone
else (§4), the care-team boundary (§5), reception's reach (§6), the radiology-image ban as a
constraint that even `row_security = off` cannot bypass (§7), cross-tenant foreign keys and the
append-only guards (§8), vendor containment (§9), and the four CI queries (§10).

---

## Known limits

Every one of these is a decision that was deferred, not a gap nobody noticed.

**Security and access**

- **The identity seam is a deployment control.** `app.current_auth_uid()` reads an unreserved
  `request.*` GUC that any role may set, so tenant isolation holds only because PostgREST verifies
  the JWT signature. Nothing in `000`–`050` can enforce that. Stated in full under
  [Deployment prerequisites](#deployment-prerequisites-security-critical); items 4 and 5 of that
  section are repeated below because they were already known limits.
- `service_role` bypasses all of it. So does superuser, including the append-only triggers. If
  either is in your threat model, stream audit events off-box and reconcile counts.
- **`audit.event` partitions carry no RLS of their own.** The parent's policies apply when the
  parent is queried; a partition queried by name is governed by its own `relrowsecurity` flag,
  which `audit.ensure_partitions()` never sets. Nothing grants `authenticated` anything on a
  partition today, so the trail's tenant isolation currently rests on that single absence — one
  `GRANT SELECT ON ALL TABLES IN SCHEMA audit` or one `ALTER DEFAULT PRIVILEGES` and every
  hospital's trail is readable with no RLS. The fix (`ENABLE`/`FORCE` plus
  `REVOKE ALL ... FROM PUBLIC` inside `ensure_partitions()` and on `event_default`, and a CI
  assertion over `audit.event_*`) deserves its own migration; `050_hardening.sql` deliberately
  left it alone rather than rewriting a function 040 owns and schedules.
- **Break-glass is now audited, not closed.** A clinician may still add *themselves* to any care
  team in their own hospital, and `app.ensure_attending_on_care_team()` still grants a care-team
  seat to a colleague named as attending on an encounter — now restricted to an active doctor or
  nurse. Both are argued clinical needs and both raise `severity = 'alert'`. They are
  accountability controls, not barriers; 020 §26 should be read that way.
- **Read auditing is app-dependent.** Nothing in the database can record a read that nobody
  reports. Closing the gap needs a product decision (route reads through RPCs and revoke direct
  `SELECT`, at the cost of the PostgREST query interface) or an ops one (`pgaudit`).
- **Step-up authentication for vendor support sessions cannot be expressed in SQL.** It needs a
  recent-MFA claim from an auth hook. Until then a stolen vendor session can open an
  `operational` (not clinical) session.
- **Break-glass is indistinguishable from routine assignment** in the data. If you want emergency
  override to be visibly different — a reason, an alert, an automatic review —
  `care_team_member` needs a flag and the audit layer needs to treat it as a distinct event.
- **Access-token TTL is a project setting, not schema.** The staleness argument assumes it is set
  to the shortest value the project allows.
- **Alert fatigue is the real operational risk.** Every vendor write to a tenant-scoped row raises
  `severity = 'alert'`, which is correct and will also be routine. Before go-live, decide what
  routes `audit.v_alerts` to a human. An alert feed nobody reads is worse than none, because it
  looks like a control.

**Data model**

- **"No known allergies" and "not asked" are indistinguishable** — an empty `patient_allergy` list
  means both. No screen shows the distinction so nothing was invented, but resolve it before this
  schema is used for real prescribing.
- **Amendment is modelled; the amendment *procedure* is not.** `supersedes_id` +
  `record_status` describe the end state, but nothing forces the predecessor to be marked
  `amended` in the same transaction. That belongs in an RPC (`amend_lab_result`, `amend_note`).
  Until then a client can leave two `active` rows in a chain.
- **Patient merge is modelled as state, not as an operation.** Decide before the first merge
  whether the loser's clinical rows are re-pointed (rewrites history) or the chain is followed at
  read time (every chart query gets more complex). Nothing follows the chain today.
- **MRN, invoice number and queue-ticket allocation are left to the app**, and all three race the
  same way: two clerks read `max + 1` in the same second. The unique index makes one fail rather
  than duplicate — the right failure — but the app must retry, or allocation moves into an RPC
  taking a per-tenant advisory lock. A sequence would fix it and needs a format decision first
  (the UI shows `104-882`, `INV-2241`).
- **Retention and erasure are unwritten.** Nothing expires. `app.deny_hard_delete()`'s escape
  hatch (`SET LOCAL app.allow_hard_delete = 'on'`) is the intended door for a lawful erasure job,
  but the job — and its object-storage half — does not exist.
  `audit.drop_partitions_before(cutoff, dry_run => true)` exists and defaults to dry-run; how long
  to keep audit data is not decided.
- **`pgvector` pins `vector(1536)`.** Change it before any rows exist if you pick a different
  embedding model. Chunk text and embedding share one table, so running two embedding models at
  once duplicates the text — acceptable during a model migration.

**Product decisions still open**

- **Currency.** The prototype prints `$` on every amount; the schema defaults to `INR` because the
  operator is in India, and the seed stores the mock's numbers as rupees in paise. One of the two
  is wrong and it is a product call. Currency is per-invoice, so either answer works.
- **The mock's CPT code `71260`** on "CT scan, chest" is a US code set. `invoice_line.code_system`
  records it explicitly as `'cpt'` so the mismatch is visible; re-code before go-live.
- **Invoice status can disagree with the computed balance.** Status is set by the front desk;
  balance is arithmetic in `app.v_invoice_balance`. A trigger could force the transition but would
  overrule a receptionist who has a reason. Recommendation: leave it manual and add "status
  disagrees with balance" to the Billing screen as a worklist filter.
- **"Require confirmation before adding AI notes to chart"** is implemented as an unconditional
  invariant, not a switchable preference. If the intent is genuinely "auto-accept my AI notes",
  that is a real weakening of a safety control on health records: it would need to be an
  organisation-level entitlement with an audit trail, and someone should decide whether it is
  offered at all. It must not become a boolean column.
- **The login screen prints "HIPAA compliant · SOC 2 Type II".** Neither claim is substantiated
  anywhere in this repository. See below.

**Verification**

- **This schema has been reviewed statically, not executed.** There is no PostgreSQL, `psql` or
  Docker on the machine it was assembled on. Dollar-quote tags are balanced, every `app.*` call
  resolves to a definition in an earlier file, and every composite foreign key matches a declared
  unique key on its parent — but nothing has been run. **Apply it to a scratch project first**,
  read every `NOTICE`, and run TESTING.md §10 before trusting any of it.
- After the first run, confirm the double-booking constraint actually exists:
  `select conname from pg_constraint where conname = 'appointment_no_double_book_ck';`
  If it is missing, `btree_gist` was unavailable and 020 downgraded to a `WARNING`.

---

## Compliance posture

**Deliberately modest, and not legal advice.**

The operator is in India, so the governing regime here is the **Digital Personal Data Protection
Act, 2023 (DPDP)** — **not HIPAA**. HIPAA is US law; it does not apply, and nothing in this
repository should be read as claiming it does. If Prognosify is later sold into the US or the EU,
that is a separate legal analysis and probably a separate deployment.

What this schema actually implements is ordinary security engineering: tenant isolation as the
primary boundary, least privilege, an append-only audit trail, and erasure that is possible but
deliberate rather than accidental. Under the DPDP Act a hospital is most plausibly the **data
fiduciary** and Prognosify a **data processor** acting on its instructions — which is the reasoning
behind the vendor containment model in 010 §7, and is also why standing vendor access to charts is
refused by construction rather than by policy.

**Two things to be clear about:**

1. **Confirm the specific obligations with someone current.** Whether any of this satisfies a
   particular DPDP requirement — notice and consent, breach notification timelines, the rights of a
   data principal, cross-border transfer rules, whether health data attracts additional duties,
   what "erasure" means for a medical record you are also required to retain — is a question for
   counsel who follows the rules and the notifications as they are issued. Do not take the specific
   obligations from this document. Nothing here is a certification claim, and the retention periods
   are deliberately left blank rather than guessed.

2. **A free or hobby tier is not an appropriate home for real patient data.** Say it plainly: it is
   fine for this demo seed and for development. It is not fine for a live hospital. Free tiers pause
   or reclaim projects, offer no backup guarantees you can rely on, no point-in-time recovery, no
   uptime commitment, and no contractual data-processing terms — and a database of health records
   with no recovery story is not a system, it is an incident waiting for a date. Before a single
   real patient is registered: a paid plan with point-in-time recovery, a written and *tested*
   restore procedure, a signed data-processing agreement with the hosting provider, MFA on every
   account that can reach the project, and the `service_role` key held somewhere that is not a
   `.env` file on a laptop.

The login screen's "HIPAA compliant · SOC 2 Type II" badges should come out until they are true.
Unsubstantiated compliance claims are their own category of risk, separate from anything the
database can enforce.
