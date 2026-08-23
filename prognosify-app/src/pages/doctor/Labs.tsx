import { useMemo, useState, type CSSProperties } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { hiChip, medChip, lowChip } from '../../data/mock';
import { Busy, Chip, Pressable } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import { getLabReviewQueue, getPatientSummaries, type LabQueueRow } from '../../lib/api';
import { timeLabel, visitStamp } from '../../lib/format';

const flagStyle = (flag: string): CSSProperties => {
  if (flag.includes('critical') || flag === 'high') return hiChip;
  if (flag !== 'normal') return medChip;
  return lowChip;
};

const flagLabel = (flag: string): string => {
  switch (flag) {
    case 'critical_high':
    case 'critical_low':
      return 'Critical â†‘';
    case 'high':
    case 'low':
      return 'Abnormal';
    case 'indeterminate':
      return 'Indeterminate';
    default:
      return 'Normal';
  }
};

const GRID_COLUMNS = '1.8fr 1.4fr 1.2fr 1fr 1.2fr 1fr';

type LabFilter = {
  prefix: string;
  label: (n: number) => string;
  color?: string;
  note: string;
  match: (row: LabQueueRow) => boolean;
};

const filters: LabFilter[] = [
  {
    prefix: 'All',
    label: (n) => `All (${n})`,
    note: 'Every result visible to you, newest first.',
    match: () => true,
  },
  {
    prefix: 'Abnormal',
    label: (n) => `Abnormal (${n})`,
    color: '#B42318',
    note: 'Flagged anything but normal â€” includes criticals.',
    match: (row) => row.abnormal_flag !== 'normal',
  },
  {
    prefix: 'Reviewed',
    label: (n) => `Reviewed (${n})`,
    note: 'Results already acknowledged or signed off.',
    match: (row) => row.review_status !== 'unreviewed',
  },
];

export default function Labs() {
  const navigate = useNavigate();
  const [activePrefix, setActivePrefix] = useState('All');

  const { data, error, loading } = useAsync(async () => {
    const [rows, summaries] = await Promise.all([getLabReviewQueue(), getPatientSummaries()]);
    const mrnById = new Map(summaries.map((s) => [s.patient_id, s.mrn]));
    return rows.map((r) => ({ ...r, mrn: mrnById.get(r.patient_id) }));
  }, []);

  const rows = useMemo(() => data ?? [], [data]);
  const activeFilter = filters.find((f) => f.prefix === activePrefix) ?? filters[0];
  const visible = rows.filter(activeFilter.match);

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="labs" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Labs awaiting review</h1>
          <div style={{ display: 'flex', gap: 8 }}>
            {filters.map((f) => {
              const selected = f.prefix === activeFilter.prefix;
              return (
                <Chip
                  key={f.prefix}
                  selected={selected}
                  onClick={() => setActivePrefix(f.prefix)}
                  style={!selected && f.color ? { color: f.color } : undefined}
                  title={`${rows.filter(f.match).length} of ${rows.length} results match. ${f.note}`}
                >
                  {f.label(rows.filter(f.match).length)}
                </Chip>
              );
            })}
          </div>
        </div>
        <div style={{ flex: 1, padding: '24px 28px', overflow: 'auto' }}>
          <div role="table" aria-label="Labs awaiting review" style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, overflow: 'hidden' }}>
            <div role="row" style={{ display: 'grid', gridTemplateColumns: GRID_COLUMNS, padding: '12px 20px', borderBottom: '1px solid #DDE3EB', fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.03em', textTransform: 'uppercase' }}>
              <div role="columnheader">Patient</div><div role="columnheader">Panel</div><div role="columnheader">Flag</div><div role="columnheader">Resulted</div><div role="columnheader">Result Â· range</div><div role="columnheader"></div>
            </div>
            {loading && (
              <div role="status" style={{ padding: '14px 20px', fontSize: 13.5, color: '#5B6B7F' }}><Busy label="Loading results" fill={false} /></div>
            )}
            {error && (
              <div role="alert" style={{ padding: '14px 20px', fontSize: 13.5, color: '#B42318' }}>Could not load results: {error}</div>
            )}
            {!loading && !error && visible.map((r, i) => (
              <div key={r.lab_result_id} role="row" style={{ display: 'grid', gridTemplateColumns: GRID_COLUMNS, padding: '14px 20px', borderBottom: i < visible.length - 1 ? '1px solid #EEF2F6' : undefined, fontSize: 13.5, alignItems: 'center' }}>
                <div role="cell" style={{ fontWeight: 600 }}>{r.patient_name}</div>
                <div role="cell" style={{ color: '#5B6B7F' }}>
                  {r.test_name}
                  <span style={{ color: '#8A97A8' }}> Â· {r.panel_name}</span>
                </div>
                <div role="cell"><span style={flagStyle(r.abnormal_flag)}>{flagLabel(r.abnormal_flag)}</span></div>
                <div role="cell" style={{ color: '#5B6B7F' }}>
                  {visitStamp(r.resulted_at) === 'Today' ? `Today ${timeLabel(r.resulted_at)}` : visitStamp(r.resulted_at)}
                </div>
                <div role="cell" style={{ color: r.abnormal_flag !== 'normal' ? '#3A4A5E' : '#5B6B7F', fontSize: 12.5 }}>
                  {r.value_numeric != null
                    ? `${r.value_numeric} ${r.unit ?? ''}`.trim()
                    : r.value_text ?? 'â€”'}
                  {r.reference_range ? ` Â· range ${r.reference_range}` : ''}
                </div>
                <div role="cell">
                  <Pressable
                    onClick={() => r.mrn && navigate(`/doctor/patients/${r.mrn}`)}
                    ariaLabel={`Review ${r.patient_name} â€” ${r.test_name}`}
                    style={{ color: '#1D4ED8', fontWeight: 600, fontSize: 13, cursor: 'pointer', textAlign: 'right', width: '100%' }}
                  >
                    Review â†’
                  </Pressable>
                </div>
              </div>
            ))}
            {!loading && !error && visible.length === 0 && (
              <div role="row" style={{ padding: '14px 20px', fontSize: 13.5, color: '#5B6B7F' }}>
                <div role="cell" aria-colspan={6}>No lab results match this filter.</div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
