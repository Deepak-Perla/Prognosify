import type { CSSProperties } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { LayoutDashboard, Users, CalendarDays, FlaskConical, MessageSquareText, Settings as SettingsIcon, LogOut, DoorOpen, ClipboardList, CalendarPlus, UserPlus, Receipt } from 'lucide-react';
import Logo from './Logo';
import { Pressable } from './ui';
import { useAuth } from '../lib/auth';

type Role = 'doctor' | 'reception';

const doctorItems: [string, string, string][] = [
  ['docDash', 'Dashboard', '/doctor/dashboard'],
  ['patients', 'Patients', '/doctor/patients'],
  ['schedule', 'Schedule', '/doctor/schedule'],
  ['labs', 'Labs', '/doctor/labs'],
  ['aiChat', 'AI assistant', '/doctor/ai-assistant'],
];

const receptionItems: [string, string, string][] = [
  ['recDash', 'Front desk', '/reception/dashboard'],
  ['checkin', 'Check-in queue', '/reception/check-in'],
  ['booking', 'Book appointment', '/reception/booking'],
  ['register', 'Register patient', '/reception/register'],
  ['billing', 'Billing', '/reception/billing'],
];

const iconFor = (key: string) => {
  switch (key) {
    case 'docDash': return LayoutDashboard;
    case 'patients': return Users;
    case 'schedule': return CalendarDays;
    case 'labs': return FlaskConical;
    case 'aiChat': return MessageSquareText;
    case 'recDash': return DoorOpen;
    case 'checkin': return ClipboardList;
    case 'booking': return CalendarPlus;
    case 'register': return UserPlus;
    case 'billing': return Receipt;
    default: return LayoutDashboard;
  }
};

const base: CSSProperties = {
  padding: '9px 10px',
  borderRadius: 7,
  fontSize: 13.5,
  cursor: 'pointer',
  display: 'flex',
  alignItems: 'center',
  gap: 10,
};

/**
 * index.css styles bare anchors (`a { color:#1D4ED8 }`, `a:hover { color:#1E40AF; text-decoration:underline }`).
 * The per-item `color` below is inline, so it already beats both rules; this kills the hover underline
 * and the mobile tap flash so a <Link> renders byte-identically to the <div> it replaced.
 */
const linkReset: CSSProperties = {
  textDecoration: 'none',
  WebkitTapHighlightColor: 'transparent',
};

export default function SideNav({ role, active }: { role: Role; active: string }) {
  const navigate = useNavigate();
  const { signOut } = useAuth();
  const items = role === 'doctor' ? doctorItems : receptionItems;

  const styleFor = (key: string): CSSProperties =>
    active === key
      ? { ...linkReset, ...base, fontWeight: 600, background: '#EDF2FE', color: '#1D4ED8' }
      : { ...linkReset, ...base, color: '#5B6B7F' };

  return (
    <nav
      aria-label="Primary"
      data-app-chrome=""
      style={{
        width: 232,
        background: '#ffffff',
        borderRight: '1px solid #DDE3EB',
        display: 'flex',
        flexDirection: 'column',
        padding: '20px 14px',
        gap: 4,
        height: '100%',
        boxSizing: 'border-box',
        flexShrink: 0,
      }}
    >
      <Logo size={26} gap={8} wordmarkSize={15} wordmarkWeight={600} wordmarkColor="#0F1C2E" style={{ padding: '0 10px 18px' }} />
      {items.map(([key, label, path]) => {
        const Icon = iconFor(key);
        return (
          <Link key={key} to={path} aria-current={active === key ? 'page' : undefined} style={styleFor(key)}>
            <Icon size={16} strokeWidth={2} aria-hidden="true" />
            <span>{label}</span>
          </Link>
        );
      })}
      <Link
        to="/settings"
        aria-current={active === 'settings' ? 'page' : undefined}
        style={{ ...styleFor('settings'), marginTop: 'auto' }}
      >
        <SettingsIcon size={16} strokeWidth={2} aria-hidden="true" />
        <span>Settings</span>
      </Link>
      {/* Log out ends the session — an action, not a destination — so it stays a button.
          It must actually clear the Supabase session, not merely navigate away: a bare
          navigate left the user signed in, so the back button walked straight back in. */}
      <Pressable
        onClick={async () => {
          await signOut();
          navigate('/login', { replace: true });
        }}
        style={{ ...base, color: '#5B6B7F' }}
      >
        <LogOut size={16} strokeWidth={2} aria-hidden="true" />
        <span>Log out</span>
      </Pressable>
    </nav>
  );
}
