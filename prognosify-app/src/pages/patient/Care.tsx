import { useState } from 'react';
import type { CSSProperties } from 'react';
import PortalNav from '../../components/PortalNav';
import { Pressable, pressableReset } from '../../components/ui';

const checklist = [
  { label: 'Metformin 500mg', sub: 'with breakfast', done: true, time: '7:45 AM' },
  { label: 'Morning glucose check', sub: '118 mg/dL', done: true, time: '8:02 AM' },
  { label: '30-minute walk', sub: 'any time today', done: false, action: 'Log it' },
  { label: 'Evening glucose check', sub: 'around 8 PM', done: false, time: 'Reminder set' },
];

const goals = [
  { label: 'HbA1c under 7.5%', meta: '8.9 → 7.5', pct: 35, color: '#B54708' },
  { label: 'Walk 5 days a week', meta: '4 of 5 this week', pct: 80, color: '#116B3F' },
  { label: 'Medication adherence', meta: '96%', pct: 96, color: '#116B3F' },
];

const doneTile: CSSProperties = { width: 20, height: 20, borderRadius: 6, background: '#116B3F', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 };
const openTile: CSSProperties = { width: 20, height: 20, borderRadius: 6, border: '1.5px solid #C6CFDA', flexShrink: 0 };

const tileId = (label: string) => `care-tile-${label.replace(/[^a-zA-Z0-9]+/g, '-')}`;

export default function PatientCare() {
  // Local-only completion state. Items that ship as done stay done; the two open ones are togglable.
  const [done, setDone] = useState<Record<string, boolean>>(() =>
    Object.fromEntries(checklist.map((c) => [c.label, c.done])),
  );
  const mark = (label: string, value: boolean) => setDone((prev) => ({ ...prev, [label]: value }));
  const doneCount = checklist.filter((c) => done[c.label]).length;

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Care plan" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
        <div style={{ width: 860, display: 'flex', flexDirection: 'column', gap: 22, padding: '36px 0' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end' }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
              <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>My care plan</h1>
              <div style={{ fontSize: 14, color: '#5B6B7F' }}>Type 2 diabetes · Set with Dr. Mehta on Jul 2 · Next review Aug 20</div>
            </div>
            <div style={{ fontSize: 13, color: '#5B6B7F' }}>Week 7 of 12</div>
          </div>
          <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <h2 style={{ fontSize: 15, fontWeight: 700, margin: 0 }}>Today · Mon, Aug 17</h2>
              <div role="status" style={{ fontSize: 12.5, color: '#116B3F', fontWeight: 600 }}>{doneCount} of {checklist.length} done</div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              {checklist.map((c) => {
                const isDone = done[c.label];
                // Only the items that start open can be checked off; the two already-logged ones stay static.
                const togglable = !c.done;
                const id = tileId(c.label);
                return (
                  <div key={c.label} style={{ display: 'flex', gap: 12, alignItems: 'center', border: `1px solid ${isDone ? '#EEF2F6' : '#DDE3EB'}`, borderRadius: 10, padding: '13px 16px' }}>
                    {togglable ? (
                      <button
                        type="button"
                        id={id}
                        role="checkbox"
                        aria-checked={isDone}
                        aria-label={c.label}
                        onClick={() => mark(c.label, !isDone)}
                        style={isDone ? { ...pressableReset, ...doneTile } : { ...pressableReset, ...openTile }}
                      >
                        {isDone ? '✓' : null}
                      </button>
                    ) : (
                      <div style={doneTile}>✓</div>
                    )}
                    <div style={{ flex: 1, fontSize: 13.5 }}>
                      <span style={{ fontWeight: 600 }}>{c.label}</span> · {c.sub}
                    </div>
                    {c.action ? (
                      !isDone && (
                        <Pressable
                          onClick={() => { mark(c.label, true); document.getElementById(id)?.focus(); }}
                          ariaLabel={`${c.action} — ${c.label}`}
                          style={{ fontSize: 12.5, color: '#1D4ED8', fontWeight: 600 }}
                        >
                          {c.action}
                        </Pressable>
                      )
                    ) : (
                      <div style={{ fontSize: 12, color: '#5B6B7F' }}>{c.time}</div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 22, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <h2 style={{ fontSize: 14.5, fontWeight: 700, margin: 0 }}>Goals · 12-week plan</h2>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12, fontSize: 13 }}>
                {goals.map((g) => (
                  <div key={g.label} style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                      <div style={{ fontWeight: 600 }}>{g.label}</div>
                      <div style={{ color: '#5B6B7F' }}>{g.meta}</div>
                    </div>
                    <div
                      role="progressbar"
                      aria-label={g.label}
                      aria-valuemin={0}
                      aria-valuemax={100}
                      aria-valuenow={g.pct}
                      aria-valuetext={g.meta}
                      style={{ height: 7, borderRadius: 4, background: '#F4F6F9' }}
                    >
                      <div style={{ width: `${g.pct}%`, height: 7, borderRadius: 4, background: g.color }} />
                    </div>
                  </div>
                ))}
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
              <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 22, display: 'flex', flexDirection: 'column', gap: 10 }}>
                <h2 style={{ fontSize: 14.5, fontWeight: 700, margin: 0 }}>My medications</h2>
                <div style={{ fontSize: 13.5, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><div>Metformin 500mg</div><div style={{ color: '#5B6B7F' }}>2× daily</div></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><div>Atorvastatin 20mg</div><div style={{ color: '#5B6B7F' }}>nightly</div></div>
                </div>
                {/* Refills need a pharmacy back end this prototype doesn't have, so the control is
                    honestly marked unavailable instead of faking a request. */}
                <button
                  type="button"
                  aria-disabled="true"
                  title="Refill requests aren't available in this prototype — nothing is sent to your pharmacy."
                  style={{ ...pressableReset, fontSize: 13, color: '#1D4ED8', fontWeight: 600 }}
                >
                  Request refill →
                </button>
              </div>
              <div style={{ background: '#0F1C2E', borderRadius: 14, padding: '18px 20px', display: 'flex', flexDirection: 'column', gap: 6, color: '#fff' }}>
                <h2 style={{ fontSize: 12.5, fontWeight: 600, color: '#8FB0FF', margin: 0 }}>WHY THIS PLAN</h2>
                <div style={{ fontSize: 13, color: '#C7D2E4', lineHeight: 1.6 }}>Patients with a similar profile who kept this routine lowered HbA1c by ~1.2 points in 12 weeks.</div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
