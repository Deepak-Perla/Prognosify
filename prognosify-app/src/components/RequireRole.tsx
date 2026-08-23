import type { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { useAuth, landingFor, type Role } from '../lib/auth';

/**
 * Route guard.
 *
 * Without this, typing /doctor/dashboard into the address bar rendered the doctor
 * dashboard with no session at all. Now:
 *   - no session            -> back to /login
 *   - session, wrong role   -> to that role's own landing screen, not a blank denial
 *   - still restoring       -> render nothing rather than bouncing (a refresh must
 *                             not look like a sign-out)
 *
 * NOTE ON SCOPE: this only controls which SCREENS render. It is not data security —
 * a determined user can edit client-side JavaScript. The real boundary is Row Level
 * Security in the database, which is why the schema work matters. This guard is for
 * navigation correctness, not protection.
 */
export default function RequireRole({ allow, children }: { allow: Role[]; children: ReactNode }) {
  const { session, role, loading } = useAuth();
  const location = useLocation();

  if (loading) return null;

  if (!session) {
    // Remember where they were headed so login can return them there.
    return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  }

  if (!role) return <Navigate to="/login" replace />;

  if (!allow.includes(role)) return <Navigate to={landingFor(role)} replace />;

  return <>{children}</>;
}
