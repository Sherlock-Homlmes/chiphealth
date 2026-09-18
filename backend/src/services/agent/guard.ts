import { modelConfig } from '../../config/models';
import { aiText, withTimeout } from '../../lib/aiText';
import { PROMPTS, renderPrompt } from '../../prompts';
import { extractJson } from '../mealAnalysis';
import type { Bindings } from '../../env';

/**
 * Layer 1 of the assistant: decide whether a message reaches the agent at all.
 *
 *   1. normalise   — NFKC, strip zero-width / bidi characters that hide text
 *   2. heuristics  — known injection phrasings (EN + VI, diacritics folded);
 *                    a hit is final, no model call
 *   3. classifier  — one tool-less model call with prompts/agent/guard.md that
 *                    labels the message allow / off_topic / injection
 *
 * The classifier fails open: if it errors, times out (AI_GUARD_TIMEOUT_MS) or
 * answers garbage the message goes
 * through, because the agent's own system prompt carries the same scope and
 * injection rules. Failing closed would lock users out whenever the model has
 * a bad minute.
 */

export type Verdict = 'allow' | 'off_topic' | 'injection';

export interface GuardResult {
  verdict: Verdict;
  reason: string;
  /** Which layer decided: a pattern hit, the model, or a fail-open pass. */
  by: 'heuristic' | 'classifier' | 'fail_open';
}

const INVISIBLE = /[\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/g;

export function normaliseInput(text: string): string {
  return text.normalize('NFKC').replace(INVISIBLE, '').trim();
}

/** Lower case, no Vietnamese diacritics, single spaces — what the patterns match on. */
export function foldForMatch(text: string): string {
  return text.toLowerCase()
    .normalize('NFD').replace(/\p{M}/gu, '')
    .replace(/đ/g, 'd')
    .replace(/\s+/g, ' ');
}

/**
 * Phrasings with no innocent reading in a health chat. Kept narrow on purpose:
 * "bỏ qua bữa sáng" (skip breakfast) must not trip anything, which is why every
 * Vietnamese pattern needs an instruction-ish noun after the verb.
 */
const INJECTION_PATTERNS: RegExp[] = [
  /\b(ignore|disregard|forget|override)\b.{0,30}\b(previous|prior|above|earlier|all|your|the)\b.{0,20}\b(instructions?|prompts?|rules?|guidelines?|directives?)\b/,
  /\b(system|developer|hidden|initial)\s+(prompt|message|instructions?)\b/,
  /\b(reveal|show|print|repeat|leak|output|dump)\b.{0,40}\b(prompt|instructions?|rules|tools?)\b/,
  /\byou are (now|no longer)\b/,
  /\b(jailbreak|jailbroken|dan mode|developer mode|god mode|do anything now)\b/,
  /\bact as\b.{0,30}\b(unrestricted|unfiltered|uncensored|without (any )?(rules|limits|restrictions))\b/,
  /\[\/?inst\]|<\|im_(start|end)\|>|<\/?\s*system\s*>|<<\s*sys\s*>>|^\s*#+\s*system\b/m,
  // "bỏ qua mọi hướng dẫn", "quên hết chỉ dẫn trước đó" — but not "bỏ qua quy
  // tắc ăn kiêng một hôm" or "đã quen với quy tắc": the noun has to be framed
  // as *the assistant's* instructions, by a quantifier or a qualifier.
  /\b(bo qua|phot lo|vo hieu hoa|khong can tuan theo|quen (het|di|sach))\b.{0,12}\b(moi|tat ca|toan bo|het)\b.{0,10}\b(huong dan|chi dan|chi thi|menh lenh)\b/,
  /\b(bo qua|phot lo|vo hieu hoa|khong can tuan theo|quen (het|di|sach))\b.{0,25}\b(huong dan|chi dan|chi thi|menh lenh|quy tac|luat)\b.{0,15}\b(truoc do|o tren|phia tren|he thong|cua ban|ban dau|duoc giao)\b/,
  /\b(tiet lo|in ra|hien thi|cho (toi|minh|tao|em|anh) xem|lap lai|dich)\b.{0,40}\b(prompt|lenh he thong|chi dan he thong|huong dan he thong|cau hinh|ma noi bo)\b/,
  /\b(che do|mode)\s+(developer|nha phat trien|khong gioi han|khong kiem duyet)\b/,
  /\b(gia vo|dong vai|nhap vai|gia su)\b.{0,40}\b(khong (co )?(gioi han|kiem duyet|rang buoc|quy tac))\b/,
  /\b(du lieu|thong tin|bua an|lich su)\b.{0,20}\b(nguoi dung|user|tai khoan) khac\b/,
];

export function matchesInjectionPattern(text: string): boolean {
  const folded = foldForMatch(text);
  return INJECTION_PATTERNS.some((re) => re.test(folded));
}

/** The message must not be able to close the tags the guard prompt frames it with. */
function defuseTags(text: string): string {
  return text.replace(/<\s*\/?\s*(message|previous)\s*>/gi, '');
}

export async function screenInput(
  env: Bindings, message: string, previousReply: string | null,
): Promise<GuardResult> {
  if (matchesInjectionPattern(message)) {
    return { verdict: 'injection', reason: 'pattern', by: 'heuristic' };
  }

  const { chat, chatMaxTokens, guardTimeoutMs } = modelConfig(env);
  try {
    const res = await withTimeout(env.AI.run(chat as never, {
      messages: [
        { role: 'system', content: renderPrompt(PROMPTS.agentGuard) },
        {
          role: 'user',
          content: renderPrompt(PROMPTS.agentGuardInput, {
            previous: defuseTags((previousReply ?? '').slice(0, 600)),
            message: defuseTags(message),
          }),
        },
      ],
      max_tokens: Math.min(chatMaxTokens, 512),
      temperature: 0,
      // A one-line label needs no chain of thought; with it on, this call
      // costs seconds on every message. Models without the switch ignore it.
      chat_template_kwargs: { enable_thinking: false },
    } as never), guardTimeoutMs, 'assistant guard');
    const parsed = extractJson(aiText(res)) as { verdict?: unknown; reason?: unknown };
    const verdict = parsed.verdict;
    if (verdict === 'allow' || verdict === 'off_topic' || verdict === 'injection') {
      return { verdict, reason: String(parsed.reason ?? '').slice(0, 200), by: 'classifier' };
    }
  } catch (err) {
    console.warn('assistant guard failed open', err);
  }
  return { verdict: 'allow', reason: 'classifier unavailable', by: 'fail_open' };
}

/** Canned reply for a blocked message — no model call, nothing to steer. */
export function refusalFor(verdict: Exclude<Verdict, 'allow'>): string {
  return renderPrompt(verdict === 'off_topic' ? PROMPTS.agentRefusalOffTopic : PROMPTS.agentRefusalInjection);
}

/**
 * Last layer, on the way out: the per-turn canary sits in the system prompt, so
 * seeing it in a reply means the prompt is being echoed. Distinctive headings of
 * the system prompt count too, for a model that paraphrased around the canary.
 */
const SYSTEM_PROMPT_MARKERS = ['BẢO MẬT & CHỐNG PROMPT INJECTION', '<user_data>', 'Mã nội bộ:'];

export function leaksSystemPrompt(reply: string, canary: string): boolean {
  if (reply.includes(canary)) return true;
  return SYSTEM_PROMPT_MARKERS.some((m) => reply.includes(m));
}
