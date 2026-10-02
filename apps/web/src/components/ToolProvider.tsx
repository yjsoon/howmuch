export type ToolCredentials = { provider: string; model: string; apiKey: string };
export function ToolProvider({ value, onChange, statement = false }: { value: ToolCredentials; onChange: (value: ToolCredentials) => void; statement?: boolean }) {
  return <div className="tool-provider">
    <label>Provider<select value={value.provider} onChange={(event) => onChange({ provider: event.target.value, model: "", apiKey: "" })}>
      <option value="openai">OpenAI</option><option value="openrouter">OpenRouter</option>
      {statement ? <option value="gemini">Google Gemini</option> : <option value="opencode">OpenCode</option>}
    </select></label>
    <label>Exact model ID<input required value={value.model} maxLength={160} placeholder={value.provider === "gemini" ? "gemini-3-flash-preview" : value.provider === "openrouter" ? "openai/gpt-4o-mini" : value.provider === "opencode" ? "deepseek-v4-flash" : "gpt-4o-mini"} onChange={(event) => onChange({ ...value, model: event.target.value })} /></label>
    <label>Your provider API key<input required type="password" autoComplete="off" value={value.apiKey} maxLength={512} onChange={(event) => onChange({ ...value, apiKey: event.target.value })} /></label>
    <p className="diagnostic-note">Keys stay in page memory and are sent only through Halation to the chosen provider. No model or provider fallback. Leaving this page clears the key. Provider charges and retention policies apply.</p>
  </div>;
}
