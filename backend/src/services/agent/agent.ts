import { and, eq, inArray } from 'drizzle-orm';
import { coachActions } from '../../db/schema';
import { modelConfig } from '../../config/models';
import { ApiError } from '../../lib/errors';
import { aiText, withTimeout } from '../../lib/aiText';
import { newId } from '../../lib/ids';
import { languageName } from '../../lib/language';
import { localDate, localTime, localWeekday } from '../../lib/time';
import { PROMPTS, promptSections, renderPrompt } from '../../prompts';
import { buildCoachContext, type ChatTurn, type CoachContext } from '../coach';
import {
  leaksSystemPrompt, normaliseInput, refusalFor, screenInput, type GuardResult,
} from './guard';
import { AGENT_TOOLS, ToolError, toolDefinitions, type ToolContext } from './tools';
import type { ApiCaller } from '../../lib/internalApi';
import type { Db } from '../../db/client';
import type { AuthUser, Bindings } from '../../env';

/**
 * One user turn of the assistant:
 *
 *   guard ─► context ─► ┌─ model decides ─► tool calls ─► results ─┐ ─► output check
 *                       └──────────── repeat until it answers ─────┘
 *
 * The model picks which tools to call, in what order and how many rounds; the
 * loop only executes them and feeds the results back. Budgets stop a runaway
 * turn: AI_AGENT_MAX_STEPS model calls, AI_AGENT_MAX_TOOL_CALLS tool calls and
 * MAX_PROPOSALS write proposals. Write tools never write — they file a pending
 * coach_actions row the user confirms (see tools.ts).
 */

export interface DeviceContext {
  waterMlToday?: number;
  waterTargetMl?: number;
}

export interface AgentTurnInput {
  db: Db;
  env: Bindings;
  user: AuthUser;
  caller: ApiCaller;
  conversationId: string;
  /** Earlier turns, oldest first, text only. */
  history: ChatTurn[];
  message: string;
  device: DeviceContext;
}

export interface TraceStep {
  tool: string;
  args: unknown;
  ok: boolean;
  error?: string;
  actionId?: string;
  ms: number;
}

export interface AgentTurnResult {
  reply: string;
  guard: GuardResult;
  /** Pending coach_actions rows filed this turn, in call order. */
  actionIds: string[];
  trace: TraceStep[];
  context: CoachContext | null;
  modelCalls: number;
  /** Wall time per layer, for the stored trace. */
  timings: { guardMs: number; contextMs: number; modelMs: number[] };
  outcome: 'answered' | 'blocked' | 'leak_blocked' | 'budget_exhausted' | 'model_error';
}

const MAX_PROPOSALS = 5;
/** A tool result is data for the model, not a dump: long lists are cut here. */
const TOOL_RESULT_MAX_CHARS = 8000;
const REPLY_MAX_CHARS = 6000;

const WEEKDAY_VI: Record<string, string> = {
  mon: 'Thứ Hai', tue: 'Thứ Ba', wed: 'Thứ Tư', thu: 'Thứ Năm',
  fri: 'Thứ Sáu', sat: 'Thứ Bảy', sun: 'Chủ Nhật',
};

interface ToolCall { id: string; name: string; arguments: unknown }

type AgentMessage =
  | { role: 'system' | 'user'; content: string }
  | { role: 'assistant'; content: string; tool_calls?: unknown[] }
  | { role: 'tool'; tool_call_id: string; content: string };

function parseArguments(raw: unknown): unknown {
  if (typeof raw !== 'string') return raw ?? {};
  try {
    return JSON.parse(raw);
  } catch {
    return { __unparseable: raw };
  }
}

/**
 * Workers AI answers tool calls OpenAI-style (`choices[0].message.tool_calls`)
 * on newer models and as a top-level `tool_calls` on older ones.
 */
export function parseCompletion(res: unknown): { content: string; toolCalls: ToolCall[] } {
  const r = res as {
    choices?: Array<{ message?: { content?: unknown; tool_calls?: unknown[] } }>;
    tool_calls?: unknown[];
  };
  const message = r?.choices?.[0]?.message;
  const raw = (message?.tool_calls ?? r?.tool_calls ?? []) as Array<{
    id?: string; name?: string; arguments?: unknown;
    function?: { name?: string; arguments?: unknown };
  }>;
  const toolCalls = raw.flatMap((c, i) => {
    const name = c.function?.name ?? c.name;
    if (typeof name !== 'string') return [];
    return [{
      id: c.id ?? `call_${i}_${newId().slice(-8)}`,
      name,
      arguments: parseArguments(c.function?.arguments ?? c.arguments),
    }];
  });
  const content = message
    ? (typeof message.content === 'string' ? message.content : '')
    : aiText(res);
  return { content, toolCalls };
}

/**
 * Plain text for a chat bubble: no leftover tool-call syntax (some models spill
 * it into content), no markdown the app would print literally.
 */
export function cleanReply(text: string): string {
  return text
    // Gemma-style control blocks: <|tool_call>…<tool_call|>, <|channel>thought…<channel|>
    .replace(/<\|(tool_call|channel)>[\s\S]*?<\1\|>/g, '')
    .replace(/<\|[^<>|]*\|>|<\|[a-z_]+\|>|<[a-z_]+\|>/g, '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/^([ \t]*)[*•]\s+/gm, '$1- ')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
    .slice(0, REPLY_MAX_CHARS);
}

/**
 * A reply that tells the user to tap a confirm card ("bấm Xác nhận…") on a turn
 * that filed no proposal: the model simulated the write protocol in prose. The
 * card only exists when a write tool actually returned pending_confirmation, so
 * such a reply promises UI that will never appear.
 */
export function promisesConfirmCard(text: string): boolean {
  return /(bấm|nhấn|chạm|ấn)[^\n.!?]{0,60}xác nhận/i.test(text);
}

let toolMessages: Map<string, string> | null = null;
function toolMessage(key: string, vars: Record<string, string | number> = {}): string {
  toolMessages ??= promptSections(PROMPTS.agentToolMessages);
  const template = toolMessages.get(key);
  if (template === undefined) throw new Error(`prompts/agent/tool_messages.md has no section ${key}`);
  return renderPrompt(template, vars);
}

export async function runAgentTurn(input: AgentTurnInput): Promise<AgentTurnResult> {
  const { db, env, user } = input;
  const message = normaliseInput(input.message);
  const previousReply = [...input.history].reverse().find((t) => t.role === 'assistant')?.content ?? null;

  // ---- layer 1: input guard
  const timings = { guardMs: 0, contextMs: 0, modelMs: [] as number[] };
  let mark = Date.now();
  const guard = await screenInput(env, message, previousReply);
  timings.guardMs = Date.now() - mark;
  if (guard.verdict !== 'allow') {
    return {
      reply: refusalFor(guard.verdict), guard, actionIds: [], trace: [],
      context: null, modelCalls: 0, timings, outcome: 'blocked',
    };
  }

  // ---- layer 2: context
  const tz = user.timezone;
  const now = Date.now();
  mark = Date.now();
  const context = await buildCoachContext(db, env, user.id, tz);
  timings.contextMs = Date.now() - mark;
  const canary = `CH-${crypto.randomUUID().slice(0, 8)}`;
  const device = input.device.waterMlToday == null ? {} : {
    water_today_ml: input.device.waterMlToday,
    water_target_ml: input.device.waterTargetMl ?? null,
  };

  const messages: AgentMessage[] = [
    {
      role: 'system',
      content: renderPrompt(PROMPTS.agentSystem, {
        today: localDate(now, tz),
        weekday: WEEKDAY_VI[localWeekday(now, tz)] ?? '',
        now_local: localTime(now, tz),
        timezone: tz,
        language: languageName(input.user.locale),
        canary,
        context_json: JSON.stringify(context),
        device_json: JSON.stringify(device),
      }),
    },
    ...input.history
      .filter((t) => t.role === 'user' || t.role === 'assistant')
      .map((t) => ({ role: t.role as 'user' | 'assistant', content: t.content })),
    { role: 'user', content: message },
  ];

  // ---- layer 3: the agent loop
  const {
    chat, chatMaxTokens, chatTemperature, agentMaxSteps, agentMaxToolCalls, agentThinking,
    agentCallTimeoutMs,
  } = modelConfig(env);
  const ctx: ToolContext = { caller: input.caller, user, memo: new Map() };
  const trace: TraceStep[] = [];
  const actionIds: string[] = [];
  const proposed = new Set<string>();
  let toolCallCount = 0;
  let modelCalls = 0;
  let reply: string | null = null;
  let outcome: AgentTurnResult['outcome'] = 'answered';
  // The card-promise correction runs at most once; a second offence falls
  // through and the leak-checked reply ships as-is.
  let cardFixUsed = false;

  const runTool = async (call: ToolCall): Promise<unknown> => {
    const tool = AGENT_TOOLS.get(call.name);
    if (!tool) return { error: toolMessage('unknown_tool', { name: call.name.slice(0, 60) }) };
    if (++toolCallCount > agentMaxToolCalls) return { error: toolMessage('tool_budget') };

    const parsed = tool.args.safeParse(call.arguments ?? {});
    if (!parsed.success) {
      const issues = parsed.error.issues.map((i) => `${i.path.join('.') || 'args'}: ${i.message}`).join('; ');
      trace.push({ tool: tool.name, args: call.arguments, ok: false, error: issues, ms: 0 });
      return { error: toolMessage('invalid_args', { issues }) };
    }

    const started = Date.now();
    try {
      if (tool.kind === 'read') {
        const result = await tool.run(ctx, parsed.data);
        trace.push({ tool: tool.name, args: parsed.data, ok: true, ms: Date.now() - started });
        return result;
      }

      const key = `${tool.name}:${JSON.stringify(parsed.data)}`;
      if (proposed.has(key)) return { status: 'duplicate', note: toolMessage('duplicate_proposal') };
      if (actionIds.length >= MAX_PROPOSALS) {
        return { error: toolMessage('too_many_proposals', { max: MAX_PROPOSALS }) };
      }

      const proposal = await tool.propose(ctx, parsed.data);
      const actionId = newId();
      await db.insert(coachActions).values({
        id: actionId,
        userId: user.id,
        conversationId: input.conversationId,
        tool: tool.name,
        argsJson: JSON.stringify(parsed.data),
        summary: proposal.summary,
        detailsJson: proposal.details?.length ? JSON.stringify(proposal.details) : null,
        status: 'pending',
        createdAt: Date.now(),
      });
      proposed.add(key);
      actionIds.push(actionId);
      trace.push({ tool: tool.name, args: parsed.data, ok: true, actionId, ms: Date.now() - started });
      return {
        status: 'pending_confirmation',
        action_id: actionId,
        summary: proposal.summary,
        note: toolMessage('pending_confirmation'),
      };
    } catch (err) {
      // Only messages written for the model go back to it; anything else is an
      // internal failure and stays in the log.
      const known = err instanceof ToolError || err instanceof ApiError;
      if (!known) console.error(`assistant tool ${tool.name} failed`, err);
      const error = known ? err.message : 'internal error';
      trace.push({ tool: tool.name, args: parsed.data, ok: false, error, ms: Date.now() - started });
      return { error: toolMessage('tool_failed', { error }) };
    }
  };

  const callModel = async (withTools: boolean) => {
    modelCalls++;
    const started = Date.now();
    const res = await withTimeout(env.AI.run(chat as never, {
      messages,
      ...(withTools ? { tools: toolDefinitions() } : {}),
      max_tokens: chatMaxTokens,
      temperature: chatTemperature,
      chat_template_kwargs: { enable_thinking: agentThinking },
    } as never), agentCallTimeoutMs, 'assistant model call');
    timings.modelMs.push(Date.now() - started);
    return parseCompletion(res);
  };

  try {
    for (let step = 0; step < agentMaxSteps; step++) {
      const { content, toolCalls } = await callModel(true);
      if (toolCalls.length === 0) {
        // "Bấm Xác nhận bên dưới" with nothing filed this turn: the model
        // narrated the write protocol instead of running it. One corrective
        // round makes it actually call the tool (the card then exists) or
        // answer without the phantom promise.
        if (!cardFixUsed && actionIds.length === 0 && promisesConfirmCard(cleanReply(content ?? ''))) {
          cardFixUsed = true;
          messages.push({ role: 'assistant', content: content ?? '' });
          messages.push({ role: 'user', content: renderPrompt(PROMPTS.agentCardFix) });
          continue;
        }
        reply = content;
        break;
      }
      messages.push({
        role: 'assistant',
        content: content ?? '',
        tool_calls: toolCalls.map((c) => ({
          id: c.id, type: 'function',
          function: { name: c.name, arguments: JSON.stringify(c.arguments ?? {}) },
        })),
      });
      // Sequential on purpose: two proposals in one round must not race the
      // duplicate check, and the reads are cheap in-process API calls.
      for (const call of toolCalls) {
        const result = await runTool(call);
        messages.push({
          role: 'tool',
          tool_call_id: call.id,
          content: JSON.stringify(result).slice(0, TOOL_RESULT_MAX_CHARS),
        });
      }
    }

    if (reply === null) {
      // Out of steps while still calling tools: one last round with the tools
      // still declared (the conversation holds tool turns) and an instruction
      // to answer from what it has. Tool-call syntax it spills is cleaned below.
      outcome = 'budget_exhausted';
      messages.push({ role: 'user', content: renderPrompt(PROMPTS.agentFinalize) });
      reply = (await callModel(true)).content;
      // Same phantom-card check as inside the loop, for the turn that ends
      // here: every write has failed validation, so the finalize reply can
      // still promise "bấm Xác nhận bên dưới" with no card behind it
      // (production trace 2026-09-19, create_workout ×4 invalid started_at).
      if (!cardFixUsed && actionIds.length === 0 && promisesConfirmCard(cleanReply(reply ?? ''))) {
        cardFixUsed = true;
        messages.push({ role: 'assistant', content: reply ?? '' });
        messages.push({ role: 'user', content: renderPrompt(PROMPTS.agentCardFix) });
        // Tools stay declared: with the argument error spelled out, this round
        // usually lands the call and the card exists for real.
        const fix = await callModel(true);
        if (fix.toolCalls.length === 0) {
          reply = fix.content;
        } else {
          messages.push({
            role: 'assistant',
            content: fix.content ?? '',
            tool_calls: fix.toolCalls.map((c) => ({
              id: c.id, type: 'function',
              function: { name: c.name, arguments: JSON.stringify(c.arguments ?? {}) },
            })),
          });
          for (const call of fix.toolCalls) {
            const result = await runTool(call);
            messages.push({
              role: 'tool',
              tool_call_id: call.id,
              content: JSON.stringify(result).slice(0, TOOL_RESULT_MAX_CHARS),
            });
          }
          // Whatever happened, answer now — no more tool rounds.
          messages.push({ role: 'user', content: renderPrompt(PROMPTS.agentFinalize) });
          reply = (await callModel(true)).content;
        }
      }
    }
  } catch (err) {
    console.error('assistant model call failed', err);
    outcome = 'model_error';
    reply = null;
  }

  // ---- layer 4: output check
  let text = cleanReply(reply ?? '');
  if (text && leaksSystemPrompt(text, canary)) {
    outcome = 'leak_blocked';
    text = refusalFor('injection');
    // A turn that echoed its instructions cannot be trusted with its proposals.
    if (actionIds.length) {
      await db.update(coachActions)
        .set({ status: 'cancelled', resolvedAt: Date.now(), errorMessage: 'output guard' })
        .where(and(eq(coachActions.userId, user.id), inArray(coachActions.id, actionIds)));
      actionIds.length = 0;
    }
  }
  if (!text) {
    text = actionIds.length
      ? renderPrompt(PROMPTS.agentProposalOnly, { count: actionIds.length })
      : renderPrompt(PROMPTS.agentFallback);
  }

  return { reply: text, guard, actionIds, trace, context, modelCalls, timings, outcome };
}
