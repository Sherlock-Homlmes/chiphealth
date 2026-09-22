import { Hono } from 'hono';
import foods from './foods';
import barcodes from './barcodes';
import kb from './kb';
import catalog from './catalog';
import adminUsers from './users';
import stats from './stats';
import adminWorkouts from './workouts';
import { searchPreview } from './searchPreview';
import { parseBody } from '../../lib/http';
import { z } from 'zod';
import type { AppEnv } from '../../env';

const app = new Hono<AppEnv>();

app.route('/foods', foods);
app.route('/barcode-misses', barcodes);
app.route('/kb-documents', kb);
app.route('/', catalog);        // /activity-types, /exercises, /translations
app.route('/users', adminUsers);
app.route('/stats', stats);
app.route('/workouts', adminWorkouts);

/** Retrieval debugger: BM25 vs vector vs the fused RRF ranking. */
app.post('/search/preview', async (c) => {
  const body = await parseBody(c, z.object({ q: z.string().min(1).max(200) }));
  return c.json(await searchPreview(c.get('db'), c.env, body.q));
});

export default app;
