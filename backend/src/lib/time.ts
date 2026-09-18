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

/** How far `timeZone` is ahead of UTC at an instant, in ms. */
function zoneOffsetMs(epochMs: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone, hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(epochMs));
  const part = (type: string) => Number(parts.find((p) => p.type === type)?.value);
  const asUtc = Date.UTC(
    part('year'), part('month') - 1, part('day'), part('hour'), part('minute'), part('second'),
  );
  return asUtc - Math.floor(epochMs / 1000) * 1000;
}

/**
 * The instant a local wall-clock time (`YYYY-MM-DD`, `HH:MM`) names in
 * `timeZone`. The offset is looked up twice so a DST edge resolves to the
 * offset actually in force at the result, not at the naive guess.
 */
export function localDateTimeToEpoch(date: string, time: string, timeZone: string): number {
  const [y, m, d] = date.split('-').map(Number) as [number, number, number];
  const [hh, mm] = time.split(':').map(Number) as [number, number];
  const naive = Date.UTC(y, m - 1, d, hh, mm);
  const guess = naive - zoneOffsetMs(naive, timeZone);
  return naive - zoneOffsetMs(guess, timeZone);
}
