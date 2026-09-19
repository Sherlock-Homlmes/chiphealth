import { modelConfig } from '../../config/models';
import { aiText, toDataUri } from '../../lib/aiText';
import { PROMPTS, renderPrompt } from '../../prompts';
import type { Bindings } from '../../env';

/**
 * What the chat agent "sees" when the user attaches a photo.
 *
 * The agent model is text-only, so before its turn runs, the vision model
 * (same one the meal-photo pipeline uses) writes a compact description, and
 * the route injects it into the user message inside <photo_description> tags.
 * The description is stored on the user message row, so later turns' history
 * still "sees" the photo without re-running vision on old images.
 *
 * Fail-soft on purpose: a broken or missing image must not sink the whole
 * turn — null means "attached, could not analyse", and the agent is told just
 * that.
 */
export async function describeChatPhoto(env: Bindings, r2Key: string): Promise<string | null> {
  try {
    const object = await env.MEDIA.get(r2Key);
    if (!object) return null;
    const bytes = new Uint8Array(await object.arrayBuffer());

    const { vision, visionMaxTokens } = modelConfig(env);
    const res = await env.AI.run(vision as never, {
      messages: [{
        role: 'user',
        content: [
          { type: 'text', text: renderPrompt(PROMPTS.coachVision) },
          { type: 'image_url', image_url: { url: toDataUri(bytes) } },
        ],
      }],
      max_tokens: visionMaxTokens,
    } as never);

    const text = aiText(res).trim();
    return text ? text.slice(0, 800) : null;
  } catch (err) {
    console.error('coach photo description failed', err);
    return null;
  }
}
