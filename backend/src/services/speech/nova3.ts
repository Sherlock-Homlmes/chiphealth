import { ApiError } from '../../lib/errors';
import type { Bindings } from '../../env';
import type { TranscribeOptions, TranscribeResult } from './types';

/**
 * Deepgram Nova-3 on Workers AI (`@cf/deepgram/nova-3`).
 *
 * A different contract from Whisper's in every part: the clip goes as a body +
 * content type rather than base64, the flags that make the text readable are
 * opt-in, and the transcript is buried in Deepgram's channel/alternative
 * shape instead of a flat `text`. That is the whole reason this lives in its
 * own file — see ./index.ts for the switch.
 */
export async function transcribeWithNova3(
  env: Bindings,
  model: string,
  audio: Uint8Array,
  opts: TranscribeOptions = {},
): Promise<TranscribeResult> {
  const result = (await env.AI.run(model as never, {
    audio: {
      // A fresh Uint8Array copy: the binding serialises the buffer, and a view
      // onto a larger pooled buffer would carry the rest of it along.
      body: new Uint8Array(audio),
      // Deepgram picks the decoder from this; an empty string makes it guess.
      contentType: opts.mimeType && opts.mimeType.length > 0
        ? opts.mimeType
        : 'audio/mpeg',
    },
    // Nova-3 takes a BCP-47 tag and understands "multi" for mixed speech.
    ...(opts.language ? { language: opts.language } : { detect_language: true }),
    // Raw Deepgram output is lowercase and unpunctuated. The transcript is
    // shown to the user for review and fed to a model that has to split a
    // meal into components, so both want sentences.
    punctuate: true,
    smart_format: true,
  } as never)) as unknown as Nova3Response;

  const text = firstTranscript(result);
  if (!text) throw new ApiError('UPSTREAM_AI_ERROR', 'Không nghe rõ nội dung');
  return { text, model };
}

interface Nova3Channel {
  alternatives?: Array<{ transcript?: string; confidence?: number }>;
}

interface Nova3Response {
  results?: { channels?: Nova3Channel[] };
  /** Some responses carry the bare Deepgram body, without the `results` wrapper. */
  channels?: Nova3Channel[];
}

/**
 * The best alternative of the first channel. Only one channel is ever asked
 * for (mono clips, no diarisation), so anything beyond the first is a model
 * quirk rather than something to merge.
 */
export function firstTranscript(res: Nova3Response): string {
  const channels = res.results?.channels ?? res.channels ?? [];
  for (const channel of channels) {
    for (const alt of channel?.alternatives ?? []) {
      const text = (alt?.transcript ?? '').trim();
      if (text) return text;
    }
  }
  return '';
}
