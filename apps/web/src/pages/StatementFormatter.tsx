import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { ToolProvider, type ToolCredentials } from "../components/ToolProvider";
import { ROW_FIELDS, statementCsv, type StatementRow } from "../../../api/src/reward-tools-contract";
import { mergeStatementImages, readStatementImage, toolRequest, type StatementImage } from "../lib/reward-tools";
import { usePlan } from "../state/plan";
import "./reward-tools.css";

export function StatementFormatterPage() {
  const { planId } = usePlan();
  const [credentials, setCredentials] = useState<ToolCredentials>({ provider: "gemini", model: "", apiKey: "" });
  const [images, setImages] = useState<StatementImage[]>([]); const [rows, setRows] = useState<StatementRow[]>([]);
  const [consent, setConsent] = useState(false); const [append, setAppend] = useState(true); const [instructions, setInstructions] = useState("");
  const [busy, setBusy] = useState(false); const [loading, setLoading] = useState(false); const [error, setError] = useState(""); const [status, setStatus] = useState("");
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);
  const addImages = async (files: FileList | File[]) => {
    if (busy || loading) return;
    setLoading(true); setError("");
    try {
      const next: StatementImage[] = [];
      for (const file of Array.from(files).slice(0, 20)) next.push(await readStatementImage(file));
      setImages((current) => mergeStatementImages(current, next));
      setConsent(false); setStatus("Images ready. Duplicate image content is kept only once; maximum 20 images.");
    } catch (cause) { setError((cause as Error).message); }
    finally { setLoading(false); }
  };
  const extract = async () => {
    const active = new AbortController(); controller.current = active; setBusy(true); setError("");
    const extracted: StatementRow[] = [];
    const initial = append ? rows : [];
    try {
      for (let i = 0; i < images.length; i++) {
        if (active.signal.aborted) break;
        setStatus(`Extracting image ${i + 1} of ${images.length}…`);
        const data = await toolRequest<{ rows: StatementRow[] }>(`/api/tools/statement-formatter?plan_id=${encodeURIComponent(planId)}`, { ...credentials, image: images[i].data, consent, instructions }, active.signal);
        if (active.signal.aborted) break;
        extracted.push(...data.rows); setRows([...initial, ...extracted]);
      }
      if (!active.signal.aborted) setStatus(`Extraction complete: ${extracted.length} rows. Review dates and amounts before exporting.`);
    } catch (cause) { if (!active.signal.aborted) setError((cause as Error).message); }
    finally { setBusy(false); }
  };
  const cancel = () => { controller.current?.abort(); setStatus("Cancelled. Completed rows retained; no further images will be sent. An already-sent request may still be billed."); };
  const download = () => {
    try {
      const csv = statementCsv(rows); const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
      const anchor = document.createElement("a"); anchor.href = url; anchor.download = "statement.csv"; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); setError("");
    } catch { setError("Correct each date (YYYY-MM-DD) and amount (digits and decimal cents, one flow per row) before exporting."); }
  };
  return <div className="reward-tool">
    <header className="report-header"><div><h1>Statement formatter</h1></div><Link to="/settings">Settings</Link></header>
    <p>Extract images into editable CSV rows. Nothing is imported into your ledger. Images, rows and provider keys are held only in this page’s memory.</p>
    <form onSubmit={(event) => { event.preventDefault(); void extract(); }}><fieldset disabled={busy || loading}>
      <ToolProvider value={credentials} statement onChange={(value) => { setCredentials(value); setConsent(false); }} />
      <div className="tool-drop" onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); void addImages(event.dataTransfer.files); }}><label>Select or drop statement images<input type="file" accept="image/png,image/jpeg,image/webp" multiple onChange={(event) => { if (event.target.files) void addImages(event.target.files); event.target.value = ""; }} /></label><small>PNG, JPEG or WebP · 5 MiB each · up to 20 images · content deduplicated</small></div>
      {images.length > 0 && <ul className="tool-images">{images.map((image) => <li key={image.id}><img src={image.data} alt={`Preview of ${image.name}`} /><span>{image.name}</span><button type="button" aria-label={`Remove ${image.name}`} onClick={() => { setImages((current) => current.filter((i) => i.id !== image.id)); setConsent(false); }}>Remove</button></li>)}</ul>}
      <label>Extraction instructions (optional)<textarea rows={2} maxLength={10000} value={instructions} onChange={(event) => setInstructions(event.target.value)} placeholder="For example: dates use DD/MM/YYYY" /></label>
      <label>Existing rows<select value={append ? "append" : "replace"} onChange={(event) => setAppend(event.target.value === "append")}><option value="append">Append extracted rows</option><option value="replace">Replace rows when the first image succeeds</option></select></label>
      <label className="tool-consent"><input type="checkbox" checked={consent} onChange={(event) => setConsent(event.target.checked)} />I consent to sending these statement images and instructions to {credentials.provider} using my key. They may contain sensitive financial data. Provider charges and retention policies apply.</label>
      <button className="primary-button" disabled={!consent || images.length === 0}>Extract {images.length || ""} images</button>
    </fieldset></form>
    {busy && <button onClick={cancel}>Cancel extraction</button>}
    <p role="status">{loading ? "Reading images…" : status}</p>{error && <p className="tool-error" role="alert">{error}</p>}
    <section className="report-section"><h2>Review transactions ({rows.length})</h2><p>Repeated transactions are not automatically deleted: identical purchases can be legitimate. Edit or remove rows before downloading.</p>
      <div className="tool-table"><table><thead><tr>{ROW_FIELDS.map((key) => <th key={key}>{key[0].toUpperCase() + key.slice(1)}</th>)}<th>Remove</th></tr></thead><tbody>{rows.map((row, index) => <tr key={index}>{ROW_FIELDS.map((key) => <td key={key}><input aria-label={`${key} row ${index + 1}`} disabled={busy} type={key === "date" ? "date" : "text"} value={row[key]} onChange={(event) => setRows((current) => current.map((r, i) => i === index ? { ...r, [key]: event.target.value } : r))} /></td>)}<td><button disabled={busy} onClick={() => setRows((current) => current.filter((_, i) => i !== index))} aria-label={`Remove row ${index + 1}`}>×</button></td></tr>)}</tbody></table></div>
      <div className="tool-actions"><button disabled={busy} onClick={() => setRows((current) => [...current, { date: "", payee: "", memo: "", outflow: "", inflow: "" }])}>Add row</button><button className="primary-button" disabled={busy || rows.length === 0} onClick={download}>Download CSV</button></div>
    </section>
  </div>;
}
