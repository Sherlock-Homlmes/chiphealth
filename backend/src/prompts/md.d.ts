/** Prompt files are bundled as plain text (wrangler.toml [[rules]] type = "Text"). */
declare module '*.md' {
  const content: string;
  export default content;
}
