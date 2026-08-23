import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Pressable, TextField } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  appointmentTitle,
  getLatestRiskScores,
  getLabReviewQueue,
  getMyFullName,
  getPatientSummaries,
  todayAppointments,
  type PatientSummaryRow,
  type RiskScoreRow,
} from '../../lib/api';
import { pct, timeLabel } from '../../lib/format';

const initialsOf = (name: string | null): string =>
  (name ?? '')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]!.toUpperCase())
    .join('') || '—';

const flagColors = (severity: 'high' | 'medium'): { border: string; bg: string; dot: string; color: string; hover: string } =>
  severity === 'high'
    ? { border: '#F1D3D0', bg: '#FEF5F4', dot: '#B42318', color: '#B42318', hover: 'hover-red' }
    : { border: '#F3E3C2', bg: '#FEFAF0', dot: '#B54708', color: '#B54708', hover: 'hover-amber' };

export default function Dashboard() {
  const navigate = useNavigate();
  // Topbar search navigates on Enter — the one honest thing a searchable header can do.
  const [search, setSearch] = useState('');

  const { data, error, loading } = useAsync(async () => {
    const [summaries, risks, appointments, labs, fullName] = await Promise.all([
      getPatientSummaries(),
      getLatestRiskScores(),
      todayAppointments(),
      getLabReviewQueue(),
      getMyFullName(),
    ]);
    const byId = new Map<string, PatientSummaryRow>(summaries.map((s) => [s.patient_id, s]));
    const flags = risks
      .filter((r) => r.band === 'high' || r.band === 'critical')
      .filter((r) => byId.has(r.patient_id))
      .slice(0, 4)
      .map((r) => ({ risk: r, patient: byId.get(r.patient_id)! }));
    return {
      summaries,
      flags: flags as { risk: RiskScoreRow; patient: PatientSummaryRow }[],
      appointments,
      unreviewedLabs: labs.filter((l) => l.review_status === 'unreviewed'),
      abnormalLabs: labs.filter(
        (l) => l.review_status === 'unreviewed' && l.abnormal_flag !== 'normal',
      ),
      fullName,
    };
  }, []);

  const searchSubmit = () => {
    const needle = search.trim().toLowerCase();
    if (!needle || !data) return;
    const hit =
      data.summaries.find((s) => s.mrn.toLowerCase() === needle) ??
      data.summaries.find((s) => s.full_name.toLowerCase().includes(needle));
    if (hit) navigate(`/doctor/patients/${hit.mrn}`);
  };

  const inpatientCount = data?.summaries.filter((s) => s.is_inpatient).length ?? 0;
  const nextAppt = data?.appointments.find((a) => a.patient);

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="docDash" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>
            Good morning{data?.fullName ? `, ${data.fullName}` : ''}
          </h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <TextField
              value={search}
              onChange={setSearch}
              placeholder="Search patients, orders, notes…"
              ariaLabel="Search patients by name or MRN"
              onKeyDown={(event) => { if (event.key === 'Enter') void searchSubmit(); }}
              style={{ border: '1px solid #DDE3EB', borderRadius: 8, background: '#F4F6F9', padding: '8px 14px', fontSize: 13, color: '#5B6B7F', width: 260, boxSizing: 'content-box' }}
            />
            <Pressable onClick={() => navigate('/settings')} ariaLabel="Account settings" style={{ width: 32, height: 32, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}>
              {initialsOf(data?.fullName ?? null)}
            </Pressable>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 20, padding: '24px 28px', overflow: 'auto' }}>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 16px', fontSize: 13, color: '#B42318' }}>
              Could not load the dashboard: {error}
            </div>
          )}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 16 }}>
            <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/patients')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.summaries.length ?? 0} patients under care. Open the patients list`}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Patients under care</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : data?.summaries.length ?? '—'}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>{inpatientCount} inpatient · {(data?.summaries.length ?? 0) - inpatientCount} outpatient</div>
            </Pressable>
            <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/patients')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.flags.length ?? 0} high-risk AI flags. Open the patients list`}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>High-risk flags (AI)</div>
              <div style={{ fontSize: 26, fontWeight: 700, color: (data?.flags.length ?? 0) > 0 ? '#B42318' : undefined }}>{loading ? '…' : data?.flags.length ?? '—'}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>Latest scores banded high or critical</div>
            </Pressable>
            <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/schedule')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.appointments.length ?? 0} appointments today. Open the schedule`}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Appointments today</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : data?.appointments.length ?? '—'}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>
                {nextAppt ? `Next: ${timeLabel(nextAppt.scheduled_start)} · ${appointmentTitle(nextAppt).split(' — ')[0]}` : 'Nothing left today'}
              </div>
            </Pressable>
            <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/labs')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.unreviewedLabs.length ?? 0} labs awaiting review. Open the lab queue`}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Labs awaiting review</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : data?.unreviewedLabs.length ?? '—'}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>{data?.abnormalLabs.length ?? 0} abnormal</div>
            </Pressable>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 16, flex: 1 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>AI risk flags</h2>
                <Pressable onClick={() => navigate('/doctor/patients')} ariaLabel="View all patients" style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>View all</Pressable>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                {!loading && !error && (data?.flags.length ?? 0) === 0 && (
                  <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F', border: '1px dashed #C6CFDA', borderRadius: 10, padding: '14px 16px' }}>
                    No high or critical risk flags right now. Scores appear here once a prognosis run covers a patient on your care team.
                  </div>
                )}
                {data?.flags.map(({ risk, patient }) => {
                  const tone = flagColors(risk.band === 'critical' || risk.band === 'high' ? 'high' : 'medium');
                  return (
                    <Pressable key={risk.id} className={tone.hover} onClick={() => navigate(`/doctor/patients/${patient.mrn}`)} style={{ display: 'flex', alignItems: 'center', gap: 12, border: `1px solid ${tone.border}`, background: tone.bg, borderRadius: 10, padding: '12px 14px', cursor: 'pointer', width: '100%' }}>
                      <div style={{ width: 8, height: 8, borderRadius: '50%', background: tone.dot, flexShrink: 0 }} />
                      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
                        <div style={{ fontSize: 14, fontWeight: 600 }}>
                          {patient.full_name} · {patient.is_inpatient ? patient.current_room ?? 'Inpatient' : 'Outpatient'}
                        </div>
                        <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>
                          {risk.change_note
                            ? `${risk.change_note.charAt(0).toUpperCase()}${risk.change_note.slice(1)}`
                            : `${risk.risk_type.replace(/_/g, ' ')} score current as of latest run`}
                        </div>
                      </div>
                      <div style={{ fontSize: 12, fontWeight: 600, color: tone.color }}>
                        {pct(risk.probability)}
                        {risk.probability != null ? ' conf.' : ''}
                      </div>
                    </Pressable>
                  );
                })}
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 16, minWidth: 0 }}>
              <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12, flex: 1 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Today's schedule</h2>
                  <Pressable onClick={() => navigate('/doctor/schedule')} ariaLabel="Open today's schedule" style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>Open</Pressable>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 13.5 }}>
                  {!loading && !error && (data?.appointments.length ?? 0) === 0 && (
                    <div role="status" style={{ color: '#5B6B7F' }}>No appointments booked for today.</div>
                  )}
                  {data?.appointments.slice(0, 5).map((a) => (
                    <div key={a.id} style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
                      <div style={{ width: 64, color: '#5B6B7F' }}>{timeLabel(a.scheduled_start)}</div>
                      <div style={{ flex: 1, fontWeight: 500 }}>
                        {appointmentTitle(a)}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
              <Pressable onClick={() => navigate('/doctor/ai-assistant')} style={{ background: '#0F1C2E', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 10, color: '#fff', cursor: 'pointer', width: '100%' }}>
                <div style={{ fontSize: 13, fontWeight: 600, color: '#8FB0FF' }}>AI DAILY BRIEF</div>
                <div style={{ fontSize: 13.5, lineHeight: 1.6, color: '#C7D2E4' }}>
                  {data && data.flags.length > 0
                    ? `${data.flags.length} patient${data.flags.length > 1 ? 's' : ''} flagged before rounds: ${data.flags
                        .slice(0, 2)
                        .map((f) => f.patient.full_name)
                        .join(', ')}${data.flags.length > 2 ? '…' : ''}. ${data.abnormalLabs.length} abnormal labs await review.`
                    : 'No urgent flags this morning. Open a patient chart to request an AI prognosis report.'}
                </div>
                <div style={{ fontSize: 13, color: '#8FB0FF', fontWeight: 500 }}>Open AI assistant →</div>
              </Pressable>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
