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
 * The BCP-47 tag the speech models take. Deepgram wants a region for English
 * ("en" alone is accepted but "en-US" is its trained default); Whisper only
 * ever reads the primary subtag, and services/speech/whisper.ts strips the
 * rest, so one tag serves both.
 */
export function speechLanguage(raw: string | null | undefined): string {
  return normaliseLocale(raw) === 'en' ? 'en-US' : 'vi';
}
