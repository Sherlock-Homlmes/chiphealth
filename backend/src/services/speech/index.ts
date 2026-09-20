import { modelConfig } from '../../config/models';
import { transcribeWithNova3 } from './nova3';
import { transcribeWithWhisper } from './whisper';
import type { Bindings } from '../../env';
import type { TranscribeOptions, TranscribeResult } from './types';

export type { TranscribeOptions, TranscribeResult } from './types';
export { transcribeWithNova3 } from './nova3';
export { transcribeWithWhisper } from './whisper';

/**
 * Every clip the app transcribes goes through here: meal dictation, spoken
 * meal logging, sleep-talk. Which model runs is `AI_ASR_MODEL` and nothing
 * else — the two request/response shapes live in nova3.ts and whisper.ts, and
 * this picks between them, so changing the model back is an env var.
 */
export async function transcribeAudio(
  env: Bindings,
  audio: Uint8Array,
  opts: TranscribeOptions = {},
): Promise<TranscribeResult> {
  const model = modelConfig(env).asr;
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
