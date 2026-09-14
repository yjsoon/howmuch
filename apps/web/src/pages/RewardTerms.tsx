import { useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { api } from "../api/client";
import type { CreditCard } from "../api/types";
import { ToolProvider, type ToolCredentials } from "../components/ToolProvider";
import { compileTermsDraft, TERMS_HOSTS } from "../../../api/src/reward-tools-contract";
import { patchRewardCard, toolRequest } from "../lib/reward-tools";
import { usePlan } from "../state/plan";
import "./reward-tools.css";

export function RewardTermsPage() {
  const { planId } = usePlan();
  const [params, setParams] = useSearchParams();
  const cardId = params.get("card") ?? "";
  const [cards, setCards] = useState<CreditCard[]>([]);
  const [credentials, setCredentials] = useState<ToolCredentials>({ provider: "openai", apiKey: "", model: "" });
  const [terms, setTerms] = useState(""); const [url, setUrl] = useState("");
  const [raw, setRaw] = useState("");
  const [consent, setConsent] = useState(false);
  const [generating, setGenerating] = useState(false);
  const [draft, setDraft] = useState<ReturnType<typeof compileTermsDraft> | null>(null);
  const [busy, setBusy] = useState(false); const [error, setError] = useState(""); const [status, setStatus] = useState("");
  const controller = useRef<AbortController | null>(null);
  const card = cards.find((c) => c.id === cardId);
  useEffect(() => {
    let cancelled = false; setCards([]); setError("");
    api.rewardsTrackerSnapshot(planId).then((data) => { if (!cancelled) setCards(data.cards); }).catch(() => { if (!cancelled) setError("Could not load reward cards. Reload to try again."); });
    return () => { cancelled = true; controller.current?.abort(); };
  }, [planId]);
  useEffect(() => { controller.current?.abort(); setBusy(false); setGenerating(false); setConsent(false); setRaw(""); setDraft(null); setStatus(""); }, [cardId, planId]);
  const generate = async () => {
    if (!card || !consent) return;
    const active = new AbortController(); controller.current = active;
    setBusy(true); setGenerating(true); setError(""); setStatus(""); setDraft(null); setRaw("");
    try {
      const data = await toolRequest<{ raw: string }>(`/api/tools/reward-terms?plan_id=${encodeURIComponent(planId)}`, { ...credentials, cardType: card.type, terms, url, consent }, active.signal);
      if (active.signal.aborted) return;
      setRaw(data.raw); setDraft(compileTermsDraft(data.raw, card));
    } catch (cause) { if (!active.signal.aborted) setError(cause instanceof Error ? cause.message : "Generation failed."); }
    finally { if (!active.signal.aborted) { setBusy(false); setGenerating(false); } }
  };
  const validate = () => {
    if (!card) return;
    try { setDraft(compileTermsDraft(raw, card)); setError(""); } catch (cause) { setDraft(null); setError((cause as Error).message); }
  };
  const save = async () => {
    if (!card || !draft) return;
    setBusy(true); setError("");
    try {
      const latest = (await api.rewardsTrackerSnapshot(planId)).cards.find((c) => c.id === cardId);
      const relevant = (c: CreditCard | undefined) => c && JSON.stringify([c.type, c.earningRate, c.earningBlockSize, c.minimumSpend, c.maximumSpend, c.subcategoriesEnabled, c.subcategories, c.spendingTiers]);
      if (!latest || relevant(latest) !== relevant(card)) throw new Error("Reward rules changed since loading. Reload and generate a new review before saving.");
      await patchRewardCard(planId, cardId, draft.patch);
      setCards((current) => current.map((c) => c.id === cardId ? { ...latest, ...draft.patch } : c));
      setDraft(null); setRaw(""); setStatus("Reward rules saved. Other card fields were left untouched.");
    } catch (cause) { setError((cause as Error).message); }
    finally { setBusy(false); }
  };
  return <div className="reward-tool">
    <header className="report-header"><div><h1>Reward terms</h1></div><Link to="/settings">Settings</Link></header>
    <p>Turn bank terms into a draft. Review every rate, spend cap and exclusion before saving. No ledger data or account identifiers are sent to the provider.</p>
    <label>Existing reward card<select disabled={busy} value={cardId} onChange={(event) => setParams({ card: event.target.value })}><option value="">Select a card…</option>{cards.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
    {cardId && cards.length > 0 && !card && <p role="alert">This card is unavailable.</p>}
    <form onSubmit={(event) => { event.preventDefault(); void generate(); }}>
      <fieldset disabled={busy}><ToolProvider value={credentials} onChange={(value) => { setCredentials(value); setConsent(false); }} />
        <label>Terms URL (optional)<input type="url" value={url} maxLength={2048} onChange={(event) => setUrl(event.target.value)} placeholder="https://www.dbs.com.sg/…" /></label>
        <details><summary>Supported URLs and privacy</summary><p>HTTPS only on {TERMS_HOSTS.join(", ")}. Redirects and PDFs are rejected. Paste their text below instead. Only the supplied terms and card type go to your provider; do not paste secrets or ledger data.</p></details>
        <label>Pasted terms and/or instructions<textarea value={terms} maxLength={80000} rows={8} onChange={(event) => setTerms(event.target.value)} placeholder="Paste reward rates, eligible spending, caps, exclusions, or your instructions…" /></label>
        <label className="tool-consent"><input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />I consent to sending these terms/instructions and the card reward type to {credentials.provider} using my key. Provider charges and retention policies apply.</label>
        <button disabled={!card || !consent || (!terms.trim() && !url.trim())} className="primary-button">Generate review draft</button>
      </fieldset>
    </form>
    {generating && <button onClick={() => { controller.current?.abort(); setBusy(false); setGenerating(false); setRaw(""); setDraft(null); setStatus("Generation cancelled. An already-sent request may still be billed."); }}>Cancel generation</button>}
    {busy && <p role="status">Working…</p>}
    {error && <p className="tool-error" role="alert">{error}</p>}{status && <p role="status">{status} <Link to={`/rewards/${cardId}`}>Return to card</Link></p>}
    {raw && <section className="report-section"><h2>Review draft</h2>
      <p>Saving replaces categories and any explicitly proposed limits/tiers. Unknown limits preserve existing values. Restrictions in notes are not automatic merchant rules and are not stored on the card.</p>
      <details><summary>Edit draft JSON</summary><label>Draft JSON<textarea rows={14} value={raw} disabled={busy} onChange={(event) => { setRaw(event.target.value); setDraft(null); }} /></label><button onClick={validate} disabled={busy}>Validate edits</button></details>
      {draft && <><div className="tool-table"><table><thead><tr><th>Category / flag</th><th>Rate</th><th>Block</th><th>Min spend</th><th>Max spend</th></tr></thead><tbody>{draft.patch.subcategories.map((c) => <tr key={c.id}><td>{c.name} <small>{c.flagColor === "unflagged" ? "default" : c.flagColor}{c.excludeFromRewards ? " · excluded" : ""}</small></td><td>{c.rewardValue}{card?.type === "cashback" ? "%" : " mi/$"}</td><td>{c.milesBlockSize ?? "—"}</td><td>{c.minimumSpend ?? "—"}</td><td>{c.maximumSpend ?? "—"}</td></tr>)}</tbody></table></div>
        <p>Card rate: {draft.patch.earningRate ?? "unchanged"} · Block: {draft.patch.earningBlockSize ?? "unchanged"} · Min spend: {draft.patch.minimumSpend ?? "unchanged"} · Max spend: {draft.patch.maximumSpend ?? "unchanged"}</p>
        <h3>Spending tiers</h3><pre>{JSON.stringify(draft.patch.spendingTiers ?? card?.spendingTiers ?? [], null, 2)}</pre>
        {draft.notes.length > 0 && <ul>{draft.notes.map((note, i) => <li key={i}>{note}</li>)}</ul>}
      </>}
      <button className="primary-button" disabled={!draft || busy} onClick={() => void save()}>Save reviewed reward rules</button>
    </section>}
  </div>;
}
