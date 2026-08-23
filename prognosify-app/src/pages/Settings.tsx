import { useEffect, useState } from 'react';
import SideNav from '../components/SideNav';
import { Pressable, TextField, Toggle, pressableReset } from '../components/ui';

/**
 * Doctor settings.
 *
 * The left sub-nav is deliberately static — the spec paints "Profile" as the only active
 * item and there are no other panels to show, so it stays presentational (no tab state).
 */
const subNavItems = ['Profile', 'Notifications', 'AI preferences', 'Security', 'Care team'];

const profileFields = [
  { key: 'fullName', label: 'Full name', type: 'text', autoComplete: 'name' },
  { key: 'department', label: 'Department', type: 'text', autoComplete: 'off' },
  { key: 'email', label: 'Email', type: 'email', autoComplete: 'email' },
  { key: 'license', label: 'License no.', type: 'text', autoComplete: 'off' },
] as const;

const aiPreferences = [
  { key: 'riskFlags', label: 'Show AI risk flags on patient lists' },
  { key: 'confirmBeforeChart', label: 'Require confirmation before adding AI notes to chart' },
  { key: 'dailyEmail', label: 'Daily AI summary email' },
] as const;

export default function Settings() {
  const [profile, setProfile] = useState({
    fullName: 'Dr. Anita Mehta',
    department: 'Cardiology',
    email: 'a.mehta@stlukes.org',
    license: 'MC-48211',
  });
  const [prefs, setPrefs] = useState({
    riskFlags: true,
    confirmBeforeChart: true,
    dailyEmail: false,
  });

  // Bumped on every save; the message clears itself a few seconds later. There is no server,
  // so the wording says plainly that the change lives only in this session.
  const [saveSignal, setSaveSignal] = useState(0);
  useEffect(() => {
    if (saveSignal === 0) return;
    const timer = window.setTimeout(() => setSaveSignal(0), 3000);
    return () => window.clearTimeout(timer);
  }, [saveSignal]);

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="settings" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ margin: 0, fontSize: 17, fontWeight: 600 }}>Settings</h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 13, color: '#5B6B7F' }}>
            <div>Dr. Anita Mehta · Cardiology</div>
            <div style={{ width: 32, height: 32, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600 }}>AM</div>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', gap: 24, padding: 28, overflow: 'auto' }}>
          <div style={{ width: 200, display: 'flex', flexDirection: 'column', gap: 2, fontSize: 13.5, flexShrink: 0 }}>
            {subNavItems.map((item) => (
              <div
                key={item}
                style={item === 'Profile'
                  ? { padding: '8px 10px', borderRadius: 7, background: '#EDF2FE', color: '#1D4ED8', fontWeight: 600, cursor: 'pointer' }
                  : { padding: '8px 10px', color: '#5B6B7F', cursor: 'pointer' }}
              >
                {item}
              </div>
            ))}
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 20, maxWidth: 720 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 18 }}>
              <h2 style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>Profile</h2>
              <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
                <div style={{ width: 56, height: 56, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 600 }}>AM</div>
                {/* Uploading a photo needs a server this demo does not have. The control stays
                    focusable and says so, rather than pretending to succeed. */}
                <button
                  type="button"
                  aria-disabled="true"
                  title="Changing the photo needs a server — not available in this demo."
                  style={{ ...pressableReset, fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}
                >
                  Change photo
                </button>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
                {profileFields.map((field) => (
                  <div key={field.key} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                    <TextField
                      type={field.type}
                      name={field.key}
                      autoComplete={field.autoComplete}
                      value={profile[field.key]}
                      onChange={(value) => setProfile((prev) => ({ ...prev, [field.key]: value }))}
                      label={field.label}
                      labelStyle={{ fontSize: 13, fontWeight: 500 }}
                      style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '10px 13px', fontSize: 14 }}
                    />
                  </div>
                ))}
              </div>
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <h2 style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>AI preferences</h2>
              {aiPreferences.map((pref) => (
                <div key={pref.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <div style={{ fontSize: 14 }}>{pref.label}</div>
                  <Toggle
                    checked={prefs[pref.key]}
                    onChange={(checked) => setPrefs((prev) => ({ ...prev, [pref.key]: checked }))}
                    ariaLabel={pref.label}
                  />
                </div>
              ))}
            </div>
            <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
              {/* position:relative only anchors the status text, which is absolutely positioned
                  and therefore cannot move the button whether it is showing or empty. */}
              <div style={{ position: 'relative' }}>
                <span
                  role="status"
                  style={{ position: 'absolute', right: '100%', marginRight: 12, top: '50%', transform: 'translateY(-50%)', whiteSpace: 'nowrap', fontSize: 13, color: '#5B6B7F' }}
                >
                  {saveSignal > 0 ? 'Saved in this session only — no server' : ''}
                </span>
                <Pressable
                  onClick={() => setSaveSignal((n) => n + 1)}
                  style={{ background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '10px 22px', fontSize: 14, fontWeight: 600, cursor: 'pointer' }}
                >
                  Save changes
                </Pressable>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
