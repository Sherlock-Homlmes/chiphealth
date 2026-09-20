export interface TranscribeOptions {
  /** The speaker's language, as stored on the account. Each backend maps it
   *  to the tag its own model takes. */
  locale?: string;
  /** The clip's media type, e.g. `audio/webm`. Deepgram needs it; Whisper does not. */
  mimeType?: string;
}

export interface TranscribeResult {
  text: string;
  /** The model id that actually ran, for the analysis record. */
  model: string;
}
