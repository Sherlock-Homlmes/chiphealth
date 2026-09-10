export type ErrorCode =
  | 'VALIDATION_ERROR' | 'UNAUTHENTICATED' | 'FORBIDDEN' | 'NOT_FOUND' | 'CONFLICT'
  | 'RATE_LIMITED' | 'UPSTREAM_AI_ERROR' | 'UPLOAD_TOO_LARGE' | 'BARCODE_NOT_FOUND'
  | 'INTERNAL';

const STATUS: Record<ErrorCode, number> = {
  VALIDATION_ERROR: 400,
  UNAUTHENTICATED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  BARCODE_NOT_FOUND: 404,
  CONFLICT: 409,
  UPLOAD_TOO_LARGE: 413,
  RATE_LIMITED: 429,
  UPSTREAM_AI_ERROR: 502,
  INTERNAL: 500,
};

export class ApiError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }

  get status(): number {
    return STATUS[this.code];
  }

  toJSON() {
    return { error: { code: this.code, message: this.message, details: this.details } };
  }
}

export const notFound = (what: string) => new ApiError('NOT_FOUND', `${what} not found`);
export const forbidden = (msg = 'Admin role required') => new ApiError('FORBIDDEN', msg);
export const unauthenticated = (msg = 'Missing or invalid token') =>
  new ApiError('UNAUTHENTICATED', msg);
