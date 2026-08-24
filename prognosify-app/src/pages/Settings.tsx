import { useState } from 'react';
import SideNav from '../components/SideNav';
import { Busy, TextField, Toggle } from '../components/ui';
import { useAsync } from '../lib/useAsync';
import { useAuth } from '../lib/auth';
import { getMyFullName, getMySettings, saveMySetting } from '../lib/api';

/**
 * Staff settings.
 *
 * Profile fields read the signed-in user's real directory row (app_user +
 * organization_member via staff_profile) and stay read-only here — identity is
 * administered, not self-edited. The AI preferences are the user's own
 * org_setting rows (member_id = their seat), written straight through.
 */
const subNavItems = ['Profile', 'Notifications', 'AI preferences', 'Security', 'Care team'];

const SETTING_KEYS = {
  riskFlags: 'ai.risk_flags_on_lists',
  confirmBeforeChart: 'ai.confirm_before_chart',
  dailyEmail: 'ai.daily_summary_email',
} as const;

const aiPreferences = [
  { key: 'riskFlags', label: 'Show smart suggestions on patient lists' },
  { key: 'confirmBeforeChart', label: 'Require confirmation before AI-drafted text is saved' },
  { key: 'dailyEmail', label: 'Daily AI summary email' },
] as const;

type PrefKey = keyof typeof SETTING_KEYS;

export default function Settings() {
  const { membership, email } = useAuth();

  const { data, error, loading, reload } = useAsync(async () => {
    if (!membership) return null;
    const [settings, fullName] = await Promise.all([
      getMySettings(membership.memberId),
      getMyFullName(),
    ]);
    return { settings, fullName };
  }, [membership?.memberId]);

  const [savingKey, setSavingKey] = useState<PrefKey | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedKey, setSavedKey] = useState<PrefKey | null>(null);

  const profile = data ? {
    fullName: data.fullName ?? '',
    seat: membership?.role ?? '',
    email: email ?? '',
  } : null;

  const prefValue = (key: PrefKey): boolean => {
    const raw = data?.settings[SETTING_KEYS[key]];
    return raw === undefined ? true : Boolean(raw);
  };

  const togglePref = async (key: PrefKey, checked: boolean) => {
    if (!membership) return;
    setSavingKey(key);
    setSaveError(null);
    try {
      await saveMySetting(membership.organizationId, membership.memberId, SETTING_KEYS[key], checked);
      setSavedKey(key);
      window.setTimeout(() => setSavedKey(null), 3000);
      reload();
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Could not save the preference.');
    } finally {
      setSavingKey(null);
    }
  };

  const initials = (profile?.fullName ?? '')
    .split(/\s+/).slice(0, 2).map((p) => p[0]?.toUpperCase()).join('') || '—';

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="settings" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ margin: 0, fontSize: 17, fontWeight: 600 }}>Settings</h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, fontSize: 13, color: '#5B6B7F' }}>
            <div>{profile?.fullName || ''}</div>
            <div style={{ width: 32, height: 32, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600 }}>{initials}</div>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', gap: 24, padding: 28, overflow: 'auto' }}>
          <div style={{ width: 200, display: 'flex', flexDirection: 'column', gap: 2, fontSize: 13.5, flexShrink: 0 }}>
            {subNavItems.map((item) => (
              <div
                key={item}
                style={item === 'Profile'
                  ? { padding: '8px 10px', borderRadius: 7, background: '#EDF2FE', color: '#1D4ED8', fontWeight: 600 }
                  : { padding: '8px 10px', color: '#5B6B7F' }}
              >
                {item}
              </div>
            ))}
          </div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 20, maxWidth: 720 }}>
            {loading && <Busy label="Loading your settings…" fill={false} />}
            {error && (
              <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 16px', fontSize: 13, color: '#B42318' }}>
                Could not load settings: {error}
              </div>
            )}
            {!loading && !error && profile && (
              <>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 18 }}>
                  <h2 style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>Profile</h2>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
                    <div style={{ width: 56, height: 56, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 600 }}>{initials}</div>
                    {/* Identity is administered by the hospital, not self-edited; the photo
                        needs object storage, which is a later milestone. */}
                    <button
                      type="button"
                      aria-disabled="true"
                      title="Photo upload needs object storage — not available in this release."
                      style={{ fontSize: 13, color: '#8A97A8', fontWeight: 500 }}
                    >
                      Change photo
                    </button>
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
                    {[
                      { label: 'Full name', value: profile.fullName },
                      { label: 'Seat role', value: profile.seat.charAt(0).toUpperCase() + profile.seat.slice(1) },
                      { label: 'Email', value: profile.email },
                      { label: 'Organisation', value: membership ? membership.organizationId.slice(0, 8) : '' },
                    ].map((field) => (
                      <TextField
                        key={field.label}
                        value={field.value}
                        onChange={() => { /* read-only display */ }}
                        label={field.label}
                        labelStyle={{ fontSize: 13, fontWeight: 500 }}
                        style={{ border: '1px solid #EEF2F6', borderRadius: 8, padding: '10px 13px', fontSize: 14, color: '#3A4A5E', background: '#F8F9FB' }}
                      />
                    ))}
                  </div>
                  <div style={{ fontSize: 12.5, color: '#8A97A8' }}>
                    Profile details come from your staff record and are maintained by your hospital's administrators.
                  </div>
                </div>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <h2 style={{ margin: 0, fontSize: 15, fontWeight: 600 }}>AI preferences</h2>
                  <div style={{ fontSize: 12.5, color: '#8A97A8' }}>Saved to your personal settings the moment you flip a switch.</div>
                  {saveError && (
                    <div role="alert" style={{ fontSize: 12.5, color: '#B42318' }}>{saveError}</div>
                  )}
                  {aiPreferences.map((pref) => (
                    <div key={pref.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <div style={{ fontSize: 14, display: 'flex', alignItems: 'center', gap: 10 }}>
                        {pref.label}
                        {savingKey === pref.key && (
                          <span aria-hidden="true" className="ui-spinner small" />
                        )}
                        {savedKey === pref.key && (
                          <span role="status" style={{ fontSize: 12, color: '#116B3F', fontWeight: 600 }}>Saved ✓</span>
                        )}
                      </div>
                      <Toggle
                        checked={prefValue(pref.key)}
                        onChange={(checked) => void togglePref(pref.key, checked)}
                        ariaLabel={pref.label}
                      />
                    </div>
                  ))}
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
