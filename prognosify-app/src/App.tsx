import { useState, type CSSProperties, type MouseEvent, type ReactNode } from 'react';
import { Navigate, Route, Routes } from 'react-router-dom';
import Login from './pages/Login';
import Forgot from './pages/Forgot';
import Settings from './pages/Settings';
import Dashboard from './pages/doctor/Dashboard';
import Patients from './pages/doctor/Patients';
import PatientDetail from './pages/doctor/PatientDetail';
import Schedule from './pages/doctor/Schedule';
import Labs from './pages/doctor/Labs';
import AIChat from './pages/doctor/AIChat';
import ReceptionDashboard from './pages/reception/Dashboard';
import CheckIn from './pages/reception/CheckIn';
import Booking from './pages/reception/Booking';
import Register from './pages/reception/Register';
import Billing from './pages/reception/Billing';
import PatientHome from './pages/patient/Home';
import PatientBook from './pages/patient/Book';
import PatientResults from './pages/patient/Results';
import PatientMessages from './pages/patient/Messages';
import PatientCare from './pages/patient/Care';
import RequireRole from './components/RequireRole';

const MAIN_ID = 'main-content';

/** Wraps a screen so only these roles can reach it. */
const staff = (node: ReactNode) => <RequireRole allow={['doctor', 'receptionist']}>{node}</RequireRole>;
const doctor = (node: ReactNode) => <RequireRole allow={['doctor']}>{node}</RequireRole>;
const reception = (node: ReactNode) => <RequireRole allow={['receptionist']}>{node}</RequireRole>;
const patient = (node: ReactNode) => <RequireRole allow={['patient']}>{node}</RequireRole>;

/**
 * Clipped rather than `display:none` so the link keeps its place in the tab order.
 * Out of flow (`position:absolute`), so it contributes exactly zero pixels to the shell.
 */
const skipLinkHidden: CSSProperties = {
  position: 'absolute',
  width: 1,
  height: 1,
  margin: -1,
  padding: 0,
  border: 0,
  overflow: 'hidden',
  clip: 'rect(0 0 0 0)',
  clipPath: 'inset(50%)',
  whiteSpace: 'nowrap',
  textDecoration: 'none',
};

const skipLinkVisible: CSSProperties = {
  position: 'absolute',
  top: 12,
  left: 12,
  zIndex: 1000,
  width: 'auto',
  height: 'auto',
  margin: 0,
  padding: '9px 14px',
  clip: 'auto',
  clipPath: 'none',
  overflow: 'visible',
  whiteSpace: 'nowrap',
  background: '#1D4ED8',
  color: '#ffffff',
  borderRadius: 7,
  fontSize: 13.5,
  fontWeight: 600,
  textDecoration: 'none',
};

/**
 * The routed screens own their own full-height shells, so `<main>` has to sit above all of
 * them — which means the persistent chrome (SideNav / PortalNav) lives inside it. Both mark
 * their outermost chrome element with `data-app-chrome`; this walks past the last one to the
 * first real content box, so the skip link genuinely skips the navigation instead of landing
 * on top of it. Falls back to `<main>` itself on screens with no chrome (Login, Forgot).
 */
function contentTarget(): HTMLElement | null {
  const main = document.getElementById(MAIN_ID);
  if (!main) return null;
  const chrome = main.querySelectorAll<HTMLElement>('[data-app-chrome]');
  let node: HTMLElement | null = chrome.length ? chrome[chrome.length - 1] : null;
  while (node && node !== main) {
    const next = node.nextElementSibling;
    if (next instanceof HTMLElement) return next;
    node = node.parentElement;
  }
  return main;
}

export default function App() {
  const [skipFocused, setSkipFocused] = useState(false);

  const handleSkip = (event: MouseEvent<HTMLAnchorElement>) => {
    const target = contentTarget();
    if (!target) return;
    event.preventDefault();
    if (!target.hasAttribute('tabindex')) {
      target.setAttribute('tabindex', '-1');
      target.addEventListener('blur', () => target.removeAttribute('tabindex'), { once: true });
    }
    target.focus();
  };

  return (
    <div style={{ width: '100vw', height: '100vh', overflow: 'hidden', position: 'relative', color: '#0F1C2E', background: '#F4F6F9' }}>
      <a
        href={`#${MAIN_ID}`}
        onClick={handleSkip}
        onFocus={() => setSkipFocused(true)}
        onBlur={() => setSkipFocused(false)}
        style={skipFocused ? skipLinkVisible : skipLinkHidden}
      >
        Skip to main content
      </a>
      <main id={MAIN_ID} tabIndex={-1} style={{ width: '100%', height: '100%' }}>
        <Routes>
          <Route path="/" element={<Navigate to="/login" replace />} />
          <Route path="/login" element={<Login />} />
          <Route path="/forgot" element={<Forgot />} />
          <Route path="/settings" element={staff(<Settings />)} />

          <Route path="/doctor/dashboard" element={doctor(<Dashboard />)} />
          <Route path="/doctor/patients" element={doctor(<Patients />)} />
          <Route path="/doctor/patients/:mrn" element={doctor(<PatientDetail />)} />
          <Route path="/doctor/schedule" element={doctor(<Schedule />)} />
          <Route path="/doctor/labs" element={doctor(<Labs />)} />
          <Route path="/doctor/ai-assistant" element={doctor(<AIChat />)} />

          <Route path="/reception/dashboard" element={reception(<ReceptionDashboard />)} />
          <Route path="/reception/check-in" element={reception(<CheckIn />)} />
          <Route path="/reception/booking" element={reception(<Booking />)} />
          <Route path="/reception/register" element={reception(<Register />)} />
          <Route path="/reception/billing" element={reception(<Billing />)} />

          <Route path="/patient/home" element={patient(<PatientHome />)} />
          <Route path="/patient/book" element={patient(<PatientBook />)} />
          <Route path="/patient/results" element={patient(<PatientResults />)} />
          <Route path="/patient/messages" element={patient(<PatientMessages />)} />
          <Route path="/patient/care-plan" element={patient(<PatientCare />)} />

          <Route path="*" element={<Navigate to="/login" replace />} />
        </Routes>
      </main>
    </div>
  );
}
