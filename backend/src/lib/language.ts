import { eq } from 'drizzle-orm';
import { users } from '../db/schema';
import type { Db } from '../db/client';

/**
 * The languages the app is offered in. One list, used by everything that has
 * to speak to the user: the speech recogniser listens in it, the assistant and
 * the coach answer in it, and the app's own strings are translated into it.
 *
 * Adding one means adding an ARB file in the Flutter app as well — the list is
 * short on purpose.
 */
export const SUPPORTED_LOCALES = ['vi', 'en'] as const;

export type SupportedLocale = typeof SUPPORTED_LOCALES[number];

export const DEFAULT_LOCALE: SupportedLocale = 'vi';

/**
 * A stored or requested locale narrowed to one we support. Accepts region tags
 * ("vi-VN", "en_US"), since that is what a device hands over, and falls back to
 * the default rather than throwing: an unknown language is a reason to speak
 * Vietnamese, not a reason to fail the request.
 */
export function normaliseLocale(raw: string | null | undefined): SupportedLocale {
  const primary = (raw ?? '').split(/[-_]/)[0]!.trim().toLowerCase();
  return (SUPPORTED_LOCALES as readonly string[]).includes(primary)
    ? primary as SupportedLocale
    : DEFAULT_LOCALE;
}

/** What to call the language inside a prompt, in that language. */
export function languageName(raw: string | null | undefined): string {
  return normaliseLocale(raw) === 'en' ? 'English' : 'tiếng Việt';
}

/**
 * The language on the account right now.
 *
 * The access token carries a copy of it and lives for an hour, so a user who
 * has just changed the setting would otherwise keep being transcribed — and
 * answered — in the old language until their token rolled over. Everything
 * that speaks to the user reads it here instead, which costs one indexed
 * lookup next to an AI call.
 */
export async function accountLocale(
  db: Db, user: { id: string; locale: string },
): Promise<SupportedLocale> {
  const rows = await db.select({ locale: users.locale }).from(users)
    .where(eq(users.id, user.id)).limit(1);
  return normaliseLocale(rows[0]?.locale ?? user.locale);
}
