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
    asr: env.AI_ASR_MODEL ?? '@cf/openai/whisper-large-v3-turbo',
    rerank: env.AI_RERANK_MODEL ?? '@cf/baai/bge-reranker-base',
    rerankEnabled: env.RERANK_ENABLED === 'true',
    promptVersion: env.PROMPT_VERSION ?? 'meal-v1',
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
