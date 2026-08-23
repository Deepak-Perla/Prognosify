import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Busy, Chip, Pressable, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  getCheckinQueue,
  setAppointmentStatus,
  type CheckinQueueRow,
} from '../../lib/api';
import { timeLabel } from '../../lib/format';

type QueueTab = 'waiting' | 'in_room' | 'done';

const TABS: { key: QueueTab; prefix: string; label: string }[] = [
  { key: 'waiting', prefix: 'Waiting', label: 'Waiting' },
  { key: 'in_room', prefix: 'In room', label: 'In room' },
  { key: 'done', prefix: 'Done', label: 'Done' },
];

/** Shared geometry for the row actions, so every variant stays byte-identical to the spec. */
const primaryAction = { background: '#1D4ED8', color: '#fff', borderRadius: 6, padding: '7px 14px', fontSize: 12, fontWeight: 600, cursor: 'pointer' } as const;

export default function CheckIn() {
  const navigate = useNavigate();
  const [tab, setTab] = useState<QueueTab>('waiting');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const { data, error, loading, reload } = useAsync(() => getCheckinQueue(), []);

  const rows = data ?? [];
  const countFor = (key: QueueTab): number => rows.filter((r) => r.status === key).length;
  // Walk-ins that nobody has triaged yet sit outside the three buckets.
  const triageNeeded = rows.filter((r) => r.status === 'booked' && !r.provider_name);
  const visible =
    tab === 'waiting'
      ? rows.filter((r) => r.status === 'waiting' || (r.status === 'booked' && r.provider_name !== null))
      : rows.filter((r) => r.status === tab);

  // The DB guard only allows bookedâ†’waitingâ†’in_room, so each action targets one legal step.
  const advance = async (row: CheckinQueueRow, next: 'waiting' | 'in_room') => {
    setBusyId(row.appointment_id);
    setActionError(null);
    try {
      await setAppointmentStatus(row.appointment_id, next);
      reload();
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Could not update the appointment.');
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="reception" active="checkin" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Check-in queue</h1>
          <div style={{ display: 'flex', gap: 8 }}>
            {TABS.map((t) => (
              <Chip
                key={t.key}
                selected={tab === t.key}
                onClick={() => setTab(t.key)}
                ariaLabel={`Show ${t.label} (${countFor(t.key)})`}
              >
                {t.label} ({loading && t.key === tab ? 'â€¦' : countFor(t.key)})
              </Chip>
            ))}
          </div>
        </div>
        <div style={{ flex: 1, padding: '24px 28px', overflow: 'auto', display: 'flex', flexDirection: 'column', gap: 12 }}>
          {loading && <Busy label="Loading today's queue…" fill={false} />}
          <div style={{ display: 'grid', gridTemplateColumns: '60px 1.8fr 1.4fr 1fr 1fr 1.2fr', padding: '0 20px', fontSize: 12, fontWeight: 600, color: '#5B6B7F', letterSpacing: '0.03em', textTransform: 'uppercase' }}>
            <div>Queue</div><div>Patient</div><div>Provider</div><div>Appt</div><div>Waiting</div><div></div>
          </div>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 12, padding: '16px 20px', fontSize: 13.5, color: '#B42318' }}>
              Could not load today's queue: {error}
            </div>
          )}
          {actionError && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 12, padding: '12px 20px', fontSize: 13, color: '#B42318' }}>
              {actionError}
            </div>
          )}
          {!error &&
            visible.map((q) => {
              const warn = q.status === 'waiting' && (q.waiting_minutes ?? 0) >= 20;
              const isWaitingRow = q.status === 'waiting';
              return (
                <div
                  key={q.appointment_id}
                  role="group"
                  aria-label={`${q.patient_name}, status ${q.status.replace('_', ' ')}`}
                  style={{ background: '#ffffff', border: warn ? '1px solid #F3E3C2' : '1px solid #DDE3EB', borderRadius: 12, display: 'grid', gridTemplateColumns: '60px 1.8fr 1.4fr 1fr 1fr 1.2fr', padding: '16px 20px', fontSize: 13.5, alignItems: 'center' }}
                >
                  <div style={{ fontWeight: 700, color: warn ? '#B54708' : '#1D4ED8' }}>{String(q.queue_ticket ?? 0).padStart(2, '0')}</div>
                  <div style={{ fontWeight: 600 }}>
                    {q.patient_name}
                    {warn && <span style={{ color: '#B54708', fontSize: 12 }}> Â· waiting {q.waiting_minutes} min</span>}
                  </div>
                  <div style={{ color: '#5B6B7F' }}>
                    {[q.provider_name, q.department_name].filter(Boolean).join(' Â· ') || 'Triage pending'}
                  </div>
                  <div style={{ color: '#5B6B7F' }}>{timeLabel(q.scheduled_start)}</div>
                  <div style={{ fontWeight: 600, color: warn ? '#B54708' : undefined }}>
                    {q.waiting_minutes != null ? `${q.waiting_minutes} min` : 'â€”'}
                  </div>
                  <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
                    {isWaitingRow ? (
                      <Pressable
                        onClick={() => void advance(q, 'in_room')}
                        disabled={busyId === q.appointment_id}
                        ariaLabel={`Send ${q.patient_name} to the room`}
                        title="Marks this appointment in_room â€” the clinic record updates immediately."
                        style={busyId === q.appointment_id ? { ...primaryAction, opacity: 0.6 } : primaryAction}
                      >
                        Send to room
                      </Pressable>
                    ) : q.status === 'booked' ? (
                      <Pressable
                        onClick={() => void advance(q, 'waiting')}
                        disabled={busyId === q.appointment_id}
                        ariaLabel={`Check in ${q.patient_name}`}
                        title="Checks the patient in â€” they move to Waiting with a live wait time."
                        style={busyId === q.appointment_id ? { ...primaryAction, opacity: 0.6 } : primaryAction}
                      >
                        Check in
                      </Pressable>
                    ) : (
                      <button
                        type="button"
                        aria-disabled="true"
                        title={q.status === 'in_room' ? `${q.patient_name} is already in a room.` : `${q.patient_name}'s visit is complete.`}
                        style={{ ...pressableReset, ...primaryAction }}
                      >
                        {q.status === 'in_room' ? 'In room' : 'Done'}
                      </button>
                    )}
                  </div>
                </div>
              );
            })}
          {!error && !loading && visible.length === 0 && (
            <div role="status" style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: '16px 20px', fontSize: 13.5, color: '#5B6B7F' }}>
              No patients in this view.
            </div>
          )}
          {!error && triageNeeded.length > 0 && (
            <div style={{ background: '#F8F9FB', border: '1px dashed #C6CFDA', borderRadius: 12, padding: '14px 20px', fontSize: 13, color: '#5B6B7F', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div>{triageNeeded.length} walk-in{triageNeeded.length > 1 ? 's' : ''} awaiting triage ({triageNeeded.map((t) => t.patient_name).join(', ')})</div>
              <Pressable onClick={() => navigate('/reception/register')} style={{ color: '#1D4ED8', fontWeight: 600, cursor: 'pointer' }}>Register walk-in â†’</Pressable>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
