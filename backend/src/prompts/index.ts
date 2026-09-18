/**
 * Every prompt the backend sends to a model lives in a .md file next to this
 * one, bundled as text (wrangler.toml [[rules]] type = "Text"). Code imports
 * them from here and fills the {{placeholders}} with renderPrompt — never an
 * inline template string, so a wording change is a prompt-file diff and
 * nothing else. See _template.md for the file conventions.
 */
import agentSystem from './agent/system.md';
import agentGuard from './agent/guard.md';
import agentGuardInput from './agent/guard_input.md';
import agentTools from './agent/tools.md';
import agentRefusalOffTopic from './agent/refusal_off_topic.md';
import agentRefusalInjection from './agent/refusal_injection.md';
import agentFallback from './agent/fallback.md';
import agentFinalize from './agent/finalize.md';
import agentProposalOnly from './agent/proposal_only.md';
import agentToolMessages from './agent/tool_messages.md';
import coachSystem from './coach/system.md';
import coachContext from './coach/context.md';
import coachInsights from './coach/insights.md';
import mealVision from './meal/vision.md';
import mealVisionNote from './meal/vision_note.md';
import mealSpeech from './meal/speech.md';
import mealEstimateSystem from './meal/estimate_system.md';
import mealEstimateUser from './meal/estimate_user.md';
import nutritionMealPlan from './nutrition/meal_plan.md';

export const PROMPTS = {
  agentSystem,
  agentGuard,
  agentGuardInput,
  agentTools,
  agentRefusalOffTopic,
  agentRefusalInjection,
  agentFallback,
  agentFinalize,
  agentProposalOnly,
  agentToolMessages,
  coachSystem,
  coachContext,
  coachInsights,
  mealVision,
  mealVisionNote,
  mealSpeech,
  mealEstimateSystem,
  mealEstimateUser,
  nutritionMealPlan,
} as const;

export type PromptVars = Record<string, string | number>;

/** Author notes in `<!-- -->` are for people reading the file, not for the model. */
function stripNotes(template: string): string {
  return template.replace(/<!--[\s\S]*?-->/g, '').trim();
}

/**
 * Fills `{{name}}` placeholders in one pass: a substituted value is never
 * scanned again, so user text containing "{{...}}" cannot pull in another
 * variable. A placeholder with no value throws — a half-rendered prompt would
 * otherwise reach the model and fail quietly.
 */
export function renderPrompt(template: string, vars: PromptVars = {}): string {
  return stripNotes(template).replace(/\{\{\s*(\w+)\s*\}\}/g, (_, key: string) => {
    if (!Object.prototype.hasOwnProperty.call(vars, key)) {
      throw new Error(`Prompt variable {{${key}}} has no value`);
    }
    return String(vars[key]);
  });
}

/** A file made of `## key` sections (agent/tools.md) as key → body. */
export function promptSections(template: string): Map<string, string> {
  const out = new Map<string, string>();
  let key: string | null = null;
  let lines: string[] = [];
  const flush = () => {
    if (key) out.set(key, lines.join('\n').trim());
  };
  for (const line of stripNotes(template).split('\n')) {
    const heading = /^##\s+(\S+)\s*$/.exec(line);
    if (heading) {
      flush();
      key = heading[1]!;
      lines = [];
    } else {
      lines.push(line);
    }
  }
  flush();
  return out;
}
