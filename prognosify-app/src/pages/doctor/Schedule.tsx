import { useMemo, useState, type CSSProperties } from 'react';
import { useNavigate } from 'react-router-dom';
import SideNav from '../../components/SideNav';
import { Busy, Pressable, SegmentedControl } from '../../components/ui';
import { useAsync } from '../../lib/useAsync';
import {
  appointmentTitle,
  getAppointmentsBetween,
  type AppointmentRow,
} from '../../lib/api';
import {
  dayBounds,
  dayKey,
  shiftDay,
  timeLabel,
  todayKey,
  weekBounds,
} from '../../lib/format';

const VIEWS = ['Day', 'Week'] as const;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const DAYS_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MONTHS_LONG = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

interface Slot {
  key: string;
  time: string;
  title: string;
  meta: string;
  clickable: boolean;
  neutral: boolean;
}

function toSlot(a: AppointmentRow): Slot {
  const meta = [
    `${a.duration_minutes} min`,
    a.department?.name ?? a.visit_type?.name ?? null,
    a.room_label ?? null,
    a.status !== 'booked' ? a.status.replace('_', ' ') : null,
  ]
    .filter(Boolean)
    .join(' Â· ');
  return {
    key: a.id,
    time: timeLabel(a.scheduled_start),
    title: appointmentTitle(a),
    meta,
    clickable: Boolean(a.patient),
    neutral: !a.patient,
  };
}

/** Monday that starts the clinic-calendar week containing `key`. */
const dateFromKey = (key: string): Date => new Date(`${key}T00:00:00+05:30`);
const mondayOf = (key: string): string => {
  const weekday = dateFromKey(key).getUTCDay();
  return shiftDay(key, -((weekday + 6) % 7));
};

const shortDayMonth = (key: string): string => {
  const d = dateFromKey(key);
  return `${MONTHS[d.getUTCMonth()]} ${d.getUTCDate()}`;
};
const weekdayShortOf = (key: string): string => DAYS[dateFromKey(key).getUTCDay()];

const blockStyle = (s: Slot): CSSProperties => ({
  flex: 1,
  background: s.neutral ? '#F4F6F9' : '#EDF2FE',
  borderLeft: `3px solid ${s.neutral ? '#5B6B7F' : '#1D4ED8'}`,
  borderRadius: 6,
  padding: '10px 14px',
  cursor: s.clickable ? 'pointer' : 'default',
});

export default function Schedule() {
  const navigate = useNavigate();
  const [view, setView] = useState<string>('Day');
  const [date, setDate] = useState<string>(todayKey());

  const isWeek = view === 'Week';
  const step = isWeek ? 7 : 1;
  const weekDays = useMemo(() => {
    const start = mondayOf(date);
    return [0, 1, 2, 3, 4, 5, 6].map((i) => shiftDay(start, i));
  }, [date]);

  // One fetch serves both views: a week's rows cover any single day inside it.
  const { data, error, loading } = useAsync(async () => {
    if (isWeek) {
      return getAppointmentsBetween(weekBounds(mondayOf(date)).startISO, weekBounds(mondayOf(date)).endISO);
    }
    const bounds = dayBounds(date);
    return getAppointmentsBetween(bounds.startISO, bounds.endISO);
  }, [view, date]);

  const slotsForDay = (key: string): Slot[] => {
    const rows = (data ?? []).filter((a) => dayKey(a.scheduled_start) === key);
    return rows.map(toSlot);
  };

  const spokenDate = (key: string): string => {
    const d = dateFromKey(key);
    return `${DAYS_LONG[d.getUTCDay()]}, ${MONTHS_LONG[d.getUTCMonth()]} ${d.getUTCDate()}`;
  };

  const daySlots = slotsForDay(date);
  const patientVisits = (data ?? []).filter((a) => a.patient).length;
  const blocks = (data ?? []).filter((a) => !a.patient).length;

  return (
    <div style={{ width: '100%', height: '100%', display: 'flex' }}>
      <SideNav role="doctor" active="schedule" />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <div style={{ height: 64, background: '#ffffff', borderBottom: '1px solid #DDE3EB', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 28px', flexShrink: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <h1 style={{ fontSize: 17, fontWeight: 600, margin: 0 }}>Schedule</h1>
            <SegmentedControl
              options={VIEWS}
              value={view}
              onChange={setView}
              ariaLabel="Calendar view"
              style={{ display: 'flex', border: '1px solid #DDE3EB', borderRadius: 8, overflow: 'hidden', fontSize: 12.5 }}
              itemStyle={{ padding: '7px 14px', color: '#5B6B7F', cursor: 'pointer' }}
              selectedItemStyle={{ background: '#1D4ED8', color: '#ffffff', fontWeight: 600 }}
            />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, fontSize: 13.5 }}>
            <Pressable onClick={() => setDate((d) => shiftDay(d, -step))} ariaLabel={isWeek ? 'Previous week' : 'Previous day'} style={{ color: '#5B6B7F', cursor: 'pointer' }}>â†</Pressable>
            <div aria-live="polite" style={{ fontWeight: 600 }}>
              {isWeek
                ? `${shortDayMonth(weekDays[0])} â€“ ${shortDayMonth(weekDays[6])}`
                : `${weekdayShortOf(date)}, ${shortDayMonth(date)}`}
            </div>
            <Pressable onClick={() => setDate((d) => shiftDay(d, step))} ariaLabel={isWeek ? 'Next week' : 'Next day'} style={{ color: '#5B6B7F', cursor: 'pointer' }}>â†’</Pressable>
          </div>
        </div>
        <div style={{ flex: 1, display: 'flex', gap: 16, padding: '24px 28px', overflow: 'auto' }}>
          <div style={{ flex: 1, background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 0, minWidth: 0 }}>
            {error && (
              <div role="alert" style={{ fontSize: 13.5, color: '#B42318' }}>Could not load the calendar: {error}</div>
            )}
            {loading && (
              <div role="status" style={{ fontSize: 13.5, color: '#5B6B7F', padding: '10px 0' }}><Busy label="Loading calendar" fill={false} /></div>
            )}
            {!loading && !error && (isWeek ? (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, minmax(0, 1fr))', gap: 10 }}>
                {weekDays.map((d) => {
                  const current = d === date;
                  const dayAppointments = slotsForDay(d);
                  return (
                    <div key={d} style={{ display: 'flex', flexDirection: 'column', gap: 8, minWidth: 0 }}>
                      <Pressable
                        onClick={() => { setDate(d); setView('Day'); }}
                        ariaLabel={`Show ${spokenDate(d)} in day view`}
                        style={{ display: 'flex', flexDirection: 'column', gap: 2, paddingBottom: 8, borderBottom: '1px solid #EEF2F6', cursor: 'pointer' }}
                      >
                        <span style={{ fontSize: 12.5, fontWeight: 600, color: current ? '#1D4ED8' : '#0F1C2E' }}>{weekdayShortOf(d)}</span>
                        <span style={{ fontSize: 12, color: '#5B6B7F' }}>{shortDayMonth(d)}</span>
                      </Pressable>
                      {dayAppointments.map((s) => (
                        s.clickable ? (
                          <Pressable key={s.key} onClick={() => navigate(`/doctor/patients/${mrnOf(data, s.key)}`)} style={blockStyle(s)}>
                            <span style={{ fontSize: 12, color: '#5B6B7F' }}>{s.time}</span>
                            <span style={{ fontSize: 12.5, fontWeight: 600 }}>{s.title}</span>
                          </Pressable>
                        ) : (
                          <div key={s.key} style={blockStyle(s)}>
                            <span style={{ fontSize: 12, color: '#5B6B7F' }}>{s.time}</span>
                            <span style={{ fontSize: 12.5, fontWeight: 600 }}>{s.title}</span>
                          </div>
                        )
                      ))}
                    </div>
                  );
                })}
              </div>
            ) : daySlots.length === 0 ? (
              <div role="status" style={{ padding: '10px 0', fontSize: 13.5, color: '#5B6B7F' }}>
                Nothing scheduled for {spokenDate(date)}.
              </div>
            ) : (
              daySlots.map((s) => (
                <div key={s.key} style={{ display: 'flex', gap: 14, borderTop: '1px solid #EEF2F6', padding: '10px 0' }}>
                  <div style={{ width: 70, fontSize: 12.5, color: '#5B6B7F', flexShrink: 0 }}>{s.time}</div>
                  {s.clickable ? (
                    <Pressable onClick={() => navigate(`/doctor/patients/${mrnOf(data, s.key)}`)} style={blockStyle(s)} ariaLabel={`Open ${s.title}`}>
                      <div style={{ fontSize: 13.5, fontWeight: 600 }}>{s.title}</div>
                      <div style={{ fontSize: 12, color: '#5B6B7F' }}>{s.meta}</div>
                    </Pressable>
                  ) : (
                    <div style={blockStyle(s)}>
                      <div style={{ fontSize: 13.5, fontWeight: 600 }}>{s.title}</div>
                      <div style={{ fontSize: 12, color: '#5B6B7F' }}>{s.meta}</div>
                    </div>
                  )}
                </div>
              ))
            ))}
          </div>
          <div style={{ width: 320, flexShrink: 0, display: 'flex', flexDirection: 'column', gap: 16 }}>
            <div style={{ background: '#ffffff', border: '1px solid #DDE3EB', borderRadius: 12, padding: 20, display: 'flex', flexDirection: 'column', gap: 10 }}>
              <h2 style={{ fontSize: 15, fontWeight: 600, margin: 0 }}>Day summary</h2>
              <div style={{ fontSize: 13.5, display: 'flex', flexDirection: 'column', gap: 8 }}>
                {[
                  ['Appointments', String((data ?? []).length)],
                  ['Patient visits', String(patientVisits)],
                  ['Calendar blocks', String(blocks)],
                ].map(([l, v]) => (
                  <div key={l} style={{ display: 'flex', justifyContent: 'space-between' }}><div style={{ color: '#5B6B7F' }}>{l}</div><div style={{ fontWeight: 600 }}>{loading ? 'â€¦' : v}</div></div>
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

/** Slots navigate to the patient chart; the MRN comes from the row itself. */
function mrnOf(rows: AppointmentRow[] | null | undefined, id: string): string {
  const hit = (rows ?? []).find((r) => r.id === id);
  return hit?.patient?.mrn ?? '';
}
