#!/usr/bin/env node
/**
 * run-sql.js — execute a .sql file against the Supabase Postgres directly.
 *
 * Usage:   node run-sql.js <file.sql> [--no-txn] [--echo]
 *          echo "SELECT 1" | node run-sql.js -
 *
 * Credentials come from DATABASE_URL in ../.env.db (gitignored) or the environment.
 * Format (Session Pooler, IPv4-friendly):
 *   DATABASE_URL=postgresql://postgres.<project-ref>:<password>@aws-0-ap-south-1.pooler.supabase.com:5432/postgres
 *
 * --no-txn  run statements as sent (needed for CREATE DATABASE etc.); default wraps the file
 *           in BEGIN…COMMIT so a failed script leaves nothing half-applied.
 * --echo    print each statement before running it.
 */

const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

function loadEnvDb() {
  const candidates = [
    path.join(__dirname, '..', '.env.db'),
    path.join(process.cwd(), '.env.db'),
  ];
  for (const file of candidates) {
    if (!fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
      const m = /^\s*DATABASE_URL\s*=\s*(.+?)\s*$/.exec(line);
      if (m && !process.env.DATABASE_URL) process.env.DATABASE_URL = m[1].trim().replace(/^['"]|['"]$/g, '');
    }
  }
}

// Split on semicolons that terminate a statement, ignoring those inside string literals,
// dollar-quoted blocks ($$…$$, $tag$…$tag$) and comments. Good enough for our migration files.
function splitStatements(sql) {
  const out = [];
  let cur = '';
  let i = 0;
  let state = 'code'; // code | line-comment | block-comment | single | double | dollar
  let dollarTag = '';
  while (i < sql.length) {
    const ch = sql[i];
    const two = sql.slice(i, i + 2);
    if (state === 'code') {
      if (two === '--') { state = 'line-comment'; cur += two; i += 2; continue; }
      if (two === '/*') { state = 'block-comment'; cur += two; i += 2; continue; }
      if (ch === "'") { state = 'single'; cur += ch; i++; continue; }
      if (ch === '"') { state = 'double'; cur += ch; i++; continue; }
      if (ch === '$') {
        const m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i));
        if (m) { dollarTag = m[0]; state = 'dollar'; cur += m[0]; i += m[0].length; continue; }
      }
      if (ch === ';') { out.push(cur.trim()); cur = ''; i++; continue; }
      cur += ch; i++; continue;
    }
    if (state === 'line-comment') {
      if (ch === '\n') state = 'code';
      cur += ch; i++; continue;
    }
    if (state === 'block-comment') {
      if (two === '*/') { state = 'code'; cur += two; i += 2; continue; }
      cur += ch; i++; continue;
    }
    if (state === 'single') {
      cur += ch;
      if (ch === "'") { if (sql[i + 1] === "'") { cur += "'"; i += 2; continue; } state = 'code'; }
      i++; continue;
    }
    if (state === 'double') {
      cur += ch;
      if (ch === '"') state = 'code';
      i++; continue;
    }
    if (state === 'dollar') {
      if (sql.startsWith(dollarTag, i)) { cur += dollarTag; state = 'code'; i += dollarTag.length; continue; }
      cur += ch; i++; continue;
    }
  }
  if (cur.trim()) out.push(cur.trim());
  return out.filter((s) => s.length > 0);
}

async function main() {
  loadEnvDb();
  if (!process.env.DATABASE_URL) {
    console.error('No DATABASE_URL. Put it in prognosify-db/.env.db or export it.');
    process.exit(2);
  }
  const args = process.argv.slice(2);
  const noTxn = args.includes('--no-txn');
  const echo = args.includes('--echo');
  const target = args.find((a) => !a.startsWith('--'));
  if (!target) {
    console.error('Usage: node run-sql.js <file.sql> [--no-txn] [--echo]');
    process.exit(2);
  }

  const sqlText =
    target === '-' ? fs.readFileSync(0, 'utf8') : fs.readFileSync(path.resolve(target), 'utf8');
  const statements = splitStatements(sqlText);

  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();

  // Surface NOTICEs (the migrations rely on them).
  client.on('notice', (n) => console.log(`NOTICE: ${n.message}`));

  let ok = 0;
  try {
    if (!noTxn) await client.query('BEGIN');
    for (let s = 0; s < statements.length; s++) {
      const stmt = statements[s];
      if (echo) {
        const preview = stmt.replace(/\s+/g, ' ').slice(0, 100);
        console.log(`[${s + 1}/${statements.length}] ${preview}${stmt.length > 100 ? ' …' : ''}`);
      }
      try {
        const res = await client.query(stmt);
        if (res.rowCount != null && res.fields.length > 0) {
          const cols = res.fields.map((f) => f.name).join(' | ');
          const rows = res.rows.slice(0, 20).map((r) =>
            Object.values(r).map((v) => (v == null ? 'NULL' : String(v).slice(0, 60))).join(' | '));
          console.log(`  → ${res.rowCount} row(s)` + (cols ? `\n     ${cols}\n${rows.map((r) => '     ' + r).join('\n')}` : ''));
        } else if (res.command && res.command !== 'SELECT') {
          console.log(`  → ${res.command} OK`);
        }
      } catch (err) {
        console.error(`\nFAILED at statement ${s + 1}: ${err.message}`);
        if (err.detail) console.error(`DETAIL: ${err.detail}`);
        if (err.hint) console.error(`HINT: ${err.hint}`);
        throw err;
      }
      ok++;
    }
    if (!noTxn) await client.query('COMMIT');
    console.log(`\nDone: ${ok}/${statements.length} statement(s), transaction ${noTxn ? 'not used' : 'committed'}.`);
  } catch (err) {
    if (!noTxn) {
      try { await client.query('ROLLBACK'); console.log('Transaction rolled back — nothing applied.'); } catch {}
    }
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

main();
