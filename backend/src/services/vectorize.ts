import { modelConfig } from '../config/models';
import type { Bindings } from '../env';

export interface VectorHit { id: string; score: number; metadata?: Record<string, unknown> }

/** Embed one or more texts with the configured Workers AI embedding model. */
export async function embed(env: Bindings, texts: string[]): Promise<number[][]> {
  if (texts.length === 0) return [];
  const { embedding } = modelConfig(env);
  const res = (await env.AI.run(embedding as never, { text: texts } as never)) as
    unknown as { data: number[][] };
  return res.data;
}

export async function embedOne(env: Bindings, text: string): Promise<number[]> {
  const [vec] = await embed(env, [text]);
  if (!vec) throw new Error('Embedding model returned no vector');
  return vec;
}

export type VectorNamespace = 'food' | 'kb';

/**
 * Vector ids are namespaced so one index can hold both the food catalog and the
 * KB corpus: `food:<foodId>` / `kb:<documentId>`.
 */
export const vectorId = (ns: VectorNamespace, id: string) => `${ns}:${id}`;
export const parseVectorId = (vid: string) => {
  const idx = vid.indexOf(':');
  return { namespace: vid.slice(0, idx) as VectorNamespace, id: vid.slice(idx + 1) };
};

export async function upsertVector(
  env: Bindings,
  ns: VectorNamespace,
  id: string,
  text: string,
  metadata: Record<string, string | number | boolean> = {},
): Promise<string> {
  const values = await embedOne(env, text);
  const vid = vectorId(ns, id);
  await env.VECTORIZE.upsert([{ id: vid, values, metadata: { ...metadata, namespace: ns } }]);
  return vid;
}

export async function deleteVectors(env: Bindings, ids: string[]): Promise<void> {
  if (ids.length) await env.VECTORIZE.deleteByIds(ids);
}

export async function queryVectors(
  env: Bindings, text: string, topK: number, namespace?: VectorNamespace,
): Promise<VectorHit[]> {
  const values = await embedOne(env, text);
  const res = await env.VECTORIZE.query(values, {
    topK,
    returnMetadata: 'all',
    ...(namespace ? { filter: { namespace } } : {}),
  });
  return res.matches.map((m) => ({
    id: m.id,
    score: m.score,
    metadata: m.metadata as Record<string, unknown> | undefined,
  }));
}
