import { useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api, getApiToken, setApiToken, useApi } from "../api/client";
import type { Category, CategoryGroup, CsvImportRow, ImportResult } from "../api/types";
import { YnabImportForm } from "../components/Onboarding";
import { usePlan } from "../state/plan";

const SECTIONS = [
  { id: "categories", label: "Categories" },
  { id: "payees", label: "Payees" },
  { id: "import", label: "Import" },
  { id: "connection", label: "Connection" },
] as const;

type SectionId = (typeof SECTIONS)[number]["id"];

export function ManagePage() {
  const [params, setParams] = useSearchParams();
  const requested = params.get("section") as SectionId | null;
  const section: SectionId = SECTIONS.some((entry) => entry.id === requested) ? (requested as SectionId) : "categories";

  return (
    <>
      <div className="report-header">
        <h1>Manage</h1>
        <div className="headline-row">
          <div className="segmented" role="group" aria-label="Manage section">
            {SECTIONS.map((entry) => (
              <button
                key={entry.id}
                type="button"
                className={section === entry.id ? "segment segment-active" : "segment"}
                onClick={() => {
                  const next = new URLSearchParams(params);
                  next.set("section", entry.id);
                  setParams(next, { replace: true });
                }}
              >
                {entry.label}
              </button>
            ))}
          </div>
        </div>
      </div>
      {section === "categories" && <CategoriesSection />}
      {section === "payees" && <PayeesSection />}
      {section === "import" && <ImportSection />}
      {section === "connection" && <ConnectionSection />}
    </>
  );
}

function CategoriesSection() {
  const { planId, categoryGroups, categories, reload } = usePlan();
  const [error, setError] = useState<string | null>(null);
  const [newGroupName, setNewGroupName] = useState("");
  const visibleGroups = useMemo(
    () => categoryGroups.filter((group) => !group.deleted),
    [categoryGroups],
  );

  const run = async (action: () => Promise<unknown>) => {
    setError(null);
    try {
      await action();
      reload();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  return (
    <>
      {error && (
        <div className="status-panel status-panel-error">
          <p className="status-title">That change did not save.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}
      {visibleGroups.map((group) => (
        <GroupCard key={group.id} group={group} planId={planId} allCategories={categories} onRun={run} />
      ))}
      <section className="report-section">
        <div className="section-heading">
          <span className="section-title">Add category group</span>
        </div>
        <form
          className="inline-form manage-form"
          onSubmit={(event) => {
            event.preventDefault();
            const name = newGroupName.trim();
            if (name) {
              run(() => api.createCategoryGroup(planId, name));
              setNewGroupName("");
            }
          }}
        >
          <input
            value={newGroupName}
            onChange={(event) => setNewGroupName(event.target.value)}
            placeholder="Group name"
            aria-label="New group name"
            required
          />
          <button type="submit" disabled={!newGroupName.trim()}>
            Add group
          </button>
        </form>
      </section>
    </>
  );
}

function GroupCard({
  group,
  planId,
  allCategories,
  onRun,
}: {
  group: CategoryGroup;
  planId: string;
  allCategories: Category[];
  onRun: (action: () => Promise<unknown>) => void;
}) {
  const [renaming, setRenaming] = useState(false);
  const [name, setName] = useState(group.name);
  const [newCategory, setNewCategory] = useState("");
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [reassignTo, setReassignTo] = useState("");
  const reassignOptions = allCategories.filter(
    (category) => category.category_group_id !== group.id && !category.deleted && !category.hidden,
  );

  return (
    <section className="report-section">
      <div className="section-heading">
        {renaming ? (
          <form
            className="inline-form"
            onSubmit={(event) => {
              event.preventDefault();
              onRun(() => api.updateCategoryGroup(planId, group.id, { name: name.trim() }));
              setRenaming(false);
            }}
          >
            <input value={name} onChange={(event) => setName(event.target.value)} autoFocus required />
            <button type="submit">Save</button>
            <button type="button" className="text-button" onClick={() => setRenaming(false)}>
              Cancel
            </button>
          </form>
        ) : (
          <>
            <span className="section-title">
              {group.name}
              {group.hidden ? <span className="muted"> · hidden</span> : null}
            </span>
            <span className="section-meta">
              <button type="button" className="text-button" onClick={() => setRenaming(true)}>
                Rename
              </button>
              <button
                type="button"
                className="text-button"
                onClick={() => onRun(() => api.updateCategoryGroup(planId, group.id, { hidden: !group.hidden }))}
              >
                {group.hidden ? "Unhide" : "Hide"}
              </button>
              <button type="button" className="text-button danger" onClick={() => setConfirmingDelete((v) => !v)}>
                Delete
              </button>
            </span>
          </>
        )}
      </div>

      {confirmingDelete && (
        <form
          className="inline-form confirm-strip"
          onSubmit={(event) => {
            event.preventDefault();
            onRun(() => api.deleteCategoryGroup(planId, group.id, reassignTo || undefined));
            setConfirmingDelete(false);
          }}
        >
          <span className="muted">Delete “{group.name}” and move its transactions to:</span>
          <select value={reassignTo} onChange={(event) => setReassignTo(event.target.value)}>
            <option value="">Uncategorised</option>
            {reassignOptions.map((category) => (
              <option key={category.id} value={category.id}>
                {category.name}
              </option>
            ))}
          </select>
          <button type="submit" className="danger">
            Delete group
          </button>
          <button type="button" className="text-button" onClick={() => setConfirmingDelete(false)}>
            Keep it
          </button>
        </form>
      )}

      <ul className="manage-list">
        {group.categories
          .filter((category) => !category.deleted)
          .map((category) => (
            <CategoryLine
              key={category.id}
              category={category}
              planId={planId}
              reassignOptions={allCategories.filter((entry) => entry.id !== category.id && !entry.deleted)}
              onRun={onRun}
            />
          ))}
      </ul>

      <form
        className="inline-form manage-form"
        onSubmit={(event) => {
          event.preventDefault();
          const categoryName = newCategory.trim();
          if (categoryName) {
            onRun(() => api.createCategory(planId, { name: categoryName, category_group_id: group.id }));
            setNewCategory("");
          }
        }}
      >
        <input
          value={newCategory}
          onChange={(event) => setNewCategory(event.target.value)}
          placeholder="New category"
          aria-label={`New category in ${group.name}`}
        />
        <button type="submit" disabled={!newCategory.trim()}>
          Add
        </button>
      </form>
    </section>
  );
}

function CategoryLine({
  category,
  planId,
  reassignOptions,
  onRun,
}: {
  category: Category;
  planId: string;
  reassignOptions: Category[];
  onRun: (action: () => Promise<unknown>) => void;
}) {
  const [renaming, setRenaming] = useState(false);
  const [name, setName] = useState(category.name);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const [reassignTo, setReassignTo] = useState("");

  if (renaming) {
    return (
      <li>
        <form
          className="inline-form"
          onSubmit={(event) => {
            event.preventDefault();
            onRun(() => api.updateCategory(planId, category.id, { name: name.trim() }));
            setRenaming(false);
          }}
        >
          <input value={name} onChange={(event) => setName(event.target.value)} autoFocus required />
          <button type="submit">Save</button>
          <button type="button" className="text-button" onClick={() => setRenaming(false)}>
            Cancel
          </button>
        </form>
      </li>
    );
  }

  return (
    <li>
      <span className={category.hidden ? "muted" : undefined}>
        {category.name}
        {category.hidden ? " · hidden" : ""}
      </span>
      <span className="manage-actions">
        <button type="button" className="text-button" onClick={() => setRenaming(true)}>
          Rename
        </button>
        <button
          type="button"
          className="text-button"
          onClick={() => onRun(() => api.updateCategory(planId, category.id, { hidden: !category.hidden }))}
        >
          {category.hidden ? "Unhide" : "Hide"}
        </button>
        <button type="button" className="text-button danger" onClick={() => setConfirmingDelete((v) => !v)}>
          Delete
        </button>
      </span>
      {confirmingDelete && (
        <form
          className="inline-form confirm-strip"
          onSubmit={(event) => {
            event.preventDefault();
            onRun(() => api.deleteCategory(planId, category.id, reassignTo || undefined));
            setConfirmingDelete(false);
          }}
        >
          <span className="muted">Move its transactions to:</span>
          <select value={reassignTo} onChange={(event) => setReassignTo(event.target.value)}>
            <option value="">Uncategorised</option>
            {reassignOptions.map((entry) => (
              <option key={entry.id} value={entry.id}>
                {entry.name}
              </option>
            ))}
          </select>
          <button type="submit" className="danger">
            Delete category
          </button>
          <button type="button" className="text-button" onClick={() => setConfirmingDelete(false)}>
            Keep it
          </button>
        </form>
      )}
    </li>
  );
}

function PayeesSection() {
  const { planId } = usePlan();
  const [version, setVersion] = useState(0);
  const payees = useApi(`payees-${planId}-${version}`, () => api.payees(planId));
  const [filter, setFilter] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [name, setName] = useState("");

  const rows = useMemo(() => {
    const needle = filter.trim().toLowerCase();
    return (payees.data ?? [])
      .filter((payee) => !payee.deleted)
      .filter((payee) => !needle || payee.name.toLowerCase().includes(needle));
  }, [filter, payees.data]);

  return (
    <section className="report-section">
      <div className="section-heading">
        <span className="section-title">Payees</span>
        <span className="section-meta">{rows.length} shown</span>
      </div>
      <input
        type="search"
        className="search-input"
        value={filter}
        onChange={(event) => setFilter(event.target.value)}
        placeholder="Filter payees..."
        aria-label="Filter payees"
      />
      {error && (
        <div className="status-panel status-panel-error compact-panel">
          <p className="status-title">Rename failed.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}
      <ul className="manage-list">
        {rows.map((payee) => (
          <li key={payee.id}>
            {renamingId === payee.id ? (
              <form
                className="inline-form"
                onSubmit={async (event) => {
                  event.preventDefault();
                  setError(null);
                  try {
                    await api.updatePayee(planId, payee.id, { name: name.trim() });
                    setRenamingId(null);
                    setVersion((n) => n + 1);
                  } catch (cause) {
                    setError(cause instanceof Error ? cause.message : String(cause));
                  }
                }}
              >
                <input value={name} onChange={(event) => setName(event.target.value)} autoFocus required />
                <button type="submit">Save</button>
                <button type="button" className="text-button" onClick={() => setRenamingId(null)}>
                  Cancel
                </button>
              </form>
            ) : (
              <>
                <span>{payee.name}</span>
                <span className="manage-actions">
                  <button
                    type="button"
                    className="text-button"
                    onClick={() => {
                      setRenamingId(payee.id);
                      setName(payee.name);
                    }}
                  >
                    Rename
                  </button>
                </span>
              </>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}

function ImportSection() {
  const { planId, accounts, reload } = usePlan();
  const openAccounts = accounts.filter((account) => !account.closed);
  const [csvAccountId, setCsvAccountId] = useState("");
  const [csvText, setCsvText] = useState("");
  const [csvResult, setCsvResult] = useState<ImportResult | null>(null);
  const [csvError, setCsvError] = useState<string | null>(null);
  const [csvBusy, setCsvBusy] = useState(false);

  const runCsvImport = async (event: React.FormEvent) => {
    event.preventDefault();
    const accountId = csvAccountId || openAccounts[0]?.id;
    if (!accountId) {
      setCsvError("Create an account first.");
      return;
    }
    setCsvBusy(true);
    setCsvError(null);
    setCsvResult(null);
    try {
      const rows = parseCsv(csvText);
      if (!rows.length) {
        throw new Error("No data rows found. Include a header row with date, payee, memo, outflow, inflow (or amount).");
      }
      const result = await api.importCsv(planId, accountId, rows);
      setCsvResult(result);
      setCsvText("");
      reload();
    } catch (cause) {
      setCsvError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setCsvBusy(false);
    }
  };

  return (
    <>
      <section className="report-section">
        <div className="section-heading">
          <span className="section-title">Import from YNAB</span>
          <span className="section-meta">Full history via a personal access token</span>
        </div>
        <p className="field-note">
          Re-running an import is safe: previously imported entries are recognised and skipped. If you have a web
          export zip instead of a token, use <code>bun run import:ynab-export</code> on the server.
        </p>
        <YnabImportForm onImported={() => reload()} />
      </section>

      <section className="report-section">
        <div className="section-heading">
          <span className="section-title">Import CSV</span>
          <span className="section-meta">Bank exports · date, payee, memo, outflow, inflow (or amount)</span>
        </div>
        <form onSubmit={runCsvImport} className="import-form">
          <label className="field">
            <span className="field-label">Into account</span>
            <select value={csvAccountId || openAccounts[0]?.id || ""} onChange={(event) => setCsvAccountId(event.target.value)}>
              {openAccounts.map((account) => (
                <option key={account.id} value={account.id}>
                  {account.name}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span className="field-label">CSV contents</span>
            <textarea
              value={csvText}
              onChange={(event) => setCsvText(event.target.value)}
              rows={8}
              placeholder={'Date,Payee,Memo,Outflow,Inflow\n2026-06-10,"Coffee Shop",latte,5.40,'}
              required
            />
          </label>
          {csvError && (
            <div className="status-panel status-panel-error compact-panel">
              <p className="status-title">Import failed.</p>
              <p className="status-detail">{csvError}</p>
            </div>
          )}
          {csvResult && (
            <div className="status-panel status-panel-success compact-panel">
              <p className="status-title">
                Imported {csvResult.imported} · skipped {csvResult.duplicate} duplicates
                {csvResult.failed ? ` · ${csvResult.failed} failed` : ""}.
              </p>
            </div>
          )}
          <button type="submit" className="save-button" disabled={csvBusy || !csvText.trim()}>
            {csvBusy ? "Importing…" : "Import rows"}
          </button>
        </form>
      </section>
    </>
  );
}

function ConnectionSection() {
  const { planId } = usePlan();
  const [token, setToken] = useState(getApiToken() ?? "");
  const [saved, setSaved] = useState(false);

  return (
    <section className="report-section">
      <div className="section-heading">
        <span className="section-title">Connection</span>
        <span className="section-meta">Plan {planId}</span>
      </div>
      <p className="field-note">
        When the server sets <code>HOWMUCH_API_TOKEN</code>, this browser sends it as a bearer token with every
        request. It is stored locally only.
      </p>
      <form
        className="inline-form manage-form"
        onSubmit={(event) => {
          event.preventDefault();
          setApiToken(token.trim() || null);
          setSaved(true);
          window.location.reload();
        }}
      >
        <input
          type="password"
          value={token}
          onChange={(event) => {
            setSaved(false);
            setToken(event.target.value);
          }}
          placeholder="API token (leave blank for open localhost)"
          aria-label="API token"
        />
        <button type="submit">{saved ? "Saved" : "Save token"}</button>
      </form>
    </section>
  );
}

/**
 * Small CSV parser with quote support; maps flexible headers (Date/Payee/
 * Memo/Outflow/Inflow/Amount, case-insensitive) onto import rows.
 */
function parseCsv(text: string): CsvImportRow[] {
  const records: string[][] = [];
  let field = "";
  let record: string[] = [];
  let inQuotes = false;
  const pushField = () => {
    record.push(field);
    field = "";
  };
  const pushRecord = () => {
    pushField();
    if (record.some((value) => value.trim() !== "")) {
      records.push(record);
    }
    record = [];
  };
  for (let i = 0; i < text.length; i += 1) {
    const char = text[i];
    if (inQuotes) {
      if (char === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += char;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ",") {
      pushField();
    } else if (char === "\n") {
      pushRecord();
    } else if (char !== "\r") {
      field += char;
    }
  }
  if (field !== "" || record.length) {
    pushRecord();
  }
  if (records.length < 2) {
    return [];
  }

  const header = records[0].map((value) => value.trim().toLowerCase());
  const col = (...names: string[]) => {
    for (const name of names) {
      const index = header.indexOf(name);
      if (index !== -1) {
        return index;
      }
    }
    return -1;
  };
  const dateCol = col("date");
  const payeeCol = col("payee", "description", "merchant");
  const memoCol = col("memo", "notes", "note");
  const outflowCol = col("outflow", "debit");
  const inflowCol = col("inflow", "credit");
  const amountCol = col("amount");
  if (dateCol === -1) {
    throw new Error('The header row needs a "Date" column.');
  }

  return records.slice(1).map((row) => {
    const value = (index: number) => (index === -1 ? undefined : row[index]?.trim() || undefined);
    return {
      date: normaliseCsvDate(value(dateCol) ?? ""),
      payee: value(payeeCol),
      memo: value(memoCol),
      outflow: value(outflowCol),
      inflow: value(inflowCol),
      amount: value(amountCol),
    };
  });
}

/** Accepts YYYY-MM-DD or DD/MM/YYYY. */
function normaliseCsvDate(raw: string): string {
  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return raw;
  }
  const dmy = raw.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (dmy) {
    return `${dmy[3]}-${dmy[2].padStart(2, "0")}-${dmy[1].padStart(2, "0")}`;
  }
  throw new Error(`Unrecognised date: ${raw}. Use YYYY-MM-DD or DD/MM/YYYY.`);
}
