import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';

/**
 * Authentication + role resolution against Supabase.
 *
 * Credentials are verified by GoTrue. The ROLE is no longer guessed from the email address:
 * it comes from `organization_member.roles` — the seat this person holds in a hospital. That is
 * where role belongs, because the database's own authorisation helpers (`app.has_role()` and
 * friends) read exactly that table, so what the UI shows and what RLS enforces can no longer
 * drift apart. Adding a staff member is now purely a data operation.
 *
 * Multi-seat users (a locum at two hospitals) currently land on their earliest active seat;
 * an organisation switcher is future work alongside hospital_admin screens.
 */

export type Role = 'doctor' | 'receptionist' | 'patient';

/** app.org_role values the UI has a portal for, most privileged clinical context first. */
const ROLE_PRECEDENCE: { db: string; app: Role }[] = [
  { db: 'doctor', app: 'doctor' },
  { db: 'receptionist', app: 'receptionist' },
  { db: 'patient', app: 'patient' },
];

function appRoleFor(dbRoles: string[]): Role | null {
  for (const { db, app } of ROLE_PRECEDENCE) {
    if (dbRoles?.includes(db)) return app;
  }
  return null;
}

export interface Membership {
  /** organization_member.id — "staff_id" everywhere downstream. */
  memberId: string;
  organizationId: string;
  role: Role;
}

/**
 * The caller's own active seat. RLS lets every user read their own membership row
 * (010's policy passes on `app_user_id = app.current_user_id()`), so this works for
 * patients as well as staff without weakening anything.
 */
async function loadMembership(authUserId: string): Promise<Membership | null> {
  const { data, error } = await supabase
    .from('organization_member')
    .select('id, organization_id, roles')
    .eq('auth_user_id', authUserId)
    .eq('status', 'active')
    .order('joined_at')
    .limit(1);
  if (error) throw new Error(error.message);
  const row = (data ?? [])[0] as
    | { id: string; organization_id: string; roles: string[] | null }
    | undefined;
  if (!row) return null;
  const role = appRoleFor(row.roles ?? []);
  return role ? { memberId: row.id, organizationId: row.organization_id, role } : null;
}

export const landingFor = (role: Role): string =>
  role === 'doctor' ? '/doctor/dashboard' : role === 'receptionist' ? '/reception/dashboard' : '/patient/home';

type AuthState = {
  /** null once resolved and signed out; undefined while still restoring. */
  session: Session | null;
  /**
   * True until the stored session AND the caller's seat have been checked, so guards don't
   * bounce a valid session on refresh just because its role lookup is still in flight.
   */
  loading: boolean;
  email: string | null;
  role: Role | null;
  membership: Membership | null;
  signIn: (email: string, password: string) => Promise<{ error: string | null; role: Role | null }>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [sessionRestored, setSessionRestored] = useState(false);
  const [membership, setMembership] = useState<Membership | null>(null);
  const [resolving, setResolving] = useState(false);

  useEffect(() => {
    let cancelled = false;

    // Restore an existing session before any guard runs, otherwise a page refresh
    // would look like a sign-out and kick the user back to /login.
    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) return;
      setSession(data.session ?? null);
      setSessionRestored(true);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next ?? null);
      setSessionRestored(true);
    });

    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  const uid = session?.user?.id ?? null;

  useEffect(() => {
    if (!uid) {
      setMembership(null);
      setResolving(false);
      return;
    }
    let cancelled = false;
    setResolving(true);
    loadMembership(uid)
      .then((m) => {
        if (!cancelled) {
          setMembership(m);
          setResolving(false);
        }
      })
      .catch((err: unknown) => {
        console.error('Role lookup failed:', err);
        if (!cancelled) {
          setMembership(null);
          setResolving(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [uid]);

  const value = useMemo<AuthState>(() => {
    const loading = !sessionRestored || resolving;
    return {
      session,
      loading,
      email: session?.user?.email ?? null,
      role: membership?.role ?? null,
      membership,
      async signIn(emailInput, password) {
        const { data, error } = await supabase.auth.signInWithPassword({
          email: emailInput.trim(),
          password,
        });
        if (error) {
          // Supabase deliberately returns one generic message for a bad email and a
          // bad password alike, so an attacker cannot enumerate valid accounts.
          // Keep it generic here too — do not "helpfully" distinguish them.
          return { error: error.message, role: null };
        }
        const authUid = data.user?.id;
        if (!authUid) return { error: 'Signed in, but no user id came back.', role: null };
        let seat: Membership | null;
        try {
          seat = await loadMembership(authUid);
        } catch (err) {
          await supabase.auth.signOut();
          return {
            error: err instanceof Error ? err.message : 'Could not look up your account.',
            role: null,
          };
        }
        if (!seat) {
          // Authenticated, but holds no active seat. Refuse rather than guess: dropping an
          // unknown account onto the doctor dashboard would be exactly the bug we fix here.
          await supabase.auth.signOut();
          return {
            error:
              'Signed in, but this account has no active seat in any organisation. ' +
              'Ask your hospital administrator to add you.',
            role: null,
          };
        }
        // The session-change effect will re-derive this; setting it here keeps the
        // navigation below race-free.
        setMembership(seat);
        return { error: null, role: seat.role };
      },
      async signOut() {
        await supabase.auth.signOut();
      },
    };
  }, [session, sessionRestored, resolving, membership]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}
