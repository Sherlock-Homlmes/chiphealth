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
 * Nova-3 is the better recogniser but it does not do Vietnamese at all — a
 * Vietnamese clip comes back empty, which the app then reports as "không nghe
 * rõ". So the language picks the model: Vietnamese goes to Whisper, which
 * handles it well, and everything else goes to the configured default.
 *
 * Both are env vars, so either half can be moved without touching code.
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
