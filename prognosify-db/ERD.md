# Prognosify entity model

43 tables in five layers. Every relationship drawn below that crosses into tenant data is a
**composite** foreign key on `(parent_id, organization_id)`, not on `parent_id` alone — which is
what turns a cross-tenant reference into a foreign-key violation instead of a code-review finding.

Columns shown are the ones that carry meaning for the model: keys, the tenant discriminator, and
the fields the 20 screens actually read. Enums, CHECK constraints, timestamps and audit columns are
in the migrations.

---

## 1. Tenancy, identity and access

The layer everything else hangs off. `organization` is the tenant; `app_user` is a person;
`organization_member` is that person's seat in one hospital and is `staff_id` everywhere downstream.
`platform_admin` is the vendor side and holds no organisation, ever — which is what contains
`super_admin` by default.

```mermaid
erDiagram
    SUBSCRIPTION_PLAN {
        uuid id PK
        text code UK "trial | essentials | clinical_ai | enterprise"
        text name
        boolean is_active
    }
    FEATURE {
        text key PK "patient_portal, ai_prognosis, billing, sso, staff_seats"
        text name
        enum kind "flag | limit"
    }
    PLAN_FEATURE {
        uuid plan_id PK,FK
        text feature_key PK,FK
        boolean enabled
        integer limit_value
    }
    ORGANIZATION {
        uuid id PK "THE TENANT"
        text slug UK
        text name
        enum status "trial | active | suspended | closed"
        text region "ap-south-1"
        text timezone "Asia/Kolkata"
        uuid plan_id FK
        timestamptz trial_ends_at
        jsonb settings "never read in a policy"
    }
    ORGANIZATION_ENTITLEMENT {
        uuid organization_id PK,FK
        text feature_key PK,FK
        boolean enabled
        integer limit_value
        timestamptz effective_from
        timestamptz effective_to "expires with no cron job"
    }
    APP_USER {
        uuid id PK
        uuid auth_user_id UK "FK to auth.users (GoTrue)"
        text email UK
        text full_name
        enum status
        uuid active_organization_id FK "a preference, never a grant"
    }
    ORGANIZATION_MEMBER {
        uuid id PK "= staff_id everywhere downstream"
        uuid organization_id FK
        uuid app_user_id FK
        uuid auth_user_id "cached join key, FK-enforced"
        array roles "hospital_admin|doctor|nurse|receptionist|patient"
        enum status "invited | active | suspended | revoked"
        text job_title
        text license_number
    }
    PLATFORM_ADMIN {
        uuid id PK "the VENDOR. no organization, ever"
        uuid app_user_id FK
        text reason
        timestamptz revoked_at
    }
    SUPPORT_SESSION {
        uuid id PK
        uuid organization_id FK "ONE named tenant"
        uuid platform_admin_id FK
        enum scope "operational | phi"
        text reason "min 20 chars"
        text ticket_ref "required for phi"
        uuid approved_by_member_id FK "a hospital_admin of THAT tenant"
        timestamptz expires_at "hard 8h ceiling"
    }
    PATIENT {
        uuid id PK
        uuid organization_id FK
        text mrn "UNIQUE per organization, never globally"
        text first_name
        text last_name
        date date_of_birth
        enum sex
        enum status "active|inactive|deceased|merged"
        uuid merged_into_patient_id FK "the duplicate warning resolves here"
        uuid portal_member_id FK "the seat, if they ever logged in"
    }

    SUBSCRIPTION_PLAN ||--o{ PLAN_FEATURE : "default per feature"
    FEATURE           ||--o{ PLAN_FEATURE : "registry gate"
    SUBSCRIPTION_PLAN ||--o{ ORGANIZATION : "is on plan"
    ORGANIZATION      ||--o{ ORGANIZATION_ENTITLEMENT : "per-tenant override"
    FEATURE           ||--o{ ORGANIZATION_ENTITLEMENT : "must be registered"
    ORGANIZATION      ||--o{ ORGANIZATION_MEMBER : "has seats"
    APP_USER          ||--o{ ORGANIZATION_MEMBER : "one person, many hospitals"
    APP_USER          ||--o| PLATFORM_ADMIN : "vendor operator"
    PLATFORM_ADMIN    ||--o{ SUPPORT_SESSION : "opens"
    ORGANIZATION      ||--o{ SUPPORT_SESSION : "grants time-boxed access to"
    ORGANIZATION_MEMBER ||--o| SUPPORT_SESSION : "hospital_admin approves phi scope"
    ORGANIZATION      ||--o{ PATIENT : "owns the chart"
    ORGANIZATION_MEMBER ||--o| PATIENT : "portal login"
    PATIENT           ||--o| PATIENT : "merged into"
```

**Why entitlements are three tables and not a `jsonb` blob.** A blob has no key registry, so
`ai_prognosis` and `ai-prognosis` are both "valid" and one silently fails — open is a billing leak,
closed is a support ticket at 2am. The Super Admin screen also has to *render* a list of features to
toggle: with a catalogue that is a `SELECT`, with a blob it is a hard-coded frontend array that
drifts. And a per-tenant override needs a validity window, a grantor and a note. Those are columns.

---

## 2. Hospital configuration and the clinical core

`department` is owned by 020 and extended by 040 — one table, one definition. Care-team membership is
both the "Care team" card on the patient screen **and** the access-control spine behind
`app.care_patient_ids()`; those being the same table is the point.

```mermaid
erDiagram
    ORGANIZATION {
        uuid id PK
        text slug
    }
    ORGANIZATION_MEMBER {
        uuid id PK "staff_id"
        uuid organization_id FK
        array roles
    }
    PATIENT {
        uuid id PK
        uuid organization_id FK
        text mrn
    }
    DEPARTMENT {
        uuid id PK
        uuid organization_id FK
        text code UK "per tenant"
        text name "Cardiology, Radiology, Gen. medicine, Pediatrics"
        integer daily_slot_capacity "denominator of Clinic load today"
        boolean is_active "retire, never delete"
    }
    VISIT_TYPE {
        uuid id PK
        uuid organization_id FK
        text code UK "per tenant"
        text name "Diabetes follow-up, Post-op consult, Annual physical"
        integer default_duration_minutes "pre-selects 15/30/45"
        enum default_modality "in_person | video | phone"
    }
    STAFF_PROFILE {
        uuid member_id PK,FK "one row per staff seat; patients have none"
        uuid organization_id FK
        uuid department_id FK "THE single department assignment"
        text specialty "free text: lists are long, local, revised"
        text default_room "Clinic 2"
        boolean accepts_bookings "filters the provider picker"
    }
    PATIENT_CONDITION {
        uuid id PK
        uuid organization_id FK
        uuid patient_id FK
        text name "Pneumonia, CHF, Type 2 diabetes, CKD stage 3"
        text code "free for ICD-10 or SNOMED later"
        enum clinical_status "active | resolved | inactive"
        boolean is_primary "at most one active primary per patient"
        uuid recorded_by FK
        enum record_status "active | amended | entered_in_error"
    }
    PATIENT_ALLERGY {
        uuid id PK
        uuid organization_id FK
        uuid patient_id FK
        text substance "Penicillin"
        enum category
        enum severity "unknown is a real answer, and the default"
        timestamptz inactivated_at "never deleted: wrong and never-recorded must differ"
        text inactivated_reason
    }
    CARE_TEAM_MEMBER {
        uuid id PK "ACCESS-CONTROL SPINE"
        uuid organization_id FK
        uuid patient_id FK
        uuid member_id FK
        enum role "attending|resident|consulting|nurse|care_coordinator"
        text assignment_note "Ward 4"
        timestamptz ended_at "assignments end; rows never delete"
        uuid added_by FK
    }
    ENCOUNTER {
        uuid id PK "an episode that HAPPENED"
        uuid organization_id FK
        uuid patient_id FK
        enum class "inpatient|outpatient|emergency|observation|virtual"
        enum status "planned|in_progress|discharged|cancelled"
        uuid department_id FK
        uuid attending_member_id FK "trigger puts them on the care team"
        text room_label "Rm 412 — text, there is no room table"
        text reason
        timestamptz started_at "Admitted Aug 13 / Last visit"
        timestamptz ended_at
    }
    APPOINTMENT {
        uuid id PK "an INTENTION, plus the front-desk queue"
        uuid organization_id FK
        uuid patient_id FK "NULL for a calendar block"
        text block_title "Ward rounds / MDT conference"
        uuid encounter_id FK "NULL until actually seen"
        uuid provider_member_id FK "NULL only for an untriaged walk-in"
        uuid department_id FK
        uuid visit_type_id FK
        enum status "booked|waiting|in_room|done|cancelled|no_show"
        enum origin "scheduled | walk_in"
        timestamptz scheduled_start
        date queue_date "ticket restarts each clinic day"
        integer queue_ticket
        timestamptz checked_in_at "waiting 32 min is computed, never stored"
    }
    VITAL_SIGN {
        uuid id PK
        uuid organization_id FK
        uuid patient_id FK
        uuid encounter_id FK
        timestamptz measured_at
        smallint heart_rate_bpm "104"
        smallint systolic_mmhg "96 — two columns, never the string 96/61"
        smallint diastolic_mmhg "61"
        numeric temperature_c "38.4"
        smallint spo2_percent "93"
        smallint respiratory_rate_bpm
        text supplemental_o2 "2L NC, in the nurse's own words"
        uuid supersedes_id FK "append-only: correct by superseding"
    }

    ORGANIZATION      ||--o{ DEPARTMENT : has
    ORGANIZATION      ||--o{ VISIT_TYPE : has
    ORGANIZATION_MEMBER ||--o| STAFF_PROFILE : "practice attributes"
    DEPARTMENT        ||--o{ STAFF_PROFILE : "practises in"
    PATIENT           ||--o{ PATIENT_CONDITION : "problem list"
    PATIENT           ||--o{ PATIENT_ALLERGY : "what will hurt them"
    PATIENT           ||--o{ CARE_TEAM_MEMBER : "who may open this chart"
    ORGANIZATION_MEMBER ||--o{ CARE_TEAM_MEMBER : "is assigned to"
    PATIENT           ||--o{ ENCOUNTER : "episodes of care"
    DEPARTMENT        ||--o{ ENCOUNTER : "under"
    ORGANIZATION_MEMBER ||--o{ ENCOUNTER : "attends"
    PATIENT           ||--o{ APPOINTMENT : "scheduled visits"
    ENCOUNTER         ||--o| APPOINTMENT : "produced"
    ORGANIZATION_MEMBER ||--o{ APPOINTMENT : "provides"
    DEPARTMENT        ||--o{ APPOINTMENT : "in"
    VISIT_TYPE        ||--o{ APPOINTMENT : "of type"
    PATIENT           ||--o{ VITAL_SIGN : observed
    ENCOUNTER         ||--o{ VITAL_SIGN : during
    VITAL_SIGN        ||--o| VITAL_SIGN : supersedes
```

**One table serves the doctor's Schedule grid, Next arrivals, the Check-in queue tabs, the Booking
slot grid and the portal's Next-appointment card.** They are the same row at different moments of
its life. Splitting them would mean keeping two copies of one state in sync, which is how a patient
ends up checked in on one screen and a no-show on another. Non-patient calendar blocks live here too
(`patient_id` NULL + `block_title`), so the provider double-booking exclusion constraint protects
them as well.

---

## 3. Labs, notes and medications

```mermaid
erDiagram
    PATIENT {
        uuid id PK
        text mrn
    }
    ENCOUNTER {
        uuid id PK
        enum class
    }
    ORGANIZATION_MEMBER {
        uuid id PK
        array roles
    }
    LAB_PANEL {
        uuid id PK "what can be ORDERED"
        uuid organization_id FK
        text code UK "per tenant"
        text name "Lactate repeat, ABG, BNP renal panel, Echo report"
        uuid department_id FK
    }
    LAB_TEST {
        uuid id PK "the ANALYTE catalogue"
        uuid organization_id FK "ranges are laboratory-specific"
        text code UK "per tenant"
        text name "Lactate, WBC, CRP, Creatinine, HbA1c, eGFR"
        text default_unit
        numeric reference_low "NULL + high 5 renders < 5"
        numeric reference_high
        numeric critical_low "panic value, NOT derived from the range"
        numeric critical_high
    }
    LAB_ORDER {
        uuid id PK "a request. tracks the SPECIMEN"
        uuid organization_id FK
        uuid patient_id FK
        uuid encounter_id FK
        uuid panel_id FK
        uuid ordered_by FK
        enum priority "routine | urgent | stat"
        enum status "ordered|collected|in_progress|resulted|cancelled"
        timestamptz collected_at
    }
    LAB_RESULT {
        uuid id PK "one analyte value"
        uuid organization_id FK
        uuid lab_order_id FK
        uuid patient_id FK "FK-proven against the order, not a hopeful copy"
        uuid lab_test_id FK
        numeric value_numeric "3.1"
        text value_text
        text unit "mmol/L"
        numeric reference_low "copied at report time"
        numeric reference_high
        enum abnormal_flag "normal|low|high|critical_low|critical_high|indeterminate"
        enum review_status "unreviewed | acknowledged | reviewed"
        uuid reviewed_by FK
        timestamptz released_to_patient_at "portal release, per row"
        uuid supersedes_id FK "a corrected value is a NEW row"
    }
    CLINICAL_NOTE {
        uuid id PK "the Timeline's prose entries"
        uuid organization_id FK
        uuid patient_id FK
        uuid encounter_id FK
        uuid author_member_id FK
        enum note_type "admission|progress|nursing|procedure|discharge|telephone"
        timestamptz occurred_at
        text body
        timestamptz signed_at "NULL = draft, editable by its author only"
        uuid supersedes_id FK
        text amendment_reason "required when superseding"
    }
    MEDICATION_ORDER {
        uuid id PK
        uuid organization_id FK
        uuid patient_id FK
        uuid encounter_id FK
        uuid prescriber_member_id FK "doctor only"
        text drug_name "Ceftriaxone"
        text dose_text "1 g"
        enum route "oral|intravenous|inhaled|..."
        text frequency_text "q24h / PRN / with breakfast — not an enum"
        boolean is_prn
        enum status "active|on_hold|completed|discontinued"
        timestamptz refill_requested_at "the ONLY column a patient may write"
    }

    LAB_PANEL ||--o{ LAB_ORDER : "requested as"
    PATIENT   ||--o{ LAB_ORDER : for
    ENCOUNTER ||--o{ LAB_ORDER : during
    ORGANIZATION_MEMBER ||--o{ LAB_ORDER : orders
    LAB_ORDER ||--o{ LAB_RESULT : produced
    LAB_TEST  ||--o{ LAB_RESULT : "measures"
    PATIENT   ||--o{ LAB_RESULT : about
    ORGANIZATION_MEMBER ||--o{ LAB_RESULT : reviews
    LAB_RESULT ||--o| LAB_RESULT : supersedes
    PATIENT   ||--o{ CLINICAL_NOTE : about
    ENCOUNTER ||--o{ CLINICAL_NOTE : during
    ORGANIZATION_MEMBER ||--o{ CLINICAL_NOTE : authors
    CLINICAL_NOTE ||--o| CLINICAL_NOTE : amends
    PATIENT   ||--o{ MEDICATION_ORDER : prescribed
    ENCOUNTER ||--o{ MEDICATION_ORDER : during
    ORGANIZATION_MEMBER ||--o{ MEDICATION_ORDER : prescribes
```

**Not modelled, each a decision:** panel↔test membership (nothing displays a panel's expected
contents, and results arrive with their own analyte identity from the analyser); a drug master
(no formulary, no code system, no interaction data — an empty catalogue filled with free text as
you go is worse than honest free text, because it looks authoritative); the eMAR (nothing in the app
records an individual administration).

---

## 4. Documents and AI output

The AI layer's shape is driven by two rules. **Provenance:** model name, version and prompt version
are `NOT NULL` on every run, because a result you cannot attribute to a model version cannot be
re-examined after the model changes. **Review:** nothing AI-generated reaches a chart or a phone
without a named human accepting it, and that is a `CHECK` constraint rather than application logic.

```mermaid
erDiagram
    PATIENT {
        uuid id PK
        text mrn
    }
    ORGANIZATION_MEMBER {
        uuid id PK
    }
    DOCUMENT {
        uuid id PK
        uuid organization_id FK
        uuid patient_id FK "every document here is about a patient"
        uuid uploaded_by_member_id FK
        enum source "patient_upload|staff_upload|device_feed|external_interface|system_generated"
        text file_name "a label, never a path"
        text mime_type
        bigint byte_size
        text checksum_sha256
        text storage_bucket "phi-documents"
        text storage_key "CHECK: must start with org/<organization_id>/"
        enum scan_status "pending|scanning|clean|quarantined|failed"
        text scanner "clamav 1.2.1 — name AND version"
        enum doc_type "lab_report|radiology_report|RADIOLOGY_IMAGE|scanned_document|..."
        enum doc_type_source "model | human"
        numeric doc_type_confidence
        uuid doc_type_confirmed_by_member_id FK
        boolean patient_visible "portal release, explicit"
        timestamptz retracted_at "never deleted; wrong-patient upload is retracted"
    }
    DOCUMENT_TEXT {
        uuid id PK "kept apart from the source it came from"
        uuid organization_id FK
        uuid document_id FK
        uuid patient_id FK "denormalised so the care-team policy needs no join"
        enum method "pdf_text_layer|ocr|dicom_header|manual_transcription|vendor_api"
        enum status "succeeded | partial | failed"
        text engine "name AND version"
        numeric confidence "mandatory for OCR"
        text content
        tsvector search_tsv "generated: lexical search, no extension needed"
        timestamptz superseded_at "two methods may be current at once"
    }
    DOCUMENT_TEXT_CHUNK {
        uuid id PK "OPTIONAL — only if pgvector is available"
        uuid organization_id FK "an unscoped ANN index is a leak with a friendly API"
        uuid document_text_id FK
        uuid patient_id FK
        integer chunk_index
        text content
        text embedding_model "vectors from different models are not comparable"
        vector embedding "vector(1536)"
    }
    AI_ANALYSIS_RUN {
        uuid id PK "ONE model call"
        uuid organization_id FK
        uuid patient_id FK "NULL only for a panel_brief"
        uuid document_id FK
        uuid document_text_id FK "the EXACT extraction that was fed in"
        enum kind "prognosis|interpretation|summarization|lab_note|plain_language|panel_brief|metadata_index"
        enum status "queued|running|succeeded|failed|refused"
        text model_provider "NOT NULL"
        text model_name "NOT NULL"
        text model_version "NOT NULL — v4.2"
        text prompt_version "NOT NULL"
        jsonb config "decoding params, for reproducibility"
        integer latency_ms
        integer input_tokens
        bigint cost_micros
        enum source_document_type "TRIGGER-MAINTAINED copy: lets the image ban be a CHECK"
    }
    AI_FINDING {
        uuid id PK
        uuid organization_id FK
        uuid run_id FK
        uuid patient_id FK "inherited from the run by trigger"
        enum kind "risk_summary|recommended_action|plain_language_explanation|lab_note|brief"
        enum severity "info|low|medium|high|critical"
        text title "Repeat lactate within 2h"
        text detail
        numeric confidence "0.920 renders as 92% conf."
        enum review_state "pending | accepted | rejected | amended"
        uuid reviewed_by_member_id FK
        text amended_text "the model's words are kept beside the clinician's"
        boolean patient_visible "CHECK: reviewed AND patient-scoped"
        timestamptz chart_committed_at "CHECK: accepted or amended only"
    }
    AI_RISK_SCORE {
        uuid id PK
        uuid organization_id FK
        uuid run_id FK
        uuid patient_id FK
        enum risk_type "sepsis|icu_transfer|length_of_stay|readmission_30d|post_op_infection|glycemic_control"
        enum value_kind "probability | range"
        interval horizon "48h — a probability without one is refused"
        numeric probability "0.9200 -> 92%"
        numeric range_low "9.00 -> 9-12 days"
        numeric range_high "12.00"
        enum band "low|medium|high|critical — STORED, not recomputed"
        numeric change_points "14 -> up 14 pts"
        text change_note "since admission"
        numeric baseline_low "vs. 5-7 day cohort median"
        timestamptz as_of "the 72h trajectory chart is these rows ordered by as_of"
    }
    AI_RISK_FACTOR {
        uuid id PK
        uuid organization_id FK
        uuid risk_score_id FK
        text label "Lactate 3.1, rising"
        numeric weight "SIGNED: +0.310 ... -0.090"
        numeric normalized_magnitude "the bar width"
        integer display_order UK "per score"
    }
    AI_CITATION {
        uuid id PK "exactly ONE subject, exactly ONE source shape"
        uuid organization_id FK
        uuid finding_id FK
        uuid risk_score_id FK
        uuid risk_factor_id FK
        enum source_kind "document_text_span|document_page_region|clinical_value|prior_finding|model_knowledge"
        uuid document_text_id FK
        integer char_start "with quoted_text snapshot"
        uuid document_id FK
        integer page_number "with bounding_box"
        text source_table "SOFT ref into 020, allowlisted"
        uuid source_row_id
        text observed_value "3.1 mmol/L, as DISPLAYED when cited"
        uuid prior_finding_id FK
    }

    PATIENT   ||--o{ DOCUMENT : about
    ORGANIZATION_MEMBER ||--o{ DOCUMENT : uploads
    DOCUMENT  ||--o{ DOCUMENT_TEXT : "extracted from"
    DOCUMENT_TEXT ||--o{ DOCUMENT_TEXT_CHUNK : "embedded as"
    DOCUMENT  ||--o{ AI_ANALYSIS_RUN : "read by"
    DOCUMENT_TEXT ||--o{ AI_ANALYSIS_RUN : "the exact input"
    PATIENT   ||--o{ AI_ANALYSIS_RUN : about
    ORGANIZATION_MEMBER ||--o{ AI_ANALYSIS_RUN : requests
    AI_ANALYSIS_RUN ||--o{ AI_FINDING : produced
    AI_ANALYSIS_RUN ||--o{ AI_RISK_SCORE : produced
    AI_RISK_SCORE ||--o{ AI_RISK_FACTOR : "contributing bars"
    ORGANIZATION_MEMBER ||--o{ AI_FINDING : reviews
    AI_FINDING    ||--o{ AI_CITATION : "rests on"
    AI_RISK_SCORE ||--o{ AI_CITATION : "rests on"
    AI_RISK_FACTOR ||--o{ AI_CITATION : "rests on"
    AI_FINDING    ||--o{ AI_CITATION : "prior finding"
    DOCUMENT_TEXT ||--o{ AI_CITATION : "quoted span"
    DOCUMENT      ||--o{ AI_CITATION : "page region"
```

**The radiology-image ban, and why it is a constraint.** `ai_analysis_run.source_document_type` is a
trigger-maintained copy of the source document's type, which lets the rule be a table `CHECK`:
a run whose source is a `radiology_image` may only be the non-interpretive `metadata_index`. Written
as an **allowlist** (`kind = 'metadata_index'`) rather than a denylist, because enums grow and a
denylist fails *open* on the next value somebody adds. An unclassified document (`doc_type` NULL) is
treated exactly like an image — an unknown file might *be* one, so it fails closed. Being a `CHECK`
rather than a policy means it binds the web session, the model worker, a `service_role` script and a
superuser at `psql` alike.

**Why `model_knowledge` is a citation kind.** It is the honest "no patient-specific evidence" case,
and it is constrained so it cannot smuggle in a fake pointer. A finding with no citation at all is
not blocked — `app.v_ai_uncited_findings` counts them instead, because if that number climbs the
prompt has stopped grounding its answers.

---

## 5. Admin, billing and the audit trail

```mermaid
erDiagram
    ORGANIZATION {
        uuid id PK
        text slug
    }
    ORGANIZATION_MEMBER {
        uuid id PK
        array roles
    }
    PATIENT {
        uuid id PK
        text mrn
    }
    DEPARTMENT {
        uuid id PK
        text name
    }
    ORG_SETTING {
        uuid id PK "hospital default AND personal override, one table"
        uuid organization_id FK
        uuid member_id FK "NULL = the hospital default"
        text key "ai.risk_flags_on_lists / ai.confirm_before_chart"
        jsonb value "never read in a policy: customer-writable"
        uuid updated_by FK
    }
    PAYER {
        uuid id PK
        uuid organization_id FK "each hospital negotiates its own panel"
        enum kind "insurer|tpa|government|corporate|self_pay"
        text code UK "per tenant"
        text name
    }
    PATIENT_COVERAGE {
        uuid id PK "step 2 of Register: Identity - Insurance - Consent"
        uuid organization_id FK
        uuid patient_id FK
        uuid payer_id FK
        enum priority "primary | secondary | tertiary"
        text member_number "REDACTED from the audit trail"
        text group_number "REDACTED from the audit trail"
        date valid_from
        boolean is_active "one active primary per patient"
    }
    INVOICE {
        uuid id PK "carries NO clinical text"
        uuid organization_id FK
        uuid patient_id FK
        text number UK "INV-2241, per tenant"
        enum status "copay_due|auth_missing|covered|overdue|draft|paid|written_off|void"
        char currency "INR — per invoice, not global"
        bigint total_minor "minor units. never float"
        bigint patient_due_minor
        uuid coverage_id FK
        uuid payer_id FK
        boolean prior_auth_required "auth_missing means this AND no ref"
        boolean denial_risk_flag "the Claims at denial risk (AI) tile"
        numeric denial_risk_score
        text denial_model_version "so an AI claim can be re-examined"
        text pdf_storage_key "CHECK: tenant-scoped"
    }
    INVOICE_LINE {
        uuid id PK "the clinically revealing half of a bill"
        uuid organization_id FK
        uuid invoice_id FK
        integer line_no UK "per invoice"
        text description "CT scan, chest"
        text service_code "71260"
        text code_system "local|cpt|icd10|snomed|cghs — explicit, CPT is US"
        uuid department_id FK
        bigint amount_minor "a correction is a NEW negative line"
    }
    PAYMENT {
        uuid id PK "money actually received"
        uuid organization_id FK
        uuid invoice_id FK "denominated in ITS currency by construction"
        bigint amount_minor "SIGNED: a refund is negative"
        enum method "cash|card|upi|netbanking|cheque|insurance|adjustment"
        uuid reverses_payment_id FK
        timestamptz received_at
        uuid received_by FK
    }
    USAGE_METRIC {
        text key PK "staff_seats_used, patients_active, ai_reports, documents"
        text name
        text unit "count | bytes | minutes"
    }
    ORGANIZATION_USAGE_DAILY {
        uuid organization_id PK,FK
        date usage_date PK
        text metric_key PK,FK
        bigint metric_value "a counter that can hold a string will hold a patient name"
    }
    AUDIT_EVENT {
        uuid id PK "APPEND-ONLY. monthly range partitions + DEFAULT"
        bigint seq "monotonic: a gap is detectable, a uuid gap is not"
        timestamptz occurred_at PK
        uuid actor_app_user_id
        uuid actor_org_id "the organisation they were ACTING IN"
        array actor_roles
        enum acting_role "app-declared. NULL means the app did not say"
        name actor_db_role "authenticated vs service_role"
        boolean actor_is_vendor
        uuid support_session_id
        enum action "insert|update|delete|read|export|login|role_change|support_open|..."
        enum severity "normal | sensitive | alert"
        enum purpose "treatment|front_desk|billing|patient_self|admin|support|compliance"
        name table_name
        uuid row_id
        uuid organization_id "the tenant that OWNS the row"
        uuid patient_id
        array changed_columns
        jsonb old_values "changed columns only, redaction applied"
        jsonb new_values
        inet client_ip
        uuid request_id
    }
    AUDIT_REDACTED_COLUMN {
        name table_schema PK
        name table_name PK
        name column_name PK "auth_user_id, member_number, group_number"
        text reason "the CHANGE stays auditable; the VALUE is never recorded"
    }

    ORGANIZATION ||--o{ ORG_SETTING : "hospital defaults"
    ORGANIZATION_MEMBER ||--o{ ORG_SETTING : "personal overrides"
    ORGANIZATION ||--o{ PAYER : "negotiates with"
    PATIENT      ||--o{ PATIENT_COVERAGE : "is covered by"
    PAYER        ||--o{ PATIENT_COVERAGE : "issues"
    PATIENT      ||--o{ INVOICE : "is billed"
    PATIENT_COVERAGE ||--o| INVOICE : "settles"
    PAYER        ||--o{ INVOICE : "settles"
    INVOICE      ||--o{ INVOICE_LINE : "itemised as"
    DEPARTMENT   ||--o{ INVOICE_LINE : "delivered by"
    INVOICE      ||--o{ PAYMENT : "paid by"
    PAYMENT      ||--o| PAYMENT : reverses
    ORGANIZATION ||--o{ ORGANIZATION_USAGE_DAILY : "counted daily"
    USAGE_METRIC ||--o{ ORGANIZATION_USAGE_DAILY : "registered key"
    ORGANIZATION ||--o{ AUDIT_EVENT : "the tenant that owns the row"
    PATIENT      ||--o{ AUDIT_EVENT : "about"
    AUDIT_REDACTED_COLUMN ||--o{ AUDIT_EVENT : "governs old_values / new_values"
```

**`actor_org_id` versus `organization_id` is the most important pair in the schema.** One is the
organisation the actor was acting in; the other is the tenant that owns the affected row. The two
differing **is** the definition of cross-tenant access, and `audit.v_cross_tenant_access` is exactly
that comparison. For an ordinary user that view must be empty — 010's policies make it structurally
impossible. Vendor rows appear there by design; what deserves a human is a row where
`explained_by_support_session` is false and the table is not commercial metadata.

**`organization_usage_daily` is the one table whose SELECT policy says `OR app.is_super_admin()`,**
and that is safe structurally rather than by policy discipline: every column is a tenant id, a date,
a registered key or a `bigint`. A count of patients is not a patient. It is also how the vendor
dashboard exists at all without granting the vendor a policy on `public.patient` — the counting
happens on a schedule, in one `SECURITY DEFINER` function, and what it leaves behind is arithmetic.

---

## Read surfaces

Views rather than tables, all declared `security_invoker` so the underlying policies still decide
which rows come back. They narrow **columns** and shape output; they never widen access.

| View | Screen |
|---|---|
| `public.v_front_desk_patient` | Register / Booking / Check-in — administrative columns only, no condition, no result, no note |
| `public.v_checkin_queue` | Check-in queue tabs, with live `waiting_minutes` |
| `public.v_patient_summary` | the doctor's Patients table: status, room, primary condition, last visit |
| `public.v_lab_review_queue` | the Labs screen, with the reference range already formatted as the UI prints it |
| `public.v_patient_timeline` | the Timeline card — notes, results, encounters and medication starts, assembled from the owning tables rather than copied |
| `app.v_invoice_balance` | the Billing screen's arithmetic: paid, outstanding, days overdue |
| `app.v_tenant_health` | the Super Admin tenant list — every figure from counters, never a live count of clinical rows |
| `app.v_effective_entitlement` | resolved feature flags per tenant |
| `app.v_ai_uncited_findings` | findings nobody can check — a number to watch, not a constraint |
| `audit.v_cross_tenant_access` | the alert this whole design exists to make unmissable |
| `audit.v_alerts`, `audit.v_read_coverage` | the feed a human reads; and how much the app is actually reporting |
| `app.v_tenant_rls_gaps`, `app.v_super_admin_policy_review`, `audit.v_unaudited_tenant_tables` | CI checks over `pg_catalog` — no tenant data, hence no `security_invoker` |
