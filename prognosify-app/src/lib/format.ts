/**
 * Formatting and clinic-day helpers.
 *
 * The clinic day is defined by the tenant's timezone (organization.timezone, seeded as
 * Asia/Kolkata). India has no daylight saving, so a fixed offset is exact here: a wall-clock
 * date in the clinic becomes a UTC instant by appending +05:30.
 */

export const CLINIC_TZ = 'Asia/Kolkata';
const CLINIC_OFFSET = '+05:30';

const dayKeyFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: CLINIC_TZ,
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

/** "2026-08-17" — the clinic-calendar day an instant falls on. */
export const dayKey = (instant: Date | string): string => dayKeyFmt.format(new Date(instant));

/** Today's key on the clinic calendar. */
export const todayKey = (): string => dayKey(new Date());

/** [startUTC, endUTC) covering one clinic-calendar day. */
export function dayBounds(key: string): { startISO: string; endISO: string } {
  const start = new Date(`${key}T00:00:00${CLINIC_OFFSET}`);
  const end = new Date(start.getTime() + 24 * 60 * 60 * 1000);
  return { startISO: start.toISOString(), endISO: end.toISOString() };
}

/** [startUTC, endUTC) covering the seven days from `key`. */
export function weekBounds(key: string): { startISO: string; endISO: string } {
  const start = new Date(`${key}T00:00:00${CLINIC_OFFSET}`);
  const end = new Date(start.getTime() + 7 * 24 * 60 * 60 * 1000);
  return { startISO: start.toISOString(), endISO: end.toISOString() };
}

/** Shift a day key by whole days (negative allowed), returning a key. */
export function shiftDay(key: string, days: number): string {
  const d = new Date(`${key}T00:00:00${CLINIC_OFFSET}`);
  d.setUTCDate(d.getUTCDate() + days);
  return dayKey(d);
}

interface ClinicParts {
  hour12: string;
  minute: string;
  ampm: string;
  weekdayShort: string;
  monthShort: string;
  dayOfMonth: string;
}

function partsOf(instant: Date | string): ClinicParts {
  const fmt = new Intl.DateTimeFormat('en-US', {
    timeZone: CLINIC_TZ,
    hour: 'numeric',
    minute: '2-digit',
    hour12: true,
    weekday: 'short',
    month: 'short',
    day: 'numeric',
  });
  const parts: Record<string, string> = {};
  for (const p of fmt.formatToParts(new Date(instant))) parts[p.type] = p.value;
  return {
    hour12: parts.hour ?? '',
    minute: (parts.minute ?? '00').padStart(2, '0'),
    ampm: (parts.dayPeriod ?? '').toUpperCase(),
    weekdayShort: parts.weekday ?? '',
    monthShort: parts.month ?? '',
    dayOfMonth: parts.day ?? '',
  };
}

/** "9:30 AM" */
export function timeLabel(instant: Date | string): string {
  const p = partsOf(instant);
  return `${p.hour12}:${p.minute} ${p.ampm}`;
}

/** "Mon, Aug 17" */
export function dayLabel(instant: Date | string): string {
  const p = partsOf(instant);
  return `${p.weekdayShort}, ${p.monthShort} ${p.dayOfMonth}`;
}

/** "Aug 17" */
export function shortDate(instant: Date | string): string {
  const p = partsOf(instant);
  return `${p.monthShort} ${p.dayOfMonth}`;
}

/** "Today", "Yesterday", or "Aug 13" — the Patients table's Last visit column. */
export function visitStamp(instant: Date | string | null | undefined): string {
  if (!instant) return '—';
  const today = todayKey();
  const that = dayKey(instant);
  if (that === today) return 'Today';
  if (that === shiftDay(today, -1)) return 'Yesterday';
  return shortDate(instant);
}

/** "Today 7:40 AM" / "Aug 16 9:00 PM" — the Timeline card's left column. */
export function stampWithTime(instant: Date | string): string {
  const today = todayKey();
  const that = dayKey(instant);
  if (that === today) return `Today ${timeLabel(instant)}`;
  if (that === shiftDay(today, -1)) return `Yesterday ${timeLabel(instant)}`;
  return `${shortDate(instant)} ${timeLabel(instant)}`;
}

/** Money is stored as bigint minor units (paise). Never float. */
export function money(minor: number | null | undefined, currency = 'INR'): string {
  const value = (minor ?? 0) / 100;
  try {
    return new Intl.NumberFormat('en-IN', { style: 'currency', currency }).format(value);
  } catch {
    return `${currency} ${value.toFixed(2)}`;
  }
}

/** probability 0.9200 → "92%". */
export function pct(probability: number | null | undefined): string {
  if (probability == null) return '—';
  return `${Math.round(probability * 100)}%`;
}

/** Postgres interval ("48:00:00") → "48h". */
export function horizonLabel(interval: string | null | undefined): string {
  if (!interval) return '';
  const h = Math.round(parseFloat(interval.split(':')[0] ?? '0') || 0);
  return h > 0 ? `${h}h` : interval;
}

const SEX_LETTER: Record<string, string> = { male: 'M', female: 'F', other: 'X', undisclosed: '' };

/** "71F" for a header line; omits the letter when sex is undisclosed. */
export function ageSex(ageYears: number | null, sex: string | null): string {
  if (ageYears == null) return '';
  return `${ageYears}${(sex && SEX_LETTER[sex]) || ''}`;
}
