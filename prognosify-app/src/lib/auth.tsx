import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { supabase } from './supabase';

/**
 * Real authentication against Supabase.
 *
 * Before this existed the login screen simply navigated to the dashboard, so any
 * email and any password "worked". Now credentials are actually verified by
 * Supabase and a rejected password stays on the login screen.
 */

export type Role = 'doctor' | 'receptionist' | 'patient';

/**
 * INTERIM role mapping.
 *
 * A user's role properly belongs in the database (`organization_member.roles`),
 * scoped to a hospital — a locum doctor can be staff at one site and a patient at
 * another, which an email address cannot express. The schema that models this is
 * written but not yet applied, so until it is we map the three seeded test logins
 * here.
 *
 * REPLACE THIS with a query against the member table once the migrations are
 * applied. It is the only place role is decided, so that is a one-function change.
 */
const ROLE_BY_EMAIL: Record<string, Role> = {
  'doctor@clinic.com': 'doctor',
  'dr.iyer@clinic.com': 'doctor',
  'dr.thomas@clinic.com': 'doctor',
  'dr.deshpande@clinic.com': 'doctor',
  'dr.kulkarni@clinic.com': 'doctor',
  'receptionist@clinic.com': 'receptionist',
  'patient@gmail.com': 'patient',
};

export const landingFor = (role: Role): string =>
  role === 'doctor' ? '/doctor/dashboard' : role === 'receptionist' ? '/reception/dashboard' : '/patient/home';

const roleFor = (email: string | undefined): Role | null =>
  (email && ROLE_BY_EMAIL[email.trim().toLowerCase()]) || null;

type AuthState = {
  /** null once resolved and signed out; undefined while still restoring. */
  session: Session | null;
  /** True until the stored session has been checked, so guards don't bounce on refresh. */
  loading: boolean;
  email: string | null;
  role: Role | null;
  signIn: (email: string, password: string) => Promise<{ error: string | null; role: Role | null }>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    // Restore an existing session before any guard runs, otherwise a page refresh
    // would look like a sign-out and kick the user back to /login.
    supabase.auth.getSession().then(({ data }) => {
      if (cancelled) return;
      setSession(data.session ?? null);
      setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next ?? null);
      setLoading(false);
    });

    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  const value = useMemo<AuthState>(() => {
    const email = session?.user?.email ?? null;
    return {
      session,
      loading,
      email,
      role: roleFor(email ?? undefined),
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
        const signedInAs = roleFor(data.user?.email ?? undefined);
        if (!signedInAs) {
          // Authenticated, but we have no role for them. Refuse rather than guess:
          // dropping an unknown account onto the doctor dashboard would be exactly
          // the bug we are fixing.
          await supabase.auth.signOut();
          return {
            error:
              'Signed in, but this account has no role assigned yet. ' +
              'Roles are assigned in the database once the schema is applied.',
            role: null,
          };
        }
        return { error: null, role: signedInAs };
      },
      async signOut() {
        await supabase.auth.signOut();
      },
    };
  }, [session, loading]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}
