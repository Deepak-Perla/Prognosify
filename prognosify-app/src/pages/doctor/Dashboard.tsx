import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Busy, Pressable, TextField } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  appointmentTitle,
  getCheckinQueue,
  getLabReviewQueue,
  getMyFullName,
  getPatientSummaries,
  todayAppointments,
  type PatientSummaryRow,
} from '../../lib/api';
import { timeLabel } from '../../lib/format';

const initialsOf = (name: string | null): string =>
  (name ?? '')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]!.toUpperCase())
    .join('') || '—';

export default function Dashboard() {
  const navigate = useNavigate();
  // Topbar search navigates on Enter — the one honest thing a searchable header can do.
  const [search, setSearch] = useState('');

  const { data, error, loading } = useAsync(async () => {
    const [summaries, appointments, labs, queue, fullName] = await Promise.all([
      getPatientSummaries(),
      todayAppointments(),
      getLabReviewQueue(),
      getCheckinQueue(),
      getMyFullName(),
    ]);
    const byId = new Map<string, PatientSummaryRow>(summaries.map((s) => [s.patient_id, s]));
    const unreviewed = labs.filter((l) => l.review_status === 'unreviewed');
    const abnormal = unreviewed.filter((l) => l.abnormal_flag !== 'normal');
    const waiting = queue
      .filter((q) => q.status === 'waiting')
      .sort((a, b) => (b.waiting_minutes ?? 0) - (a.waiting_minutes ?? 0));
    const nextAppt = appointments.find((a) => a.patient);
    return {
      summaries,
      byId,
      appointments,
      unreviewedCount: unreviewed.length,
      abnormal,
      waiting,
      waitingCount: waiting.length,
      avgWait:
        waiting.length > 0
          ? Math.round(waiting.reduce((s, w) => s + (w.waiting_minutes ?? 0), 0) / waiting.length)
          : null,
      nextAppt,
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
              placeholder="Search patients by name or MRN…"
              ariaLabel="Search patients by name or MRN"
              onKeyDown={(event) => { if (event.key === 'Enter') searchSubmit(); }}
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
          {loading && <Busy label="Loading your day…" fill={false} />}
          {!loading && !error && (
            <>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 16 }}>
                <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/patients')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.summaries.length ?? 0} patients under care. Open the patients list`}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Patients under care</div>
                  <div style={{ fontSize: 26, fontWeight: 700 }}>{data?.summaries.length ?? '—'}</div>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>{inpatientCount} inpatient · {(data?.summaries.length ?? 0) - inpatientCount} outpatient</div>
                </Pressable>
                <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/schedule')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.appointments.length ?? 0} appointments today. Open the schedule`}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Appointments today</div>
                  <div style={{ fontSize: 26, fontWeight: 700 }}>{data?.appointments.length ?? '—'}</div>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>
                    {data?.nextAppt ? `Next: ${timeLabel(data.nextAppt.scheduled_start)}` : 'Nothing left today'}
                  </div>
                </Pressable>
                <Pressable className="hover-border-accent" onClick={() => navigate('/reception/check-in')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.waitingCount ?? 0} patients waiting. Open the queue`}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Waiting now</div>
                  <div style={{ fontSize: 26, fontWeight: 700, color: (data?.avgWait ?? 0) >= 20 ? '#B54708' : undefined }}>{data?.waitingCount ?? '—'}</div>
                  <div style={{ fontSize: 12, color: data?.avgWait != null && data.avgWait >= 20 ? '#B54708' : '#5B6B7F' }}>
                    {data?.avgWait != null ? `Avg wait ${data.avgWait} min` : 'No one queued'}
                  </div>
                </Pressable>
                <Pressable className="hover-border-accent" onClick={() => navigate('/doctor/labs')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', width: '100%' }} ariaLabel={`${data?.unreviewedCount ?? 0} labs awaiting review. Open the lab queue`}>
                  <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Labs awaiting review</div>
                  <div style={{ fontSize: 26, fontWeight: 700, color: (data?.abnormal.length ?? 0) > 0 ? '#B54708' : undefined }}>{data?.unreviewedCount ?? '—'}</div>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>{data?.abnormal.length ?? 0} abnormal</div>
                </Pressable>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 16, flex: 1 }}>
                <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 14 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Needs attention</h2>
                    <Pressable onClick={() => navigate('/doctor/labs')} ariaLabel="Open the lab queue" style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>All labs</Pressable>
                  </div>
                  <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
                    {(data?.abnormal.length ?? 0) === 0 && (data?.waiting.length ?? 0) === 0 && (
                      <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F', border: '1px dashed #C6CFDA', borderRadius: 10, padding: '14px 16px', lineHeight: 1.6 }}>
                        Nothing needs attention right now — no abnormal results and no long waits.
                      </div>
                    )}
                    {data?.abnormal.slice(0, 3).map((l) => {
                      const patient = data.byId.get(l.patient_id);
                      return (
                        <Pressable key={l.lab_result_id} className="hover-red" onClick={() => patient && navigate(`/doctor/patients/${patient.mrn}`)} style={{ display: 'flex', alignItems: 'center', gap: 12, border: '1px solid #F1D3D0', background: '#FEF5F4', borderRadius: 10, padding: '12px 14px', cursor: 'pointer', width: '100%' }}>
                          <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#B42318', flexShrink: 0 }} />
                          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
                            <div style={{ fontSize: 14, fontWeight: 600 }}>{l.patient_name} — {l.test_name}</div>
                            <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>
                              {l.value_numeric != null ? `${l.value_numeric} ${l.unit ?? ''}`.trim() : l.value_text}
                              {l.reference_range ? ` · range ${l.reference_range}` : ''} · awaiting review
                            </div>
                          </div>
                          <div style={{ fontSize: 12, fontWeight: 600, color: l.abnormal_flag.includes('critical') ? '#B42318' : '#B54708' }}>
                            {l.abnormal_flag.includes('critical') ? 'Critical' : 'Abnormal'}
                          </div>
                        </Pressable>
                      );
                    })}
                    {data?.waiting.slice(0, 3).filter((w) => (w.waiting_minutes ?? 0) >= 15).map((w) => (
                      <Pressable key={w.appointment_id} className="hover-amber" onClick={() => navigate('/reception/check-in')} style={{ display: 'flex', alignItems: 'center', gap: 12, border: '1px solid #F3E3C2', background: '#FEFAF0', borderRadius: 10, padding: '12px 14px', cursor: 'pointer', width: '100%' }}>
                        <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#B54708', flexShrink: 0 }} />
                        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2 }}>
                          <div style={{ fontSize: 14, fontWeight: 600 }}>{w.patient_name} waiting {w.waiting_minutes} min</div>
                          <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>
                            {[w.provider_name, w.department_name].filter(Boolean).join(' · ') || 'Triage pending'}
                          </div>
                        </div>
                        <div style={{ fontSize: 12, fontWeight: 600, color: '#B54708' }}>Queue</div>
                      </Pressable>
                    ))}
                  </div>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 16, minWidth: 0 }}>
                  <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12, flex: 1 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Today's schedule</h2>
                      <Pressable onClick={() => navigate('/doctor/schedule')} ariaLabel="Open today's schedule" style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>Open</Pressable>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 13.5 }}>
                      {(data?.appointments.length ?? 0) === 0 && (
                        <div role="status" style={{ color: '#5B6B7F' }}>No appointments booked for today.</div>
                      )}
                      {data?.appointments.slice(0, 5).map((a) => (
                        <div key={a.id} style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
                          <div style={{ width: 64, color: '#5B6B7F' }}>{timeLabel(a.scheduled_start)}</div>
                          <div style={{ flex: 1, fontWeight: 500 }}>{appointmentTitle(a)}</div>
                        </div>
                      ))}
                    </div>
                  </div>
                  <Pressable onClick={() => navigate('/doctor/labs')} className="on-dark" style={{ background: '#0F1C2E', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 10, color: '#fff', cursor: 'pointer', width: '100%' }}>
                    <div style={{ fontSize: 13, fontWeight: 600, color: '#8FB0FF' }}>TODAY AT A GLANCE</div>
                    <div style={{ fontSize: 13.5, lineHeight: 1.6, color: '#C7D2E4' }}>
                      {data && data.abnormal.length > 0
                        ? `${data.appointments.length} appointments today, ${data.waitingCount} waiting now. ${data.abnormal.length} abnormal result${data.abnormal.length > 1 ? 's' : ''} need${data.abnormal.length > 1 ? '' : 's'} your review — ${data.abnormal[0].patient_name}'s ${data.abnormal[0].test_name} first.`
                        : `${data?.appointments.length ?? 0} appointments today, ${data?.waitingCount ?? 0} waiting now. No abnormal results await review.`}
                    </div>
                    <div style={{ fontSize: 13, color: '#8FB0FF', fontWeight: 500 }}>Review the lab queue →</div>
                  </Pressable>
                </div>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
