import { useEffect, useMemo, useState, type CSSProperties } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Pressable, SegmentedControl, TextField } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  createAppointment,
  getAppointmentsBetween,
  getBookingProviders,
  getVisitTypes,
  searchFrontDeskPatients,
  type FrontDeskPatient,
} from '../../lib/api';
import { dayBounds, dayLabel, shortDate } from '../../lib/format';

/** The slot grid: the next five working days × five fixed clinic times (clinic wall clock). */
const SLOT_TIMES = [
  { label: '9:00', hour: 9 },
  { label: '10:15', hour: 10.25 },
  { label: '11:30', hour: 11.5 },
  { label: '2:00', hour: 14 },
  { label: '4:15', hour: 16.25 },
] as const;

const DURATIONS = ['15 min', '30 min', '45 min'] as const;
const durationMinutes = (label: string): number => parseInt(label, 10);
const nearestDuration = (minutes: number): string =>
  DURATIONS.reduce(
    (best, d) => (Math.abs(durationMinutes(d) - minutes) < Math.abs(durationMinutes(best) - minutes) ? d : best),
    DURATIONS[0],
  );

/** UA neutraliser for a real <select>: no appearance, no chrome, inherits the spec's type. */
const selectReset: CSSProperties = {
  appearance: 'none',
  WebkitAppearance: 'none',
  fontFamily: 'inherit',
  fontSize: 'inherit',
  fontWeight: 'inherit',
  fontStyle: 'inherit',
  lineHeight: 'inherit',
  letterSpacing: 'inherit',
  textAlign: 'inherit',
  color: 'inherit',
  background: 'none',
  border: 0,
  borderRadius: 0,
  padding: 0,
  margin: 0,
  height: 'auto',
  maxWidth: '100%',
  cursor: 'pointer',
};

const fieldBox: CSSProperties = { border: '1px solid #DDE3EB', borderRadius: 8, padding: '10px 13px', fontSize: 14 };
const fieldLabel: CSSProperties = { fontSize: 13, fontWeight: 500 };

interface SlotRef {
  dayIndex: number;
  timeIndex: number;
}

/** A clinic-day key ("2026-08-18") for today + offsets; Sunday rolls to Monday. */
function gridDay(offsetFromToday: number): string {
  const nowIst = new Date(new Date().getTime() + 5.5 * 3600000);
  const d = new Date(Date.UTC(nowIst.getUTCFullYear(), nowIst.getUTCMonth(), nowIst.getUTCDate() + offsetFromToday));
  if (d.getUTCDay() === 0) d.setUTCDate(d.getUTCDate() + 1);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
}

/** UTC instant for a clinic-wall-clock time on `key` (IST is a fixed +05:30). */
const slotInstant = (key: string, hour: number): number => {
  const hh = String(Math.floor(hour)).padStart(2, '0');
  const mm = String(Math.round((hour % 1) * 60)).padStart(2, '0');
  return new Date(`${key}T${hh}:${mm}:00+05:30`).getTime();
};

export default function Booking() {
  const navigate = useNavigate();

  const [patientQuery, setPatientQuery] = useState('');
  const [patientMatches, setPatientMatches] = useState<FrontDeskPatient[]>([]);
  const [patient, setPatient] = useState<FrontDeskPatient | null>(null);

  const providersState = useAsync(() => getBookingProviders(), []);
  const visitTypesState = useAsync(() => getVisitTypes(), []);

  const [providerId, setProviderId] = useState('');
  const [visitTypeId, setVisitTypeId] = useState('');
  const [duration, setDuration] = useState<string>(nearestDuration(30));
  const [slot, setSlot] = useState<SlotRef | null>(null);

  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [booked, setBooked] = useState(false);

  // Live patient search as the desk types.
  useEffect(() => {
    let cancelled = false;
    const needle = patientQuery.trim();
    if (!needle) {
      setPatientMatches([]);
      return;
    }
    const timer = window.setTimeout(() => {
      searchFrontDeskPatients(needle)
        .then((rows) => !cancelled && setPatientMatches(rows))
        .catch(() => !cancelled && setPatientMatches([]));
    }, 250);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [patientQuery]);

  const provider = providersState.data?.find((p) => p.member_id === providerId) ?? null;

  // Defaults once the catalogues arrive.
  useEffect(() => {
    if (!providerId && providersState.data && providersState.data.length > 0) {
      setProviderId(providersState.data[0].member_id);
    }
  }, [providersState.data, providerId]);
  useEffect(() => {
    if (!visitTypeId && visitTypesState.data && visitTypesState.data.length > 0) {
      onVisitTypeChange(visitTypesState.data[0]);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- runs once when visit types load
  }, [visitTypesState.data]);

  const onVisitTypeChange = (idOrType: string | { id: string; default_duration_minutes: number }) => {
    const id = typeof idOrType === 'string' ? idOrType : idOrType.id;
    const vt =
      typeof idOrType === 'string'
        ? visitTypesState.data?.find((v) => v.id === id)
        : idOrType;
    setVisitTypeId(id);
    if (vt) setDuration(nearestDuration(vt.default_duration_minutes || 30));
    setSlot(null);
  };

  const weekDays = useMemo(() => [0, 1, 2, 3, 4].map(gridDay), []);
  const gridKey = weekDays[0];

  // Existing bookings for the chosen provider. Nine days from today covers the whole grid even
  // when a Sunday rolls a column into next week.
  const existingState = useAsync(async () => {
    if (!providerId) return [];
    const startISO = dayBounds(gridKey).startISO;
    const endISO = new Date(new Date(dayBounds(gridKey).endISO).getTime() + 8 * 86400000).toISOString();
    const rows = await getAppointmentsBetween(startISO, endISO);
    return rows.filter((a) => a.provider_member_id === providerId && a.status !== 'cancelled');
  }, [gridKey, providerId]);

  const isTaken = (dayIdx: number, timeIdx: number): boolean => {
    const start = slotInstant(weekDays[dayIdx], SLOT_TIMES[timeIdx].hour);
    const end = start + durationMinutes(duration) * 60000;
    return (existingState.data ?? []).some((a) => {
      const aStart = new Date(a.scheduled_start).getTime();
      const aEnd = new Date(a.scheduled_end).getTime();
      return start < aEnd && end > aStart;
    });
  };

  const selectedSummary = slot
    ? `${shortDate(new Date(slotInstant(weekDays[slot.dayIndex], SLOT_TIMES[slot.timeIndex].hour)).toISOString())} · ${SLOT_TIMES[slot.timeIndex].label}`
    : null;

  const confirm = async () => {
    if (!slot || !patient || !provider || !visitTypeId) return;
    setSaving(true);
    setSaveError(null);
    try {
      const startMs = slotInstant(weekDays[slot.dayIndex], SLOT_TIMES[slot.timeIndex].hour);
      await createAppointment({
        patientId: patient.patient_id,
        providerMemberId: provider.member_id,
        visitTypeId,
        startISO: new Date(startMs).toISOString(),
        endISO: new Date(startMs + durationMinutes(duration) * 60000).toISOString(),
        roomLabel: provider.default_room,
        modality: 'in_person',
      });
      setBooked(true);
      setTimeout(() => navigate('/reception/dashboard'), 900);
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : 'Could not save the booking.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="reception" active="booking" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Book appointment</h1>
        </div>
        <div style={{ flex: 1, display: 'flex', gap: 16, padding: '24px 28px', overflow: 'auto' }}>
          <div style={{ width: 400, flexShrink: 0, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6, position: 'relative' }}>
              <label htmlFor="booking-patient" style={fieldLabel}>Patient</label>
              <div style={{ ...fieldBox, display: 'flex', justifyContent: 'space-between' }}>
                <TextField
                  id="booking-patient"
                  ariaLabel="Search for a patient by name or MRN"
                  value={patient ? `${patient.first_name} ${patient.last_name} · MRN ${patient.mrn}` : patientQuery}
                  onChange={(value) => {
                    setPatient(null);
                    setSlot(null);
                    setPatientQuery(value);
                  }}
                  placeholder="Type a name or MRN…"
                  placeholderColor="#8A97A8"
                  style={{ flex: 1 }}
                />
                {(patient || patientQuery) && (
                  <Pressable onClick={() => { setPatient(null); setPatientQuery(''); }} ariaLabel="Clear the selected patient" style={{ color: '#5B6B7F', cursor: 'pointer' }}>✕</Pressable>
                )}
              </div>
              {patientMatches.length > 0 && (
                <div role="listbox" aria-label="Patient matches" style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 8, boxShadow: '0 8px 24px rgba(15,28,46,0.12)', overflow: 'hidden' }}>
                  {patientMatches.map((p) => (
                    <Pressable
                      key={p.patient_id}
                      onClick={() => {
                        setPatient(p);
                        setPatientQuery('');
                        setPatientMatches([]);
                        setSlot(null);
                      }}
                      ariaLabel={`Select ${p.first_name} ${p.last_name}`}
                      style={{ padding: '10px 14px', fontSize: 13, borderTop: '1px solid #EEF2F6', cursor: 'pointer' }}
                    >
                      <span style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</span>
                      <span style={{ color: '#5B6B7F' }}> · MRN {p.mrn}</span>
                    </Pressable>
                  ))}
                </div>
              )}
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <label htmlFor="booking-visit-type" style={fieldLabel}>Visit type</label>
              <div style={{ ...fieldBox, display: 'flex', justifyContent: 'space-between' }}>
                <select id="booking-visit-type" value={visitTypeId} onChange={(e) => onVisitTypeChange(e.target.value)} style={selectReset}>
                  {(visitTypesState.data ?? []).map((v) => (
                    <option key={v.id} value={v.id}>{v.name}</option>
                  ))}
                </select>
                <span aria-hidden="true" style={{ color: '#5B6B7F' }}>▾</span>
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <label htmlFor="booking-provider" style={fieldLabel}>Provider</label>
              <div style={{ ...fieldBox, display: 'flex', justifyContent: 'space-between' }}>
                <select id="booking-provider" value={providerId} onChange={(e) => { setProviderId(e.target.value); setSlot(null); }} style={selectReset}>
                  {(providersState.data ?? []).map((p) => (
                    <option key={p.member_id} value={p.member_id}>
                      {[p.full_name, p.department_name ?? p.specialty].filter(Boolean).join(' · ')}
                    </option>
                  ))}
                </select>
                <span aria-hidden="true" style={{ color: '#5B6B7F' }}>▾</span>
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={fieldLabel}>Duration</div>
              <SegmentedControl
                options={DURATIONS}
                value={duration}
                onChange={(d) => { setDuration(d); setSlot(null); }}
                ariaLabel="Duration"
                style={{ display: 'flex', gap: 8 }}
                itemStyle={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '8px 14px', fontSize: 13, color: '#5B6B7F', cursor: 'pointer' }}
                selectedItemStyle={{ border: '1px solid #1D4ED8', background: '#EDF2FE', color: '#1D4ED8', fontWeight: 600 }}
              />
            </div>
            {saveError && (
              <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 14px', fontSize: 12.5, color: '#B42318', lineHeight: 1.6 }}>
                {saveError}
              </div>
            )}
            {booked && (
              <div role="status" style={{ background: '#F0F7F2', border: '1px solid #CFE6D8', borderRadius: 10, padding: '12px 14px', fontSize: 12.5, color: '#116B3F', lineHeight: 1.6 }}>
                Appointment booked — returning to the front desk.
              </div>
            )}
            {!booked && (
              <Pressable
                onClick={() => void confirm()}
                disabled={!slot || !patient || saving}
                title={!patient ? 'Choose a patient first.' : !slot ? 'Pick an open slot in the grid.' : undefined}
                style={{
                  background: '#1D4ED8',
                  color: '#fff',
                  opacity: !slot || !patient || saving ? 0.55 : 1,
                  borderRadius: 8,
                  padding: '12px 0',
                  textAlign: 'center',
                  fontSize: 14,
                  fontWeight: 600,
                  cursor: !slot || !patient ? 'not-allowed' : 'pointer',
                }}
              >
                {saving
                  ? 'Saving…'
                  : slot && patient
                    ? `Confirm booking · ${patient.first_name} ${patient.last_name} · ${selectedSummary}`
                    : 'Confirm booking'}
              </Pressable>
            )}
          </div>
          <div style={{ flex: 1, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 24, display: 'flex', flexDirection: 'column', gap: 14, minWidth: 0 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Available slots · {provider?.full_name ?? '…'}</h2>
              <div style={{ fontSize: 13, color: '#5B6B7F' }}>{weekDays[0]} – {weekDays[4]}</div>
            </div>
            {existingState.error && (
              <div role="alert" style={{ fontSize: 13, color: '#B42318' }}>Could not load existing bookings: {existingState.error}</div>
            )}
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5,1fr)', gap: 10, fontSize: 12.5 }}>
              {weekDays.map((k, i) => (
                <div key={k} style={{ textAlign: 'center', color: i === 0 ? '#1D4ED8' : '#5B6B7F', fontWeight: i === 0 ? 700 : 600 }}>
                  {dayLabel(`${k}T09:00:00+05:30`)}
                </div>
              ))}
              {SLOT_TIMES.map((t, ti) =>
                weekDays.map((k, di) => {
                  const taken = Boolean(patient) && isTaken(di, ti);
                  const selected = slot !== null && slot.dayIndex === di && slot.timeIndex === ti;
                  if (taken) {
                    return (
                      <div key={`${ti}-${di}`} title="Already booked for this provider" style={{ background: '#F4F6F9', color: '#C6CFDA', borderRadius: 8, padding: '9px 0', textAlign: 'center', textDecoration: 'line-through' }}>
                        {t.label}
                      </div>
                    );
                  }
                  return (
                    <Pressable
                      key={`${ti}-${di}`}
                      onClick={() => { setSlot({ dayIndex: di, timeIndex: ti }); setSaveError(null); }}
                      disabled={!patient || taken}
                      ariaPressed={selected}
                      ariaLabel={`${shortDate(new Date(slotInstant(k, t.hour)).toISOString())}, ${t.label}${!patient ? ' — choose a patient first' : ''}`}
                      title={!patient ? 'Choose a patient first.' : undefined}
                      style={{
                        ...(selected
                          ? { border: '1px solid #1D4ED8', background: '#EDF2FE', color: '#1D4ED8', fontWeight: 700 }
                          : { border: '1px solid #DDE3EB' }),
                        ...(!patient ? { opacity: 0.55 } : {}),
                        borderRadius: 8,
                        padding: '9px 0',
                        textAlign: 'center',
                        cursor: !patient ? 'not-allowed' : 'pointer',
                      }}
                    >
                      {t.label}
                    </Pressable>
                  );
                }),
              ).flat()}
            </div>
            <div style={{ fontSize: 12, color: '#8A97A8' }}>
              Struck-through slots collide with this provider's existing bookings at the chosen duration.
              {!patient && ' Choose a patient to enable the grid.'}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
