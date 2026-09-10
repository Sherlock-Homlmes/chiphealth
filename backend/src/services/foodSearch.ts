import { searchConfig } from '../config/models';
import { queryVectors, parseVectorId } from './vectorize';
import type { Bindings } from '../env';

export type CandidateKind = 'food' | 'kb';

export interface Candidate {
  kind: CandidateKind;
  id: string;
  title: string;
  snippet?: string;
  /** Fused Reciprocal Rank Fusion score; higher is better. */
  score: number;
  bm25Rank?: number;
  vectorRank?: number;
  vectorScore?: number;
}

export interface HybridSearchResult {
  bm25: Array<{ kind: CandidateKind; id: string; title: string; rank: number }>;
  vector: Array<{ kind: CandidateKind; id: string; rank: number; score: number }>;
  fused: Candidate[];
}

/**
 * FTS5 MATCH is its own query language: bare user input can be a syntax error.
 * Each token is quoted and given a prefix wildcard, then OR-ed.
 */
export function toFtsQuery(input: string): string {
  const tokens = input
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((t) => t.length > 0)
    .slice(0, 12);
  if (tokens.length === 0) return '';
  return tokens.map((t) => `"${t.replace(/"/g, '""')}"*`).join(' OR ');
}

async function bm25Foods(db: D1Database, q: string, limit: number) {
  const { results } = await db
    .prepare(
      `SELECT f.id AS id, f.name AS title
         FROM foods_fts
         JOIN foods f ON f.rowid = foods_fts.rowid
        WHERE foods_fts MATCH ?1
        ORDER BY bm25(foods_fts, 4.0, 2.0, 1.0)
        LIMIT ?2`,
    )
    .bind(q, limit)
    .all<{ id: string; title: string }>();
  return results ?? [];
}

async function bm25Kb(db: D1Database, q: string, limit: number) {
  const { results } = await db
    .prepare(
      `SELECT d.id AS id, d.title AS title, substr(d.content, 1, 400) AS snippet
         FROM food_kb_fts
         JOIN food_kb_documents d ON d.rowid = food_kb_fts.rowid
        WHERE food_kb_fts MATCH ?1 AND d.is_active = 1
        ORDER BY bm25(food_kb_fts, 3.0, 1.0)
        LIMIT ?2`,
    )
    .bind(q, limit)
    .all<{ id: string; title: string; snippet: string }>();
  return results ?? [];
}

/**
 * Hybrid retrieval: BM25 (SQLite FTS5) + ANN (Vectorize), fused with Reciprocal
 * Rank Fusion — `score = Σ 1 / (k + rank)`, k = SEARCH_RRF_K, rank is 1-based.
 *
 * RRF needs only the ordering from each retriever, so BM25 scores (negative, scale
 * -free) and cosine similarities (0..1) never have to be normalised against each
 * other. No cross-encoder rerank in v1.
 */
export async function hybridFoodSearch(
  env: Bindings, query: string,
): Promise<HybridSearchResult> {
  const cfg = searchConfig(env);
  const ftsQuery = toFtsQuery(query);
  if (!ftsQuery) return { bm25: [], vector: [], fused: [] };

  const [foodRows, kbRows, vectorHits] = await Promise.all([
    bm25Foods(env.DB, ftsQuery, cfg.bm25TopK),
    bm25Kb(env.DB, ftsQuery, cfg.bm25TopK),
    queryVectors(env, query, cfg.vectorTopK).catch(() => []),
  ]);

  const titles = new Map<string, { title: string; snippet?: string }>();
  const bm25: HybridSearchResult['bm25'] = [];

  // Two BM25 lists are interleaved into one ranking so a food row and a KB chunk
  // compete on equal footing before fusion.
  const merged: Array<{ kind: CandidateKind; id: string; title: string; snippet?: string }> = [];
  const maxLen = Math.max(foodRows.length, kbRows.length);
  for (let i = 0; i < maxLen; i++) {
    const f = foodRows[i];
    if (f) merged.push({ kind: 'food', id: f.id, title: f.title });
    const k = kbRows[i];
    if (k) merged.push({ kind: 'kb', id: k.id, title: k.title, snippet: k.snippet });
  }
  merged.forEach((row, i) => {
    titles.set(`${row.kind}:${row.id}`, { title: row.title, snippet: row.snippet });
    bm25.push({ kind: row.kind, id: row.id, title: row.title, rank: i + 1 });
  });

  const vector = vectorHits.map((hit, i) => {
    const { namespace, id } = parseVectorId(hit.id);
    const kind: CandidateKind = namespace === 'kb' ? 'kb' : 'food';
    const key = `${kind}:${id}`;
    if (!titles.has(key)) {
      titles.set(key, { title: String(hit.metadata?.title ?? id) });
    }
    return { kind, id, rank: i + 1, score: hit.score };
  });

  const fusedMap = new Map<string, Candidate>();
  const contribute = (
    key: string, kind: CandidateKind, id: string, rank: number,
    field: 'bm25Rank' | 'vectorRank', vectorScore?: number,
  ) => {
    const meta = titles.get(key);
    const existing = fusedMap.get(key) ?? {
      kind, id, title: meta?.title ?? id, snippet: meta?.snippet, score: 0,
    };
    existing.score += 1 / (cfg.rrfK + rank);
    existing[field] = rank;
    if (vectorScore !== undefined) existing.vectorScore = vectorScore;
    fusedMap.set(key, existing);
  };

  for (const r of bm25) contribute(`${r.kind}:${r.id}`, r.kind, r.id, r.rank, 'bm25Rank');
  for (const r of vector) {
    contribute(`${r.kind}:${r.id}`, r.kind, r.id, r.rank, 'vectorRank', r.score);
  }

  const fused = [...fusedMap.values()]
    .filter((c) => c.score >= cfg.minScore)
    .sort((a, b) => b.score - a.score)
    .slice(0, cfg.finalTopK);

  return { bm25, vector, fused };
}
