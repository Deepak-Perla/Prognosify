import { useNavigate } from 'react-router-dom';
import PortalNav from '../../components/PortalNav';
import { Pressable } from '../../components/ui';
import { lowChip, medChip, hiChip } from '../../data/mock';
import type { CSSProperties } from 'react';
import { useAsync } from '../../lib/useAsync';
import { getReleasedResults } from '../../lib/api';
import { shortDate, visitStamp } from '../../lib/format';

const statusChip = (flag: string): { text: string; style: CSSProperties } => {
  if (flag === 'critical_high' || flag === 'critical_low') return { text: 'Critical', style: hiChip };
  if (flag === 'high' || flag === 'low' || flag === 'indeterminate') return { text: 'Outside range', style: medChip };
  return { text: 'In range', style: lowChip };
};

/** Plain-language sentence per abnormal flag — the portal's whole reason to exist. */
const explanationFor = (flag: string): string => {
  switch (flag) {
    case 'critical_high':
    case 'critical_low':
      return 'This value needs attention soon. Your care team has been notified and may contact you.';
    case 'high':
    case 'low':
      return 'This reading is a little outside the usual range. Your care team will review it with you at your next visit.';
    default:
      return '';
  }
};

export default function PatientResults() {
  const navigate = useNavigate();
  const { data, error, loading } = useAsync(() => getReleasedResults(), []);

  const results = data ?? [];
  // Feature card: prefer an out-of-range result so "needs attention" leads; else the newest.
  const featured = results.find((r) => r.abnormal_flag !== 'normal') ?? results[0] ?? null;
  const isHba1c = Boolean(featured && /hba1c|a1c/i.test(featured.test.name));
  const hba1cValue = featured?.value_numeric ?? null;

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Results" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
        <div style={{ width: 860, display: 'flex', flexDirection: 'column', gap: 22, padding: '36px 0' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>My results</h1>
            <div style={{ fontSize: 14, color: '#5B6B7F' }}>Explained in plain language. Your care team sees everything here too.</div>
          </div>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 12, padding: '16px 20px', fontSize: 13.5, color: '#B42318' }}>
              Could not load your results: {error}
            </div>
          )}
          {loading && (
            <div role="status" style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, fontSize: 14, color: '#5B6B7F' }}>
              Loading your results…
            </div>
          )}
          {!loading && !error && !featured && (
            <div role="status" style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, fontSize: 14, color: '#5B6B7F', lineHeight: 1.6 }}>
              Nothing has been released to you yet. Results appear here once your care team reviews and shares them.
            </div>
          )}
          {!loading && featured && (
            <div
              style={{
                background: '#ffffff',
                border: `1px solid ${featured.abnormal_flag === 'normal' ? '#DDE3EB' : '#F3E3C2'}`,
                borderRadius: 14,
                padding: 24,
                display: 'flex',
                flexDirection: 'column',
                gap: 14,
              }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
                  <h2 style={{ fontSize: 16, fontWeight: 700, margin: 0 }}>
                    {featured.test.name}
                    {' · '}
                    {featured.value_numeric != null
                      ? `${featured.value_numeric}${featured.unit ? ` ${featured.unit}` : ''}`
                      : featured.value_text}
                  </h2>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Resulted {visitStamp(featured.resulted_at)}</div>
                </div>
                {(() => {
                  const chip = statusChip(featured.abnormal_flag);
                  return <span style={chip.style}>{chip.text}</span>;
                })()}
              </div>
              {isHba1c && hba1cValue != null && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {/* Purely presentational gradient; role="img" + a spoken description so the marker
                      position is not invisible to assistive tech. */}
                  {(() => {
                    const clamped = Math.min(12, Math.max(5, hba1cValue));
                    const pos = ((clamped - 5) / 7) * 100;
                    return (
                      <>
                        <div
                          role="img"
                          aria-label={`HbA1c ${hba1cValue} percent on a scale from 5.0 to 12.0.`}
                          style={{ position: 'relative', height: 10, borderRadius: 5, background: 'linear-gradient(to right,#7BC49A 0%,#7BC49A 38%,#EFC96B 38%,#EFC96B 62%,#E38B80 62%,#E38B80 100%)' }}
                        >
                          <div style={{ position: 'absolute', left: `${Math.min(97, Math.max(1, pos))}%`, top: -4, width: 4, height: 18, background: '#0F1C2E', borderRadius: 2 }} />
                        </div>
                        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, color: '#8A97A8' }}>
                          <div>5.0</div><div>12.0</div>
                        </div>
                      </>
                    );
                  })()}
                </div>
              )}
              {explanationFor(featured.abnormal_flag) && (
                <div style={{ fontSize: 13.5, lineHeight: 1.65, color: '#3A4A5E' }}>{explanationFor(featured.abnormal_flag)}</div>
              )}
              <div style={{ display: 'flex', gap: 10 }}>
                <Pressable onClick={() => navigate('/patient/messages')} style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 500 }}>Ask my care team</Pressable>
                <Pressable onClick={() => navigate('/patient/book')} style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 500 }}>Book follow-up</Pressable>
              </div>
            </div>
          )}
          {!loading && !error && results.length > 0 && (
            <div role="table" aria-label="All results" style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, overflow: 'hidden' }}>
              <div role="row" style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 1fr 1fr', padding: '12px 22px', borderBottom: '1px solid #DDE3EB', fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.03em', textTransform: 'uppercase' }}>
                <div role="columnheader">Test</div><div role="columnheader">Result</div><div role="columnheader">Status</div><div role="columnheader">Date</div>
              </div>
              {results.map((r, i) => {
                const chip = statusChip(r.abnormal_flag);
                return (
                  <div role="row" key={r.id} title={shortDate(r.resulted_at)} style={{ display: 'grid', gridTemplateColumns: '1.6fr 1fr 1fr 1fr', padding: '14px 22px', borderBottom: i < results.length - 1 ? '1px solid #EEF2F6' : undefined, fontSize: 13.5, alignItems: 'center' }}>
                    <div role="cell" style={{ fontWeight: 600 }}>{r.test.name}</div>
                    <div role="cell">{r.value_numeric != null ? `${r.value_numeric}${r.unit ? ` ${r.unit}` : ''}` : r.value_text}</div>
                    <div role="cell"><span style={chip.style}>{chip.text}</span></div>
                    <div role="cell" style={{ color: '#5B6B7F' }}>{visitStamp(r.resulted_at)}</div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
