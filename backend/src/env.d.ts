import type { Db } from './db/client';

export interface Bindings {
  DB: D1Database;
  MEDIA: R2Bucket;
  AI: Ai;
  VECTORIZE: VectorizeIndex;

  ENVIRONMENT: string;
  API_BASE_URL: string;
  ADMIN_ORIGIN: string;

  GOOGLE_CLIENT_IDS: string;
  JWT_SECRET: string;
  ACCESS_TOKEN_TTL_SECONDS?: string;
  REFRESH_TOKEN_TTL_SECONDS?: string;
  BOOTSTRAP_ADMIN_EMAILS?: string;

  AI_VISION_MODEL?: string;
  AI_CHAT_MODEL?: string;
  AI_CHAT_MAX_TOKENS?: string;
  AI_VISION_MAX_TOKENS?: string;
  AI_MIN_ITEM_CONFIDENCE?: string;
  MAX_MEAL_AUDIO_BYTES?: string;
  AI_CHAT_TEMPERATURE?: string;
  AI_EMBEDDING_MODEL?: string;
  AI_EMBEDDING_DIMENSIONS?: string;
  AI_ASR_MODEL?: string;
  AI_RERANK_MODEL?: string;
  RERANK_ENABLED?: string;

  SEARCH_BM25_TOP_K?: string;
  SEARCH_VECTOR_TOP_K?: string;
  SEARCH_RRF_K?: string;
  SEARCH_FINAL_TOP_K?: string;
  SEARCH_MIN_SCORE?: string;

  WEB_SEARCH_ENABLED?: string;
  WEB_SEARCH_PROVIDER?: string;
  WEB_SEARCH_API_KEY?: string;
  WEB_SEARCH_MAX_RESULTS?: string;

  R2_PUBLIC_URL?: string;
  R2_PUBLIC_BASE_URL?: string;
  R2_BUCKET_NAME?: string;
  UPLOAD_URL_TTL_SECONDS?: string;
  MAX_MEAL_PHOTO_BYTES?: string;
  MAX_SLEEP_CLIP_BYTES?: string;
  ORPHAN_ASSET_TTL_HOURS?: string;
  FAILED_MEAL_TTL_HOURS?: string;

  FCM_PROJECT_ID?: string;
  FCM_SERVICE_ACCOUNT_JSON?: string;

  SLEEP_DEBT_WINDOW_DAYS?: string;
  DEFAULT_TARGET_SLEEP_MINUTES?: string;
  PROMPT_VERSION?: string;
}

export interface AuthUser {
  id: string;
  email: string;
  role: 'user' | 'admin';
  timezone: string;
  locale: string;
}

export interface Variables {
  db: Db;
  user: AuthUser;
  requestId: string;
}

export interface AppEnv {
  Bindings: Bindings;
  Variables: Variables;
}
