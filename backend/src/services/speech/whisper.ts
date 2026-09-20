import { ApiError } from '../../lib/errors';
import type { Bindings } from '../../env';
import type { TranscribeOptions, TranscribeResult } from './types';

/**
 * OpenAI Whisper on Workers AI (`@cf/openai/whisper-large-v3-turbo`).
 *
 * Kept beside the Deepgram path rather than replaced: switching back is an
 * `AI_ASR_MODEL` change and nothing else, so a regression on one model is an
 * env var away from being undone.
 *
 * Whisper takes the clip base64-encoded in `audio` and ignores the content
 * type — it sniffs the container itself.
 */
export async function transcribeWithWhisper(
  env: Bindings,
  model: string,
  audio: Uint8Array,
  opts: TranscribeOptions = {},
): Promise<TranscribeResult> {
  // Chunked: String.fromCharCode(...bytes) on a whole clip blows the argument
  // limit somewhere north of a hundred kilobytes.
  let binary = '';
  for (let i = 0; i < audio.length; i += 0x8000) {
    binary += String.fromCharCode(...audio.subarray(i, i + 0x8000));
  }

  const result = (await env.AI.run(model as never, {
    audio: btoa(binary),
    // Whisper takes a bare ISO-639-1 code; a BCP-47 tag like "vi-VN" is not
    // one, so only the primary subtag is sent.
    ...(opts.locale ? { language: primaryLanguage(opts.locale) } : {}),
  } as never)) as unknown as { text?: string };

  const text = (result.text ?? '').trim();
  if (!text) throw new ApiError('UPSTREAM_AI_ERROR', 'Không nghe rõ nội dung');
  return { text, model };
}

export function primaryLanguage(tag: string): string {
  return tag.split(/[-_]/)[0]!.toLowerCase();
}
