import type { CSSProperties } from 'react';
import { Bell } from 'lucide-react';
import { Link, useNavigate } from 'react-router-dom';
import Logo from './Logo';
import { Pressable } from './ui';
import { useAuth } from '../lib/auth';

const items: [string, string][] = [
  ['Home', '/patient/home'],
  ['Book visit', '/patient/book'],
  ['Results', '/patient/results'],
  ['Messages', '/patient/messages'],
  ['Care plan', '/patient/care-plan'],
];

/** Mock unread count. Rendered in the badge and spoken in the bell's accessible name, so the two never drift. */
const unreadCount = 1;

/**
 * index.css styles bare anchors (`a { color:#1D4ED8 }`, `a:hover { color:#1E40AF; text-decoration:underline }`).
 * Each item's `color` is inline and already beats both; this kills the hover underline and the tap flash
 * so a <Link> renders byte-identically to the <div> it replaced.
 */
const linkReset: CSSProperties = {
  textDecoration: 'none',
  WebkitTapHighlightColor: 'transparent',
};

export default function PortalNav({ active, homeVariant = false }: { active: string; homeVariant?: boolean }) {
  const navigate = useNavigate();
  const { signOut } = useAuth();
  const avatarStyle ={ width: 32, height: 32, borderRadius: '50%', background: '#0F6E5D', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600 } as const;
  return (
    <header data-app-chrome="" style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 48px', flexShrink: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 32 }}>
        <Logo size={26} gap={8} wordmarkSize={15} wordmarkWeight={600} />
        <nav aria-label="Patient portal" style={{ display: 'flex', gap: 22, fontSize: 13.5 }}>
          {items.map(([label, path]) => (
            <Link
              key={label}
              to={path}
              aria-current={active === label ? 'page' : undefined}
              style={active === label
                ? { ...linkReset, color: '#1D4ED8', fontWeight: 600, cursor: 'pointer' }
                : { ...linkReset, color: '#5B6B7F', cursor: 'pointer' }}
            >
              {label}
            </Link>
          ))}
        </nav>
      </div>
      {homeVariant ? (
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <Pressable
            onClick={() => navigate('/patient/messages')}
            ariaLabel={`Notifications: ${unreadCount} unread message${unreadCount === 1 ? '' : 's'}. Go to Messages`}
            style={{ fontSize: 13, color: '#5B6B7F', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 2 }}
          >
            <Bell size={16} aria-hidden="true" />
            {/* The count is already spoken by the button's accessible name above; hidden here to avoid a bare "1". */}
            <span aria-hidden="true" style={{ background: '#B42318', color: '#fff', borderRadius: 8, fontSize: 10, fontWeight: 700, padding: '1px 5px' }}>{unreadCount}</span>
          </Pressable>
          {/* Actually ends the session, rather than just navigating to /login. */}
          <Pressable
            onClick={async () => { await signOut(); navigate('/login', { replace: true }); }}
            ariaLabel="Priya Nair — sign out"
            style={{ ...avatarStyle, cursor: 'pointer' }}
          >PN</Pressable>
        </div>
      ) : (
        <div style={avatarStyle}>PN</div>
      )}
    </header>
  );
}
