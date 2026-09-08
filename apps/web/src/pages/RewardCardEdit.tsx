import { useEffect, useMemo, useState } from "react";
import { Link, useLocation, useNavigate, useParams } from "react-router-dom";
import { api, useApi } from "../api/client";
import type {
  CardSubcategory,
  CardSpendingTier,
  CreditCard,
  RewardCardType,
  RewardFlagColour,
  SpendingTierSubcategory,
  Transaction,
} from "../api/types";
import { CategorySelect } from "../components/CategorySelect";
import { FlagPicker, FlagTag } from "../components/FlagTag";
import { splitCategoryGroups } from "../lib/categories";
import { formatDate } from "../lib/dates";
import { isFlagColour, ledgerFlagFromReward, rewardFlagFromLedger } from "../lib/flags";
import { formatMoney } from "../lib/money";
import { rewardCardAccountChoices, syncedRewardCardName } from "../lib/reward-card-accounts";
import { ledgerFlagNames, namedFlagLabel, namesFromSubcategories, parseRewardFlagNames, REWARD_NAME_COLOURS, snapshotFlagLabel } from "../lib/reward-flag-names";
import { usePlan } from "../state/plan";

type FlagDraft = {
  id: string;
  name: string;
  flagColor: RewardFlagColour;
  rewardValue: string;
  priority: string;
  active: boolean;
  excludeFromRewards: boolean;
  milesBlockSize: string;
  minimumSpend: string;
  maximumSpend: string;
  createdAt: string;
  updatedAt: string;
};

type TierOverrideDraft = {
  key: string;
  subcategoryId: string;
  rewardValue: string;
  maximumSpend: string;
};

type TierDraft = {
  id: string;
  spendThreshold: string;
  earningRate: string;
  maximumSpend: string;
  overrides: TierOverrideDraft[];
};

type CardDraft = {
  id: string;
  name: string;
  issuer: string;
  type: RewardCardType;
  ynabAccountId: string;
  featured: boolean;
  billingType: "calendar" | "billing";
  billingDay: string;
  rewardMonthCount: string;
  rewardAnchorDate: string;
  rewardMonthlyMinimum: string;
  promoStart: string;
  promoEnd: string;
  promoDescription: string;
  earningRate: string;
  earningBlockSize: string;
  minimumSpend: string;
  maximumSpend: string;
  flags: FlagDraft[];
  flagNames: Partial<Record<RewardFlagColour, string>>;
  tiers: TierDraft[];
};

export function RewardCardEditPage() {
  const { cardId } = useParams();
  const { planId } = usePlan();
  const isNew = !cardId;
  const snapshot = useApi(
    `rewards-card-edit:${planId}:${cardId ?? "new"}`,
    () => api.rewardsTrackerSnapshot(planId),
  );

  if (snapshot.loading && !snapshot.data) {
    return (
      <div className="status-panel">
        <p className="status-title">{isNew ? "Loading accounts…" : "Loading card…"}</p>
      </div>
    );
  }
  if (snapshot.error) {
    return (
      <div className="status-panel status-panel-error" role="alert">
        <p className="status-title">{isNew ? "Could not load accounts." : "Could not load this card."}</p>
        <p className="status-detail">{snapshot.error}</p>
      </div>
    );
  }
  const card = isNew ? null : snapshot.data?.cards.find((entry) => entry.id === cardId) ?? null;
  if (!isNew && !card) {
    return (
      <div className="status-panel">
        <p className="status-title">Card not found.</p>
        <p className="status-detail">
          This card is not stored on this plan. <Link to="/rewards">Back to Rewards</Link>.
        </p>
      </div>
    );
  }
  const takenAccountIds = (snapshot.data?.cards ?? [])
    .filter((entry) => entry.id !== card?.id)
    .map((entry) => entry.ynabAccountId)
    .filter(Boolean);
  return <CardEditor card={card} takenAccountIds={takenAccountIds} />;
}

function CardEditor({ card, takenAccountIds }: { card: CreditCard | null; takenAccountIds: string[] }) {
  const { planId, accounts, categoryGroups } = usePlan();
  const location = useLocation();
  const navigate = useNavigate();
  const rewardsHref = { pathname: "/rewards", search: location.search };
  const [draft, setDraft] = useState<CardDraft>(() => (card ? draftFromCard(card) : emptyDraft()));
  const [busy, setBusy] = useState<"save" | "delete" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pendingDelete, setPendingDelete] = useState(false);
  const [importCategoryId, setImportCategoryId] = useState("");
  const [importFlagColor, setImportFlagColor] = useState<RewardFlagColour>("red");
  const [importRate, setImportRate] = useState("");
  const groups = useMemo(() => splitCategoryGroups(categoryGroups), [categoryGroups]);
  const accountChoices = useMemo(
    () => rewardCardAccountChoices(accounts, takenAccountIds, card?.ynabAccountId),
    [accounts, takenAccountIds, card?.ynabAccountId],
  );
  const accountById = useMemo(() => new Map(accounts.map((account) => [account.id, account])), [accounts]);
  const categoryName = useMemo(() => {
    for (const group of [...groups.primary, ...groups.quiet]) {
      for (const category of group.categories) {
        if (category.id === importCategoryId) return category.name;
      }
    }
    return "";
  }, [groups, importCategoryId]);
  const pickerNames = ledgerFlagNames(draft.flagNames);

  const setColourName = (colour: RewardFlagColour, value: string) => {
    setDraft((current) => ({
      ...current,
      flagNames: { ...current.flagNames, [colour]: value },
      flags: current.flags.map((flag) => (
        flag.flagColor === colour ? { ...flag, name: value, updatedAt: new Date().toISOString() } : flag
      )),
    }));
  };

  const save = async () => {
    const written = creditCardWrite(draft, { clearMissing: Boolean(card) });
    if ("error" in written) {
      setError(written.error);
      return;
    }
    setBusy("save");
    setError(null);
    try {
      if (card) {
        await api.updateRewardCard(planId, card.id, written.card);
      } else {
        await api.createRewardCard(planId, written.card);
      }
      navigate(rewardsHref);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  const remove = async () => {
    if (!card) return;
    setBusy("delete");
    setError(null);
    try {
      await api.deleteRewardCard(planId, card.id);
      navigate(rewardsHref);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(null);
    }
  };

  const addImportedFlag = () => {
    if (!importCategoryId || !categoryName) {
      setError("Choose a category to add as a flag.");
      return;
    }
    const rate = requiredFinite(importRate, "Category flag rate");
    if (!rate.ok) {
      setError(rate.error);
      return;
    }
    setError(null);
    setDraft((current) => {
      const named = current.flagNames[importFlagColor]?.trim() || categoryName;
      return {
        ...current,
        flags: [...current.flags, newFlag({
          name: named,
          flagColor: importFlagColor,
          rewardValue: String(rate.value),
          priority: String(current.flags.length + 1),
        })],
        flagNames: current.flagNames[importFlagColor]?.trim()
          ? current.flagNames
          : { ...current.flagNames, [importFlagColor]: categoryName },
      };
    });
    setImportCategoryId("");
    setImportRate("");
  };

  return (
    <>
      <header className="report-header">
        <div>
          <Link to={rewardsHref} className="page-eyebrow">← Rewards</Link>
          <h1>{card ? "Edit card" : "Add card"}</h1>
        </div>
      </header>

      {error && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not update this card.</p>
          <p className="status-detail">{error}</p>
        </div>
      )}

      {pendingDelete && card && (
        <section className="transaction-editor schedule-delete-confirm" aria-labelledby="delete-card-heading">
          <div className="section-heading">
            <div>
              <span className="section-title" id="delete-card-heading">Delete this reward card?</span>
              <span className="section-meta">Ledger transactions stay. The card rules are removed.</span>
            </div>
          </div>
          <p>{card.name} will no longer appear on Rewards.</p>
          <div className="transaction-editor-actions">
            <button type="button" className="text-button" onClick={() => setPendingDelete(false)} disabled={busy === "delete"}>Cancel</button>
            <button type="button" className="save-button schedule-delete-button" onClick={() => void remove()} disabled={busy === "delete"}>
              {busy === "delete" ? "Deleting…" : "Delete card"}
            </button>
          </div>
        </section>
      )}

      <section className="transaction-editor" aria-labelledby="card-editor-heading">
        <div className="section-heading">
          <div>
            <span className="section-title" id="card-editor-heading">{card ? "Card details" : "Existing HowMuch card"}</span>
            <span className="section-meta">Pick a credit card account you already have. This does not create a new ledger account.</span>
          </div>
        </div>
        <form
          className="transaction-editor-form"
          onSubmit={(event) => {
            event.preventDefault();
            void save();
          }}
        >
          {accountChoices.length === 0 && !card && (
            <p className="field-note">No HowMuch credit cards left to add. Every credit card account already has rewards rules, or add a credit card account first.</p>
          )}
          <div className="field-row">
            <label className="field">
              <span className="field-label">HowMuch card</span>
              <select
                value={draft.ynabAccountId}
                onChange={(event) => {
                  const nextId = event.target.value;
                  setDraft((current) => ({
                    ...current,
                    ynabAccountId: nextId,
                    name: syncedRewardCardName({
                      name: current.name,
                      previousAccountName: accountById.get(current.ynabAccountId)?.name,
                      nextAccountName: accountById.get(nextId)?.name,
                    }),
                  }));
                }}
                required
              >
                <option value="">Choose a HowMuch card</option>
                {accountChoices.map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.name}{account.closed ? " (closed)" : ""}
                  </option>
                ))}
              </select>
            </label>
            <label className="field">
              <span className="field-label">Name</span>
              <input value={draft.name} onChange={(event) => setDraft((current) => ({ ...current, name: event.target.value }))} required />
            </label>
          </div>
          <div className="field-row">
            <label className="field">
              <span className="field-label">Issuer</span>
              <input value={draft.issuer} onChange={(event) => setDraft((current) => ({ ...current, issuer: event.target.value }))} />
            </label>
            <label className="field">
              <span className="field-label">Type</span>
              <select
                value={draft.type}
                onChange={(event) => setDraft((current) => ({ ...current, type: event.target.value as RewardCardType }))}
              >
                <option value="cashback">Cashback</option>
                <option value="miles">Miles</option>
              </select>
            </label>
          </div>
          <label className="transaction-editor-checkbox">
            <input
              type="checkbox"
              checked={draft.featured}
              onChange={(event) => setDraft((current) => ({ ...current, featured: event.target.checked }))}
            />
            Featured
          </label>

          <div className="field-row">
            <label className="field">
              <span className="field-label">Billing cycle</span>
              <select
                value={draft.billingType}
                onChange={(event) => setDraft((current) => ({ ...current, billingType: event.target.value as "calendar" | "billing" }))}
              >
                <option value="calendar">Calendar month</option>
                <option value="billing">Billing cycle</option>
              </select>
            </label>
            <label className="field">
              <span className="field-label">Day of month</span>
              <input
                type="text"
                inputMode="numeric"
                value={draft.billingDay}
                onChange={(event) => setDraft((current) => ({ ...current, billingDay: event.target.value }))}
              />
              <span className="field-note">Optional. Used when the cycle follows a statement day.</span>
            </label>
          </div>

          <div className="field-row">
            <label className="field">
              <span className="field-label">Reward period months</span>
              <input
                type="text"
                inputMode="numeric"
                value={draft.rewardMonthCount}
                onChange={(event) => setDraft((current) => ({ ...current, rewardMonthCount: event.target.value }))}
              />
            </label>
            <label className="field">
              <span className="field-label">Anchor date</span>
              <input
                type="date"
                value={draft.rewardAnchorDate}
                onChange={(event) => setDraft((current) => ({ ...current, rewardAnchorDate: event.target.value }))}
              />
            </label>
            <label className="field">
              <span className="field-label">Monthly minimum spend</span>
              <input
                type="text"
                inputMode="decimal"
                value={draft.rewardMonthlyMinimum}
                onChange={(event) => setDraft((current) => ({ ...current, rewardMonthlyMinimum: event.target.value }))}
              />
            </label>
          </div>
          <p className="field-note">Leave the reward period blank if this card has no qualifying window.</p>

          <div className="field-row">
            <label className="field">
              <span className="field-label">Promotional start</span>
              <input
                type="date"
                value={draft.promoStart}
                onChange={(event) => setDraft((current) => ({ ...current, promoStart: event.target.value }))}
              />
            </label>
            <label className="field">
              <span className="field-label">Promotional end</span>
              <input
                type="date"
                value={draft.promoEnd}
                onChange={(event) => setDraft((current) => ({ ...current, promoEnd: event.target.value }))}
              />
            </label>
            <label className="field">
              <span className="field-label">Promotional description</span>
              <input
                value={draft.promoDescription}
                onChange={(event) => setDraft((current) => ({ ...current, promoDescription: event.target.value }))}
              />
            </label>
          </div>

          <div className="field-row">
            <label className="field">
              <span className="field-label">Earning rate</span>
              <input
                type="text"
                inputMode="decimal"
                value={draft.earningRate}
                onChange={(event) => setDraft((current) => ({ ...current, earningRate: event.target.value }))}
              />
            </label>
            <label className="field">
              <span className="field-label">Block size</span>
              <input
                type="text"
                inputMode="decimal"
                value={draft.earningBlockSize}
                onChange={(event) => setDraft((current) => ({ ...current, earningBlockSize: event.target.value }))}
              />
            </label>
          </div>
          <div className="field-row">
            <label className="field">
              <span className="field-label">Minimum spend</span>
              <input
                type="text"
                inputMode="decimal"
                value={draft.minimumSpend}
                onChange={(event) => setDraft((current) => ({ ...current, minimumSpend: event.target.value }))}
              />
            </label>
            <label className="field">
              <span className="field-label">Maximum spend</span>
              <input
                type="text"
                inputMode="decimal"
                value={draft.maximumSpend}
                onChange={(event) => setDraft((current) => ({ ...current, maximumSpend: event.target.value }))}
              />
            </label>
          </div>

          <fieldset className="transaction-editor-splits rewards-editor-block">
            <legend>Colour names</legend>
            <p className="field-note">These names show on this account’s flags. Everyday Account and other untracked accounts keep the plain colour tags.</p>
            <div className="rewards-colour-names">
              {REWARD_NAME_COLOURS.map((colour) => {
                const label = colour === "unflagged" ? "None" : colour[0]!.toUpperCase() + colour.slice(1);
                return (
                  <div className="rewards-colour-name-row" key={colour}>
                    {colour === "unflagged" ? (
                      <span className="field-label">None</span>
                    ) : (
                      <FlagTag colour={colour} name={draft.flagNames[colour] || label} />
                    )}
                    <label className="field">
                      <span className="sr-only">{label} name</span>
                      <input
                        value={draft.flagNames[colour] ?? ""}
                        placeholder={label}
                        aria-label={`${label} name`}
                        onChange={(event) => setColourName(colour, event.target.value)}
                      />
                    </label>
                  </div>
                );
              })}
            </div>
          </fieldset>

          <fieldset className="transaction-editor-splits rewards-editor-block">
            <legend>Flag subcategories</legend>
            <p className="field-note">These are the same colour tags as the ledger. None is Unflagged spend. Name the colour above and it appears on this account.</p>
            <div className="field-row">
              <label className="field">
                <span className="field-label">Import category</span>
                <CategorySelect
                  value={importCategoryId}
                  onChange={setImportCategoryId}
                  groups={groups}
                  emptyLabel="Choose category"
                  aria-label="Import category"
                />
              </label>
              <div className="field">
                <span className="field-label" id="import-flag-colour-label">Flag colour</span>
                <FlagPicker
                  labelledBy="import-flag-colour-label"
                  value={ledgerFlagFromReward(importFlagColor)}
                  onChange={(value) => setImportFlagColor(rewardFlagFromLedger(value))}
                  names={pickerNames}
                />
              </div>
              <label className="field">
                <span className="field-label">Rate</span>
                <input type="text" inputMode="decimal" value={importRate} onChange={(event) => setImportRate(event.target.value)} />
              </label>
            </div>
            <button type="button" className="text-button" onClick={addImportedFlag}>Add flag from category</button>
            {draft.flags.map((flag, index) => (
              <FlagRow
                key={flag.id}
                flag={flag}
                index={index}
                colourName={draft.flagNames[flag.flagColor] ?? flag.name}
                pickerNames={pickerNames}
                onChange={(next) => setDraft((current) => ({
                  ...current,
                  flags: current.flags.map((entry) => entry.id === flag.id ? next : entry),
                  flagNames: next.flagColor === flag.flagColor
                    ? current.flagNames
                    : { ...current.flagNames, [next.flagColor]: current.flagNames[next.flagColor] ?? next.name },
                }))}
                onRemove={() => setDraft((current) => ({
                  ...current,
                  flags: current.flags.filter((entry) => entry.id !== flag.id),
                }))}
              />
            ))}
            <button
              type="button"
              className="text-button"
              onClick={() => setDraft((current) => ({
                ...current,
                flags: [...current.flags, newFlag({ priority: String(current.flags.length + 1) })],
              }))}
            >
              Add flag
            </button>
          </fieldset>

          <fieldset className="transaction-editor-splits rewards-editor-block">
            <legend>Spending tiers</legend>
            {draft.tiers.map((tier) => (
              <TierRow
                key={tier.id}
                tier={tier}
                flags={draft.flags}
                flagNames={draft.flagNames}
                onChange={(next) => setDraft((current) => ({
                  ...current,
                  tiers: current.tiers.map((entry) => entry.id === tier.id ? next : entry),
                }))}
                onRemove={() => setDraft((current) => ({
                  ...current,
                  tiers: current.tiers.filter((entry) => entry.id !== tier.id),
                }))}
              />
            ))}
            <button
              type="button"
              className="text-button"
              onClick={() => setDraft((current) => ({ ...current, tiers: [...current.tiers, newTier()] }))}
            >
              Add spending tier
            </button>
          </fieldset>

          <div className="transaction-editor-actions">
            <Link to={rewardsHref} className="text-button">Cancel</Link>
            {card && (
              <button type="button" className="text-button" onClick={() => setPendingDelete(true)} disabled={busy !== null}>
                Delete card
              </button>
            )}
            <button type="submit" className="save-button" disabled={busy !== null}>
              {busy === "save" ? "Saving…" : "Save card"}
            </button>
          </div>
        </form>
      </section>

      <CardLedger planId={planId} accountId={draft.ynabAccountId} flagNames={draft.flagNames} pickerNames={pickerNames} />
    </>
  );
}

function FlagRow({
  flag,
  index,
  colourName,
  pickerNames,
  onChange,
  onRemove,
}: {
  flag: FlagDraft;
  index: number;
  colourName: string;
  pickerNames: Record<string, string>;
  onChange: (flag: FlagDraft) => void;
  onRemove: () => void;
}) {
  const patch = (next: Partial<FlagDraft>) => onChange({ ...flag, ...next, updatedAt: new Date().toISOString() });
  const ledgerColour = ledgerFlagFromReward(flag.flagColor);
  return (
    <div className="rewards-editor-row">
      <div className="field">
        <span className="field-label" id={`flag-${index + 1}-colour-label`}>Flag colour</span>
        <span className="rewards-flag-colour-row">
          <FlagPicker
            labelledBy={`flag-${index + 1}-colour-label`}
            value={ledgerColour}
            onChange={(value) => patch({ flagColor: rewardFlagFromLedger(value), name: pickerNames[value] || flag.name })}
            names={pickerNames}
          />
          <FlagTag colour={ledgerColour || null} name={namedFlagLabel({ [flag.flagColor]: colourName }, ledgerColour, colourName)} />
        </span>
      </div>
      <label className="field">
        <span className="field-label">Reward value</span>
        <input type="text" inputMode="decimal" value={flag.rewardValue} onChange={(event) => patch({ rewardValue: event.target.value })} aria-label={`Flag ${index + 1} reward value`} />
      </label>
      <label className="field">
        <span className="field-label">Priority</span>
        <input type="text" inputMode="numeric" value={flag.priority} onChange={(event) => patch({ priority: event.target.value })} aria-label={`Flag ${index + 1} priority`} />
      </label>
      <label className="field">
        <span className="field-label">Minimum spend</span>
        <input type="text" inputMode="decimal" value={flag.minimumSpend} onChange={(event) => patch({ minimumSpend: event.target.value })} />
      </label>
      <label className="field">
        <span className="field-label">Maximum spend</span>
        <input type="text" inputMode="decimal" value={flag.maximumSpend} onChange={(event) => patch({ maximumSpend: event.target.value })} />
      </label>
      <label className="field">
        <span className="field-label">Miles block</span>
        <input type="text" inputMode="decimal" value={flag.milesBlockSize} onChange={(event) => patch({ milesBlockSize: event.target.value })} />
      </label>
      <label className="transaction-editor-checkbox">
        <input type="checkbox" checked={flag.active} onChange={(event) => patch({ active: event.target.checked })} />
        Active
      </label>
      <label className="transaction-editor-checkbox">
        <input type="checkbox" checked={flag.excludeFromRewards} onChange={(event) => patch({ excludeFromRewards: event.target.checked })} />
        Exclude from rewards
      </label>
      <button type="button" className="text-button" onClick={onRemove}>Remove</button>
    </div>
  );
}

function TierRow({
  tier,
  flags,
  flagNames,
  onChange,
  onRemove,
}: {
  tier: TierDraft;
  flags: FlagDraft[];
  flagNames: Partial<Record<RewardFlagColour, string>>;
  onChange: (tier: TierDraft) => void;
  onRemove: () => void;
}) {
  const patch = (next: Partial<TierDraft>) => onChange({ ...tier, ...next });
  return (
    <div className="rewards-editor-row">
      <label className="field">
        <span className="field-label">Spend threshold</span>
        <input type="text" inputMode="decimal" value={tier.spendThreshold} onChange={(event) => patch({ spendThreshold: event.target.value })} />
      </label>
      <label className="field">
        <span className="field-label">Earning rate</span>
        <input type="text" inputMode="decimal" value={tier.earningRate} onChange={(event) => patch({ earningRate: event.target.value })} />
      </label>
      <label className="field">
        <span className="field-label">Maximum spend</span>
        <input type="text" inputMode="decimal" value={tier.maximumSpend} onChange={(event) => patch({ maximumSpend: event.target.value })} />
      </label>
      {tier.overrides.map((override) => (
        <div key={override.key} className="rewards-editor-override">
          <label className="field">
            <span className="field-label">Flag override</span>
            <select
              value={override.subcategoryId}
              onChange={(event) => patch({
                overrides: tier.overrides.map((entry) => entry.key === override.key ? { ...entry, subcategoryId: event.target.value } : entry),
              })}
            >
              <option value="">Choose flag</option>
              {flags.map((flag) => (
                <option key={flag.id} value={flag.id}>{flagNames[flag.flagColor]?.trim() || flag.name || flag.flagColor}</option>
              ))}
            </select>
          </label>
          <label className="field">
            <span className="field-label">Override rate</span>
            <input
              type="text"
              inputMode="decimal"
              value={override.rewardValue}
              onChange={(event) => patch({
                overrides: tier.overrides.map((entry) => entry.key === override.key ? { ...entry, rewardValue: event.target.value } : entry),
              })}
            />
          </label>
          <label className="field">
            <span className="field-label">Override maximum</span>
            <input
              type="text"
              inputMode="decimal"
              value={override.maximumSpend}
              onChange={(event) => patch({
                overrides: tier.overrides.map((entry) => entry.key === override.key ? { ...entry, maximumSpend: event.target.value } : entry),
              })}
            />
          </label>
          <button
            type="button"
            className="text-button"
            onClick={() => patch({ overrides: tier.overrides.filter((entry) => entry.key !== override.key) })}
          >
            Remove override
          </button>
        </div>
      ))}
      <button
        type="button"
        className="text-button"
        onClick={() => patch({
          overrides: [...tier.overrides, { key: crypto.randomUUID(), subcategoryId: flags[0]?.id ?? "", rewardValue: "", maximumSpend: "" }],
        })}
      >
        Add flag override
      </button>
      <button type="button" className="text-button" onClick={onRemove}>Remove tier</button>
    </div>
  );
}

function CardLedger({
  planId,
  accountId,
  flagNames,
  pickerNames,
}: {
  planId: string;
  accountId: string;
  flagNames: Partial<Record<RewardFlagColour, string>>;
  pickerNames: Record<string, string>;
}) {
  const [overrides, setOverrides] = useState<Record<string, { flag_color: string | null; flag_name: string | null }>>({});
  const [flagError, setFlagError] = useState<string | null>(null);
  const [pendingId, setPendingId] = useState<string | null>(null);
  useEffect(() => {
    setOverrides({});
    setFlagError(null);
  }, [accountId]);
  const ledger = useApi(
    accountId ? `${planId}:card-ledger:${accountId}` : "card-ledger:none",
    () => (accountId
      ? api.accountTransactions(planId, accountId, { limit: 250 })
      : Promise.resolve({ transactions: [] as Transaction[], has_more: false, next_offset: null, server_knowledge: 0 })),
  );

  if (!accountId) return null;

  const setFlag = async (transaction: Transaction, value: string) => {
    const flagColor = value === "" ? null : value;
    const previous = overrides[transaction.id];
    setPendingId(transaction.id);
    setFlagError(null);
    setOverrides((current) => ({
      ...current,
      [transaction.id]: {
        flag_color: flagColor,
        flag_name: namedFlagLabel(flagNames, flagColor) ?? null,
      },
    }));
    try {
      const updated = await api.updateTransaction(planId, transaction.id, { flag_color: flagColor });
      setOverrides((current) => ({
        ...current,
        [transaction.id]: {
          flag_color: updated.flag_color ?? null,
          flag_name: updated.flag_name ?? null,
        },
      }));
    } catch (cause) {
      setOverrides((current) => {
        const next = { ...current };
        if (previous) next[transaction.id] = previous;
        else delete next[transaction.id];
        return next;
      });
      setFlagError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setPendingId(null);
    }
  };

  return (
    <section className="report-section" aria-labelledby="card-ledger-heading">
      <div className="section-heading">
        <span className="section-title" id="card-ledger-heading">Account ledger</span>
        <span className="section-meta">Newest first</span>
      </div>
      {flagError && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not update the flag.</p>
          <p className="status-detail">{flagError}</p>
        </div>
      )}
      {ledger.loading && !ledger.data && <div className="status-panel"><p className="status-title">Loading transactions…</p></div>}
      {ledger.error && (
        <div className="status-panel status-panel-error" role="alert">
          <p className="status-title">Could not load transactions.</p>
          <p className="status-detail">{ledger.error}</p>
        </div>
      )}
      {!ledger.loading && (ledger.data?.transactions.length ?? 0) === 0 && (
        <p className="field-note">No transactions on this account.</p>
      )}
      {(ledger.data?.transactions.length ?? 0) > 0 && (
        <table className="report-table">
          <thead>
            <tr>
              <th>Date</th>
              <th>Payee</th>
              <th className="num">Amount</th>
              <th>Flag</th>
            </tr>
          </thead>
          <tbody>
            {ledger.data?.transactions.map((transaction) => {
              const snapshot = overrides[transaction.id] ?? transaction;
              const colour = snapshot.flag_color;
              const flagName = snapshotFlagLabel(flagNames, colour, snapshot);
              return (
                <tr key={transaction.id}>
                  <td>{formatDate(transaction.date)}</td>
                  <td>
                    <span className="rewards-group-label">
                      <FlagTag colour={colour} name={flagName} />
                      {transaction.payee_name ?? "No payee"}
                    </span>
                  </td>
                  <td className={transaction.amount < 0 ? "num amount-negative" : "num"}>{formatMoney(transaction.amount)}</td>
                  <td>
                    <FlagPicker
                      value={colour ?? ""}
                      onChange={(value) => void setFlag(transaction, value)}
                      disabled={pendingId === transaction.id}
                      names={pickerNames}
                    />
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </section>
  );
}

function emptyDraft(): CardDraft {
  return {
    id: `card_${crypto.randomUUID()}`,
    name: "",
    issuer: "",
    type: "cashback",
    ynabAccountId: "",
    featured: true,
    billingType: "calendar",
    billingDay: "",
    rewardMonthCount: "",
    rewardAnchorDate: "",
    rewardMonthlyMinimum: "",
    promoStart: "",
    promoEnd: "",
    promoDescription: "",
    earningRate: "",
    earningBlockSize: "",
    minimumSpend: "",
    maximumSpend: "",
    flags: [],
    flagNames: {},
    tiers: [],
  };
}

function draftFromCard(card: CreditCard): CardDraft {
  return {
    id: card.id,
    name: card.name,
    issuer: card.issuer,
    type: card.type === "miles" ? "miles" : "cashback",
    ynabAccountId: card.ynabAccountId,
    featured: card.featured !== false,
    billingType: card.billingCycle?.type === "billing" ? "billing" : "calendar",
    billingDay: numberText(card.billingCycle?.dayOfMonth),
    rewardMonthCount: numberText(card.rewardPeriod?.monthCount),
    rewardAnchorDate: card.rewardPeriod?.anchorDate ?? "",
    rewardMonthlyMinimum: numberText(card.rewardPeriod?.monthlyMinimumSpend),
    promoStart: card.promotionalPeriod?.startDate ?? "",
    promoEnd: card.promotionalPeriod?.endDate ?? "",
    promoDescription: card.promotionalPeriod?.description ?? "",
    earningRate: numberText(card.earningRate),
    earningBlockSize: numberText(card.earningBlockSize),
    minimumSpend: numberText(card.minimumSpend),
    maximumSpend: numberText(card.maximumSpend),
    flags: (card.subcategories ?? []).map((flag) => {
      const now = new Date().toISOString();
      return {
        id: flag.id || `subcat_${crypto.randomUUID()}`,
        name: flag.name,
        flagColor: rewardFlagFromLedger(flag.flagColor),
        rewardValue: numberText(flag.rewardValue),
        priority: numberText(flag.priority),
        active: flag.active !== false,
        excludeFromRewards: flag.excludeFromRewards === true,
        milesBlockSize: numberText(flag.milesBlockSize),
        minimumSpend: numberText(flag.minimumSpend),
        maximumSpend: numberText(flag.maximumSpend),
        createdAt: flag.createdAt || now,
        updatedAt: flag.updatedAt || now,
      };
    }),
    flagNames: {
      ...namesFromSubcategories((card.subcategories ?? []).map((flag) => ({
        flagColor: rewardFlagFromLedger(flag.flagColor),
        name: flag.name,
      }))),
      ...parseRewardFlagNames(card.flagNames),
    },
    tiers: (card.spendingTiers ?? []).map((tier) => ({
      id: tier.id,
      spendThreshold: numberText(tier.spendThreshold),
      earningRate: numberText(tier.earningRate),
      maximumSpend: numberText(tier.maximumSpend),
      overrides: (tier.subcategories ?? []).map((override) => ({
        key: crypto.randomUUID(),
        subcategoryId: override.subcategoryId,
        rewardValue: numberText(override.rewardValue),
        maximumSpend: numberText(override.maximumSpend),
      })),
    })),
  };
}

function creditCardWrite(draft: CardDraft, options: { clearMissing?: boolean } = {}): { card: CreditCard } | { error: string } {
  if (!draft.ynabAccountId) return { error: "Choose a HowMuch card." };
  if (!draft.name.trim()) return { error: "Enter a card name." };

  const card: CreditCard = {
    id: draft.id,
    name: draft.name.trim(),
    issuer: draft.issuer.trim(),
    type: draft.type,
    ynabAccountId: draft.ynabAccountId,
    featured: draft.featured,
  };

  const billingDay = optionalFinite(draft.billingDay, "Billing day of month");
  if (!billingDay.ok) return { error: billingDay.error };
  card.billingCycle = { type: draft.billingType };
  if (billingDay.value != null) card.billingCycle.dayOfMonth = billingDay.value;

  const rewardTouched = draft.rewardMonthCount.trim() || draft.rewardAnchorDate.trim() || draft.rewardMonthlyMinimum.trim();
  if (rewardTouched) {
    const monthCount = requiredFinite(draft.rewardMonthCount, "Reward period months");
    if (!monthCount.ok) return { error: monthCount.error };
    if (!draft.rewardAnchorDate.trim()) return { error: "Reward period needs an anchor date." };
    const monthlyMinimum = requiredFinite(draft.rewardMonthlyMinimum, "Monthly minimum spend");
    if (!monthlyMinimum.ok) return { error: monthlyMinimum.error };
    card.rewardPeriod = {
      monthCount: monthCount.value,
      anchorDate: draft.rewardAnchorDate,
      monthlyMinimumSpend: monthlyMinimum.value,
    };
  } else if (options.clearMissing) {
    Object.assign(card, { rewardPeriod: null });
  }

  const promoTouched = draft.promoStart.trim() || draft.promoEnd.trim() || draft.promoDescription.trim();
  if (promoTouched) {
    if (!draft.promoEnd.trim()) return { error: "Promotional period needs an end date." };
    card.promotionalPeriod = { endDate: draft.promoEnd };
    if (draft.promoStart.trim()) card.promotionalPeriod.startDate = draft.promoStart;
    if (draft.promoDescription.trim()) card.promotionalPeriod.description = draft.promoDescription.trim();
  } else if (options.clearMissing) {
    Object.assign(card, { promotionalPeriod: null });
  }

  const earningRate = optionalFinite(draft.earningRate, "Earning rate");
  if (!earningRate.ok) return { error: earningRate.error };
  card.earningRate = earningRate.value ?? null;
  const earningBlockSize = optionalFinite(draft.earningBlockSize, "Block size");
  if (!earningBlockSize.ok) return { error: earningBlockSize.error };
  card.earningBlockSize = earningBlockSize.value ?? null;
  const minimumSpend = optionalFinite(draft.minimumSpend, "Minimum spend");
  if (!minimumSpend.ok) return { error: minimumSpend.error };
  card.minimumSpend = minimumSpend.value ?? null;
  const maximumSpend = optionalFinite(draft.maximumSpend, "Maximum spend");
  if (!maximumSpend.ok) return { error: maximumSpend.error };
  card.maximumSpend = maximumSpend.value ?? null;

  const flags: CardSubcategory[] = [];
  for (const [index, flag] of draft.flags.entries()) {
    const colourName = draft.flagNames[flag.flagColor]?.trim() || flag.name.trim();
    if (!colourName) return { error: `Name the ${flag.flagColor === "unflagged" ? "None" : flag.flagColor} colour on this card.` };
    if (!isRewardFlagColour(flag.flagColor)) return { error: `Flag ${index + 1} needs a recognised colour.` };
    const rewardValue = requiredFinite(flag.rewardValue, `Flag ${index + 1} reward value`);
    if (!rewardValue.ok) return { error: rewardValue.error };
    const priority = requiredFinite(flag.priority, `Flag ${index + 1} priority`);
    if (!priority.ok) return { error: priority.error };
    const milesBlockSize = optionalFinite(flag.milesBlockSize, `Flag ${index + 1} miles block`);
    if (!milesBlockSize.ok) return { error: milesBlockSize.error };
    const flagMinimum = optionalFinite(flag.minimumSpend, `Flag ${index + 1} minimum spend`);
    if (!flagMinimum.ok) return { error: flagMinimum.error };
    const flagMaximum = optionalFinite(flag.maximumSpend, `Flag ${index + 1} maximum spend`);
    if (!flagMaximum.ok) return { error: flagMaximum.error };
    const written: CardSubcategory = {
      id: flag.id,
      name: colourName,
      flagColor: flag.flagColor,
      rewardValue: rewardValue.value,
      priority: priority.value,
      active: flag.active,
      createdAt: flag.createdAt,
      updatedAt: flag.updatedAt,
    };
    if (milesBlockSize.value !== undefined) written.milesBlockSize = milesBlockSize.value;
    if (flagMinimum.value !== undefined) written.minimumSpend = flagMinimum.value;
    if (flagMaximum.value !== undefined) written.maximumSpend = flagMaximum.value;
    if (flag.excludeFromRewards) written.excludeFromRewards = true;
    flags.push(written);
  }
  card.subcategoriesEnabled = flags.length > 0;
  card.subcategories = flags;
  card.flagNames = parseRewardFlagNames(draft.flagNames);

  const tiers: CardSpendingTier[] = [];
  for (const [index, tier] of draft.tiers.entries()) {
    const spendThreshold = requiredFinite(tier.spendThreshold, `Spending tier ${index + 1} threshold`);
    if (!spendThreshold.ok) return { error: spendThreshold.error };
    const written: CardSpendingTier = { id: tier.id, spendThreshold: spendThreshold.value };
    const earningRate = optionalFinite(tier.earningRate, `Spending tier ${index + 1} earning rate`);
    if (!earningRate.ok) return { error: earningRate.error };
    if (earningRate.value !== undefined) written.earningRate = earningRate.value;
    const tierMaximum = optionalFinite(tier.maximumSpend, `Spending tier ${index + 1} maximum spend`);
    if (!tierMaximum.ok) return { error: tierMaximum.error };
    if (tierMaximum.value !== undefined) written.maximumSpend = tierMaximum.value;
    if (tier.overrides.length > 0) {
      const overrides: SpendingTierSubcategory[] = [];
      for (const [overrideIndex, override] of tier.overrides.entries()) {
        if (!override.subcategoryId) return { error: `Spending tier ${index + 1} override ${overrideIndex + 1} needs a flag.` };
        const overrideRate = requiredFinite(override.rewardValue, `Spending tier ${index + 1} override ${overrideIndex + 1} rate`);
        if (!overrideRate.ok) return { error: overrideRate.error };
        const mapped: SpendingTierSubcategory = { subcategoryId: override.subcategoryId, rewardValue: overrideRate.value };
        const overrideMaximum = optionalFinite(override.maximumSpend, `Spending tier ${index + 1} override ${overrideIndex + 1} maximum`);
        if (!overrideMaximum.ok) return { error: overrideMaximum.error };
        if (overrideMaximum.value !== undefined) mapped.maximumSpend = overrideMaximum.value;
        overrides.push(mapped);
      }
      written.subcategories = overrides;
    }
    tiers.push(written);
  }
  card.spendingTiers = tiers;
  return { card };
}

function newFlag(partial?: Partial<FlagDraft>): FlagDraft {
  const now = new Date().toISOString();
  return {
    id: `subcat_${crypto.randomUUID()}`,
    name: "",
    flagColor: "red",
    rewardValue: "",
    priority: "1",
    active: true,
    excludeFromRewards: false,
    milesBlockSize: "",
    minimumSpend: "",
    maximumSpend: "",
    createdAt: now,
    updatedAt: now,
    ...partial,
  };
}

function newTier(): TierDraft {
  return {
    id: `tier_${crypto.randomUUID()}`,
    spendThreshold: "",
    earningRate: "",
    maximumSpend: "",
    overrides: [],
  };
}

function numberText(value: number | null | undefined): string {
  return value == null ? "" : String(value);
}

function isRewardFlagColour(value: string): value is RewardFlagColour {
  return value === "unflagged" || isFlagColour(value);
}

type ParsedNumber = { ok: true; value?: number | null } | { ok: false; error: string };

function optionalFinite(text: string, label: string): ParsedNumber {
  const trimmed = text.trim();
  if (!trimmed) return { ok: true, value: undefined };
  const value = Number(trimmed);
  if (!Number.isFinite(value)) return { ok: false, error: `${label} must be a number.` };
  return { ok: true, value };
}

function requiredFinite(text: string, label: string): { ok: true; value: number } | { ok: false; error: string } {
  const parsed = optionalFinite(text, label);
  if (!parsed.ok) return parsed;
  if (parsed.value == null) return { ok: false, error: `${label} is required.` };
  return { ok: true, value: parsed.value };
}
