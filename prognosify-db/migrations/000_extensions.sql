-- =============================================================================================
-- 000_extensions.sql — Prognosify: extensions and preconditions
-- PostgreSQL 15+ / Supabase (ap-south-1). Idempotent: safe to re-run.
--
-- RUN THIS FIRST. Every later migration assumes the objects below already exist.
--
-- WHY THIS FILE EXISTS AT ALL
--   Three of the four migrations depend on something that is not part of core PostgreSQL, and
--   each of them handles a missing dependency differently (010 assumes gen_random_uuid(), 020
--   downgrades a double-booking constraint to a WARNING, 030 skips its whole vector section).
--   Deciding all three in one short file, before any table exists, means the failure mode is
--   "the first migration refuses to run" rather than "the schema applied but one constraint is
--   quietly missing".
--
-- WHAT IT DOES NOT DO
--   It creates no schema, no table and no policy. Nothing here is tenant-aware because nothing
--   here holds data.
-- =============================================================================================


-- =============================================================================================
-- SECTION 0 — VERSION FLOOR
--
-- 15 is the floor, not a preference. The schema uses MERGE-free but 14+ syntax throughout, and
-- more importantly Supabase's own tooling and the RLS behaviour these migrations were written
-- against assume a modern server. Refusing early beats a cryptic syntax error 80 KB into 020.
-- =============================================================================================

DO $version$
BEGIN
  IF current_setting('server_version_num')::int < 150000 THEN
    RAISE EXCEPTION 'Prognosify requires PostgreSQL 15 or newer; this server is %.',
                    current_setting('server_version')
      USING errcode = '0A000';
  END IF;
END
$version$;


-- =============================================================================================
-- SECTION 1 — WHERE EXTENSIONS LIVE
--
-- Supabase provisions a dedicated `extensions` schema and its projects keep it on the search
-- path; installing there keeps `public` free of extension objects and keeps the Supabase
-- linter quiet. On a plain RDS/Neon database that schema does not exist, and the extension
-- lands in the default creation schema (normally `public`). Both are fine — what matters is
-- that 020 does NOT assume either, which is why it resolves the operator-class schema at
-- runtime rather than hard-coding one.
-- =============================================================================================

DO $ext$
DECLARE
  v_target text := NULL;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'extensions') THEN
    v_target := 'extensions';
  END IF;

  -- ---- pgcrypto ------------------------------------------------------------------------------
  -- gen_random_uuid() has been in core since PostgreSQL 13, so on a supported server this is
  -- belt-and-braces for that function. It is installed anyway because pgcrypto also provides
  -- digest()/hmac(), which is what a checksum or signature helper would reach for later, and
  -- because every table in this schema defaults its primary key to gen_random_uuid() — a
  -- default that fails to resolve is a migration that fails on its first CREATE TABLE.
  IF v_target IS NULL THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pgcrypto';
  ELSE
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA %I', v_target);
  END IF;

  -- ---- btree_gist ----------------------------------------------------------------------------
  -- Required by 020's provider double-booking constraint:
  --     EXCLUDE USING gist (provider_member_id WITH =, tstzrange(...) WITH &&)
  -- The tstzrange half uses a core opclass; `uuid WITH =` under gist does not exist without
  -- btree_gist. Without it 020 downgrades that constraint to a WARNING and a doctor can be
  -- booked into two rooms at once with nothing stopping it, so install it here where the
  -- failure is loud and isolated.
  IF v_target IS NULL THEN
    EXECUTE 'CREATE EXTENSION IF NOT EXISTS btree_gist';
  ELSE
    EXECUTE format('CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA %I', v_target);
  END IF;

  -- ---- pgvector (OPTIONAL) --------------------------------------------------------------------
  -- Only 030 §11 uses it, and 030 already skips that section cleanly when it is absent. It is
  -- attempted here so that the decision is made once, up front, instead of surprising someone
  -- 100 KB later. A managed host that does not offer it is not an error.
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'vector') THEN
    BEGIN
      IF v_target IS NULL THEN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS vector';
      ELSE
        EXECUTE format('CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA %I', v_target);
      END IF;
      RAISE NOTICE 'prognosify/000: pgvector enabled — 030 §11 will create document_text_chunk.';
    EXCEPTION WHEN insufficient_privilege OR feature_not_supported THEN
      RAISE NOTICE 'prognosify/000: pgvector present but not installable here; 030 §11 will skip.';
    END;
  ELSE
    RAISE NOTICE 'prognosify/000: pgvector unavailable; 030 §11 will skip. Lexical search in '
                 '030 §3 (document_text.search_tsv) is unaffected.';
  END IF;
END
$ext$;


-- =============================================================================================
-- SECTION 2 — VERIFY, DO NOT ASSUME
--
-- "CREATE EXTENSION succeeded" and "the thing 020 needs is reachable" are different claims. The
-- second one is what actually matters, so check it directly.
-- =============================================================================================

DO $verify$
DECLARE
  v_opc_schema text;
BEGIN
  IF to_regprocedure('pg_catalog.gen_random_uuid()') IS NULL
     AND to_regproc('gen_random_uuid') IS NULL THEN
    RAISE EXCEPTION 'gen_random_uuid() is not resolvable. Every primary key in this schema '
                    'defaults to it.'
      USING hint = 'Install pgcrypto into a schema on the search_path, or upgrade to PG 13+.';
  END IF;

  SELECT n.nspname INTO v_opc_schema
    FROM pg_opclass oc
    JOIN pg_am        am ON am.oid = oc.opcmethod AND am.amname = 'gist'
    JOIN pg_namespace n  ON n.oid  = oc.opcnamespace
    JOIN pg_type      t  ON t.oid  = oc.opcintype AND t.typname = 'uuid'
   LIMIT 1;

  IF v_opc_schema IS NULL THEN
    RAISE WARNING 'prognosify/000: no gist operator class for uuid (btree_gist missing). '
                  '020 will create public.appointment WITHOUT the provider double-booking '
                  'constraint, and the booking service becomes the only thing preventing it.';
  ELSE
    RAISE NOTICE 'prognosify/000: btree_gist opclass found in schema %. 020 will schema-qualify '
                 'it, so the double-booking constraint applies regardless of search_path.',
                 v_opc_schema;
  END IF;
END
$verify$;


-- =============================================================================================
-- SECTION 3 — MIGRATION ORDER (the contract the rest of this directory depends on)
--
--   000_extensions.sql          this file
--   010_tenancy_identity.sql    schema `app`, tenants, plans/entitlements, identity, membership,
--                               platform_admin, public.patient, support sessions, the whole
--                               session-helper API every later policy is written against
--   020_clinical.sql            departments/visit types, staff profile, care teams, encounters,
--                               appointments, vitals, labs, notes, medications
--   030_documents_ai.sql        documents, extracted text, AI runs/findings/scores/citations
--   040_admin_billing_audit.sql org settings, billing, vendor usage counters, schema `audit`
--
-- Then, once: seed.sql (demo data for two hospitals).
--
-- THE DRAFTS 001-004 ARE GONE, AND MUST STAY GONE. They were the single-tenant first pass.
-- They defined a conflicting public.patient and an app.has_role(text) that would sit beside
-- 010's app.has_role(app.org_role) as an overload — after which `app.has_role('doctor')` is
-- ambiguous and every policy in the database fails to resolve at query time. 020 and 040 both
-- refuse to run if they detect that overload; this check is here so the refusal happens first.
-- =============================================================================================

DO $no_drafts$
BEGIN
  IF (SELECT count(*) FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'app' AND p.proname = 'has_role') > 1 THEN
    RAISE EXCEPTION 'app.has_role() is overloaded — the retired 001-004 drafts are installed.'
      USING errcode = '42723',
            hint = 'Drop them (or restore a clean database) before running 010.';
  END IF;

  IF to_regtype('authz.app_role') IS NOT NULL THEN
    RAISE EXCEPTION 'The drafts'' authz schema is present; its actor model collides with 040.'
      USING errcode = '42710',
            hint = 'DROP SCHEMA authz CASCADE, or run these migrations on a clean database.';
  END IF;

  RAISE NOTICE 'prognosify/000: extensions ready. Apply 010, 020, 030, 040 in that order.';
END
$no_drafts$;
