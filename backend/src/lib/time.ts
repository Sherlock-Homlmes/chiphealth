/** Local calendar day (YYYY-MM-DD) for an instant, in the given IANA timezone. */
export function localDate(epochMs: number, timeZone: string): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date(epochMs));
}

/** Local wall-clock HH:MM for an instant, in the given IANA timezone. */
export function localTime(epochMs: number, timeZone: string): string {
  return new Intl.DateTimeFormat('en-GB', {
    timeZone, hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(epochMs));
}

/** Local weekday key (mon..sun) for an instant. */
export function localWeekday(epochMs: number, timeZone: string): string {
  return new Intl.DateTimeFormat('en-US', { timeZone, weekday: 'short' })
    .format(new Date(epochMs)).toLowerCase();
}

/** Shift a YYYY-MM-DD string by whole days. Calendar-safe, timezone-free. */
export function addDays(isoDate: string, days: number): string {
  const [y, m, d] = isoDate.split('-').map(Number) as [number, number, number];
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + days);
  return dt.toISOString().slice(0, 10);
}

/** Inclusive list of YYYY-MM-DD from..to. */
export function dateRange(from: string, to: string): string[] {
  const out: string[] = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}

/** Whole years between a YYYY-MM-DD birth date and now. */
export function ageFromDob(dob: string, now = Date.now()): number {
  const [y, m, d] = dob.split('-').map(Number) as [number, number, number];
  const today = new Date(now);
  let age = today.getUTCFullYear() - y;
  const beforeBirthday =
    today.getUTCMonth() + 1 < m ||
    (today.getUTCMonth() + 1 === m && today.getUTCDate() < d);
  if (beforeBirthday) age--;
  return age;
}
