import { useState, type CSSProperties } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { ArrowLeft } from 'lucide-react';
import SideNav from '../../components/SideNav';
import { Busy, Pressable, TextArea } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import { useAuth } from '../../lib/auth';
import {
  addClinicalNote,
  getLabPanels,
  getPatientChart,
  getPatientSummaryByMrn,
  orderLab,
  RISK_TYPE_LABEL,
  type LabQueueRow,
  type RiskScoreRow,
} from '../../lib/api';
import { ageSex, horizonLabel, pct, stampWithTime, timeLabel, visitStamp } from '../../lib/format';

/**
 * Chart writes go straight to Supabase under the signed-in doctor's seat: notes are inserted
 * signed (clinical_note policy pins author = caller), lab orders carry their ordering member,
 * and Row Level Security limits both to patients on the care team.
 */
const priorities = ['routine', 'urgent', 'stat'] as const;

const headerButton: CSSProperties = { border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 500, cursor: 'pointer' };

const resultText = (r: Pick<LabQueueRow, 'value_numeric' | 'value_text' | 'unit'>): string => {
  if (r.value_numeric != null) return `${r.value_numeric} ${r.unit ?? ''}`.trim();
  return r.value_text ?? 'â€”';
};

/** Trend vs the same test's previous occurrence in the fetched window. */
function trendFor(labs: LabQueueRow[], index: number): { text: string; color: string } | null {
  const current = labs[index];
  const previous = labs
    .slice(index + 1)
    .find((l) => l.test_name === current.test_name && l.value_numeric != null);
  if (current.value_numeric == null || !previous || previous.value_numeric == null) return null;
  const delta = current.value_numeric - previous.value_numeric;
  const eps = Math.abs(current.value_numeric) * 0.05;
  if (Math.abs(delta) <= eps) return { text: 'â†’ stable', color: '#5B6B7F' };
  return delta > 0
    ? { text: 'â†‘ rising', color: current.abnormal_flag.includes('critical') || current.abnormal_flag === 'high' ? '#B42318' : '#B54708' }
    : { text: 'â†“ falling', color: '#116B3F' };
}

export default function PatientDetail() {
  const navigate = useNavigate();
  const mrn = useParams<{ mrn: string }>().mrn ?? '';
  const { membership } = useAuth();

  const [noteOpen, setNoteOpen] = useState(false);
  const [noteBody, setNoteBody] = useState('');
  const [noteBusy, setNoteBusy] = useState(false);
  const [noteError, setNoteError] = useState<string | null>(null);

  const [ordering, setOrdering] = useState(false);
  const [panelId, setPanelId] = useState('');
  const [priority, setPriority] = useState<(typeof priorities)[number]>('routine');
  const [orderBusy, setOrderBusy] = useState(false);
  const [orderError, setOrderError] = useState<string | null>(null);
  const [orderDone, setOrderDone] = useState(false);

  const panelsState = useAsync(() => getLabPanels(), []);

  const { data, error, loading, reload } = useAsync(async () => {
    const summary = await getPatientSummaryByMrn(mrn);
    if (!summary) return null;
    const chart = await getPatientChart(summary.patient_id);
    return { summary, chart };
  }, [mrn]);

  const saveNote = async () => {
    if (!membership || !data || !noteBody.trim()) return;
    setNoteBusy(true);
    setNoteError(null);
    try {
      await addClinicalNote({
        organizationId: membership.organizationId,
        patientId: data.summary.patient_id,
        authorMemberId: membership.memberId,
        body: noteBody,
      });
      setNoteBody('');
      setNoteOpen(false);
      reload();
    } catch (err) {
      setNoteError(err instanceof Error ? err.message : 'Could not save the note.');
    } finally {
      setNoteBusy(false);
    }
  };

  const submitOrder = async () => {
    if (!membership || !data || !panelId) return;
    setOrderBusy(true);
    setOrderError(null);
    try {
      await orderLab({
        organizationId: membership.organizationId,
        patientId: data.summary.patient_id,
        panelId,
        orderedByMemberId: membership.memberId,
        priority,
      });
      setOrdering(false);
      setPanelId('');
      setOrderDone(true);
      window.setTimeout(() => setOrderDone(false), 4000);
      reload();
    } catch (err) {
      setOrderError(err instanceof Error ? err.message : 'Could not place the order.');
    } finally {
      setOrderBusy(false);
    }
  };

  if (loading) {
    return (
      <div style={{ width: '100%', height: '100%', display: 'flex' }}>
        <SideNav role="doctor" active="patients" />
        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }} role="status">
          <Busy label="Loading chartâ€¦" />
        </div>
      </div>
    );
  }

  if (error || !data) {
    return (
      <div style={{ width: '100%', height: '100%', display: 'flex' }}>
        <SideNav role="doctor" active="patients" />
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 12 }}>
          <div role="alert" style={{ fontSize: 14, color: '#B42318' }}>{error ?? `No patient with MRN ${mrn} is visible to you.`}</div>
          <Pressable onClick={() => navigate('/doctor/patients')} style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 600 }}>â† All patients</Pressable>
        </div>
      </div>
    );
  }

  const { summary, chart } = data;
  const initials = summary.full_name.split(/\s+/).slice(0, 2).map((p) => p[0]?.toUpperCase()).join('');
  const leadScore = chart.riskScores.find((s) => s.value_kind === 'probability') ?? chart.riskScores[0] ?? null;
  const allergyLine = chart.allergies.length > 0 ? ` Â· Allergies: ${chart.allergies.map((a) => a.substance).join(', ')}` : '';

  // Vitals cards follow the mock's colour language: red when clearly abnormal, amber borderline.
  const hr = chart.vitals?.heart_rate_bpm ?? null;
  const temp = chart.vitals?.temperature_c != null ? Number(chart.vitals.temperature_c) : null;
  const spo2 = chart.vitals?.spo2_percent ?? null;
  const bp =
    chart.vitals && (chart.vitals.systolic_mmhg != null || chart.vitals.diastolic_mmhg != null)
      ? `${chart.vitals.systolic_mmhg ?? '?'}/${chart.vitals.diastolic_mmhg ?? '?'}`
      : null;

  const vitals: [string, string, string | undefined][] = [
    ['Heart rate', hr != null ? String(hr) : 'â€”', hr != null && hr > 100 ? '#B42318' : undefined],
    ['BP', bp ?? 'â€”', undefined],
    ['Temp', temp != null ? `${temp.toFixed(1)}Â°C` : 'â€”', temp != null && temp >= 38 ? '#B54708' : undefined],
    ['SpOâ‚‚', spo2 != null ? `${spo2}%` : 'â€”', spo2 != null && spo2 < 94 ? '#B54708' : undefined],
  ];

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="patients" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ background: '#ffffff', borderBottom: '1px solid #DDE3EB', padding: '16px 28px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <Pressable onClick={() => navigate('/doctor/patients')} ariaLabel="Back to patients" style={{ fontSize: 13, color: '#5B6B7F', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 4 }}>
              <ArrowLeft size={14} /> Patients
            </Pressable>
            <div style={{ width: 44, height: 44, borderRadius: '50%', background: '#0F1C2E', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 15, fontWeight: 600 }}>{initials}</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <h1 style={{ fontSize: 18, fontWeight: 700, margin: 0 }}>{summary.full_name}</h1>
                {leadScore && (
                  <span style={{ background: leadScore.band === 'high' || leadScore.band === 'critical' ? '#FEF5F4' : leadScore.band === 'medium' ? '#FEFAF0' : '#F0F7F2', color: leadScore.band === 'high' || leadScore.band === 'critical' ? '#B42318' : leadScore.band === 'medium' ? '#B54708' : '#116B3F', border: '1px solid #E5E9F0', borderRadius: 12, padding: '3px 10px', fontSize: 12, fontWeight: 600 }}>
                    {(leadScore.band === 'high' || leadScore.band === 'critical' ? 'High' : leadScore.band)} risk Â· {leadScore.probability != null ? pct(leadScore.probability) : leadScore.band}
                  </span>
                )}
              </div>
              <div style={{ fontSize: 13, color: '#5B6B7F' }}>
                {[
                  ageSex(summary.age_years, summary.sex),
                  `MRN ${summary.mrn}`,
                  summary.current_room ? `Rm ${summary.current_room.replace(/^Rm\s*/i, '')}` : summary.is_inpatient ? 'Inpatient' : 'Outpatient',
                  summary.admitted_at ? `Admitted ${visitStamp(summary.admitted_at)}` : null,
                  summary.primary_condition,
                  allergyLine,
                ]
                  .filter(Boolean)
                  .join(' Â· ')}
              </div>
            </div>
          </div>
          <div style={{ display: 'flex', gap: 10 }}>
            <Pressable
              onClick={() => { setNoteOpen((v) => !v); setOrdering(false); }}
              ariaExpanded={noteOpen}
              style={headerButton}
            >
              {noteOpen ? 'Close note' : 'Add note'}
            </Pressable>
            <Pressable
              onClick={() => { setOrdering((v) => !v); setNoteOpen(false); }}
              ariaExpanded={ordering}
              style={headerButton}
            >
              {ordering ? 'Close order' : 'Order labs'}
            </Pressable>
            <Pressable onClick={() => navigate(`/doctor/patients/${summary.mrn}/prognosis`)} style={{ background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>AI prognosis report</Pressable>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', gap: 16, padding: '24px 28px', overflow: 'auto' }}>
          <div style={{ flex: 1.5, display: 'flex', flexDirection: 'column', gap: 16, minWidth: 0 }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 12 }}>
              {vitals.map(([label, value, color]) => (
                <div key={label} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 10, padding: 14, display: 'flex', flexDirection: 'column', gap: 4 }}>
                  <div style={{ fontSize: 12, color: '#5B6B7F' }}>{label}</div>
                  <div style={{ fontSize: 20, fontWeight: 700, color: color || '#0F1C2E' }}>{value}</div>
                </div>
              ))}
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Recent labs</h2>
                <Pressable onClick={() => navigate('/doctor/labs')} style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>All labs</Pressable>
              </div>
              {ordering && (
                <div role="group" aria-label="Order a lab panel" style={{ border: '1px solid #C9D8FA', background: '#F8FAFF', borderRadius: 10, padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {orderError && (
                    <div role="alert" style={{ fontSize: 12.5, color: '#B42318' }}>{orderError}</div>
                  )}
                  <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
                    <select
                      aria-label="Lab panel"
                      value={panelId}
                      onChange={(e) => setPanelId(e.target.value)}
                      disabled={panelsState.loading}
                      style={{ flex: 1, minWidth: 200, border: '1px solid #DDE3EB', borderRadius: 8, padding: '9px 12px', fontSize: 13.5, background: '#fff', color: '#0F1C2E' }}
                    >
                      <option value="">{panelsState.loading ? 'Loading panelsâ€¦' : 'Choose a panelâ€¦'}</option>
                      {(panelsState.data ?? []).map((p) => (
                        <option key={p.id} value={p.id}>{p.name}</option>
                      ))}
                    </select>
                    <div role="radiogroup" aria-label="Priority" style={{ display: 'flex', gap: 6 }}>
                      {priorities.map((p) => (
                        <Pressable
                          key={p}
                          onClick={() => setPriority(p)}
                          ariaPressed={priority === p}
                          title={`Priority: ${p}`}
                          style={{
                            border: priority === p ? '1px solid #1D4ED8' : '1px solid #DDE3EB',
                            background: priority === p ? '#EDF2FE' : '#fff',
                            color: priority === p ? '#1D4ED8' : '#5B6B7F',
                            borderRadius: 8,
                            padding: '8px 12px',
                            fontSize: 12.5,
                            fontWeight: priority === p ? 600 : 500,
                            textTransform: 'capitalize',
                            cursor: 'pointer',
                          }}
                        >
                          {p}
                        </Pressable>
                      ))}
                    </div>
                    <Pressable
                      onClick={() => void submitOrder()}
                      disabled={!panelId || orderBusy}
                      style={{
                        background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '9px 16px',
                        fontSize: 13, fontWeight: 600, cursor: !panelId || orderBusy ? 'default' : 'pointer',
                        opacity: !panelId || orderBusy ? 0.55 : 1,
                      }}
                    >
                      {orderBusy ? 'Orderingâ€¦' : 'Place order'}
                    </Pressable>
                  </div>
                </div>
              )}
              {orderDone && (
                <div role="status" style={{ fontSize: 12.5, color: '#116B3F' }}>
                  Order placed â€” it is now in the labs queue.
                </div>
              )}
              {chart.recentLabs.length === 0 ? (
                <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F' }}>No lab results on file for this patient.</div>
              ) : (
                <>
                  <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr 1fr', fontSize: 12, fontWeight: 600, color: '#5B6B7F', textTransform: 'uppercase', letterSpacing: '0.03em', paddingBottom: 8, borderBottom: '1px solid #EEF2F6' }}>
                    <div>Test</div><div>Result</div><div>Range</div><div>Trend</div>
                  </div>
                  {chart.recentLabs.map((l, i) => {
                    const trend = trendFor(chart.recentLabs, i);
                    const flagged = l.abnormal_flag !== 'normal';
                    return (
                      <div key={l.lab_result_id} style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr 1fr 1fr', fontSize: 13.5, alignItems: 'center' }}>
                        <div style={{ fontWeight: 500 }}>{l.panel_name}</div>
                        <div style={{ color: flagged ? (l.abnormal_flag.includes('critical') ? '#B42318' : '#B54708') : '#0F1C2E', fontWeight: 600 }}>
                          {resultText(l)}
                        </div>
                        <div style={{ color: '#5B6B7F' }}>{l.reference_range || 'â€”'}</div>
                        <div style={{ color: trend?.color ?? '#5B6B7F' }}>{trend?.text ?? 'â€”'}</div>
                      </div>
                    );
                  })}
                </>
              )}
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12 }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Timeline</h2>
              {noteOpen && (
                <div role="group" aria-label="Add a progress note" style={{ border: '1px solid #C9D8FA', background: '#F8FAFF', borderRadius: 10, padding: 14, display: 'flex', flexDirection: 'column', gap: 10 }}>
                  {noteError && (
                    <div role="alert" style={{ fontSize: 12.5, color: '#B42318' }}>{noteError}</div>
                  )}
                  <TextArea
                    ariaLabel="Progress note"
                    value={noteBody}
                    onChange={setNoteBody}
                    placeholder="Progress note â€” saved signed and attributed to youâ€¦"
                    rows={3}
                    style={{ border: '1px solid #DDE3EB', borderRadius: 8, background: '#fff', padding: '10px 12px', fontSize: 13.5, color: '#0F1C2E', minHeight: 72 }}
                  />
                  <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8 }}>
                    <Pressable
                      onClick={() => { setNoteOpen(false); setNoteBody(''); setNoteError(null); }}
                      style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '8px 14px', fontSize: 13, cursor: 'pointer' }}
                    >
                      Cancel
                    </Pressable>
                    <Pressable
                      onClick={() => void saveNote()}
                      disabled={!noteBody.trim() || noteBusy}
                      style={{
                        background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '8px 16px',
                        fontSize: 13, fontWeight: 600,
                        cursor: !noteBody.trim() || noteBusy ? 'default' : 'pointer',
                        opacity: !noteBody.trim() || noteBusy ? 0.55 : 1,
                      }}
                    >
                      {noteBusy ? 'Savingâ€¦' : 'Sign & save'}
                    </Pressable>
                  </div>
                </div>
              )}
              {chart.timeline.length === 0 ? (
                <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F' }}>No recorded events yet.</div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 13.5 }}>
                  {chart.timeline.map((entry) => (
                    <div key={`${entry.source_table}-${entry.source_id}`} style={{ display: 'flex', gap: 12 }}>
                      <div style={{ width: 110, color: '#5B6B7F', flexShrink: 0 }}>{stampWithTime(entry.occurred_at)}</div>
                      <div>{entry.summary}</div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
          <div style={{ width: 360, flexShrink: 0, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div className="on-dark" style={{ background: '#0F1C2E', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 14, color: '#fff' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 style={{ fontSize: 13, fontWeight: 600, color: '#8FB0FF', margin: 0 }}>AI PROGNOSIS</h2>
                {chart.run && <div style={{ fontSize: 11, color: '#5B6B7F' }}>Updated {timeLabel(chart.run.created_at)}</div>}
              </div>
              {chart.riskScores.filter((s) => s.value_kind === 'probability').length === 0 ? (
                <div role="status" style={{ fontSize: 13, lineHeight: 1.6, color: '#C7D2E4' }}>
                  No AI risk scores yet for this patient. Open the prognosis report to request a run once the model service is connected.
                </div>
              ) : (
                chart.riskScores
                  .filter((s) => s.value_kind === 'probability')
                  .map((s: RiskScoreRow) => {
                    const value = pct(s.probability);
                    const tone = s.band === 'high' || s.band === 'critical' ? '#FF8A7A' : s.band === 'medium' ? '#FFC66B' : '#8FD6AC';
                    return (
                      <div key={s.id} style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13 }}>
                          <div style={{ color: '#C7D2E4' }}>
                            {RISK_TYPE_LABEL[s.risk_type]}{s.horizon ? ` (${horizonLabel(s.horizon)})` : ''}
                          </div>
                          <div style={{ fontWeight: 700, color: tone }}>{s.band === 'critical' || s.band === 'high' ? 'High' : s.band === 'medium' ? 'Medium' : 'Low'} Â· {value}</div>
                        </div>
                        <div aria-hidden="true" style={{ height: 6, borderRadius: 3, background: '#22344E' }}>
                          <div style={{ width: `${Math.round((s.probability ?? 0) * 100)}%`, height: 6, borderRadius: 3, background: tone }} />
                        </div>
                      </div>
                    );
                  })
              )}
              {chart.factors.length > 0 && (
                <div style={{ fontSize: 13, lineHeight: 1.6, color: '#C7D2E4' }}>
                  Key drivers: {chart.factors.slice(0, 3).map((f) => f.label).join(', ')}. Recommend reviewing these alongside the full report before rounds.
                </div>
              )}
              <Pressable onClick={() => navigate(`/doctor/patients/${summary.mrn}/prognosis`)} style={{ background: '#1D4ED8', borderRadius: 8, padding: '10px 0', textAlign: 'center', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>Open full report</Pressable>
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Medications</h2>
              {chart.medications.length === 0 ? (
                <div style={{ fontSize: 13.5, color: '#5B6B7F' }}>No active medications.</div>
              ) : (
                <div style={{ fontSize: 13.5, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  {chart.medications.slice(0, 5).map((m) => (
                    <div key={m.id} style={{ display: 'flex', justifyContent: 'space-between' }}>
                      <div>{m.drug_name} {m.dose_text}</div>
                      <div style={{ color: '#5B6B7F' }}>{m.frequency_text}{m.status !== 'active' ? ` Â· ${m.status}` : ''}</div>
                    </div>
                  ))}
                </div>
              )}
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Care team</h2>
              {chart.careTeam.length === 0 ? (
                <div style={{ fontSize: 13.5, color: '#5B6B7F' }}>No open care-team assignments.</div>
              ) : (
                <div style={{ fontSize: 13.5, display: 'flex', flexDirection: 'column', gap: 8 }}>
                  {chart.careTeam.slice(0, 5).map((c) => (
                    <div key={c.id} style={{ display: 'flex', justifyContent: 'space-between' }}>
                      <div>{c.member?.app_user?.full_name ?? 'Unknown member'}</div>
                      <div style={{ color: '#5B6B7F' }}>
                        {(c.role.charAt(0).toUpperCase() + c.role.slice(1)).replace('_', ' ')}
                        {c.assignment_note ? ` Â· ${c.assignment_note}` : ''}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
