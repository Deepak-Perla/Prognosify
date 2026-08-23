import { useState, type FormEvent } from 'react';
import { useNavigate } from 'react-router-dom';
import Logo from '../components/Logo';
import { Pressable, TextField, pressableReset } from '../components/ui';

/**
 * Password-reset request screen.
 *
 * The email box is a real `<input>` in a real `<form>`, so Enter submits. The prototype's
 * grey `you@hospital.org` was prompt text, so it becomes an actual placeholder — the field
 * starts empty. Submitting returns to sign-in exactly as the prototype did; nothing here
 * claims a mail was sent, because there is no server to send one.
 */
export default function Forgot() {
  const navigate = useNavigate();
  const [email, setEmail] = useState('');

  const requestReset = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    navigate('/login');
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div style={{ width: 440, boxSizing: 'content-box', background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 40, display: 'flex', flexDirection: 'column', gap: 22 }}>
        <Logo size={28} gap={9} wordmarkSize={16} wordmarkWeight={600} />
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          <h1 style={{ margin: 0, fontSize: 22, fontWeight: 700 }}>Reset your password</h1>
          <div style={{ fontSize: 14, color: '#5B6B7F', lineHeight: 1.5 }}>Enter your work email and we'll send a reset link. Staff accounts may require IT approval.</div>
        </div>
        {/* The form carries the card's own gap:22 rhythm and is reset to zero box metrics,
            so the field and the button sit exactly where the bare divs did. */}
        <form onSubmit={requestReset} style={{ display: 'flex', flexDirection: 'column', gap: 22, margin: 0, padding: 0, border: 0 }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <TextField
              type="email"
              name="email"
              autoComplete="email"
              value={email}
              onChange={setEmail}
              placeholder="you@hospital.org"
              label="Email"
              labelStyle={{ fontSize: 13, fontWeight: 500 }}
              style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '11px 14px', fontSize: 14, color: '#5B6B7F' }}
            />
          </div>
          {/* Pressable is type="button", so the submit control is a raw <button> with the same reset. */}
          <button
            type="submit"
            className="hover-darken"
            style={{ ...pressableReset, width: '100%', background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '12px 0', textAlign: 'center', fontSize: 14, fontWeight: 600, cursor: 'pointer' }}
          >
            Send reset link
          </button>
        </form>
        <Pressable onClick={() => navigate('/login')} style={{ width: '100%', fontSize: 13, color: '#1D4ED8', fontWeight: 500, textAlign: 'center', cursor: 'pointer' }}>Back to sign in</Pressable>
      </div>
    </div>
  );
}
