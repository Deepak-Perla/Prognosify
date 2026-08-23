import { useId, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { hiChip, medChip, lowChip, chip } from '../../data/mock';
import type { CSSProperties } from 'react';
import { Busy, Chip, TextField, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  getLatestRiskScores,
  getPatientSummaries,
  type Band,
  type PatientSummaryRow,
  type RiskScoreRow,
} from '../../lib/api';
import { ageSex, dayKey, shiftDay, todayKey, visitStamp } from '../../lib/format';

const RECENT_DAYS = 7;
const PAGE_SIZE = 8;

const bandChip: Record<Band, CSSProperties> = {
  high: hiChip,
  critical: chip('#FEF5F4', '#B42318', '#F1D3D0'),
  medium: medChip,
  low: lowChip,
};

interface Row {
  patientId: string;
  name: string;
  mrn: string;
  status: string;
  condition: string;
  riskLabel: string | null;
  riskStyle: CSSProperties | null;
  lastVisitAt: string | null;
}

function toRow(summary: PatientSummaryRow, risk: RiskScoreRow | undefined): Row {
  const label = risk ? `${risk.band === 'critical' ? 'High' : bandLabel(risk.band)} Â· ${riskPercent(risk)}` : null;
  return {
    patientId: summary.patient_id,
    name: `${summary.full_name} Â· ${ageSex(summary.age_years, summary.sex).trim()}`,
    mrn: summary.mrn,
    status: summary.is_inpatient ? `Inpatient Â· ${summary.current_room ?? 'ward'}` : 'Outpatient',
    condition: summary.primary_condition ?? 'â€”',
    riskLabel: label,
    riskStyle: risk ? bandChip[risk.band] : null,
    lastVisitAt: summary.last_visit_at,
  };
}

const bandLabel = (band: Band): string => band.charAt(0).toUpperCase() + band.slice(1);

/** Range scores (e.g. length of stay) have no probability; show the band alone on lists. */
function riskPercent(risk: RiskScoreRow): string {
  if (risk.probability == null) return bandLabel(risk.band);
  return `${Math.round(risk.probability * 100)}%`;
}

type Filter = {
  label: string;
  note: string;
  match: (row: Row) => boolean;
};

const filtersFor = (rows: Row[]): Filter[] => [
  { label: `All (${rows.length})`, note: 'Every active patient record at this hospital.', match: () => true },
  {
    label: `High risk (${rows.filter((r) => r.riskLabel?.startsWith('High')).length})`,
    note: "Latest AI risk score for the patient is banded high or critical. Scores appear only for patients on your care team.",
    match: (row) => row.riskLabel?.startsWith('High') === true,
  },
  {
    label: `Inpatient (${rows.filter((r) => r.status.startsWith('Inpatient')).length})`,
    note: 'Currently admitted with an open inpatient encounter.',
    match: (row) => row.status.startsWith('Inpatient'),
  },
  {
    label: 'Recently seen',
    note: `Last visit within the last ${RECENT_DAYS} days.`,
    match: (row) => daysSinceVisit(row.lastVisitAt) <= RECENT_DAYS,
  },
];

const daysSinceVisit = (lastVisitAt: string | null): number => {
  if (!lastVisitAt) return Number.POSITIVE_INFINITY;
  const today = todayKey();
  let diff = 0;
  let cursor = today;
  while (cursor !== dayKey(lastVisitAt) && diff < 3650) {
    cursor = shiftDay(cursor, -1);
    diff++;
  }
  return diff;
};

const GRID_COLUMNS = '2.2fr 1fr 1.2fr 1.6fr 1.2fr 1fr';

const visuallyHidden = {
  position: 'absolute' as const,
  width: 1,
  height: 1,
  padding: 0,
  margin: -1,
  overflow: 'hidden' as const,
  clip: 'rect(0 0 0 0)',
  whiteSpace: 'nowrap' as const,
  border: 0,
};

export default function Patients() {
  const navigate = useNavigate();
  const addPatientNoteId = useId();
  const [active, setActive] = useState<string>('All');
  const [query, setQuery] = useState('');
  const [page, setPage] = useState(0);

  const { data, error, loading } = useAsync(async () => {
    const [summaries, risks] = await Promise.all([getPatientSummaries(), getLatestRiskScores()]);
    const riskByPatient = new Map(risks.map((r) => [r.patient_id, r]));
    return summaries.map((s) => toRow(s, riskByPatient.get(s.patient_id)));
  }, []);

  const rows = useMemo(() => data ?? [], [data]);
  // The chip labels carry live counts, so selection is tracked on the stable prefix ("All", â€¦).
  const filters = useMemo(() => filtersFor(rows), [rows]);
  const activePrefix = active.split(' (')[0];
  const activeFilter =
    filters.find((f) => f.label.split(' (')[0] === activePrefix) ?? filters[0];

  const needle = query.trim().toLowerCase();
  const matches = rows.filter(
    (row) =>
      activeFilter.match(row) &&
      (needle === '' || row.name.toLowerCase().includes(needle) || row.mrn.toLowerCase().includes(needle)),
  );

  const pageCount = Math.max(1, Math.ceil(matches.length / PAGE_SIZE));
  const currentPage = Math.min(page, pageCount - 1);
  const visible = matches.slice(currentPage * PAGE_SIZE, currentPage * PAGE_SIZE + PAGE_SIZE);
  const hasPrev = currentPage > 0;
  const hasNext = currentPage < pageCount - 1;

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="patients" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Patients</h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <TextField
              value={query}
              onChange={(value) => { setQuery(value); setPage(0); }}
              placeholder="Search by name or MRNâ€¦"
              ariaLabel="Search patients by name or MRN"
              style={{ border: '1px solid #DDE3EB', borderRadius: 8, background: '#F4F6F9', padding: '8px 14px', fontSize: 13, color: '#5B6B7F', width: 240 }}
            />
            {/* Registration happens at the front desk (reception â†’ Register); the doctor portal
                does not create patients, so this stays marked unavailable rather than faking it. */}
            <button
              type="button"
              aria-disabled="true"
              aria-describedby={addPatientNoteId}
              title="Patients are registered at the front desk â€” see reception â†’ Register."
              onClick={() => { /* intentionally does nothing: see aria-disabled */ }}
              style={{ ...pressableReset, background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}
            >
              Add patient
            </button>
            <span id={addPatientNoteId} style={visuallyHidden}>Patient registration lives in the reception portal.</span>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 16, padding: '24px 28px', overflow: 'auto' }}>
          <div style={{ display: 'flex', gap: 8 }}>
            {filters.map((f) => (
              <Chip
                key={f.label}
                selected={f.label === activeFilter.label}
                onClick={() => { setActive(f.label); setPage(0); }}
                title={`${rows.filter(f.match).length} of ${rows.length} records match. ${f.note}`}
              >
                {f.label}
              </Chip>
            ))}
          </div>
          <div role="table" aria-label="Patients" style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
            <div role="row" style={{ display: 'grid', gridTemplateColumns: GRID_COLUMNS, padding: '12px 20px', borderBottom: '1px solid #DDE3EB', fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.03em', textTransform: 'uppercase' }}>
              <div role="columnheader">Patient</div><div role="columnheader">MRN</div><div role="columnheader">Status</div><div role="columnheader">Primary condition</div><div role="columnheader">AI risk</div><div role="columnheader">Last visit</div>
            </div>
            {loading && (
              <div role="status" style={{ padding: '18px 20px', fontSize: 13.5, color: '#5B6B7F' }}><Busy label="Loading patients" fill={false} /></div>
            )}
            {error && (
              <div role="alert" style={{ padding: '18px 20px', fontSize: 13.5, color: '#B42318' }}>
                Could not load patients: {error}
              </div>
            )}
            {!loading && !error && visible.map((row) => (
              // Raw <button> (UA-reset with the shared `pressableReset`) so the row can carry
              // role="row" while staying a real, Enter/Space-activatable control.
              <button
                key={row.patientId}
                type="button"
                role="row"
                className="hover-bg-row"
                onClick={() => navigate(`/doctor/patients/${row.mrn}`)}
                style={{ ...pressableReset, display: 'grid', gridTemplateColumns: GRID_COLUMNS, padding: '14px 20px', borderBottom: '1px solid #EEF2F6', fontSize: 13.5, alignItems: 'center', cursor: 'pointer', width: '100%' }}
              >
                <div role="cell" style={{ fontWeight: 600 }}>{row.name}</div>
                <div role="cell" style={{ color: '#5B6B7F' }}>{row.mrn}</div>
                <div role="cell">{row.status}</div>
                <div role="cell" style={{ color: '#5B6B7F' }}>{row.condition}</div>
                <div role="cell">{row.riskLabel && row.riskStyle ? <span style={row.riskStyle}>{row.riskLabel}</span> : <span style={{ color: '#8A97A8' }}>â€”</span>}</div>
                <div role="cell" style={{ color: '#5B6B7F' }}>{visitStamp(row.lastVisitAt)}</div>
              </button>
            ))}
            {!loading && !error && visible.length === 0 && (
              <div role="row" style={{ padding: '14px 20px', fontSize: 13.5, color: '#5B6B7F' }}>
                <div role="cell" aria-colspan={6}>No patients match this search or filter.</div>
              </div>
            )}
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, color: '#5B6B7F' }}>
            <div aria-live="polite">
              Showing {visible.length} of {matches.length} patients
              {rows.length !== matches.length ? ` (${rows.length} total)` : ''}
            </div>
            <div style={{ display: 'flex', gap: 14 }}>
              <button
                type="button"
                aria-disabled={!hasPrev}
                title={hasPrev ? 'Previous page' : 'Already on the first page'}
                onClick={() => { if (hasPrev) setPage(currentPage - 1); }}
                style={{ ...pressableReset, cursor: 'pointer' }}
              >
                â† Prev
              </button>
              <button
                type="button"
                aria-disabled={!hasNext}
                title={hasNext ? 'Next page' : `All ${matches.length} matching records fit on this page.`}
                onClick={() => { if (hasNext) setPage(currentPage + 1); }}
                style={{ ...pressableReset, color: '#1D4ED8', fontWeight: 600, cursor: 'pointer' }}
              >
                Next â†’
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
