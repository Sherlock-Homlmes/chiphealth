import type { Bindings } from '../env';

/**
 * Single place where model ids and retrieval tuning are read.
 * Defaults mirror backend/.dev.vars.example — override per environment, no code change.
 */
export function modelConfig(env: Bindings) {
  const num = (v: string | undefined, d: number) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : d;
  };

  return {
    vision: env.AI_VISION_MODEL ?? '@cf/google/gemma-4-26b-a4b-it',
    visionMaxTokens: num(env.AI_VISION_MAX_TOKENS, 4096),
    /**
     * Floor for a detected component's match confidence. Below it the food base
     * recognised nothing and the numbers would be invented, so the item is
     * dropped rather than counted into the day.
     */
    minItemConfidence: num(env.AI_MIN_ITEM_CONFIDENCE, 0.5),
    chat: env.AI_CHAT_MODEL ?? '@cf/google/gemma-4-26b-a4b-it',
    /** Reasoning models spend most of this before the answer starts. */
    chatMaxTokens: num(env.AI_CHAT_MAX_TOKENS, 4096),
    chatTemperature: num(env.AI_CHAT_TEMPERATURE, 0.4),
    embedding: env.AI_EMBEDDING_MODEL ?? '@cf/baai/bge-m3',
    embeddingDimensions: num(env.AI_EMBEDDING_DIMENSIONS, 1024),
    /**
     * Speech-to-text. Deepgram ids take the Nova-3 request shape, everything
     * else takes Whisper's — see services/speech/index.ts. Setting this back
     * to `@cf/openai/whisper-large-v3-turbo` is all it takes to switch models.
     */
    asr: env.AI_ASR_MODEL ?? '@cf/deepgram/nova-3',
    rerank: env.AI_RERANK_MODEL ?? '@cf/baai/bge-reranker-base',
    rerankEnabled: env.RERANK_ENABLED === 'true',
    promptVersion: env.PROMPT_VERSION ?? 'meal-v1',
    /** Assistant agent: model rounds per user turn before it must answer. */
    agentMaxSteps: num(env.AI_AGENT_MAX_STEPS, 6),
    /** Assistant agent: tool executions per user turn, across all rounds. */
    agentMaxToolCalls: num(env.AI_AGENT_MAX_TOOL_CALLS, 12),
    /**
     * Let the chat model reason before each agent round. Off by default: on
     * gemma-4 it multiplies a round's latency several times over for little
     * gain in tool choice. Models without the switch ignore it.
     */
    agentThinking: env.AI_AGENT_THINKING === 'true',
    /**
     * Wall-clock caps on single model calls. Workers AI occasionally queues a
     * request for most of a minute; the guard then fails open (the agent holds
     * the same rules) and an agent round gives up with the fallback reply.
     */
    guardTimeoutMs: num(env.AI_GUARD_TIMEOUT_MS, 8000),
    agentCallTimeoutMs: num(env.AI_AGENT_CALL_TIMEOUT_MS, 45000),
    /** Assistant messages a user may send per rolling minute / per rolling day. */
    agentRatePerMinute: num(env.AI_AGENT_RATE_PER_MINUTE, 6),
    agentRatePerDay: num(env.AI_AGENT_RATE_PER_DAY, 150),
  } as const;
}

export function searchConfig(env: Bindings) {
  const num = (v: string | undefined, d: number) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : d;
  };
  return {
    bm25TopK: num(env.SEARCH_BM25_TOP_K, 20),
    vectorTopK: num(env.SEARCH_VECTOR_TOP_K, 20),
    /** RRF constant: score = sum(1 / (rrfK + rank)). */
    rrfK: num(env.SEARCH_RRF_K, 60),
    finalTopK: num(env.SEARCH_FINAL_TOP_K, 8),
    minScore: num(env.SEARCH_MIN_SCORE, 0),
  } as const;
}
