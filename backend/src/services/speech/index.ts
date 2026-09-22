import { modelConfig } from '../../config/models';
import { normaliseLocale } from '../../lib/language';
import { transcribeWithNova3 } from './nova3';
import { transcribeWithWhisper } from './whisper';
import type { Bindings } from '../../env';
import type { TranscribeOptions, TranscribeResult } from './types';

export type { TranscribeOptions, TranscribeResult } from './types';
export { transcribeWithNova3 } from './nova3';
export { transcribeWithWhisper } from './whisper';

/**
 * The model that transcribes this speaker.
 *
 * Whisper on both halves now. Nova-3 does not do Vietnamese at all — a
 * Vietnamese clip comes back empty, which the app then reports as "không nghe
 * rõ" — and on the languages it does cover it mishears enough to be the worse
 * transcript in practice.
 *
 * The split stays: Vietnamese reads `AI_ASR_MODEL_VI` and everything else the
 * configured default, so one language can be moved to another model without
 * dragging the other along, and Nova-3 is one env var away from coming back.
 */
export function asrModelFor(env: Bindings, locale?: string): string {
  return normaliseLocale(locale) === 'vi'
    ? env.AI_ASR_MODEL_VI ?? '@cf/openai/whisper-large-v3-turbo'
    : modelConfig(env).asr;
}

/**
 * Every clip the app transcribes goes through here: meal dictation, spoken
 * meal logging, sleep-talk. The two request/response shapes live in nova3.ts
 * and whisper.ts; this picks the model for the speaker's language and then the
 * shape for that model, so switching either is an env var and nothing else.
 *
 * `opts.locale` is the language on the account, read from the row at request
 * time by `accountLocale` rather than from the hour-old access token — see
 * lib/language.ts. A user who has just changed the setting is heard in the new
 * language on the very next clip.
 */
export async function transcribeAudio(
  env: Bindings,
  audio: Uint8Array,
  opts: TranscribeOptions = {},
): Promise<TranscribeResult> {
  const model = asrModelFor(env, opts.locale);
  return asrFamily(model) === 'deepgram'
    ? transcribeWithNova3(env, model, audio, opts)
    : transcribeWithWhisper(env, model, audio, opts);
}

/**
 * Which request shape a model id wants. Matched on the vendor prefix rather
 * than the exact id, so `@cf/deepgram/nova-3` and whatever Deepgram ships next
 * both land on the same code path.
 */
export function asrFamily(model: string): 'deepgram' | 'whisper' {
  return model.toLowerCase().includes('/deepgram/') ? 'deepgram' : 'whisper';
}
