import { inArray } from 'drizzle-orm';
import { foods, foodKbDocuments } from '../../db/schema';
import { hybridFoodSearch } from '../../services/foodSearch';
import { searchConfig } from '../../config/models';
import type { Db } from '../../db/client';
import type { Bindings } from '../../env';

type Corpus = 'foods' | 'food_kb_documents';

const corpusOf = (kind: 'food' | 'kb'): Corpus =>
  kind === 'kb' ? 'food_kb_documents' : 'foods';

/**
 * Retrieval debugger for the admin panel: the BM25 list, the vector list and the
 * fused RRF list side by side, each row carrying its rank in every retriever so
 * the effect of a tuning change is visible at a glance.
 */
export async function searchPreview(db: Db, env: Bindings, q: string) {
  const started = Date.now();
  const raw = await hybridFoodSearch(env, q);
  const cfg = searchConfig(env);

  // Titles for vector-only hits are not in the BM25 lists, so resolve them here.
  const foodIds = new Set<string>();
  const kbIds = new Set<string>();
  for (const row of [...raw.bm25, ...raw.vector, ...raw.fused]) {
    (row.kind === 'kb' ? kbIds : foodIds).add(row.id);
  }

  const [foodRows, kbRows] = await Promise.all([
    foodIds.size
      ? db.select({ id: foods.id, name: foods.name, brand: foods.brand })
          .from(foods).where(inArray(foods.id, [...foodIds]))
      : Promise.resolve([]),
    kbIds.size
      ? db.select({ id: foodKbDocuments.id, title: foodKbDocuments.title, content: foodKbDocuments.content })
          .from(foodKbDocuments).where(inArray(foodKbDocuments.id, [...kbIds]))
      : Promise.resolve([]),
  ]);

  const titles = new Map<string, { title: string; snippet: string | null }>();
  for (const f of foodRows) {
    titles.set(`food:${f.id}`, {
      title: [f.name, f.brand].filter(Boolean).join(' · '),
      snippet: null,
    });
  }
  for (const d of kbRows) {
    titles.set(`kb:${d.id}`, { title: d.title, snippet: d.content.slice(0, 240) });
  }

  const describe = (kind: 'food' | 'kb', id: string, fallback: string) =>
    titles.get(`${kind}:${id}`) ?? { title: fallback, snippet: null };

  return {
    q,
    rrfK: cfg.rrfK,
    bm25: raw.bm25.map((r) => {
      const meta = describe(r.kind, r.id, r.title);
      return {
        id: r.id,
        corpus: corpusOf(r.kind),
        title: meta.title,
        snippet: meta.snippet,
        rank: r.rank,
        // BM25 exposes no comparable absolute score here — rank is the signal.
        score: null,
      };
    }),
    vector: raw.vector.map((r) => {
      const meta = describe(r.kind, r.id, r.id);
      return {
        id: r.id,
        corpus: corpusOf(r.kind),
        title: meta.title,
        snippet: meta.snippet,
        rank: r.rank,
        score: Math.round(r.score * 10000) / 10000,
      };
    }),
    fused: raw.fused.map((r, i) => {
      const meta = describe(r.kind, r.id, r.title);
      return {
        id: r.id,
        corpus: corpusOf(r.kind),
        title: meta.title,
        snippet: meta.snippet,
        rank: i + 1,
        fusedScore: Math.round(r.score * 100000) / 100000,
        bm25Rank: r.bm25Rank ?? null,
        vectorRank: r.vectorRank ?? null,
      };
    }),
    tookMs: Date.now() - started,
  };
}
