import { useState } from 'react';
import PortalNav from '../../components/PortalNav';
import { Busy, Pressable, SegmentedControl } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  bookPortalSlot,
  getBookingProviders,
  getPortalSlots,
  getVisitTypes,
  type SlotRow,
} from '../../lib/api';
import { dayLabel, shortDate, timeLabel } from '../../lib/format';

/** Group a provider's free slots into one column per clinic day. */
function groupByDay(slots: SlotRow[]): { key: string; label: string; slots: SlotRow[] }[] {
  const map = new Map<string, SlotRow[]>();
  for (const s of slots) {
    const key = s.slot_start.slice(0, 10);
    if (!map.has(key)) map.set(key, []);
    map.get(key)!.push(s);
  }
  return [...map.entries()].map(([key, list]) => ({
    key,
    label: dayLabel(`${key}T09:00:00+05:30`),
    slots: list,
  }));
}

export default function PatientBook() {
  const [providerId, setProviderId] = useState('');
  const [visitTypeId, setVisitTypeId] = useState('');
  const [selected, setSelected] = useState<SlotRow | null>(null);
  const [booking, setBooking] = useState(false);
  const [bookError, setBookError] = useState<string | null>(null);
  const [booked, setBooked] = useState(false);

  const providersState = useAsync(() => getBookingProviders(), []);
  const visitTypesState = useAsync(() => getVisitTypes(), []);

  const activeProviderId =
    providerId || providersState.data?.[0]?.member_id || '';
  const activeVisitTypeId =
    visitTypeId || visitTypesState.data?.[0]?.id || '';

  // Availability comes from the security-definer RPC: free times only, nobody else's data.
  const slotsState = useAsync(async () => {
    if (!activeProviderId) return [];
    return getPortalSlots(activeProviderId);
  }, [activeProviderId]);

  const days = groupByDay(slotsState.data ?? []);

  const confirm = async () => {
    if (!selected || !activeVisitTypeId) return;
    setBooking(true);
    setBookError(null);
    try {
      await bookPortalSlot(activeProviderId, activeVisitTypeId, selected.slot_start);
      setBooked(true);
      window.setTimeout(() => { window.location.assign('/patient/home'); }, 1200);
    } catch (err) {
      setBookError(err instanceof Error ? err.message : 'Could not book that slot.');
      setSelected(null);
      slotsState.reload();
    } finally {
      setBooking(false);
    }
  };

  const loading = providersState.loading || visitTypesState.loading;
  const providerName =
    providersState.data?.find((p) => p.member_id === activeProviderId)?.full_name ?? 'your care team';

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex', flexDirection: 'column', background: '#FBFCFD' }}>
      <PortalNav active="Book visit" />
      <div style={{ flex: 1, display: 'flex', justifyContent: 'center', overflow: 'auto' }}>
        <div style={{ width: 860, display: 'flex', flexDirection: 'column', gap: 22, padding: '36px 0' }}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
            <h1 style={{ fontSize: 24, fontWeight: 700, margin: 0 }}>Book a visit</h1>
            <div style={{ fontSize: 14, color: '#5B6B7F' }}>Choose your care team member and a time that suits you.</div>
          </div>

          {loading && (
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24 }}>
              <Busy label="Loading your care team…" fill={false} />
            </div>
          )}

          {!loading && (
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 14, padding: 24, display: 'flex', flexDirection: 'column', gap: 16 }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <label htmlFor="book-provider" style={{ fontSize: 13, fontWeight: 500 }}>Care team member</label>
                <select
                  id="book-provider"
                  value={activeProviderId}
                  onChange={(e) => { setProviderId(e.target.value); setSelected(null); }}
                  style={{ border: '1px solid #DDE3EB', borderRadius: 8, padding: '11px 13px', fontSize: 14, background: '#fff' }}
                >
                  {(providersState.data ?? []).map((p) => (
                    <option key={p.member_id} value={p.member_id}>
                      {[p.full_name, p.department_name ?? p.specialty].filter(Boolean).join(' · ')}
                    </option>
                  ))}
                </select>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <span style={{ fontSize: 13, fontWeight: 500 }}>Visit type</span>
                <SegmentedControl
                  options={(visitTypesState.data ?? []).map((v) => v.name)}
                  value={visitTypesState.data?.find((v) => v.id === activeVisitTypeId)?.name ?? ''}
                  onChange={(name) => {
                    const hit = visitTypesState.data?.find((v) => v.name === name);
                    if (hit) { setVisitTypeId(hit.id); setSelected(null); }
                  }}
                  ariaLabel="Visit type"
                  style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}
                  itemStyle={{ border: '1px solid #DDE3EB', borderRadius: 10, padding: '9px 14px', fontSize: 13, color: '#5B6B7F', cursor: 'pointer' }}
                  selectedItemStyle={{ border: '1px solid #1D4ED8', background: '#EDF2FE', color: '#1D4ED8', fontWeight: 600 }}
                />
              </div>

              <h2 style={{ fontSize: 14.5, fontWeight: 600, margin: 0 }}>
                Available times with {providerName}
              </h2>
              {slotsState.error && (
                <div role="alert" style={{ fontSize: 13, color: '#B42318' }}>
                  Could not load available times: {slotsState.error}
                </div>
              )}
              {slotsState.loading && (
                <Busy label="Finding open times…" fill={false} />
              )}
              {!slotsState.loading && !slotsState.error && days.length === 0 && (
                <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F', lineHeight: 1.6 }}>
                  No open slots in the next two weeks. Call the front desk — they can always find room for you.
                </div>
              )}
              {days.map((day) => (
                <div key={day.key} style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ fontSize: 12.5, fontWeight: 600, color: '#5B6B7F' }}>{day.label}</div>
                  <div role="group" aria-label={`Times on ${day.label}`} style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    {day.slots.map((s) => {
                      const isSelected = selected?.slot_start === s.slot_start;
                      return (
                        <Pressable
                          key={s.slot_start}
                          onClick={() => { setSelected(s); setBookError(null); }}
                          ariaPressed={isSelected}
                          ariaLabel={`${timeLabel(s.slot_start)} on ${shortDate(s.slot_start)}`}
                          style={{
                            border: isSelected ? '1px solid #1D4ED8' : '1px solid #DDE3EB',
                            background: isSelected ? '#EDF2FE' : '#fff',
                            color: isSelected ? '#1D4ED8' : '#0F1C2E',
                            fontWeight: isSelected ? 700 : 500,
                            borderRadius: 8,
                            padding: '9px 16px',
                            fontSize: 13,
                            cursor: 'pointer',
                          }}
                        >
                          {timeLabel(s.slot_start)}
                        </Pressable>
                      );
                    })}
                  </div>
                </div>
              ))}

              {bookError && (
                <div role="alert" style={{ background: '#FEF5F4', border: '1px solid #F1D3D0', borderRadius: 10, padding: '12px 14px', fontSize: 12.5, color: '#B42318', lineHeight: 1.6 }}>
                  {bookError}
                </div>
              )}
              {booked && (
                <div role="status" style={{ background: '#F0F7F2', border: '1px solid #CFE6D8', borderRadius: 10, padding: '12px 14px', fontSize: 12.5, color: '#116B3F', lineHeight: 1.6 }}>
                  Booked! Taking you to your home page…
                </div>
              )}
            </div>
          )}

          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <Pressable onClick={() => window.location.assign('/patient/home')} style={{ border: '1px solid #DDE3EB', background: '#ffffff', borderRadius: 8, padding: '11px 20px', fontSize: 14, fontWeight: 500, cursor: 'pointer' }}>
              Back
            </Pressable>
            <Pressable
              onClick={() => void confirm()}
              disabled={!selected || booking || booked}
              title={!selected ? 'Pick a time above first.' : undefined}
              style={{
                background: '#1D4ED8',
                color: '#fff',
                borderRadius: 8,
                padding: '11px 22px',
                fontSize: 14,
                fontWeight: 600,
                cursor: !selected || booking ? 'default' : 'pointer',
                opacity: !selected || booking ? 0.55 : 1,
              }}
            >
              {booking
                ? 'Booking…'
                : booked
                  ? 'Booked ✓'
                  : selected
                    ? `Confirm ${shortDate(selected.slot_start)} · ${timeLabel(selected.slot_start)} →`
                    : 'Confirm'}
            </Pressable>
          </div>
        </div>
      </div>
    </div>
  );
}
