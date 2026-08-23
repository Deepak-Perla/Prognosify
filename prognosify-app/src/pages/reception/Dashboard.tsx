import type { CSSProperties, ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Pressable, pressableReset } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  balanceMinor,
  getCheckinQueue,
  getDepartments,
  getInvoices,
  todayAppointments,
  type CheckinQueueRow,
} from '../../lib/api';
import { dayLabel, money, timeLabel } from '../../lib/format';

/**
 * A real, focusable button for an action this build cannot perform (no telephony).
 * `aria-disabled` (not `disabled`) so it stays keyboard reachable and can explain itself.
 */
function UnavailableAction({ style, title, ariaLabel, children }: { style: CSSProperties; title: string; ariaLabel: string; children: ReactNode }) {
  return (
    <button type="button" aria-disabled="true" aria-label={ariaLabel} title={title} style={{ ...pressableReset, ...style }}>
      {children}
    </button>
  );
}

export default function ReceptionDashboard() {
  const navigate = useNavigate();

  const { data, error, loading } = useAsync(async () => {
    const [queue, appointments, invoices, departments] = await Promise.all([
      getCheckinQueue(),
      todayAppointments(),
      getInvoices(),
      getDepartments(),
    ]);

    const waiting = queue.filter((q) => q.status === 'waiting');
    const avgWait =
      waiting.length > 0
        ? Math.round(waiting.reduce((sum, w) => sum + (w.waiting_minutes ?? 0), 0) / waiting.length)
        : null;

    // Outstanding = unpaid patient share across the front desk's worklist statuses.
    const openInvoices = invoices.filter(
      (inv) => ['copay_due', 'overdue', 'auth_missing'].includes(inv.status) && balanceMinor(inv) > 0,
    );

    // Clinic load: today's booked volume against each department's daily capacity.
    const load = departments
      .filter((d) => (d.daily_slot_capacity ?? 0) > 0)
      .map((d) => ({
        label: d.name,
        count: appointments.filter((a) => a.department?.id === d.id).length,
        capacity: d.daily_slot_capacity!,
      }))
      .map((d) => ({
        ...d,
        pct: Math.min(100, Math.round((d.count / d.capacity) * 100)),
      }))
      .sort((a, b) => b.pct - a.pct);

    return {
      queue,
      waiting,
      avgWait,
      walkIns: appointments.filter((a) => a.origin === 'walk_in').length,
      openTotalMinor: openInvoices.reduce((sum, inv) => sum + balanceMinor(inv), 0),
      openCount: openInvoices.length,
      oldestOverdueDays: openInvoices.reduce(
        (max, inv) => {
          if (!inv.due_at) return max;
          const days = Math.floor((Date.now() - new Date(inv.due_at).getTime()) / 86400000);
          return Math.max(max, days);
        },
        0,
      ),
      load,
    };
  }, []);

  const arrivals: CheckinQueueRow[] = (data?.queue ?? [])
    .filter((q) => q.status === 'booked' || q.status === 'waiting')
    .slice(0, 5);
  const busiest = data?.load[0];

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="reception" active="recDash" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Front desk · {dayLabel(new Date())}</h1>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <Pressable onClick={() => navigate('/reception/register')} style={{ border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 500, cursor: 'pointer' }}>Register patient</Pressable>
            <Pressable onClick={() => navigate('/reception/booking')} style={{ background: '#1D4ED8', color: '#fff', borderRadius: 8, padding: '9px 16px', fontSize: 13, fontWeight: 600, cursor: 'pointer' }}>Book appointment</Pressable>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 20, padding: '24px 28px', overflow: 'auto' }}>
          {error && (
            <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 16px', fontSize: 13, color: '#B42318' }}>
              Could not load the front-desk dashboard: {error}
            </div>
          )}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4,1fr)', gap: 16 }}>
            <Pressable className="hover-border-accent" ariaLabel={`Waiting now: ${data?.waiting.length ?? 0} patients. Open the check-in queue`} onClick={() => navigate('/reception/check-in')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer' }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Waiting now</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : data?.waiting.length ?? '—'}</div>
              <div style={{ fontSize: 12, color: '#B54708' }}>{data?.avgWait != null ? `Avg wait ${data.avgWait} min` : 'No one queued'}</div>
            </Pressable>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Appointments today</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : data?.queue.length ?? '—'}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>{data?.walkIns ?? 0} walk-ins</div>
            </div>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6 }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Checked in today</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : (data?.queue.filter((q) => q.checked_in_at).length ?? '—')}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>Waiting or in room right now</div>
            </div>
            <Pressable className="hover-border-accent" ariaLabel={`Pending payments: ${money(data?.openTotalMinor)} across ${data?.openCount ?? 0} invoices. Open billing`} onClick={() => navigate('/reception/billing')} style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 18, display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer' }}>
              <div style={{ fontSize: 12.5, color: '#5B6B7F' }}>Pending payments</div>
              <div style={{ fontSize: 26, fontWeight: 700 }}>{loading ? '…' : money(data?.openTotalMinor)}</div>
              <div style={{ fontSize: 12, color: '#5B6B7F' }}>
                {data?.openCount ?? 0} invoices{data && data.oldestOverdueDays > 0 ? ` · oldest ${data.oldestOverdueDays} days` : ''}
              </div>
            </Pressable>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 16, flex: 1 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Next arrivals</h2>
                <Pressable onClick={() => navigate('/reception/check-in')} style={{ fontSize: 13, color: '#1D4ED8', fontWeight: 500, cursor: 'pointer' }}>Open queue</Pressable>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 13.5 }}>
                {!loading && !error && arrivals.length === 0 && (
                  <div role="status" style={{ color: '#5B6B7F' }}>Nothing left on today's list.</div>
                )}
                {arrivals.map((a) => {
                  const longWait = (a.waiting_minutes ?? 0) >= 20;
                  return (
                    <div key={a.appointment_id} style={{ display: 'flex', alignItems: 'center', gap: 12, border: longWait ? '1px solid #F3E3C2' : '1px solid #EEF2F6', background: longWait ? '#FEFAF0' : undefined, borderRadius: 10, padding: '12px 14px' }}>
                      <div style={{ width: 64, color: '#5B6B7F' }}>{timeLabel(a.scheduled_start)}</div>
                      <div style={{ flex: 1, fontWeight: 600 }}>
                        {a.patient_name}
                        {longWait && <span style={{ color: '#B54708', fontSize: 12, fontWeight: 600 }}> · waiting {a.waiting_minutes} min</span>}
                      </div>
                      <div style={{ color: '#5B6B7F' }}>
                        {[a.provider_name, a.department_name].filter(Boolean).join(' · ') || 'Triage pending'}
                      </div>
                      {a.provider_name ? (
                        <Pressable
                          onClick={() => navigate('/reception/check-in')}
                          ariaLabel={`Open the queue for ${a.patient_name}`}
                          title="Opens the check-in queue."
                          style={{ background: '#1D4ED8', color: '#fff', borderRadius: 6, padding: '6px 12px', fontSize: 12, fontWeight: 600, cursor: 'pointer' }}
                        >
                          Queue
                        </Pressable>
                      ) : (
                        <UnavailableAction
                          ariaLabel={`Triage ${a.patient_name}`}
                          title="Walk-ins need triage before a provider can be assigned."
                          style={{ border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 6, padding: '6px 12px', fontSize: 12, fontWeight: 600, color: '#1D4ED8', cursor: 'pointer' }}
                        >
                          Triage
                        </UnavailableAction>
                      )}
                    </div>
                  );
                })}
              </div>
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 16, minWidth: 0 }}>
              <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 12 }}>
                <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Clinic load today</h2>
                {!loading && !error && (data?.load.length ?? 0) === 0 && (
                  <div role="status" style={{ fontSize: 13, color: '#5B6B7F' }}>
                    No department capacities configured yet — set daily slot capacity per department to see load.
                  </div>
                )}
                <div style={{ display: 'flex', flexDirection: 'column', gap: 10, fontSize: 13 }}>
                  {(data?.load ?? []).map((d) => (
                    <div key={d.label} style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <div style={{ width: 90, color: '#5B6B7F' }}>{d.label}</div>
                      <div
                        role="progressbar"
                        aria-label={`${d.label} clinic load`}
                        aria-valuenow={d.pct}
                        aria-valuemin={0}
                        aria-valuemax={100}
                        aria-valuetext={`${d.pct}% — ${d.count} of ${d.capacity} slots booked`}
                        style={{ flex: 1, height: 8, borderRadius: 4, background: '#F4F6F9' }}
                      >
                        <div style={{ width: `${d.pct}%`, height: 8, borderRadius: 4, background: d.pct >= 90 ? '#B54708' : '#1D4ED8' }} />
                      </div>
                      <div style={{ width: 64, textAlign: 'right', fontWeight: 600 }}>
                        {d.pct}%<span style={{ color: '#8A97A8', fontWeight: 500, fontSize: 11 }}> ({d.count}/{d.capacity})</span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
              {busiest && busiest.pct >= 80 && (
                <div className="on-dark" style={{ background: '#0F1C2E', borderRadius: 12, padding: '18px 20px', display: 'flex', flexDirection: 'column', gap: 8, color: '#fff' }}>
                  <h3 style={{ fontSize: 13, fontWeight: 600, color: '#8FB0FF', margin: 0 }}>FRONT-DESK NOTE</h3>
                  <div style={{ fontSize: 13.5, color: '#C7D2E4', lineHeight: 1.6 }}>
                    {busiest.label} is at {busiest.pct}% capacity today ({busiest.count} of {busiest.capacity} slots). Steer new bookings to lighter departments.
                  </div>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
