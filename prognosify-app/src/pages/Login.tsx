import { useState, type FormEvent } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import Logo from '../components/Logo';
import { Pressable, TextField, pressableReset } from '../components/ui';
import { landingFor, useAuth } from '../lib/auth';

/**
 * Sign-in screen.
 *
 * Credentials are verified by Supabase. Previously this handler ignored both
 * fields and navigated straight to the doctor dashboard, so every email and
 * password appeared to work — that is fixed: a wrong password now stays here
 * with an error, and the destination comes from the account's role.
 *
 * The three "Demo as" buttons no longer bypass the login. They fill in the
 * matching test account's email; you still have to enter the password. A button
 * that skips authentication is precisely the bug this screen just had.
 */
export default function Login() {
  const navigate = useNavigate();
  const location = useLocation();
  const { signIn } = useAuth();

  const [email, setEmail] = useState('doctor@clinic.com');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // Where the guard sent them from, so we can return them after a successful login.
  const intended = (location.state as { from?: string } | null)?.from;

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (busy) return;
    setError(null);
    setBusy(true);
    const { error: failure, role } = await signIn(email, password);
    setBusy(false);
    if (failure || !role) {
      setError(failure ?? 'Could not sign in.');
      return;
    }
    navigate(intended ?? landingFor(role), { replace: true });
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      {/* Chromium on Windows paints a reveal/clear affordance inside password inputs; the mockup has none.
          <style> is display:none, so it generates no box and cannot affect the flex layout. */}
      <style>{'.login-password::-ms-reveal, .login-password::-ms-clear { display: none; }'}</style>
      <div className="on-dark" style={{ width: '38%', minWidth: 420, background: '#0F1C2E', color: '#fff', display: 'flex', flexDirection: 'column', justifyContent: 'space-between', padding: 56, boxSizing: 'border-box' }}>
        <Logo size={30} tone="white" gap={10} wordmarkSize={18} wordmarkWeight={600} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <div style={{ fontSize: 34, fontWeight: 700, lineHeight: 1.2 }}>Clinical foresight for every patient.</div>
          <div style={{ fontSize: 15, color: '#9FB0C4', lineHeight: 1.6 }}>AI-assisted prognoses, risk flags and care planning — in one hospital dashboard.</div>
        </div>
        <div style={{ fontSize: 12, color: '#5B6B7F' }}>DPDP-aligned · Demo data is synthetic</div>
      </div>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ width: 400, display: 'flex', flexDirection: 'column', gap: 22 }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <h1 style={{ margin: 0, fontSize: 24, fontWeight: 700 }}>Sign in</h1>
            <div style={{ fontSize: 14, color: '#5B6B7F' }}>Use your hospital credentials.</div>
          </div>
          <form onSubmit={submit} style={{ display: 'flex', flexDirection: 'column', gap: 22, margin: 0, padding: 0, border: 0 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <TextField
                  type="email"
                  name="email"
                  autoComplete="username"
                  value={email}
                  onChange={(v) => { setEmail(v); setError(null); }}
                  label="Email"
                  labelStyle={{ fontSize: 13, fontWeight: 500 }}
                  style={{ border: '1px solid #DDE3EB', borderRadius: 8, background: '#fff', padding: '11px 14px', fontSize: 14 }}
                />
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <TextField
                  type="password"
                  name="password"
                  autoComplete="current-password"
                  className="login-password"
                  value={password}
                  onChange={(v) => { setPassword(v); setError(null); }}
                  placeholder="Your password"
                  label="Password"
                  labelStyle={{ fontSize: 13, fontWeight: 500 }}
                  style={{ border: '1px solid #DDE3EB', borderRadius: 8, background: '#fff', padding: '11px 14px', fontSize: 14 }}
                />
              </div>
            </div>
            {error ? (
              <div
                role="alert"
                style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', color: '#B42318', borderRadius: 8, padding: '10px 14px', fontSize: 13, lineHeight: 1.5 }}
              >
                {error}
              </div>
            ) : null}
            <button
              type="submit"
              className="hover-darken"
              disabled={busy}
              style={{ ...pressableReset, width: '100%', background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '12px 0', textAlign: 'center', fontSize: 14, fontWeight: 600, cursor: busy ? 'default' : 'pointer', opacity: busy ? 0.7 : 1 }}
            >
              {busy ? 'Signing in…' : 'Sign in'}
            </button>
          </form>
          <div style={{ display: 'flex', justifyContent: 'center', fontSize: 13 }}>
            <Pressable onClick={() => navigate('/forgot')} style={{ color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>Forgot password?</Pressable>
          </div>
          <div style={{ borderTop: '1px solid #DDE3EB', paddingTop: 18, display: 'flex', flexDirection: 'column', gap: 10 }}>
            <div id="login-demo-as" style={{ fontSize: 12, color: '#5B6B7F', letterSpacing: '0.04em', textTransform: 'uppercase', fontWeight: 600 }}>Fill in a test account</div>
            <div role="group" aria-labelledby="login-demo-as" style={{ display: 'flex', gap: 8 }}>
              {([
                ['Doctor', 'doctor@clinic.com'],
                ['Receptionist', 'receptionist@clinic.com'],
                ['Patient', 'patient@gmail.com'],
              ] as const).map(([label, addr]) => (
                <Pressable
                  key={label}
                  className="hover-accent-text"
                  onClick={() => { setEmail(addr); setError(null); }}
                  ariaLabel={`Fill in the ${label} test account email`}
                  style={{ flex: 1, border: '1px solid #DDE3EB', background: '#fff', borderRadius: 8, padding: '9px 0', textAlign: 'center', fontSize: 13, fontWeight: 500, cursor: 'pointer' }}
                >
                  {label}
                </Pressable>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
