/**
 * Workers AI hands a completion back in three different shapes depending on the
 * model: `response` as text, `response` already parsed into JSON when the model
 * obeyed a JSON instruction, or an OpenAI-style `choices[]` — which every
 * reasoning model uses. Callers only ever want the text, so normalise here
 * rather than in each call site.
 */
export function aiText(res: unknown): string {
  const r = res as {
    response?: unknown;
    choices?: { message?: { content?: unknown } }[];
  };
  const raw = r?.response ?? r?.choices?.[0]?.message?.content ?? '';
  return typeof raw === 'string' ? raw : JSON.stringify(raw);
}

/**
 * Vision models take the image as a data URI inside a chat message. Chunked so a
 * multi-megabyte photo cannot blow the argument limit of `String.fromCharCode`.
 */
export function toDataUri(bytes: Uint8Array, contentType = 'image/jpeg'): string {
  let binary = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return `data:${contentType};base64,${btoa(binary)}`;
}
