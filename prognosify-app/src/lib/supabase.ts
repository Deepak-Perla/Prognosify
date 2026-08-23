import { createClient } from '@supabase/supabase-js';

/**
 * The app's single Supabase client.
 *
 * Values come from `.env.local` (gitignored). Anything prefixed `VITE_` is
 * compiled into the browser bundle, so only the publishable anon key belongs
 * here — see the guard below.
 */

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

const unset = (v: string | undefined) => !v || v === 'REPLACE_ME';

if (unset(url) || unset(anonKey)) {
  throw new Error(
    'Supabase is not configured.\n\n' +
      'Open prognosify-app/.env.local and replace the REPLACE_ME values with your\n' +
      'Project URL and anon key (Supabase dashboard → Project Settings → API),\n' +
      'then restart `npm run dev` — Vite only reads .env files at startup.',
  );
}

/**
 * Refuse to start if a service_role key was pasted in by mistake.
 *
 * That key bypasses Row Level Security entirely. Because `VITE_*` values are
 * shipped to every visitor's browser, pasting it here would publish full
 * read/write access to the whole database. Supabase keys are JWTs whose payload
 * carries the role, so we can catch the mistake instead of shipping it.
 */
function assertNotServiceRole(key: string) {
  const payload = key.split('.')[1];
  if (!payload) return; // not a JWT shape — nothing to inspect
  try {
    const decoded = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
    if (decoded?.role && decoded.role !== 'anon') {
      throw new Error(
        `VITE_SUPABASE_ANON_KEY holds a "${decoded.role}" key, not the anon key.\n\n` +
          'That key ignores Row Level Security, and everything in VITE_* is shipped to\n' +
          "every visitor's browser — this would expose the entire database.\n" +
          'Use the "anon / public" key from Project Settings → API instead.',
      );
    }
  } catch (err) {
    // Re-throw our own error; ignore decode failures from a non-JWT string.
    if (err instanceof Error && err.message.startsWith('VITE_SUPABASE_ANON_KEY')) throw err;
  }
}

assertNotServiceRole(anonKey!);

export const supabase = createClient(url!, anonKey!, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
  },
});
