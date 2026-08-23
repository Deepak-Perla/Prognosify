import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import PortalNav from '../../components/PortalNav';
import { Pressable, SegmentedControl, pressableReset } from '../../components/ui';

const slots = [
  { day: 'Thu, Aug 20', time: '9:00 AM', tag: 'Recommended', tagColor: '#116B3F' },
  { day: 'Thu, Aug 20', time: '10:30 AM', tag: 'Clinic 2', tagColor: '#8A97A8' },
  { day: 'Fri, Aug 21', time: '11:40 AM', tag: 'Clinic 2', tagColor: '#8A97A8' },
  { day: 'Mon, Aug 24', time: '2:10 PM', tag: 'Clinic 2', tagColor: '#8A97A8' },
];

const visitTypes = ['In person', 'Video consult'] as const;

/** "Thu, Aug 20" + "9:00 AM" -> "Thu 9:00 AM", the short form the Confirm button uses. */
const shortLabel = (s: typeof slots[number]) => `${s.day.split(',')[0]} ${s.time}`;

const slotBase = { borderRadius: 10, padding: 14, display: 'flex', flexDirection: 'column' as const, gap: 4 };

export default function PatientBook() {
  const navigate = useNavigate();
  const [visitType, setVisitType] = useState<string>(visitTypes[0]);
  // No slot is pre-selected: the mockup paints all four cards unselected, so state starts empty.
  const [selected, setSelected] = useState<number | null>(null);
  const [showHint, setShowHint] = useState(false);

  const confirmSlot = selected === null ? slots[0] : slots[selected];

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Book visit" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
        <div style={{ width: 760, display: 'flex', flexDirection: 'column', gap: 22, padding: '36px 0' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>Book a visit</h1>
            <div style={{ fontSize: 14, color: '#5B6B7F' }}>Step 2 of 3 · Choose a time</div>
          </div>
          <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <SegmentedControl
              options={visitTypes}
              value={visitType}
              onChange={setVisitType}
              ariaLabel="Visit type"
              style={{ display: 'flex', gap: 10 }}
              itemStyle={{ border: '1px solid #DDE3EB', borderRadius: 10, padding: '10px 16px', fontSize: 13.5, color: '#5B6B7F' }}
              selectedItemStyle={{ border: '1px solid #1D4ED8', background: '#EDF2FE', color: '#1D4ED8', fontWeight: 600 }}
            />
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <h2 style={{ fontSize: 14.5, fontWeight: 600, margin: 0 }}>Dr. Anita Mehta · Diabetes follow-up</h2>
              {/* No provider directory exists in this prototype, so this is honestly marked unavailable
                  rather than wired to a fake picker. Still focusable so its state is discoverable. */}
              <button
                type="button"
                aria-disabled="true"
                title="Choosing a different provider isn't available in this prototype."
                style={{ ...pressableReset, fontSize: 13, color: '#1D4ED8', fontWeight: 500 }}
              >
                Change provider
              </button>
            </div>
            <div role="group" aria-label="Available times" style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 10, fontSize: 13 }}>
              {slots.map((s, i) => (
                <Pressable
                  key={s.time}
                  className="hover-accent-text"
                  ariaPressed={selected === i}
                  onClick={() => { setSelected(i); setShowHint(false); }}
                  style={selected === i
                    ? { ...slotBase, border: '1px solid #1D4ED8', background: '#EDF2FE' }
                    : { ...slotBase, border: '1px solid #DDE3EB' }}
                >
                  <div style={{ fontWeight: 600 }}>{s.day}</div>
                  <div style={{ color: s.tagColor === '#116B3F' ? '#1D4ED8' : '#0F1C2E', fontWeight: 700 }}>{s.time}</div>
                  <div style={{ fontSize: 11.5, color: s.tagColor, fontWeight: 600 }}>{s.tag}</div>
                </Pressable>
              ))}
            </div>
            <div style={{ background: '#F8F9FB', border: '1px solid #DDE3EB', borderRadius: 10, padding: '12px 14px', fontSize: 12.5, color: '#5B6B7F' }}>
              Morning visits work best for you — you've kept 9 of 9 morning appointments this year.
            </div>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <Pressable onClick={() => navigate('/patient/home')} style={{ border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 8, padding: '11px 20px', fontSize: 14, fontWeight: 500 }}>Back</Pressable>
            <button
              type="button"
              aria-disabled={selected === null || undefined}
              aria-describedby={showHint ? 'book-confirm-hint' : undefined}
              title="Prototype only — this returns you to your portal home; no appointment is actually booked."
              onClick={() => { if (selected === null) setShowHint(true); else navigate('/patient/home'); }}
              style={{ ...pressableReset, background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '11px 22px', fontSize: 14, fontWeight: 600 }}
            >
              Confirm {shortLabel(confirmSlot)} →
            </button>
          </div>
          {showHint && (
            <div id="book-confirm-hint" role="status" style={{ fontSize: 12.5, color: '#B54708', textAlign: 'right' }}>
              Choose a time above first.
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
