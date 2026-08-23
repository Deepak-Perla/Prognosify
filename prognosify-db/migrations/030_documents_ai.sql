-- =============================================================================================
-- 030_documents_ai.sql — Prognosify documents and AI output, multi-tenant
-- PostgreSQL 15+ / Supabase (ap-south-1). Idempotent: safe to re-run.
--
-- DEPENDS ON 010_tenancy_identity.sql. Read that file first. This one creates no tenants, no
-- identities, no roles and no helper functions of its own beyond five triggers; it uses the
-- exported app.* API and follows the five house rules verbatim.
--
-- REPLACES the single-tenant draft 002_documents_ai.sql. That file (and 001/003/004) must be
-- out of the migration path before 010 runs — see 010's header for why.
--
-- WHAT THIS FILE OWNS
--   public.document              the upload: who, for whom, bytes-in-object-storage metadata,
--                                virus scan state, type classification and human confirmation
--   public.document_text         extracted text, kept apart from the source it came from
--   public.ai_analysis_run       one model call: model NAME AND VERSION, prompt version,
--                                timing, tokens, cost, and the source it was allowed to read
--   public.ai_finding            structured output + the MANDATORY human review state
--   public.ai_risk_score         the numbers the prognosis screen prints (92% / 48h, 9-12 days)
--   public.ai_risk_factor        the weighted contributing bars (+0.31 lactate … -0.09 abx)
--   public.ai_citation           what any of the above rests on, back to a span or a value
--   public.document_text_chunk   OPTIONAL pgvector section, §11, created only if available
--
-- WHAT THIS FILE DOES NOT OWN
--   patients (010), encounters/labs/vitals/notes/appointments (020), audit trail (040).
--   Citations into 020's clinical rows are deliberately SOFT references — see §8.
--
-- THE SAFETY RULE, STATED ONCE AND ENFORCED IN §5
--   Raw radiology IMAGES are never sent to a general-purpose model for interpretation. Only the
--   radiologist's REPORT TEXT is analysed. In this schema that is not a convention: an analysis
--   run carries a copy of its source document's type, and a table CHECK refuses any row whose
--   source is a radiology_image unless the analysis kind is the explicitly non-interpretive
--   'metadata_index'. A CHECK binds every writer — the web session, the model worker, a
--   service_role script and a superuser at psql alike. An UNCLASSIFIED document is treated the
--   same as an image: fail closed.
--
-- COMPLIANCE POSTURE (unchanged from 010, deliberately modest — not legal advice)
--   The operator is in India: the governing regime is the Digital Personal Data Protection Act,
--   2023, not HIPAA. Nothing here is a claim of certification or of legal sufficiency. Whether
--   any of it satisfies a specific DPDP obligation is a question for counsel.
-- =============================================================================================


-- =============================================================================================
-- SECTION 0 — PRECONDITIONS
--
-- This file needs 010 for the session-helper API and 020 for app.care_patient_ids(), which is
-- the per-patient half of every clinical policy in §9. An earlier draft of this file was written
-- as though 020 did not exist yet and scoped its policies to tenant + role only; it now runs
-- after 020 and uses the real predicate. Failing here is much better than applying a documents
-- schema in which any clinician can read any chart in the hospital.
-- =============================================================================================

DO $preflight$
BEGIN
  IF to_regprocedure('app.current_org_id()') IS NULL THEN
    RAISE EXCEPTION '030 requires 010_tenancy_identity.sql. Run it first.' USING errcode = '42P01';
  END IF;

  IF to_regprocedure('app.care_patient_ids()') IS NULL THEN
    RAISE EXCEPTION '030 requires 020_clinical.sql: app.care_patient_ids() is missing.'
      USING errcode = '42P01',
            hint = 'The policies in §9 scope documents and AI output to the caller''s care team. '
                   'Without it they would fall back to tenant + role, which lets any clinician '
                   'read any chart in their hospital. Run 020 first.';
  END IF;

  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'app' AND p.proname = 'has_role') > 1 THEN
    RAISE EXCEPTION 'app.has_role() is overloaded — the retired 001-004 drafts are installed.'
      USING errcode = '42723';
  END IF;
END
$preflight$;


-- =============================================================================================
-- SECTION 1 — CLOSED VALUE SETS
--
-- Every one of these exists because some screen or the safety rule needs the set to be closed.
-- Types live in schema `app` beside 010's, so `\dT app.*` lists the whole vocabulary at once.
-- =============================================================================================

DO $types$
BEGIN
  -- ---- documents ----------------------------------------------------------------------------
  IF to_regtype('app.document_source') IS NULL THEN
    CREATE TYPE app.document_source AS ENUM (
      'patient_upload',      -- patient portal
      'staff_upload',        -- reception (insurance card, consent) or clinician
      'device_feed',         -- a modality or analyser pushing a file
      'external_interface',  -- outside lab, HIE, fax gateway
      'system_generated');   -- e.g. the PDF the prognosis screen's "Export PDF" produces
  END IF;

  IF to_regtype('app.document_scan_status') IS NULL THEN
    CREATE TYPE app.document_scan_status AS ENUM (
      'pending',      -- row exists, bytes not confirmed in the bucket yet
      'scanning',     -- handed to the malware scanner
      'clean',        -- passed; only now may the bytes be served or processed
      'quarantined',  -- rejected; the bytes must never be served
      'failed');      -- upload or scan could not complete
  END IF;

  IF to_regtype('app.document_type') IS NULL THEN
    CREATE TYPE app.document_type AS ENUM (
      'lab_report',
      'radiology_report',   -- the narrative text — analysable
      'radiology_image',    -- the scan itself (DICOM/JPEG) — store and display ONLY, see §5
      'scanned_document',   -- consent form, insurance card, referral letter
      'chart_image',        -- a photograph or screenshot of a chart or graph
      'other');
  END IF;

  IF to_regtype('app.classification_source') IS NULL THEN
    CREATE TYPE app.classification_source AS ENUM ('model', 'human');
  END IF;

  IF to_regtype('app.text_extraction_method') IS NULL THEN
    CREATE TYPE app.text_extraction_method AS ENUM (
      'pdf_text_layer',       -- native text, no OCR involved
      'ocr',
      'dicom_header',         -- header fields only; never pixel interpretation
      'manual_transcription',
      'vendor_api');
  END IF;

  IF to_regtype('app.text_extraction_status') IS NULL THEN
    CREATE TYPE app.text_extraction_status AS ENUM ('succeeded', 'partial', 'failed');
  END IF;

  -- ---- AI -----------------------------------------------------------------------------------
  -- One value per AI surface that actually exists in the 20 screens, plus the one non-
  -- interpretive kind that is permitted over an image. Deliberately short: a long enum makes
  -- the allowlist in §5 harder to reason about, and every extra value is a new way to be wrong.
  IF to_regtype('app.ai_analysis_kind') IS NULL THEN
    CREATE TYPE app.ai_analysis_kind AS ENUM (
      'prognosis',        -- dashboard risk flags, patient-detail rail, prognosis report
      'interpretation',   -- "what does this report mean" — the kind banned over images
      'summarization',    -- condensing a document or an episode
      'lab_note',         -- the Labs screen's "AI note" column
      'plain_language',   -- patient portal: the HbA1c explanation, "why this plan"
      'panel_brief',      -- doctor dashboard's dark "AI daily brief" card
      'metadata_index');  -- headers, checksums, duplicate detection. NO reading of content.
  END IF;

  IF to_regtype('app.ai_run_status') IS NULL THEN
    CREATE TYPE app.ai_run_status AS ENUM ('queued', 'running', 'succeeded', 'failed', 'refused');
  END IF;

  IF to_regtype('app.ai_run_trigger') IS NULL THEN
    CREATE TYPE app.ai_run_trigger AS ENUM ('user_request', 'schedule', 'event');
  END IF;

  IF to_regtype('app.ai_finding_kind') IS NULL THEN
    CREATE TYPE app.ai_finding_kind AS ENUM (
      'risk_summary',                -- "Key drivers: rising lactate, HR trend, age, low BP"
      'recommended_action',          -- the prognosis screen's three checkbox cards
      'plain_language_explanation',  -- portal results / care plan
      'lab_note',                    -- "Drives sepsis flag"
      'brief',                       -- daily brief, front-desk tip
      'other');
  END IF;

  IF to_regtype('app.ai_severity') IS NULL THEN
    CREATE TYPE app.ai_severity AS ENUM ('info', 'low', 'medium', 'high', 'critical');
  END IF;

  IF to_regtype('app.ai_review_state') IS NULL THEN
    CREATE TYPE app.ai_review_state AS ENUM ('pending', 'accepted', 'rejected', 'amended');
  END IF;

  IF to_regtype('app.ai_risk_type') IS NULL THEN
    CREATE TYPE app.ai_risk_type AS ENUM (
      'sepsis',              -- 92% / 48h
      'icu_transfer',        -- 54% / 72h
      'length_of_stay',      -- 9-12 days
      'readmission_30d',     -- Whitfield on the dashboard
      'post_op_infection',   -- Okafor on the dashboard
      'glycemic_control',    -- Nair on the dashboard
      'deterioration_other');
  END IF;

  IF to_regtype('app.ai_value_kind') IS NULL THEN
    CREATE TYPE app.ai_value_kind AS ENUM ('probability', 'range');
  END IF;

  IF to_regtype('app.ai_risk_band') IS NULL THEN
    CREATE TYPE app.ai_risk_band AS ENUM ('low', 'medium', 'high', 'critical');
  END IF;

  IF to_regtype('app.ai_citation_source') IS NULL THEN
    CREATE TYPE app.ai_citation_source AS ENUM (
      'document_text_span',    -- offsets into an extraction — the checkable case
      'document_page_region',  -- page + bounding box, for a figure or a scanned table
      'clinical_value',        -- a row owned by 020: an observation, a lab result, a med
      'prior_finding',         -- an earlier finding this one builds on
      'model_knowledge');      -- NO patient-specific evidence. Recorded, not hidden.
  END IF;
END
$types$;


-- =============================================================================================
-- SECTION 2 — DOCUMENTS
--
-- Rule 3 of the brief, implemented: no bytes in a column. The row holds a bucket plus a key,
-- and the key is forced tenant-first by a CHECK on app.storage_key_belongs_to() — which is
-- IMMUTABLE precisely so it can be used here. A key that does not start `org/<uuid>/` cannot be
-- inserted, so a guessed or leaked path cannot walk into another hospital's bucket prefix, and
-- the storage-side policy is a prefix match rather than a per-object ACL.
--
-- CONSOLIDATION NOTE — classification lives HERE, not in a history table.
--   The draft carried document_classifications (one row per decision) plus a view for "the
--   current one". Every screen reads only the current classification; the history question
--   ("who changed this from lab_report to radiology_image, and when") is exactly what 040's
--   audit trail answers, for every column, without a second table to keep in step. So the
--   current classification is five columns on the document, and reclassification is an UPDATE
--   the audit trail records. One table instead of two plus a view.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.document (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id         uuid        NOT NULL REFERENCES public.organization (id)
                                        ON UPDATE CASCADE ON DELETE RESTRICT,

    -- Every document in this product is about a patient. There is no org-level document surface
    -- in the 20 screens, so NOT NULL rather than a nullable column nobody would ever fill.
    patient_id              uuid        NOT NULL,

    -- organization_member.id, i.e. 010's "staff_id". A patient uploading through the portal has
    -- a seat too, so this is NOT NULL for every route except a device or interface feed.
    uploaded_by_member_id   uuid        NULL,
    source                  app.document_source NOT NULL,

    file_name               text        NOT NULL,
    mime_type               text        NOT NULL,
    byte_size               bigint      NOT NULL,
    checksum_sha256         text        NOT NULL,

    storage_bucket          text        NOT NULL DEFAULT 'phi-documents',
    storage_key             text        NOT NULL,

    scan_status             app.document_scan_status NOT NULL DEFAULT 'pending',
    scanned_at              timestamptz NULL,
    scanner                 text        NULL,   -- 'clamav 1.2.1' — name AND version
    scan_detail             text        NULL,   -- signature name on a quarantine

    -- NULL means NOT YET CLASSIFIED, and §5 treats that exactly like a radiology image: no
    -- interpretation. There is deliberately no 'unknown' enum value and no default, because a
    -- default here would be a lie that opens the image gate.
    doc_type                app.document_type NULL,
    doc_type_confidence     numeric(4,3) NULL,
    doc_type_source         app.classification_source NULL,
    doc_type_confirmed_by_member_id uuid NULL,
    doc_type_confirmed_at   timestamptz NULL,

    -- Release to the patient portal is an explicit act, never a side effect of uploading.
    patient_visible         boolean     NOT NULL DEFAULT false,

    -- Rule 4: clinical data is never hard-deleted. The wrong-patient upload — a real front desk
    -- event — is a retraction that keeps the row, the audit trail and the storage key.
    retracted_at            timestamptz NULL,
    retracted_reason        text        NULL,
    retracted_by_member_id  uuid        NULL,

    created_at              timestamptz NOT NULL DEFAULT now(),
    updated_at              timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_id_org_uk UNIQUE (id, organization_id),

    -- House rule 3: cross-tenant references become foreign-key violations, not review findings.
    CONSTRAINT document_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT document_uploader_fk
      FOREIGN KEY (uploaded_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT document_confirmer_fk
      FOREIGN KEY (doc_type_confirmed_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT document_retractor_fk
      FOREIGN KEY (retracted_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,

    -- A file name is a label, never a path: a '/' in it is how a display string becomes a
    -- traversal attempt somewhere downstream.
    CONSTRAINT document_file_name_ck
      CHECK (btrim(file_name) <> '' AND length(file_name) <= 255
             AND file_name !~ '[/\\]' AND file_name <> '..'),
    CONSTRAINT document_mime_ck    CHECK (mime_type ~ '^[a-z]+/[A-Za-z0-9.+_-]+$'),
    CONSTRAINT document_size_ck    CHECK (byte_size > 0 AND byte_size <= 2147483648), -- 2 GiB
    CONSTRAINT document_checksum_ck CHECK (checksum_sha256 ~ '^[0-9a-f]{64}$'),

    -- THE TENANT-SCOPED STORAGE KEY. This is rule 3's second half.
    CONSTRAINT document_storage_key_tenant_ck
      CHECK (app.storage_key_belongs_to(storage_key, organization_id)),
    CONSTRAINT document_storage_key_shape_ck
      CHECK (length(storage_key) BETWEEN 12 AND 1024 AND storage_key !~ '\.\.'),

    CONSTRAINT document_scan_ck
      CHECK ((scan_status IN ('pending', 'scanning')) = (scanned_at IS NULL)),

    CONSTRAINT document_classification_ck
      CHECK ((doc_type IS NULL) = (doc_type_source IS NULL)),
    CONSTRAINT document_class_confidence_ck
      CHECK (doc_type_confidence IS NULL
             OR (doc_type_confidence >= 0 AND doc_type_confidence <= 1)),
    -- A model classification with no confidence cannot be triaged for human review, so it is
    -- not a classification we accept.
    CONSTRAINT document_model_confidence_ck
      CHECK (doc_type_source IS DISTINCT FROM 'model' OR doc_type_confidence IS NOT NULL),
    CONSTRAINT document_human_confirm_ck
      CHECK ((doc_type_confirmed_by_member_id IS NULL) = (doc_type_confirmed_at IS NULL)),
    -- "human" as the source means a person actually put their name to it.
    CONSTRAINT document_human_source_ck
      CHECK (doc_type_source IS DISTINCT FROM 'human'
             OR doc_type_confirmed_by_member_id IS NOT NULL),

    CONSTRAINT document_retracted_ck
      CHECK (num_nulls(retracted_at, retracted_reason, retracted_by_member_id) IN (0, 3)),
    CONSTRAINT document_retracted_reason_ck
      CHECK (retracted_reason IS NULL OR length(btrim(retracted_reason)) >= 10)
);

-- One row per stored object: two documents claiming the same bytes-location is a bug that ends
-- with one of them serving the other's PHI.
CREATE UNIQUE INDEX IF NOT EXISTS document_storage_key_uk
  ON public.document (storage_bucket, storage_key);
CREATE INDEX IF NOT EXISTS document_patient_ix
  ON public.document (organization_id, patient_id, created_at DESC)
  WHERE retracted_at IS NULL;
CREATE INDEX IF NOT EXISTS document_pipeline_ix
  ON public.document (organization_id, scan_status, created_at)
  WHERE scan_status IN ('pending', 'scanning');
-- The classification review queue: unclassified, or classified by a model and never confirmed.
CREATE INDEX IF NOT EXISTS document_unconfirmed_ix
  ON public.document (organization_id, created_at)
  WHERE retracted_at IS NULL AND doc_type_confirmed_at IS NULL;

COMMENT ON TABLE public.document IS
  'An uploaded file. The bytes live in object storage; this row holds the metadata, the '
  'tenant-scoped storage key, the malware-scan state and the current type classification. '
  'Never hard-deleted — a wrong upload is retracted.';
COMMENT ON COLUMN public.document.storage_key IS
  'Object key, forced to begin with app.storage_prefix(organization_id) by a CHECK. The tenant '
  'is the first path segment so a leaked or guessed key cannot cross hospitals and the bucket '
  'policy is a prefix match.';
COMMENT ON COLUMN public.document.scan_status IS
  'Bytes must not be served or processed before this reads ''clean''. The database enforces the '
  'processing half (§5 refuses an analysis run over an unscanned document); the serving half '
  'belongs to whatever signs the download URL, because Postgres does not sign URLs.';
COMMENT ON COLUMN public.document.doc_type IS
  'NULL means not yet classified. §5 treats NULL exactly like radiology_image: no model '
  'interpretation. Fail closed — an unclassified file might BE an image.';
COMMENT ON COLUMN public.document.doc_type_confirmed_by_member_id IS
  'The human who confirmed the type. A model classification stands until someone confirms it, '
  'and the safety gate in §5 does not care whether a human agreed — radiology_image is barred '
  'either way.';
COMMENT ON COLUMN public.document.patient_visible IS
  'Released to the patient portal. Uploads by the patient themselves are readable by them '
  'through the RLS policy without this flag; everything else needs a deliberate release.';

DROP TRIGGER IF EXISTS t_touch ON public.document;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.document
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.document;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.document
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 3 — EXTRACTED TEXT (kept apart from the source, as required)
--
-- WHY A SEPARATE TABLE AND NOT A COLUMN ON document
--   1. Extraction is a claim ABOUT the document, made by a named engine at a version, with a
--      confidence. Those facts have to sit next to the text or the text is unaccountable.
--   2. Re-extraction is routine (a better OCR engine, a rotated scan). Superseding a row keeps
--      the old text, which matters because an ai_citation may point into it.
--   3. It is the big column. Keeping it out of public.document keeps the row the UI actually
--      lists narrow.
--   4. Different reach: a clinician may read the OCR of a radiology report; the patient portal
--      never shows raw extracted text, and §9 makes that a policy rather than a UI habit.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.document_text (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   uuid        NOT NULL REFERENCES public.organization (id)
                                  ON UPDATE CASCADE ON DELETE RESTRICT,
    document_id       uuid        NOT NULL,
    patient_id        uuid        NOT NULL,   -- denormalised from the document so §9 needs no join

    method            app.text_extraction_method NOT NULL,
    status            app.text_extraction_status NOT NULL,
    -- Engine name AND version, same argument as the model version on a run: a text extraction
    -- whose producer you cannot name is a text extraction you cannot re-run or blame.
    engine            text        NOT NULL,
    confidence        numeric(4,3) NULL,

    content           text        NULL,
    char_count        integer     GENERATED ALWAYS AS (length(coalesce(content, ''))) STORED,
    page_count        integer     NULL,

    -- Lexical search comes free with the column and needs no extension. Semantic search is the
    -- optional pgvector section in §11; this one works everywhere.
    search_tsv        tsvector    GENERATED ALWAYS AS
                                  (to_tsvector('english', coalesce(content, ''))) STORED,

    extracted_at      timestamptz NOT NULL DEFAULT now(),
    superseded_at     timestamptz NULL,
    superseded_reason text        NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_text_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT document_text_document_fk
      FOREIGN KEY (document_id, organization_id)
      REFERENCES public.document (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT document_text_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT document_text_engine_ck  CHECK (btrim(engine) <> ''),
    CONSTRAINT document_text_content_ck CHECK ((status = 'failed') = (content IS NULL)),
    CONSTRAINT document_text_confidence_ck
      CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    -- OCR without a confidence cannot be triaged, and OCR is the method most likely to be
    -- quietly wrong. A clean PDF text layer has no meaningful confidence, so it is exempt.
    CONSTRAINT document_text_ocr_confidence_ck
      CHECK (method <> 'ocr' OR status = 'failed' OR confidence IS NOT NULL),
    CONSTRAINT document_text_pages_ck  CHECK (page_count IS NULL OR page_count > 0),
    CONSTRAINT document_text_superseded_ck
      CHECK ((superseded_at IS NULL) = (superseded_reason IS NULL))
);

-- One live extraction per (document, method). Two methods may both be current — a PDF's own
-- text layer and an OCR pass over the same scan are different evidence, not rivals.
CREATE UNIQUE INDEX IF NOT EXISTS document_text_current_uk
  ON public.document_text (document_id, method) WHERE superseded_at IS NULL;
CREATE INDEX IF NOT EXISTS document_text_patient_ix
  ON public.document_text (organization_id, patient_id, extracted_at DESC);
CREATE INDEX IF NOT EXISTS document_text_search_ix
  ON public.document_text USING gin (search_tsv);

COMMENT ON TABLE public.document_text IS
  'Text extracted from a document, with the method, the engine version and a confidence. Kept '
  'separate from public.document so re-extraction supersedes rather than overwrites — an '
  'ai_citation may point into a superseded row and must still resolve.';
COMMENT ON COLUMN public.document_text.method IS
  'dicom_header reads header FIELDS only. It is not, and must never become, a way to describe '
  'pixels — that is the interpretation §5 forbids.';

DROP TRIGGER IF EXISTS t_no_delete ON public.document_text;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.document_text
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();

-- The composite FKs above guarantee the tenant matches. They cannot guarantee this row's
-- patient is the DOCUMENT's patient, so a trigger pins it. Written by the extraction worker,
-- which runs as service_role and therefore bypasses RLS but not triggers.
CREATE OR REPLACE FUNCTION app.document_text_inherit_scope()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_pat uuid;
BEGIN
  SELECT d.organization_id, d.patient_id INTO v_org, v_pat
    FROM public.document d WHERE d.id = NEW.document_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'document % does not exist.', NEW.document_id USING errcode = '23503';
  END IF;
  NEW.organization_id := v_org;
  NEW.patient_id      := v_pat;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_inherit_scope ON public.document_text;
CREATE TRIGGER t_inherit_scope BEFORE INSERT OR UPDATE ON public.document_text
  FOR EACH ROW EXECUTE FUNCTION app.document_text_inherit_scope();


-- =============================================================================================
-- SECTION 4 — AI ANALYSIS RUNS
--
-- One row per model call. The screens show "Model v4.2 · Generated 6:15 AM" — this is the row
-- behind that pill, and behind every number and sentence the AI surfaces print.
--
-- WHY THE MODEL IS DENORMALISED TEXT AND NOT A FK TO A CATALOGUE TABLE
--   The draft had ai_models + ai_model_validations + ai_prompt_configs. A result must stay
--   interpretable for as long as it is in a chart — years. A FK to a mutable catalogue row is
--   WORSE for that than a string: somebody edits the catalogue ("we retired v4.2, repoint it")
--   and every historical result silently changes what it claims to be. Recording provider,
--   name, version and prompt version as immutable text on the run makes the row self-describing
--   forever, and costs three columns instead of three tables with their own RLS and grants.
--   What a catalogue would still buy — "which models is this tenant allowed to call" — is an
--   entitlement question, and 010 already owns entitlements. Noted in the open questions.
--
-- WHY THERE IS NO INSERT POLICY (see §9)
--   Runs, findings, scores, factors and citations are written by the trusted model worker as
--   service_role. A web session has SELECT and, on findings only, UPDATE. So there is no path
--   by which a signed-in user can fabricate a model result, backdate a risk score, or invent a
--   citation. That is a property worth more than the convenience of client-side writes.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.ai_analysis_run (
    id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid        NOT NULL REFERENCES public.organization (id)
                                     ON UPDATE CASCADE ON DELETE RESTRICT,

    -- NULL only for a 'panel_brief', which is about a clinician's whole list, not one chart.
    patient_id           uuid        NULL,

    -- The source the model was given. document_text_id names the EXACT extraction that was fed
    -- in, which is what makes a text-span citation checkable years later.
    document_id          uuid        NULL,
    document_text_id     uuid        NULL,

    kind                 app.ai_analysis_kind NOT NULL,
    status               app.ai_run_status    NOT NULL DEFAULT 'queued',
    triggered_by         app.ai_run_trigger   NOT NULL DEFAULT 'user_request',
    requested_by_member_id uuid      NULL,

    -- A result without its model version is unusable. All four are NOT NULL, and they are known
    -- before the call is made, so 'queued' is not an excuse to leave them empty.
    model_provider       text        NOT NULL,
    model_name           text        NOT NULL,
    model_version        text        NOT NULL,
    prompt_version       text        NOT NULL,
    -- Decoding parameters and anything else needed to reproduce the call. Never read in a
    -- policy, so jsonb is safe here in the way 010 defines "safe".
    config               jsonb       NOT NULL DEFAULT '{}'::jsonb,

    requested_at         timestamptz NOT NULL DEFAULT now(),
    started_at           timestamptz NULL,
    completed_at         timestamptz NULL,
    -- Provider-reported generation latency. Distinct from completed_at - started_at, which
    -- includes our own queueing; keeping both is how you tell "the model is slow" from "we are".
    latency_ms           integer     NULL,

    input_tokens         integer     NULL,
    output_tokens        integer     NULL,
    -- Millionths of a currency unit: integer arithmetic, no float drift on a billing figure.
    cost_micros          bigint      NULL,
    cost_currency        text        NOT NULL DEFAULT 'INR',

    error_code           text        NULL,
    error_detail         text        NULL,

    -- MAINTAINED BY TRIGGER, NEVER BY THE CALLER (§5). A copy of the source document's type at
    -- the moment of the run, so the safety rule can be a table CHECK instead of a convention.
    source_document_type app.document_type NULL,

    created_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ai_run_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT ai_run_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_run_document_fk
      FOREIGN KEY (document_id, organization_id)
      REFERENCES public.document (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_run_document_text_fk
      FOREIGN KEY (document_text_id, organization_id)
      REFERENCES public.document_text (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_run_requester_fk
      FOREIGN KEY (requested_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,

    -- ---- scope ------------------------------------------------------------------------------
    CONSTRAINT ai_run_patient_scope_ck
      CHECK (kind = 'panel_brief' OR patient_id IS NOT NULL),
    CONSTRAINT ai_run_panel_brief_ck
      CHECK (kind <> 'panel_brief'
             OR (patient_id IS NULL AND document_id IS NULL
                 AND requested_by_member_id IS NOT NULL)),
    CONSTRAINT ai_run_text_needs_document_ck
      CHECK (document_text_id IS NULL OR document_id IS NOT NULL),

    -- ---- provenance -------------------------------------------------------------------------
    CONSTRAINT ai_run_model_ck
      CHECK (btrim(model_provider) <> '' AND btrim(model_name) <> ''
             AND btrim(model_version) <> '' AND btrim(prompt_version) <> ''),
    CONSTRAINT ai_run_config_ck CHECK (jsonb_typeof(config) = 'object'),

    -- ---- timing, cost -----------------------------------------------------------------------
    CONSTRAINT ai_run_started_ck   CHECK (started_at IS NULL OR started_at >= requested_at),
    CONSTRAINT ai_run_completed_ck
      CHECK (completed_at IS NULL
             OR (started_at IS NOT NULL AND completed_at >= started_at)),
    CONSTRAINT ai_run_terminal_ck
      CHECK (status IN ('queued', 'running') OR completed_at IS NOT NULL),
    CONSTRAINT ai_run_error_ck
      CHECK ((status IN ('failed', 'refused')) = (error_code IS NOT NULL)),
    CONSTRAINT ai_run_latency_ck  CHECK (latency_ms IS NULL OR latency_ms >= 0),
    CONSTRAINT ai_run_tokens_ck
      CHECK ((input_tokens IS NULL OR input_tokens >= 0)
             AND (output_tokens IS NULL OR output_tokens >= 0)),
    CONSTRAINT ai_run_cost_ck     CHECK (cost_micros IS NULL OR cost_micros >= 0),
    CONSTRAINT ai_run_currency_ck CHECK (cost_currency ~ '^[A-Z]{3}$'),

    -- =========================================================================================
    -- THE SAFETY RULE, DECLARED (enforcement machinery in §5)
    --
    -- ai_run_source_classified_ck: a run over a document may only proceed if that document has
    --   been classified. An unclassified file might BE a radiology image, so "unknown" is
    --   treated as forbidden. metadata_index is exempt because it reads headers, not content.
    --
    -- ai_run_no_image_interpretation_ck: THE RULE. A run whose source document is a
    --   radiology_image can only be the non-interpretive 'metadata_index'. Every other kind —
    --   interpretation, summarization, prognosis, lab_note, plain_language, panel_brief — is
    --   refused by the database.
    --
    -- Written as an ALLOWLIST (kind = 'metadata_index') rather than a denylist
    -- (kind <> 'interpretation') on purpose: enums grow, and a denylist fails OPEN on the next
    -- value somebody adds. This one fails closed on every value that does not yet exist.
    -- =========================================================================================
    CONSTRAINT ai_run_source_classified_ck
      CHECK (document_id IS NULL
             OR kind = 'metadata_index'
             OR source_document_type IS NOT NULL),
    CONSTRAINT ai_run_no_image_interpretation_ck
      CHECK (kind = 'metadata_index'
             OR source_document_type IS DISTINCT FROM 'radiology_image')
);

CREATE INDEX IF NOT EXISTS ai_run_patient_ix
  ON public.ai_analysis_run (organization_id, patient_id, kind, requested_at DESC);
CREATE INDEX IF NOT EXISTS ai_run_document_ix
  ON public.ai_analysis_run (organization_id, document_id)
  WHERE document_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ai_run_inflight_ix
  ON public.ai_analysis_run (organization_id, status, requested_at)
  WHERE status IN ('queued', 'running');
-- Spend and latency by model version, which is the question finance and the on-call both ask.
CREATE INDEX IF NOT EXISTS ai_run_cost_ix
  ON public.ai_analysis_run (organization_id, model_name, model_version, completed_at DESC)
  WHERE completed_at IS NOT NULL;

COMMENT ON TABLE public.ai_analysis_run IS
  'One model call: what was asked, which model AND VERSION answered, over which source, how '
  'long it took and what it cost. Every AI row in this schema hangs off one of these, so no '
  'output can exist without its provenance.';
COMMENT ON COLUMN public.ai_analysis_run.model_version IS
  'Immutable text, not a FK. A result must still name its own model years later; a foreign key '
  'to an editable catalogue lets history be rewritten by an UPDATE somewhere else.';
COMMENT ON COLUMN public.ai_analysis_run.document_text_id IS
  'The exact extraction fed to the model. Text-span citations resolve against this row, which '
  'is why superseding an extraction must not delete it.';
COMMENT ON COLUMN public.ai_analysis_run.source_document_type IS
  'Trigger-maintained copy of the source document''s type. It exists so the radiology-image ban '
  'can be a CHECK constraint: a CHECK binds the web session, the model worker, service_role and '
  'a superuser at psql equally, which no amount of application discipline does.';

DROP TRIGGER IF EXISTS t_no_delete ON public.ai_analysis_run;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.ai_analysis_run
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 5 — THE SAFETY GATE: NO MODEL INTERPRETATION OF RADIOLOGY IMAGES
--
-- The architecture forbids sending a raw radiology IMAGE to a general-purpose model to be
-- interpreted. Only the radiologist's REPORT TEXT is analysed. This section makes that
-- impossible to record by accident, in three layers that each catch what the others cannot:
--
--   LAYER 1 (§4, declarative)  Two CHECK constraints on ai_analysis_run. CHECKs are evaluated
--       for every writer with no exceptions — the app, the model worker, a service_role script,
--       a superuser typing INSERT at psql. They are also visible in \d ai_analysis_run, so a
--       reviewer sees the rule in the table definition rather than having to find a trigger.
--       CHECKs cannot read another table, which is why layer 2 exists.
--
--   LAYER 2 (here)  A BEFORE INSERT OR UPDATE trigger on ai_analysis_run that fills
--       source_document_type from the document — the caller never supplies it — and raises a
--       readable, actionable error before the CHECK fires with a terse one. It also enforces
--       the two things a CHECK cannot see: the document must be scan_status='clean', and the
--       run's patient must be the document's patient.
--
--   LAYER 3 (here)  A BEFORE UPDATE trigger on public.document. Without it the rule has an
--       obvious hole: classify a file as radiology_report, run 'interpretation' over it, then
--       reclassify it to radiology_image. Layer 3 refuses that reclassification while an
--       interpretive run exists, and otherwise re-syncs source_document_type on every run of
--       that document so layer 1 keeps holding.
--
-- WHAT IS DELIBERATELY *NOT* CLAIMED
--   This stops the fact from being RECORDED in this database. It does not reach into the model
--   worker's process and stop it opening the object and posting pixels somewhere — no schema
--   can. What it does is make the bypass leave no legitimate row: an interpretation of an image
--   has nowhere to land, so it cannot reach a chart, a screen, or a citation. Pair it with an
--   egress control in the worker.
-- =============================================================================================

CREATE OR REPLACE FUNCTION app.ai_run_enforce_source_policy()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_doc_org   uuid;
  v_doc_pat   uuid;
  v_doc_type  app.document_type;
  v_scan      app.document_scan_status;
  v_retracted timestamptz;
BEGIN
  -- A run is a historical record of a model call. Everything that says WHAT was asked, of WHAT,
  -- by WHICH model is frozen once the row exists; only the lifecycle columns (status, timings,
  -- tokens, cost, error) move afterwards. Without this the provenance argument for denormalised
  -- model text (§4) collapses — a version you can edit later is not a version.
  IF TG_OP = 'UPDATE' THEN
    IF NEW.kind             IS DISTINCT FROM OLD.kind
       OR NEW.organization_id  IS DISTINCT FROM OLD.organization_id
       OR NEW.patient_id       IS DISTINCT FROM OLD.patient_id
       OR NEW.document_id      IS DISTINCT FROM OLD.document_id
       OR NEW.document_text_id IS DISTINCT FROM OLD.document_text_id
       OR NEW.model_provider   IS DISTINCT FROM OLD.model_provider
       OR NEW.model_name       IS DISTINCT FROM OLD.model_name
       OR NEW.model_version    IS DISTINCT FROM OLD.model_version
       OR NEW.prompt_version   IS DISTINCT FROM OLD.prompt_version
       OR NEW.config           IS DISTINCT FROM OLD.config
       OR NEW.requested_at     IS DISTINCT FROM OLD.requested_at THEN
      RAISE EXCEPTION 'An analysis run records a call that already happened: its subject, '
                      'source and model are immutable.'
        USING errcode = '42501',
              hint = 'Record a new run. Only status, timings, tokens, cost and error may change.';
    END IF;
  END IF;

  IF NEW.document_id IS NULL THEN
    -- No source document: patient-level prognosis, a panel brief. Nothing to copy, and a
    -- caller-supplied type here would be a lie the CHECK would then trust.
    NEW.source_document_type := NULL;
    RETURN NEW;
  END IF;

  SELECT d.organization_id, d.patient_id, d.doc_type, d.scan_status, d.retracted_at
    INTO v_doc_org, v_doc_pat, v_doc_type, v_scan, v_retracted
    FROM public.document d
   WHERE d.id = NEW.document_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'document % does not exist.', NEW.document_id USING errcode = '23503';
  END IF;

  -- Belt and braces over the composite FK: if these ever disagree, something is very wrong and
  -- the answer is to stop, not to guess.
  IF v_doc_org IS DISTINCT FROM NEW.organization_id THEN
    RAISE EXCEPTION 'Cross-tenant analysis run: document % belongs to organisation %, run to %.',
                    NEW.document_id, v_doc_org, NEW.organization_id
      USING errcode = '42501';
  END IF;

  IF NEW.patient_id IS NULL THEN
    NEW.patient_id := v_doc_pat;
  ELSIF NEW.patient_id IS DISTINCT FROM v_doc_pat THEN
    RAISE EXCEPTION 'Analysis run names patient % but document % belongs to patient %.',
                    NEW.patient_id, NEW.document_id, v_doc_pat
      USING errcode = '23514';
  END IF;

  -- Freshness checks belong to the moment the run is created. On UPDATE they would misfire:
  -- reclassifying an already-retracted document re-syncs its runs (see the AFTER trigger below)
  -- and must not fail because the document was retracted afterwards.
  IF TG_OP = 'INSERT' THEN
    IF v_retracted IS NOT NULL THEN
      RAISE EXCEPTION 'Document % was retracted and must not be analysed.', NEW.document_id
        USING errcode = '42501';
    END IF;

    -- "clean" is the whole point of scanning. Processing an unscanned or quarantined file is
    -- the same mistake as serving it.
    IF v_scan <> 'clean' THEN
      RAISE EXCEPTION 'Document % has scan status % — only a clean document may be analysed.',
                      NEW.document_id, v_scan
        USING errcode = '42501',
              hint = 'Wait for the malware scan to pass, or handle the quarantine.';
    END IF;
  END IF;

  -- Fill the copy the CHECK constraints read. Callers do not get to set this.
  NEW.source_document_type := v_doc_type;

  -- ---- THE RULE, with the error a human can act on ------------------------------------------
  IF NEW.kind <> 'metadata_index' THEN
    IF v_doc_type IS NULL THEN
      RAISE EXCEPTION
        'Document % is not classified yet; it cannot be analysed (requested kind: %).',
        NEW.document_id, NEW.kind
        USING errcode = '42501',
              hint = 'Classify the document first. Unclassified is treated as an image: an '
                     'unknown file may BE a radiology image, so this fails closed.';
    ELSIF v_doc_type = 'radiology_image' THEN
      RAISE EXCEPTION
        'Radiology images are stored and displayed only: document % cannot be sent to a model '
        'for %.', NEW.document_id, NEW.kind
        USING errcode = '42501',
              hint = 'Analyse the radiologist''s REPORT (document type radiology_report) '
                     'instead. The only kind permitted over an image is metadata_index, which '
                     'reads headers and checksums and never the pixels.';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.ai_run_enforce_source_policy() IS
  'Layer 2 of the radiology-image safety gate. Fills ai_analysis_run.source_document_type from '
  'the document (callers never set it), pins the run to the document''s tenant and patient, '
  'requires a clean malware scan, and refuses any non-metadata_index run over an image or an '
  'unclassified file. The CHECK constraints in §4 are the backstop if this is ever detached.';

DROP TRIGGER IF EXISTS t_source_policy ON public.ai_analysis_run;
CREATE TRIGGER t_source_policy BEFORE INSERT OR UPDATE ON public.ai_analysis_run
  FOR EACH ROW EXECUTE FUNCTION app.ai_run_enforce_source_policy();


-- ---- Layer 3: reclassification, plus the column guard for document UPDATE --------------------
-- One BEFORE UPDATE trigger on public.document doing two jobs, because they are the same job:
-- deciding which changes to a document are legitimate.
CREATE OR REPLACE FUNCTION app.document_before_update()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_offending uuid;
  v_kind      app.ai_analysis_kind;
BEGIN
  -- ---- 1. Immutable facts about the stored object -------------------------------------------
  -- Re-pointing a document row at different bytes, or at a different patient, is how one
  -- patient's scan ends up displayed under another's name. None of it is an edit; all of it is
  -- a new upload.
  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id
     OR NEW.patient_id     IS DISTINCT FROM OLD.patient_id
     OR NEW.storage_bucket IS DISTINCT FROM OLD.storage_bucket
     OR NEW.storage_key    IS DISTINCT FROM OLD.storage_key
     OR NEW.checksum_sha256 IS DISTINCT FROM OLD.checksum_sha256
     OR NEW.byte_size      IS DISTINCT FROM OLD.byte_size
     OR NEW.mime_type      IS DISTINCT FROM OLD.mime_type
     OR NEW.source         IS DISTINCT FROM OLD.source THEN
    RAISE EXCEPTION 'The stored object, its patient and its tenant are immutable on a document.'
      USING errcode = '42501',
            hint = 'Upload a new document and retract this one, so both are visible in history.';
  END IF;

  -- ---- 2. Scan state belongs to the scanner --------------------------------------------------
  -- Without this, any clinician with UPDATE could mark their own upload clean and unlock
  -- processing. current_user is the database role: the scanner runs as service_role.
  IF NEW.scan_status IS DISTINCT FROM OLD.scan_status
     AND NOT (current_user IN ('service_role', 'postgres')
              -- A direct connection that never did SET ROLE: a migration or a runbook, not a
              -- request carrying an end user's identity (PostgREST always switches role).
              OR current_user = session_user) THEN
    RAISE EXCEPTION 'Only the malware scanner may change scan_status (current role: %).',
                    current_user
      USING errcode = '42501';
  END IF;

  -- ---- 3. LAYER 3 OF THE SAFETY GATE: reclassification ---------------------------------------
  IF NEW.doc_type IS DISTINCT FROM OLD.doc_type THEN
    -- Becoming an image (or becoming unclassified) while an interpretive run already exists
    -- would leave a recorded interpretation of an image behind. Refuse the reclassification and
    -- say why; the run itself is history and must not be quietly rewritten either.
    -- Reclassifying to any analysable type is always fine. Only the two forbidden destinations
    -- — radiology_image, and back to unclassified — have to look behind them.
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

    -- Re-syncing the runs' denormalised copy happens in the AFTER trigger below, NOT here: at
    -- BEFORE time this row's new doc_type is not yet in the heap, so the run's own trigger
    -- would re-read the OLD value and quietly undo the sync.
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION app.document_before_update() IS
  'Guards the columns RLS cannot (RLS is row-level, not column-level): the stored object, its '
  'patient and its tenant are frozen, scan_status belongs to the scanner, and — layer 3 of the '
  'radiology-image gate — a document cannot be reclassified into radiology_image or back to '
  'unclassified while an interpretive analysis run over it exists.';

DROP TRIGGER IF EXISTS t_guard_update ON public.document;
CREATE TRIGGER t_guard_update BEFORE UPDATE ON public.document
  FOR EACH ROW EXECUTE FUNCTION app.document_before_update();

-- After the new classification is in the heap, push it onto every run of this document so the
-- §4 CHECKs keep judging the current truth. The runs' own trigger re-derives the same value,
-- which is the belt to this braces.
CREATE OR REPLACE FUNCTION app.document_sync_run_source_type()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  UPDATE public.ai_analysis_run r
     SET source_document_type = NEW.doc_type
   WHERE r.document_id = NEW.id
     AND r.source_document_type IS DISTINCT FROM NEW.doc_type;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS t_sync_run_source_type ON public.document;
CREATE TRIGGER t_sync_run_source_type AFTER UPDATE OF doc_type ON public.document
  FOR EACH ROW WHEN (NEW.doc_type IS DISTINCT FROM OLD.doc_type)
  EXECUTE FUNCTION app.document_sync_run_source_type();


-- =============================================================================================
-- SECTION 6 — FINDINGS AND THE MANDATORY HUMAN REVIEW STATE
--
-- THE SETTINGS TOGGLE, AND WHY IT IS NOT A COLUMN
--   The Settings screen has "Require confirmation before adding AI notes to chart", per user,
--   default ON. Modelling it literally means a per-user checkbox that can switch off a safety
--   control on health records — which is to say, a safety control that does not exist, since
--   whoever is careless enough to need it is exactly who will turn it off.
--   So the reality this schema models is the invariant underneath the toggle: AI output cannot
--   reach a chart, and cannot reach the patient portal, while its review state is 'pending'.
--   That is two CHECK constraints (finding_chart_gate_ck, finding_patient_visible_ck), always
--   on, for every writer. The toggle keeps its remaining honest meaning — whether the UI shows
--   a confirmation step — and that is a user preference, not a schema object here.
--   If the owner intends the toggle to mean "auto-accept my AI notes", that is a real
--   weakening and needs to be an organisation-level entitlement with an audit trail, not a
--   checkbox. Flagged in the open questions rather than silently implemented.
--
-- CONSOLIDATION NOTE — review state is columns on the finding, not an ai_review_decisions table.
--   The current state is what every screen reads. The history of how it got there ("who
--   rejected this at 6:20, who amended it at 6:40") is every-column change history, which is
--   precisely 040's job for the whole database. A dedicated table would duplicate that for one
--   table's worth of rows and then need its own RLS, grants and delete guard.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.ai_finding (
    id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id       uuid        NOT NULL REFERENCES public.organization (id)
                                      ON UPDATE CASCADE ON DELETE RESTRICT,
    run_id                uuid        NOT NULL,
    patient_id            uuid        NULL,   -- NULL only for a panel brief; inherited in §6.1

    kind                  app.ai_finding_kind NOT NULL,
    severity              app.ai_severity     NOT NULL DEFAULT 'info',

    title                 text        NOT NULL,   -- 'Repeat lactate within 2h'
    detail                text        NOT NULL DEFAULT '',  -- 'Confirm trajectory before …'
    confidence            numeric(4,3) NULL,      -- 0.920 renders as "92% conf."
    display_order         integer     NOT NULL DEFAULT 0,

    -- ---- the review gate ----------------------------------------------------------------------
    review_state          app.ai_review_state NOT NULL DEFAULT 'pending',
    reviewed_by_member_id uuid        NULL,
    reviewed_at           timestamptz NULL,
    review_note           text        NULL,
    -- What the clinician actually meant, when they accepted the substance but rewrote the words.
    -- Keeping the model's original title/detail beside it is the point: an amendment is a
    -- correction with both versions visible, not an overwrite.
    amended_text          text        NULL,

    patient_visible       boolean     NOT NULL DEFAULT false,
    chart_committed_at    timestamptz NULL,
    chart_committed_by_member_id uuid NULL,

    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ai_finding_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT ai_finding_run_fk
      FOREIGN KEY (run_id, organization_id)
      REFERENCES public.ai_analysis_run (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_finding_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_finding_reviewer_fk
      FOREIGN KEY (reviewed_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_finding_committer_fk
      FOREIGN KEY (chart_committed_by_member_id, organization_id)
      REFERENCES public.organization_member (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT ai_finding_title_ck CHECK (btrim(title) <> ''),
    CONSTRAINT ai_finding_confidence_ck
      CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),

    -- "with who and when": a decided finding always names both.
    CONSTRAINT ai_finding_review_pair_ck
      CHECK ((review_state = 'pending')
             = (reviewed_by_member_id IS NULL AND reviewed_at IS NULL)),
    CONSTRAINT ai_finding_amended_ck
      CHECK ((review_state = 'amended') = (amended_text IS NOT NULL)),
    -- A rejection with no reason teaches nobody anything, least of all the people tuning the
    -- prompt six months from now.
    CONSTRAINT ai_finding_rejected_note_ck
      CHECK (review_state <> 'rejected' OR length(btrim(coalesce(review_note, ''))) >= 3),

    -- ==== THE MANDATORY REVIEW GATE, DECLARATIVE ==============================================
    CONSTRAINT ai_finding_chart_gate_ck
      CHECK (chart_committed_at IS NULL OR review_state IN ('accepted', 'amended')),
    CONSTRAINT ai_finding_chart_pair_ck
      CHECK ((chart_committed_at IS NULL) = (chart_committed_by_member_id IS NULL)),
    -- Nothing reaches the patient portal unreviewed either, and a portal-visible finding must
    -- belong to a patient.
    CONSTRAINT ai_finding_patient_visible_ck
      CHECK (NOT patient_visible
             OR (patient_id IS NOT NULL AND review_state IN ('accepted', 'amended')))
);

CREATE INDEX IF NOT EXISTS ai_finding_run_ix
  ON public.ai_finding (run_id, display_order);
CREATE INDEX IF NOT EXISTS ai_finding_patient_ix
  ON public.ai_finding (organization_id, patient_id, kind, created_at DESC);
-- The review queue, which is what the Labs screen's "Reviewed today" filter needs a source for.
CREATE INDEX IF NOT EXISTS ai_finding_pending_ix
  ON public.ai_finding (organization_id, severity, created_at)
  WHERE review_state = 'pending';

COMMENT ON TABLE public.ai_finding IS
  'One structured statement from a model run — a recommended action, a risk summary, a lab '
  'note, a plain-language explanation — plus the human review it must pass before it can reach '
  'a chart or the patient portal.';
COMMENT ON COLUMN public.ai_finding.chart_committed_at IS
  'When this was written into the patient record. ai_finding_chart_gate_ck makes commitment '
  'impossible while review_state is pending or rejected — that constraint IS the Settings '
  'screen''s "confirm before writing to chart", made unconditional so it cannot be switched off.';
COMMENT ON COLUMN public.ai_finding.amended_text IS
  'The clinician''s wording where they accepted the substance but not the phrasing. The model''s '
  'original title and detail stay in place beside it: an amendment shows both versions.';

DROP TRIGGER IF EXISTS t_touch ON public.ai_finding;
CREATE TRIGGER t_touch BEFORE UPDATE ON public.ai_finding
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();
DROP TRIGGER IF EXISTS t_no_delete ON public.ai_finding;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.ai_finding
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- ---- 6.1 scope inheritance (shared by ai_finding and ai_risk_score) --------------------------
-- Both tables hang off a run and both denormalise (organization_id, patient_id) so §9's policies
-- are a column comparison instead of a join. One function serves both because both name their
-- parent in a column called run_id. SECURITY DEFINER so an RLS-hidden parent cannot silently
-- yield NULL, which would widen rather than narrow who can read the child.
CREATE OR REPLACE FUNCTION app.ai_output_inherit_scope()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_org uuid;
  v_pat uuid;
BEGIN
  SELECT r.organization_id, r.patient_id INTO v_org, v_pat
    FROM public.ai_analysis_run r WHERE r.id = NEW.run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ai_analysis_run % does not exist.', NEW.run_id USING errcode = '23503';
  END IF;
  NEW.organization_id := v_org;
  NEW.patient_id      := v_pat;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS t_inherit_scope ON public.ai_finding;
CREATE TRIGGER t_inherit_scope BEFORE INSERT OR UPDATE ON public.ai_finding
  FOR EACH ROW EXECUTE FUNCTION app.ai_output_inherit_scope();


-- ---- 6.2 what a reviewer may change ----------------------------------------------------------
-- RLS decides which ROWS a caller may update; it says nothing about which COLUMNS. Without this
-- guard, a clinician with the review grant could edit the model's own words, its confidence or
-- its run — i.e. rewrite what the model said and then accept it, which is worse than no review
-- at all because it looks like review.
CREATE OR REPLACE FUNCTION app.ai_finding_before_update()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_member uuid := app.current_member_id();
BEGIN
  -- Trusted workers (service_role, migrations) may complete a run's output normally.
  IF v_member IS NULL THEN
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

  -- A review names the person doing it, and they cannot name somebody else.
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
  'the server clock rather than trusting values from the client.';

DROP TRIGGER IF EXISTS t_guard_update ON public.ai_finding;
CREATE TRIGGER t_guard_update BEFORE UPDATE ON public.ai_finding
  FOR EACH ROW EXECUTE FUNCTION app.ai_finding_before_update();


-- =============================================================================================
-- SECTION 7 — RISK SCORES AND CONTRIBUTING FACTORS
--
-- This is the prognosis screen, column by column:
--   "Sepsis risk · 48h / 92% / ↑ 14 pts since admission"
--        risk_type='sepsis', horizon='48 hours', probability=0.9200, band='high',
--        change_points=14, change_window='since admission' (as a note),
--   "ICU transfer · 72h / 54% / ↑ 8 pts in 24h"
--        risk_type='icu_transfer', horizon='72 hours', probability=0.5400, band='medium'
--   "Est. length of stay / 9–12 days / vs. 5–7 day cohort median"
--        risk_type='length_of_stay', value_kind='range', range 9–12, unit='days',
--        baseline 5–7, baseline_label='cohort median'
--   The 7-bar "Risk trajectory · 72h" chart is not a separate table: it is the rows for one
--   (patient, risk_type) ordered by as_of. That is also why there is no previous_score_id — a
--   self-referencing chain would be a second, forgeable ordering of the same facts.
--
-- WHY RISK SCORES CARRY NO REVIEW STATE
--   A score is a reading, always shown with the disclaimer strip the design mandates. What gets
--   ACCEPTED and written into a chart is a finding — a recommended action, a summary. Putting a
--   review state on both would give the same clinical act two records that can disagree.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.ai_risk_score (
    id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id  uuid        NOT NULL REFERENCES public.organization (id)
                                 ON UPDATE CASCADE ON DELETE RESTRICT,
    run_id           uuid        NOT NULL,
    patient_id       uuid        NOT NULL,

    risk_type        app.ai_risk_type  NOT NULL,
    value_kind       app.ai_value_kind NOT NULL,
    -- The prediction window. "92%" with no horizon is not a clinical statement, so a
    -- probability without one is refused below.
    horizon          interval    NULL,

    probability      numeric(5,4) NULL,   -- 0.9200 → "92%"
    range_low        numeric(10,2) NULL,  --  9.00 ┐ "9–12 days"
    range_high       numeric(10,2) NULL,  -- 12.00 ┘
    unit             text        NULL,    -- 'days'

    -- Stored, not derived from the probability at read time: re-tuning the thresholds later
    -- must not silently recolour output a clinician already acted on.
    band             app.ai_risk_band NOT NULL,

    -- The movement line under the number.
    change_points    numeric(6,2) NULL,   -- 14  → "↑ 14 pts"
    change_note      text        NULL,    -- 'since admission', 'in 24h'

    -- The comparison line: "vs. 5–7 day cohort median".
    baseline_low     numeric(10,2) NULL,
    baseline_high    numeric(10,2) NULL,
    baseline_label   text        NULL,

    as_of            timestamptz NOT NULL DEFAULT now(),
    created_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ai_risk_score_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT ai_risk_score_run_fk
      FOREIGN KEY (run_id, organization_id)
      REFERENCES public.ai_analysis_run (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_risk_score_patient_fk
      FOREIGN KEY (patient_id, organization_id)
      REFERENCES public.patient (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,

    -- One score per risk type per run: a run that produced two sepsis numbers is a bug.
    CONSTRAINT ai_risk_score_run_type_uk UNIQUE (run_id, risk_type),

    CONSTRAINT ai_risk_score_shape_ck CHECK (
         (value_kind = 'probability'
            AND probability IS NOT NULL AND range_low IS NULL AND range_high IS NULL)
      OR (value_kind = 'range'
            AND probability IS NULL AND range_low IS NOT NULL AND range_high IS NOT NULL
            AND unit IS NOT NULL)),
    CONSTRAINT ai_risk_score_probability_ck
      CHECK (probability IS NULL OR (probability >= 0 AND probability <= 1)),
    CONSTRAINT ai_risk_score_range_ck
      CHECK (range_low IS NULL OR range_high >= range_low),
    CONSTRAINT ai_risk_score_horizon_ck
      CHECK (horizon IS NULL OR horizon > interval '0'),
    -- A probability with no window is uninterpretable, and the UI label ("Sepsis risk · 48h")
    -- is generated from this column, so an empty one is a blank label too.
    CONSTRAINT ai_risk_score_probability_horizon_ck
      CHECK (value_kind <> 'probability' OR horizon IS NOT NULL),
    CONSTRAINT ai_risk_score_baseline_ck
      CHECK ((baseline_low IS NULL) = (baseline_high IS NULL)
             AND (baseline_low IS NULL OR baseline_high >= baseline_low)),
    CONSTRAINT ai_risk_score_change_ck
      CHECK (change_note IS NULL OR change_points IS NOT NULL)
);

-- The trajectory chart and "latest score for this patient" are the same index.
CREATE INDEX IF NOT EXISTS ai_risk_score_series_ix
  ON public.ai_risk_score (organization_id, patient_id, risk_type, as_of DESC);
CREATE INDEX IF NOT EXISTS ai_risk_score_run_ix
  ON public.ai_risk_score (run_id);
-- The dashboard's "High-risk flags (AI)" KPI and its tinted list.
CREATE INDEX IF NOT EXISTS ai_risk_score_high_ix
  ON public.ai_risk_score (organization_id, as_of DESC)
  WHERE band IN ('high', 'critical');

COMMENT ON TABLE public.ai_risk_score IS
  'The numbers the prognosis and dashboard screens print: sepsis 92% over 48h, ICU transfer 54% '
  'over 72h, length of stay 9-12 days. One row per (run, risk_type); the 72-hour trajectory '
  'chart is these rows ordered by as_of, not a separate time series.';
COMMENT ON COLUMN public.ai_risk_score.band IS
  'The red/amber/green band, stored rather than computed at read time so changing the '
  'thresholds later cannot recolour a decision somebody already made.';

DROP TRIGGER IF EXISTS t_no_delete ON public.ai_risk_score;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.ai_risk_score
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();
DROP TRIGGER IF EXISTS t_inherit_scope ON public.ai_risk_score;
CREATE TRIGGER t_inherit_scope BEFORE INSERT OR UPDATE ON public.ai_risk_score
  FOR EACH ROW EXECUTE FUNCTION app.ai_output_inherit_scope();


CREATE TABLE IF NOT EXISTS public.ai_risk_factor (
    id                   uuid     PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id      uuid     NOT NULL REFERENCES public.organization (id)
                                  ON UPDATE CASCADE ON DELETE RESTRICT,
    risk_score_id        uuid     NOT NULL,

    label                text     NOT NULL,          -- 'Lactate 3.1, rising'
    -- Signed contribution in the model's own units: +0.310, -0.090. The sign carries meaning —
    -- the screen colours negative (protective) factors green.
    weight               numeric(6,3) NOT NULL,
    -- 0–1, the bar width the screen draws. Separate from weight because the bar is scaled to
    -- the largest factor in the set, and that scaling is the model's to state, not the UI's to
    -- guess from a column it does not know the maximum of.
    normalized_magnitude numeric(4,3) NULL,
    display_order        integer  NOT NULL DEFAULT 0,
    detail               text     NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ai_risk_factor_id_org_uk UNIQUE (id, organization_id),
    CONSTRAINT ai_risk_factor_score_fk
      FOREIGN KEY (risk_score_id, organization_id)
      REFERENCES public.ai_risk_score (id, organization_id)
      ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_risk_factor_label_ck CHECK (btrim(label) <> ''),
    CONSTRAINT ai_risk_factor_magnitude_ck
      CHECK (normalized_magnitude IS NULL
             OR (normalized_magnitude >= 0 AND normalized_magnitude <= 1)),
    CONSTRAINT ai_risk_factor_order_uk UNIQUE (risk_score_id, display_order)
);

CREATE INDEX IF NOT EXISTS ai_risk_factor_score_ix
  ON public.ai_risk_factor (risk_score_id, display_order);

COMMENT ON TABLE public.ai_risk_factor IS
  'The weighted contributing factors the prognosis screen renders as labelled bars: +0.31 '
  'lactate, +0.24 HR trend, +0.18 MAP, +0.13 age/comorbidities, -0.09 antibiotic response. '
  'Each factor should carry at least one ai_citation; §8 explains why that is a convention '
  'here rather than a constraint.';

DROP TRIGGER IF EXISTS t_no_delete ON public.ai_risk_factor;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.ai_risk_factor
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 8 — CITATIONS: WHY A CLINICIAN CAN CHECK THE WORK
--
-- The AI assistant screen says "Lactate rose from 2.2 to 3.1 mmol/L (+0.31 to risk score)".
-- That sentence is only worth anything if the 3.1 points at an actual row somebody can open.
-- This table is that pointer, for findings, scores and individual factors alike.
--
-- ONE TABLE, FIVE SHAPES. The alternative is five narrow tables (span / region / value / prior
-- finding / none) and a UNION every time the UI wants "the evidence for this". A citation is
-- read as a list, always, so the polymorphic column set with one CHECK per shape is the design
-- that matches how it is used. Each shape's CHECK is strict enough that a half-filled citation
-- cannot be stored.
--
-- SOFT REFERENCE INTO 020's CLINICAL TABLES, DELIBERATELY
--   source_kind='clinical_value' points at a lab result, a vital, a medication — rows owned by
--   020, which this migration must not couple to. There is no FK, and the reason is not
--   laziness: a hard FK would make 030 unloadable until 020's table names are frozen, and would
--   make renaming a clinical table a cross-migration event. What we keep instead is the honest
--   part — the value AS DISPLAYED at the time it was cited (observed_value, observed_at) — so
--   the citation still tells the truth about what the model saw even if the row later changes.
--   The pair (source_table, source_row_id) is resolved by a documented join in the API.
--   Tightening source_table to an allowlist once 020 exists is in the open questions.
--
-- WHY "AT LEAST ONE CITATION" IS NOT A CONSTRAINT
--   It cannot be one: the finding must exist before a row can reference it, so any such rule is
--   deferred-constraint or trigger machinery that fires at COMMIT. More importantly, the
--   honest failure mode is a finding that rests on general knowledge, and 'model_knowledge'
--   exists so that case is RECORDED rather than faked with a plausible-looking pointer.
--   Enforcing a count would push authors toward the fake. The CI query in §12 reports
--   uncited findings instead, which is the right pressure in the right place.
-- =============================================================================================

CREATE TABLE IF NOT EXISTS public.ai_citation (
    id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id   uuid        NOT NULL REFERENCES public.organization (id)
                                  ON UPDATE CASCADE ON DELETE RESTRICT,

    -- Exactly one subject. Enforced below.
    finding_id        uuid        NULL,
    risk_score_id     uuid        NULL,
    risk_factor_id    uuid        NULL,

    source_kind       app.ai_citation_source NOT NULL,

    -- A — a span inside an extraction (source_kind = 'document_text_span')
    document_text_id  uuid        NULL,
    char_start        integer     NULL,
    char_end          integer     NULL,
    -- Snapshot of the quoted words. Re-extraction moves character offsets; this column means an
    -- old citation still shows the clinician what was actually quoted.
    quoted_text       text        NULL,

    -- B — a region of a rendered page (source_kind = 'document_page_region')
    document_id       uuid        NULL,
    page_number       integer     NULL,
    bounding_box      jsonb       NULL,   -- {"x":0.12,"y":0.44,"w":0.30,"h":0.06}, page-relative

    -- C — a clinical value owned by 020 (source_kind = 'clinical_value'). Soft reference.
    source_table      text        NULL,
    source_row_id     uuid        NULL,
    source_column     text        NULL,
    observed_value    text        NULL,   -- '3.1 mmol/L', exactly as displayed when cited
    observed_at       timestamptz NULL,

    -- D — an earlier finding this one builds on (source_kind = 'prior_finding')
    prior_finding_id  uuid        NULL,

    relevance         numeric(4,3) NULL,
    display_order     integer     NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ai_citation_id_org_uk UNIQUE (id, organization_id),

    -- Every FK composite, so a citation cannot reach across tenants even by accident.
    CONSTRAINT ai_citation_finding_fk
      FOREIGN KEY (finding_id, organization_id)
      REFERENCES public.ai_finding (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_citation_score_fk
      FOREIGN KEY (risk_score_id, organization_id)
      REFERENCES public.ai_risk_score (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_citation_factor_fk
      FOREIGN KEY (risk_factor_id, organization_id)
      REFERENCES public.ai_risk_factor (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_citation_text_fk
      FOREIGN KEY (document_text_id, organization_id)
      REFERENCES public.document_text (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_citation_document_fk
      FOREIGN KEY (document_id, organization_id)
      REFERENCES public.document (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ai_citation_prior_finding_fk
      FOREIGN KEY (prior_finding_id, organization_id)
      REFERENCES public.ai_finding (id, organization_id) ON UPDATE CASCADE ON DELETE RESTRICT,

    CONSTRAINT ai_citation_one_subject_ck CHECK (
      num_nonnulls(finding_id, risk_score_id, risk_factor_id) = 1),

    CONSTRAINT ai_citation_span_ck CHECK (
      source_kind <> 'document_text_span'
      OR (document_text_id IS NOT NULL AND char_start IS NOT NULL AND char_start >= 0
          AND char_end > char_start AND btrim(coalesce(quoted_text, '')) <> '')),
    CONSTRAINT ai_citation_region_ck CHECK (
      source_kind <> 'document_page_region'
      OR (document_id IS NOT NULL AND page_number IS NOT NULL AND page_number > 0
          AND bounding_box IS NOT NULL AND jsonb_typeof(bounding_box) = 'object')),
    CONSTRAINT ai_citation_clinical_ck CHECK (
      source_kind <> 'clinical_value'
      OR (source_table IS NOT NULL AND source_row_id IS NOT NULL
          AND btrim(coalesce(observed_value, '')) <> '')),
    CONSTRAINT ai_citation_prior_ck CHECK (
      source_kind <> 'prior_finding' OR prior_finding_id IS NOT NULL),
    -- The honest escape hatch must stay honest: it may not smuggle in a pointer that suggests
    -- patient-specific evidence there was none of.
    CONSTRAINT ai_citation_model_knowledge_ck CHECK (
      source_kind <> 'model_knowledge'
      OR num_nonnulls(document_text_id, document_id, source_table, source_row_id,
                      prior_finding_id) = 0),

    -- Shape only, not an allowlist: 020 owns those names and this file must not pin them.
    CONSTRAINT ai_citation_source_table_ck
      CHECK (source_table IS NULL OR source_table ~ '^[a-z][a-z0-9_]{2,40}$'),
    CONSTRAINT ai_citation_relevance_ck
      CHECK (relevance IS NULL OR (relevance >= 0 AND relevance <= 1))
);

-- The allowlist the CHECK above could not carry inline. It is applied as a separate constraint
-- so the CREATE TABLE stays loadable on its own, and it is added here rather than left as an
-- open question because §0 has already established that 020 ran and its table names are final.
-- A `clinical_value` citation pointing at 'lab_reslt' is evidence nobody can follow; with the
-- allowlist it is a constraint violation at write time instead.
DO $citation_allowlist$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_citation_source_table_allowed_ck') THEN
    ALTER TABLE public.ai_citation ADD CONSTRAINT ai_citation_source_table_allowed_ck
      CHECK (source_table IS NULL OR source_table IN (
        'vital_sign', 'lab_result', 'lab_order', 'clinical_note', 'medication_order',
        'encounter', 'patient_condition', 'patient_allergy', 'appointment'));
  END IF;
END
$citation_allowlist$;

CREATE INDEX IF NOT EXISTS ai_citation_finding_ix
  ON public.ai_citation (finding_id, display_order) WHERE finding_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ai_citation_score_ix
  ON public.ai_citation (risk_score_id, display_order) WHERE risk_score_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ai_citation_factor_ix
  ON public.ai_citation (risk_factor_id, display_order) WHERE risk_factor_id IS NOT NULL;
-- "What has the model ever cited this lab result for?" — the reverse lookup an audit asks.
CREATE INDEX IF NOT EXISTS ai_citation_source_ix
  ON public.ai_citation (organization_id, source_table, source_row_id)
  WHERE source_table IS NOT NULL;

COMMENT ON TABLE public.ai_citation IS
  'What a finding, score or contributing factor rests on: a text span in an extraction, a '
  'region of a page, a clinical value owned by 020, or an earlier finding. Output with no '
  'citation is output nobody can check; the ''model_knowledge'' kind exists so "there was no '
  'patient-specific evidence" is recorded rather than hidden.';
COMMENT ON COLUMN public.ai_citation.quoted_text IS
  'Verbatim snapshot of the cited words, so a citation into a later re-extracted document still '
  'shows the clinician what was quoted even after the offsets have moved.';
COMMENT ON COLUMN public.ai_citation.source_table IS
  'Soft reference into migration 020 — no cross-migration FK, so 020 can evolve independently. '
  'observed_value/observed_at hold the value as displayed when cited, which is the part that '
  'must not change underneath the citation.';

DROP TRIGGER IF EXISTS t_no_delete ON public.ai_citation;
CREATE TRIGGER t_no_delete BEFORE DELETE ON public.ai_citation
  FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete();


-- =============================================================================================
-- SECTION 9 — ROW LEVEL SECURITY
--
-- Read every policy as: TENANT first, then role, then row. Every one of them opens with
-- `organization_id = app.current_org_id()`, which is house rule 4 and the reason a vendor
-- super_admin sees nothing here: they hold no membership, so that function returns NULL, so
-- every policy below yields zero rows. There is no `OR app.is_super_admin()` anywhere in this
-- file and there must never be one — §12 fails CI if somebody adds it.
--
-- ENABLE, never FORCE (010 §8.1): the helper functions are SECURITY DEFINER owned by the table
-- owner, and FORCE would have the policies calling the functions that read the tables.
--
-- THE PER-PATIENT SEAM — CLOSED (this was the largest open item in the first draft)
--   These policies scope to TENANT, then ROLE, then ROW. The row predicate is 020's
--   `patient_id = ANY (app.care_patient_ids())`: the patients the caller holds an open
--   care_team_member row for. An earlier draft of this file stopped at tenant + role because it
--   was written as though 020 had not landed, which meant any doctor or nurse could read any
--   chart in their own hospital — tenant isolation intact, the second boundary missing. 020 runs
--   first (§0 now refuses to apply this file otherwise), so the predicate is used directly.
--
--   Shape, identical on every clinical table here and in 020, so a reviewer can check them at a
--   glance:
--       organization_id = app.current_org_id()             -- tenant, always first
--       AND app.is_clinician()                             -- purpose
--       AND patient_id = ANY (app.care_patient_ids())      -- row
--   app.care_patient_ids() is argument-free and STABLE, so PostgreSQL folds it into an InitPlan
--   and evaluates it once per statement, not once per row.
--
--   ai_risk_factor and ai_citation deliberately do NOT repeat the predicate: they are scoped
--   through an EXISTS on their parent, whose own policy applies inside the subquery. That is
--   what keeps evidence visible exactly when the claim it supports is visible, with no second
--   copy of the rule to drift.
--
-- ROLE REACH, DECIDED PER TABLE (and why)
--   clinician (doctor/nurse) — documents, extracted text, runs, findings, scores, factors,
--       citations. The clinical surface.
--   receptionist — documents they uploaded, plus scanned_document/other. They register patients
--       and scan consent forms and insurance cards; they have no business in a radiology report.
--   patient — their own uploads, documents released to them, and findings explicitly marked
--       patient_visible AND reviewed. Never risk scores: the portal shows plain language by
--       design, and "sepsis 92%" arriving unmediated on a phone is the failure mode that design
--       exists to prevent.
--   hospital_admin — nothing. Administering a hospital is not a treatment purpose (010 §8.6).
-- =============================================================================================

ALTER TABLE public.document          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.document_text     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_analysis_run   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_finding        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_risk_score     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_risk_factor    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ai_citation       ENABLE ROW LEVEL SECURITY;

-- ---- document --------------------------------------------------------------------------------
DROP POLICY IF EXISTS document_select ON public.document;
CREATE POLICY document_select ON public.document FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
      -- You can always see what you uploaded, including before it is classified — otherwise
      -- the front desk loses sight of its own scan the moment it lands. Scoped to your own
      -- seat, so it is not a route into anyone else's chart.
      OR uploaded_by_member_id = app.current_member_id()
      OR (app.is_front_desk() AND doc_type IN ('scanned_document', 'other'))
      OR (patient_id = app.current_patient_id()
          AND (source = 'patient_upload' OR patient_visible))
    )
  );

-- The client declares nothing about safety: scan_status must start at 'pending' (only the
-- scanner moves it, per app.document_before_update), the row is not portal-visible on arrival,
-- and the uploader is the caller's own seat. The tenant-scoped storage key is a CHECK, so it
-- holds here too.
DROP POLICY IF EXISTS document_insert ON public.document;
CREATE POLICY document_insert ON public.document FOR INSERT
  WITH CHECK (
    organization_id = app.current_org_id()
    AND scan_status = 'pending'
    AND NOT patient_visible
    AND retracted_at IS NULL
    AND uploaded_by_member_id = app.current_member_id()
    AND (
      -- A clinician uploads into a chart they are on. Reception is NOT care-team scoped here on
      -- purpose: scanning a consent form or an insurance card at registration happens before
      -- anyone is assigned, and the document_select policy above already limits what the desk
      -- can read back to the administrative document types and its own uploads.
      (app.is_clinician() AND patient_id = ANY (app.care_patient_ids())
                          AND source = 'staff_upload')
      OR (app.is_front_desk() AND source = 'staff_upload')
      OR (patient_id = app.current_patient_id() AND source = 'patient_upload')
    )
  );

-- Classification confirmation, portal release and retraction. Column-level limits are in
-- app.document_before_update(); RLS only decides which rows are in reach.
DROP POLICY IF EXISTS document_update ON public.document;
CREATE POLICY document_update ON public.document FOR UPDATE
  USING (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id = ANY (app.care_patient_ids()))
      -- The receptionist who just scanned the wrong consent form must be able to retract it
      -- without finding a doctor. They can only reach rows they uploaded themselves.
      OR uploaded_by_member_id = app.current_member_id()
    )
  )
  WITH CHECK (organization_id = app.current_org_id());
-- No DELETE policy anywhere in this file, and app.deny_hard_delete() behind it.

-- ---- document_text ---------------------------------------------------------------------------
-- Clinicians on the care team only. Raw OCR of a radiology report is not a front-desk surface
-- and not a portal surface; the portal gets a reviewed plain-language finding instead.
-- patient_id is denormalised onto this table precisely so this predicate needs no join.
DROP POLICY IF EXISTS document_text_select ON public.document_text;
CREATE POLICY document_text_select ON public.document_text FOR SELECT
  USING (organization_id = app.current_org_id()
         AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));
-- Written by the extraction worker as service_role: no INSERT or UPDATE policy on purpose.

-- ---- ai_analysis_run -------------------------------------------------------------------------
DROP POLICY IF EXISTS ai_analysis_run_select ON public.ai_analysis_run;
CREATE POLICY ai_analysis_run_select ON public.ai_analysis_run FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id IS NOT NULL
                          AND patient_id = ANY (app.care_patient_ids()))
      -- A panel brief is about one clinician's own list; another doctor has no call on it.
      OR (patient_id IS NULL AND requested_by_member_id = app.current_member_id())
    )
  );
-- No write policies: runs are created and completed by the model worker as service_role. A web
-- session therefore cannot fabricate a model result or backdate one.

-- ---- ai_finding ------------------------------------------------------------------------------
DROP POLICY IF EXISTS ai_finding_select ON public.ai_finding;
CREATE POLICY ai_finding_select ON public.ai_finding FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND (
      (app.is_clinician() AND patient_id IS NOT NULL
                          AND patient_id = ANY (app.care_patient_ids()))
      OR (patient_id IS NULL
          AND EXISTS (SELECT 1 FROM public.ai_analysis_run r
                       WHERE r.id = ai_finding.run_id
                         AND r.requested_by_member_id = app.current_member_id()))
      -- The portal, and only what a clinician deliberately released after reviewing it. The
      -- two conditions are also a CHECK (ai_finding_patient_visible_ck); stating them here too
      -- means a future relaxation of one does not quietly widen the other.
      OR (patient_id = app.current_patient_id()
          AND patient_visible
          AND review_state IN ('accepted', 'amended'))
    )
  );

-- The one AI table a human writes: the review decision itself.
DROP POLICY IF EXISTS ai_finding_update ON public.ai_finding;
CREATE POLICY ai_finding_update ON public.ai_finding FOR UPDATE
  USING (organization_id = app.current_org_id()
         AND app.is_clinician() AND patient_id IS NOT NULL
         AND patient_id = ANY (app.care_patient_ids()))
  WITH CHECK (organization_id = app.current_org_id());
-- Reviewing model output about a patient is a clinical act, so it needs the same treatment
-- relationship as reading the chart. Without the row predicate, "accept" — the decision that
-- lets a finding reach a chart and then a phone — would be available to the whole hospital.

-- ---- ai_risk_score ---------------------------------------------------------------------------
-- Clinicians on the care team. Deliberately not the patient: the portal's design answer to a
-- risk number is a reviewed plain-language explanation, not the raw percentage.
DROP POLICY IF EXISTS ai_risk_score_select ON public.ai_risk_score;
CREATE POLICY ai_risk_score_select ON public.ai_risk_score FOR SELECT
  USING (organization_id = app.current_org_id()
         AND app.is_clinician()
         AND patient_id = ANY (app.care_patient_ids()));

-- ---- ai_risk_factor --------------------------------------------------------------------------
-- Scoped through its parent. Because the subquery is an ordinary query, ai_risk_score's own
-- policy applies inside it — including the care-team predicate above — so this policy narrows
-- with the score and cannot drift out of step with it.
DROP POLICY IF EXISTS ai_risk_factor_select ON public.ai_risk_factor;
CREATE POLICY ai_risk_factor_select ON public.ai_risk_factor FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND EXISTS (SELECT 1 FROM public.ai_risk_score s
                 WHERE s.id = ai_risk_factor.risk_score_id)
  );

-- ---- ai_citation -----------------------------------------------------------------------------
-- Same inheritance trick, one branch per subject. A citation is visible exactly when the thing
-- it explains is visible — evidence never outlives its claim.
DROP POLICY IF EXISTS ai_citation_select ON public.ai_citation;
CREATE POLICY ai_citation_select ON public.ai_citation FOR SELECT
  USING (
    organization_id = app.current_org_id()
    AND app.is_clinician()
    AND (
      EXISTS (SELECT 1 FROM public.ai_finding f     WHERE f.id = ai_citation.finding_id)
      OR EXISTS (SELECT 1 FROM public.ai_risk_score s  WHERE s.id = ai_citation.risk_score_id)
      OR EXISTS (SELECT 1 FROM public.ai_risk_factor k WHERE k.id = ai_citation.risk_factor_id)
    )
  );


-- =============================================================================================
-- SECTION 10 — GRANTS
--
-- Privileges and policies are two different gates and both have to be shut. A policy the caller
-- has no table privilege for is decoration; a privilege with no policy is a hole. The shape
-- below is deliberate: `authenticated` can read the clinical surface, upload a document, and
-- record a review. Everything else — creating runs, writing findings, scores, factors,
-- citations, extracted text — is service_role only, which is what makes model output
-- unforgeable from a browser.
--
-- >>> BEGIN SUPABASE-SPECIFIC: role names are the PostgREST convention <<<
-- =============================================================================================

DO $grants$
BEGIN
  -- New functions arrive with EXECUTE granted to PUBLIC. 010's blanket revoke ran before these
  -- existed, so take it back here too and hand it out deliberately.
  EXECUTE 'REVOKE EXECUTE ON FUNCTION
             app.document_text_inherit_scope(), app.ai_run_enforce_source_policy(),
             app.document_before_update(), app.document_sync_run_source_type(),
             app.ai_output_inherit_scope(), app.ai_finding_before_update()
           FROM PUBLIC';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT ON
               public.document, public.document_text, public.ai_analysis_run,
               public.ai_finding, public.ai_risk_score, public.ai_risk_factor,
               public.ai_citation
             TO authenticated';

    -- Uploading is a user action; classification confirmation, portal release and retraction
    -- are UPDATEs on the same row.
    EXECUTE 'GRANT INSERT, UPDATE ON public.document TO authenticated';
    -- The review decision. No INSERT: a user cannot create a finding to then accept.
    EXECUTE 'GRANT UPDATE ON public.ai_finding TO authenticated';

    -- Postgres checks EXECUTE on a trigger function when the trigger is created, not when it
    -- fires, so this is belt-and-braces. Calling any of them directly just raises.
    EXECUTE 'GRANT EXECUTE ON FUNCTION
               app.document_before_update(), app.document_sync_run_source_type(),
               app.ai_finding_before_update(), app.ai_output_inherit_scope(),
               app.document_text_inherit_scope(), app.ai_run_enforce_source_policy()
             TO authenticated';
  END IF;

  -- The model worker, the extraction worker and the malware scanner. service_role already holds
  -- BYPASSRLS; it still needs table privileges.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT SELECT, INSERT, UPDATE ON
               public.document, public.document_text, public.ai_analysis_run,
               public.ai_finding, public.ai_risk_score, public.ai_risk_factor,
               public.ai_citation
             TO service_role';
    EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA app TO service_role';
  END IF;

  -- DELETE is granted to nobody, on any table in this file. app.deny_hard_delete() is the
  -- backstop for whoever gets it anyway.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON
               public.document, public.document_text, public.ai_analysis_run,
               public.ai_finding, public.ai_risk_score, public.ai_risk_factor,
               public.ai_citation
             FROM anon';
  END IF;

  RAISE NOTICE 'prognosify/030: bytes live in object storage under app.storage_prefix(org). '
               'Whatever signs download URLs MUST check document.scan_status = ''clean'' and '
               'that the key prefix matches the caller''s organisation — the database cannot '
               'sign a URL for you.';
END
$grants$;
-- >>> END SUPABASE-SPECIFIC <<< ----------------------------------------------------------------


-- =============================================================================================
-- SECTION 11 — OPTIONAL: pgvector semantic search over report text
--
-- ================== THIS ENTIRE SECTION IS OPTIONAL AND FUTURE-FACING ==================
-- Nothing in the 20 screens needs it today. It is here so the shape is agreed before somebody
-- bolts an untenanted vector table onto the side. If pgvector is unavailable the block raises a
-- NOTICE and skips; the lexical search in §3 (document_text.search_tsv + its GIN index) keeps
-- working either way and covers most of "find the report that mentions X".
--
-- ONE TABLE, NOT TWO. The draft had chunks and embeddings separately, which is the textbook
-- shape and correct when several embedding models coexist. Here a chunk exists only to be
-- embedded, so the row carries both and is keyed (text, model, index). The cost is honest and
-- worth naming: running two embedding models at once duplicates the chunk TEXT. That happens
-- during a model migration and nowhere else, and paying it there is cheaper than carrying a
-- join everywhere forever.
--
-- TENANT SCOPING IS NOT OPTIONAL EVEN THOUGH THE SECTION IS. A vector index is a retrieval
-- surface: an unscoped nearest-neighbour query over every hospital's reports is a cross-tenant
-- leak with a friendly API. organization_id, composite FKs and RLS apply exactly as elsewhere,
-- and every similarity query must filter on organization_id AND one embedding_model — vectors
-- from different models are not comparable, so mixing them silently returns nonsense.
-- =============================================================================================

DO $vec$
DECLARE
  v_ext_schema text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
    RAISE NOTICE 'prognosify/030 §11: pgvector not available on this server; semantic search '
                 'skipped. Lexical search (document_text.search_tsv) is unaffected.';
    RETURN;
  END IF;

  EXECUTE 'CREATE EXTENSION IF NOT EXISTS vector';

  -- Supabase installs extensions into "extensions"; most other hosts use "public". Resolve it
  -- rather than assuming, and schema-qualify both the type and the operator class.
  SELECT n.nspname INTO v_ext_schema
    FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'vector';

  -- Dimension note: 1536 suits several common embedding models. vector(n) is fixed per column,
  -- so change it HERE, before any rows exist, if you pick a model of a different width.
  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS public.document_text_chunk (
      id               uuid    PRIMARY KEY DEFAULT gen_random_uuid(),
      organization_id  uuid    NOT NULL REFERENCES public.organization (id)
                               ON UPDATE CASCADE ON DELETE RESTRICT,
      document_text_id uuid    NOT NULL,
      patient_id       uuid    NOT NULL,

      chunk_index      integer NOT NULL,
      char_start       integer NOT NULL,
      char_end         integer NOT NULL,
      content          text    NOT NULL,

      embedding_model  text    NOT NULL,
      embedding        %I.vector(1536) NOT NULL,
      created_at       timestamptz NOT NULL DEFAULT now(),

      CONSTRAINT document_text_chunk_id_org_uk UNIQUE (id, organization_id),
      CONSTRAINT document_text_chunk_text_fk
        FOREIGN KEY (document_text_id, organization_id)
        REFERENCES public.document_text (id, organization_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
      CONSTRAINT document_text_chunk_patient_fk
        FOREIGN KEY (patient_id, organization_id)
        REFERENCES public.patient (id, organization_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
      CONSTRAINT document_text_chunk_uk UNIQUE (document_text_id, embedding_model, chunk_index),
      CONSTRAINT document_text_chunk_span_ck
        CHECK (char_start >= 0 AND char_end > char_start),
      CONSTRAINT document_text_chunk_content_ck CHECK (btrim(content) <> ''),
      CONSTRAINT document_text_chunk_model_ck   CHECK (btrim(embedding_model) <> '')
    )$ddl$, v_ext_schema);

  EXECUTE $c1$COMMENT ON TABLE public.document_text_chunk IS
    'OPTIONAL (§11). Chunks of extracted report text with their embeddings, one row per '
    '(extraction, embedding model, chunk). Keyed to a span so a hit points at the passage a '
    'clinician should read — and converts directly into an ai_citation of kind '
    'document_text_span.'$c1$;
  EXECUTE $c2$COMMENT ON COLUMN public.document_text_chunk.embedding_model IS
    'Embeddings from different models are not comparable. Every similarity query must filter on '
    'organization_id AND one embedding_model, or it returns confident nonsense across tenants.'$c2$;

  -- HNSW needs pgvector >= 0.5. Without it the table still works (exact scan), so a missing
  -- index is a notice, not a failed migration.
  BEGIN
    EXECUTE format('CREATE INDEX IF NOT EXISTS document_text_chunk_hnsw
                      ON public.document_text_chunk
                      USING hnsw (embedding %I.vector_cosine_ops)', v_ext_schema);
  EXCEPTION WHEN undefined_object OR feature_not_supported OR syntax_error THEN
    RAISE NOTICE 'prognosify/030 §11: HNSW unavailable (pgvector < 0.5). Table created without '
                 'a vector index.';
  END;

  EXECUTE 'CREATE INDEX IF NOT EXISTS document_text_chunk_scope_ix
             ON public.document_text_chunk (organization_id, embedding_model, patient_id)';

  EXECUTE 'ALTER TABLE public.document_text_chunk ENABLE ROW LEVEL SECURITY';
  EXECUTE 'DROP POLICY IF EXISTS document_text_chunk_select ON public.document_text_chunk';
  -- Same three-part shape as every other clinical policy here. A nearest-neighbour search is a
  -- retrieval surface: without the row predicate, one similarity query would return passages
  -- from charts the caller has no relationship with — and it would look like a feature.
  EXECUTE $p1$CREATE POLICY document_text_chunk_select ON public.document_text_chunk FOR SELECT
             USING (organization_id = app.current_org_id()
                    AND app.is_clinician()
                    AND patient_id = ANY (app.care_patient_ids()))$p1$;

  EXECUTE 'DROP TRIGGER IF EXISTS t_no_delete ON public.document_text_chunk';
  EXECUTE 'CREATE TRIGGER t_no_delete BEFORE DELETE ON public.document_text_chunk
             FOR EACH ROW EXECUTE FUNCTION app.deny_hard_delete()';

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT ON public.document_text_chunk TO authenticated';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    EXECUTE 'GRANT SELECT, INSERT ON public.document_text_chunk TO service_role';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'REVOKE ALL ON public.document_text_chunk FROM anon';
  END IF;

  RAISE NOTICE 'prognosify/030 §11: pgvector enabled; public.document_text_chunk created.';
END
$vec$;


-- =============================================================================================
-- SECTION 12 — SELF-CHECKS (run in CI; they are the cheapest audit you will ever get)
-- =============================================================================================

-- Findings nobody can check. Not a constraint (§8 explains why), but a number that should be
-- watched: if it climbs, the prompt has stopped grounding its answers.
CREATE OR REPLACE VIEW app.v_ai_uncited_findings
WITH (security_invoker = true) AS
SELECT f.organization_id,
       f.id            AS finding_id,
       f.kind,
       f.created_at,
       r.model_name,
       r.model_version,
       r.prompt_version
  FROM public.ai_finding f
  JOIN public.ai_analysis_run r ON r.id = f.run_id
 WHERE NOT EXISTS (SELECT 1 FROM public.ai_citation c WHERE c.finding_id = f.id);

COMMENT ON VIEW app.v_ai_uncited_findings IS
  'Findings with no citation of any kind, not even model_knowledge. security_invoker, so it '
  'shows the caller only their own tenant.';

-- Granted here rather than in §10 because the view does not exist until this section.
DO $view_grant$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'GRANT SELECT ON app.v_ai_uncited_findings TO authenticated';
  END IF;
END
$view_grant$;

DO $ci$
DECLARE
  v_gaps text;
  v_missing text;
BEGIN
  -- 1. No policy in this file may hand the vendor blanket access to clinical rows. 010 provides
  --    this gate; call it with every PHI table 030 owns.
  PERFORM app.assert_no_vendor_phi_policies(ARRAY[
    'document', 'document_text', 'ai_analysis_run', 'ai_finding',
    'ai_risk_score', 'ai_risk_factor', 'ai_citation', 'document_text_chunk']);

  -- 2. House rule 4: every table carrying organization_id has RLS on.
  SELECT string_agg(g.table_name, ', ') INTO v_gaps FROM app.v_tenant_rls_gaps g;
  IF v_gaps IS NOT NULL THEN
    RAISE EXCEPTION 'Tables carry organization_id but have RLS disabled: %', v_gaps
      USING errcode = '42501';
  END IF;

  -- 3. The safety rule is only real while its constraints exist. Somebody dropping one to get a
  --    test to pass is exactly the failure this catches, and it costs one catalogue query.
  SELECT string_agg(x.name, ', ') INTO v_missing
    FROM (VALUES
            ('ai_run_no_image_interpretation_ck'),
            ('ai_run_source_classified_ck'),
            ('ai_finding_chart_gate_ck'),
            ('ai_finding_patient_visible_ck'),
            ('document_storage_key_tenant_ck')
         ) AS x(name)
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conname = x.name);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'Safety constraints missing: %', v_missing
      USING errcode = '42501',
            hint = 'These are the radiology-image ban, the review gate and the tenant-scoped '
                   'storage key. Do not drop them to make a test pass.';
  END IF;

  -- 3b. THE PER-PATIENT PREDICATE. Every clinical SELECT policy in this file must mention
  --     app.care_patient_ids(). This is the check that stops the first draft's tenant+role
  --     scoping from being reintroduced by a careless edit — it is the difference between "a
  --     doctor can read their patients' documents" and "a doctor can read the hospital's".
  SELECT string_agg(x.tbl, ', ') INTO v_missing
    FROM (VALUES ('document'), ('document_text'), ('ai_analysis_run'),
                 ('ai_finding'), ('ai_risk_score')) AS x(tbl)
   WHERE NOT EXISTS (
           SELECT 1 FROM pg_policies p
            WHERE p.schemaname = 'public' AND p.tablename = x.tbl AND p.cmd = 'SELECT'
              AND coalesce(p.qual, '') LIKE '%care_patient_ids%');
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'SELECT policies are not care-team scoped on: %', v_missing
      USING errcode = '42501',
            hint = 'Tenant isolation is not the only boundary. AND in '
                   '`patient_id = ANY (app.care_patient_ids())` — see §9.';
  END IF;

  -- 4. The trigger layers behind the CHECKs.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 't_source_policy'
                    AND tgrelid = 'public.ai_analysis_run'::regclass AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Trigger t_source_policy is missing from public.ai_analysis_run.'
      USING errcode = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 't_guard_update'
                    AND tgrelid = 'public.document'::regclass AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'Trigger t_guard_update is missing from public.document.'
      USING errcode = '42501';
  END IF;

  RAISE NOTICE 'prognosify/030: self-checks passed.';
END
$ci$;


-- =============================================================================================
-- HOW TO TEST THE SAFETY RULE BY HAND (five statements, one scratch database)
--
--   -- 1. an image, classified and scanned clean
--   INSERT INTO public.document (organization_id, patient_id, uploaded_by_member_id, source,
--          file_name, mime_type, byte_size, checksum_sha256, storage_key,
--          scan_status, scanned_at, doc_type, doc_type_source, doc_type_confidence)
--   VALUES (:org, :patient, :member, 'device_feed', 'chest.dcm', 'application/dicom',
--           100000, repeat('a',64), app.storage_prefix(:org) || 'chest.dcm',
--           'clean', now(), 'radiology_image', 'model', 0.98);
--
--   -- 2. THIS MUST FAIL: interpretation over an image
--   INSERT INTO public.ai_analysis_run (organization_id, document_id, kind, model_provider,
--          model_name, model_version, prompt_version)
--   VALUES (:org, :doc, 'interpretation', 'acme', 'acme-vision', '4.2', 'p-11');
--   --> ERROR: Radiology images are stored and displayed only …
--
--   -- 3. THIS MUST SUCCEED: the non-interpretive kind
--   … same INSERT with kind = 'metadata_index';
--
--   -- 4. THIS MUST FAIL: the reclassification hole. Classify a document as radiology_report,
--   --    run 'interpretation' over it, then
--   UPDATE public.document SET doc_type = 'radiology_image' WHERE id = :doc2;
--   --> ERROR: Document … cannot be reclassified … analysis run … already read it.
--
--   -- 5. THIS MUST FAIL even as a superuser, because it is a CHECK and not a policy:
--   SET LOCAL row_security = off;  -- makes no difference
--   INSERT … kind = 'summarization' over an image;
--   --> ERROR: new row … violates check constraint "ai_run_no_image_interpretation_ck"
-- =============================================================================================


-- =============================================================================================
-- OPEN QUESTIONS — deferred decisions, not oversights
--
-- 1. THE PER-PATIENT PREDICATE — RESOLVED, no longer open. §9 now ANDs 020's
--    `patient_id = ANY (app.care_patient_ids())` into document_select, document_insert,
--    document_update, document_text_select, ai_analysis_run_select, ai_finding_select,
--    ai_finding_update, ai_risk_score_select and (when pgvector is present)
--    document_text_chunk_select. §0 refuses to apply the file if 020 has not run, and §12
--    check 3b fails CI if any of those policies loses the predicate. Two exceptions, both
--    argued in place: reception's own uploads (scanning happens before assignment) and
--    ai_risk_factor / ai_citation, which inherit through an EXISTS on their parent.
--
-- 2. THE SETTINGS TOGGLE. "Require confirmation before adding AI notes to chart" is implemented
--    here as an unconditional invariant (§6), because a per-user checkbox that disables a
--    safety control on health records is not a control. If the owner intends it to mean
--    "auto-accept my AI notes", that is a real weakening: it needs to be an organisation-level
--    entitlement in 010's feature registry with an audit trail, and someone should decide
--    whether it is offered at all. It is not something to add as a boolean column here.
--
-- 3. MODEL REGISTRY. Model identity is denormalised text on the run, on purpose (§4). What that
--    does not answer is "which models may this tenant call" — an entitlement question. If it
--    becomes real, add feature keys to 010's registry rather than a catalogue table here, or
--    the two will disagree about what is allowed.
--
-- 4. CITATION ALLOWLIST — RESOLVED. ai_citation_source_table_allowed_ck (§8) now pins
--    source_table to 020's nine clinical table names, so a typo is a write-time error rather
--    than evidence nobody can follow. If 020 ever adds a citable table, add it there too; the
--    shape-only ai_citation_source_table_ck is kept alongside it as the cheaper first filter.
--
-- 5. RETENTION. Nothing here expires. Extracted text and superseded extractions accumulate
--    indefinitely, and DPDP-driven erasure would have to reach object storage as well as these
--    rows. app.deny_hard_delete()'s escape hatch (SET LOCAL app.allow_hard_delete) is the
--    intended door for a lawful erasure job; the job itself, and the storage side of it, are
--    unwritten.
--
-- 6. SERVING BYTES. The database refuses to ANALYSE a document that is not scan_status='clean'.
--    It cannot refuse to SERVE one, because it does not sign URLs. Whatever does must check
--    both scan_status and that the key prefix matches the caller's organisation. Worth a test
--    in the API suite, since it is the one half of rule 3 that lives outside this file.
--
-- 7. EMBEDDING WIDTH. §11 pins vector(1536). vector(n) is fixed per column, so a different
--    embedding model means changing it before any rows exist — or a new table and a backfill.
--
-- 8. VERIFICATION CAVEAT. There is no PostgreSQL, psql or Docker on the machine this was
--    written on, so this file has NOT been executed. It has been reviewed statically:
--    dollar-quote tags balanced and distinct, every app.* call resolves to a definition in 010
--    or in this file, no forward references outside plpgsql bodies. Run it against a scratch
--    database — and run the five statements above — before trusting it.
-- =============================================================================================
