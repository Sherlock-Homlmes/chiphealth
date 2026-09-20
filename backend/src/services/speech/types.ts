export interface TranscribeOptions {
  /** BCP-47 tag ("vi", "en", "vi-VN"). Each backend narrows it to what it takes. */
  language?: string;
  /** The clip's media type, e.g. `audio/webm`. Deepgram needs it; Whisper does not. */
  mimeType?: string;
}

export interface TranscribeResult {
  text: string;
  /** The model id that actually ran, for the analysis record. */
  model: string;
}
