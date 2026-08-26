import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import type { Account, AccountGroupSort, AccountPreferences, CustomAccountGroup } from "../api/types";
import type { AccountGroup } from "../lib/account-groups";
import {
  addCustomAccountGroup,
  customAccountGroupNameError,
  deleteCustomAccountGroup,
  moveAccountInGroup,
  moveCustomAccountGroup,
  renameCustomAccountGroup,
  setAccountGroupSort,
  setAccountInCustomGroup,
  setFavouriteAccount,
} from "../state/account-preferences";
import { usePlan } from "../state/plan";

const SORT_OPTIONS: Array<{ value: AccountGroupSort; label: string }> = [
  { value: "manual", label: "Manual" },
  { value: "alphabetical", label: "Alphabetical" },
  { value: "mostUsedLast30Days", label: "Most used (30 days)" },
];

const BUILT_IN_GROUPS = [
  { id: "favourites", label: "Favourites" },
  { id: "cash", label: "Cash" },
  { id: "credit", label: "Credit" },
  { id: "tracking", label: "Tracking" },
  { id: "closed", label: "Closed" },
];

export interface AccountUsageState {
  phase: "idle" | "loading" | "loaded" | "error";
  message: string | null;
}

export function AccountOrganizationDialog({
  accountGroups,
  usage,
  onRetryUsage,
  onClose,
}: {
  accountGroups: AccountGroup[];
  usage: AccountUsageState;
  onRetryUsage: () => void;
  onClose: () => void;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const {
    accounts,
    accountPreferencesSync,
    updateAccountPreferences,
    retryAccountPreferences,
  } = usePlan();
  const preferences = accountPreferencesSync.preferences;
  const groupsById = useMemo(() => new Map(accountGroups.map((group) => [group.id, group])), [accountGroups]);
  const openAccounts = useMemo(
    () => accounts.filter((account) => !account.closed).sort(accountNameOrder),
    [accounts],
  );

  useEffect(() => {
    const dialog = dialogRef.current;
    if (dialog && !dialog.open) dialog.showModal();
  }, []);

  const saving = accountPreferencesSync.phase === "saving";
  const requestClose = () => {
    if (saving) return;
    if (accountPreferencesSync.phase === "error" && !window.confirm(
      "These account organisation changes have not been saved. Close and keep them visible with a retry option?",
    )) return;
    dialogRef.current?.close();
  };

  return (
    <dialog
      ref={dialogRef}
      className="account-organizer"
      aria-labelledby="account-organizer-title"
      aria-describedby="account-organizer-description"
      onCancel={(event) => {
        if (saving || accountPreferencesSync.phase === "error") {
          event.preventDefault();
          requestClose();
        }
      }}
      onClose={onClose}
      onClick={(event) => {
        if (event.target === event.currentTarget) requestClose();
      }}
    >
      <div className="account-organizer-surface">
        <header className="account-organizer-header">
          <div>
            <span className="page-eyebrow">Synced with iOS</span>
            <h2 id="account-organizer-title">Organise accounts</h2>
            <p id="account-organizer-description">
              Favourites, your groups, and account order are shared with your other signed-in devices. Cash, Credit, Tracking, and Closed stay a type index.
            </p>
          </div>
          <button type="button" className="account-organizer-close" onClick={requestClose} disabled={saving} aria-label="Close account organiser">×</button>
        </header>

        <SyncStatus state={accountPreferencesSync} onRetry={retryAccountPreferences} />

        {accountPreferencesSync.phase === "unsupported" ? (
          <section className="account-organizer-unsupported">
            <h3>Editing is unavailable</h3>
            <p>
              This server version does not expose synced account organisation. The existing sidebar remains available,
              and editing will appear after the server is upgraded.
            </p>
          </section>
        ) : (
          <div className="account-organizer-content">
            <section className="account-organizer-section" aria-labelledby="favourites-heading">
              <div className="account-organizer-section-heading">
                <div>
                  <h3 id="favourites-heading">Favourites</h3>
                  <p>Favourite open accounts appear first in the sidebar.</p>
                </div>
              </div>
              <AccountCheckboxes
                accounts={openAccounts}
                selected={new Set(preferences.favourite_account_ids)}
                legend="Choose favourite accounts"
                emptyMessage="There are no open accounts to favourite."
                onChange={(accountId, selected) => updateAccountPreferences((current) =>
                  setFavouriteAccount(current, accountId, selected))}
              />
            </section>

            <section className="account-organizer-section" aria-labelledby="custom-groups-heading">
              <div className="account-organizer-section-heading">
                <div>
                  <h3 id="custom-groups-heading">Custom groups</h3>
                  <p>An account can belong to more than one group.</p>
                </div>
              </div>
              <NewGroupForm preferences={preferences} onCreate={(id, name) =>
                updateAccountPreferences((current) => addCustomAccountGroup(current, id, name))} />
              {preferences.custom_account_groups.length === 0 ? (
                <p className="account-organizer-empty">No custom groups yet. Create one for collections such as Travel or Shared.</p>
              ) : (
                <div className="custom-group-list">
                  {preferences.custom_account_groups.map((group, index) => (
                    <CustomGroupEditor
                      key={group.id}
                      group={group}
                      index={index}
                      count={preferences.custom_account_groups.length}
                      accounts={accounts}
                      preferences={preferences}
                      onUpdate={updateAccountPreferences}
                    />
                  ))}
                </div>
              )}
            </section>

            <section className="account-organizer-section" aria-labelledby="collection-sort-heading">
              <div className="account-organizer-section-heading">
                <div>
                  <h3 id="collection-sort-heading">Your groups</h3>
                  <p>Sort Favourites and the groups you created. Manual order is shared across devices.</p>
                </div>
              </div>
              <GroupSortList
                items={[
                  BUILT_IN_GROUPS[0]!,
                  ...preferences.custom_account_groups.map((group) => ({ id: group.id, label: group.name })),
                ]}
                groupsById={groupsById}
                preferences={preferences}
                usage={usage}
                onRetryUsage={onRetryUsage}
                onUpdate={updateAccountPreferences}
              />
            </section>

            <section className="account-organizer-section" aria-labelledby="type-index-heading">
              <div className="account-organizer-section-heading">
                <div>
                  <h3 id="type-index-heading">By type</h3>
                  <p>Cash, Credit, Tracking, and Closed follow account type and closed status. Sort inside a list. Accounts do not move between these lists.</p>
                </div>
              </div>
              <GroupSortList
                items={BUILT_IN_GROUPS.slice(1)}
                groupsById={groupsById}
                preferences={preferences}
                usage={usage}
                onRetryUsage={onRetryUsage}
                onUpdate={updateAccountPreferences}
                tone="index"
              />
            </section>
          </div>
        )}

        <footer className="account-organizer-footer">
          <button type="button" className="save-button" onClick={requestClose} disabled={saving}>
            {saving ? "Saving…" : "Done"}
          </button>
        </footer>
      </div>
    </dialog>
  );
}

function GroupSortList({
  items,
  groupsById,
  preferences,
  usage,
  onRetryUsage,
  onUpdate,
  tone,
}: {
  items: Array<{ id: string; label: string }>;
  groupsById: Map<string, AccountGroup>;
  preferences: AccountPreferences;
  usage: AccountUsageState;
  onRetryUsage: () => void;
  onUpdate: (updater: (current: AccountPreferences) => AccountPreferences) => void;
  tone?: "index";
}) {
  return (
    <div className="group-sort-list">
      {items.map((item) => {
        const accountsInGroup = groupsById.get(item.id)?.accounts ?? [];
        const sort = preferences.account_group_sorts[item.id] ?? "manual";
        return (
          <div className={tone === "index" ? "group-sort-card group-sort-card-index" : "group-sort-card"} key={item.id}>
            <div className="group-sort-heading">
              <label htmlFor={`group-sort-${item.id}`}>{item.label}</label>
              <select
                id={`group-sort-${item.id}`}
                value={sort}
                onChange={(event) => onUpdate((current) =>
                  setAccountGroupSort(current, item.id, event.target.value as AccountGroupSort))}
              >
                {SORT_OPTIONS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
              </select>
            </div>
            {sort === "mostUsedLast30Days" && <UsageStatus usage={usage} onRetry={onRetryUsage} />}
            {sort === "manual" && accountsInGroup.length > 1 && (
              <ol className="account-order-list" aria-label={`Manual order for ${item.label}`}>
                {accountsInGroup.map((account, index) => (
                  <li key={account.id}>
                    <span>{account.name}</span>
                    <MoveButtons
                      label={account.name}
                      first={index === 0}
                      last={index === accountsInGroup.length - 1}
                      onMove={(direction) => onUpdate((current) => moveAccountInGroup(
                        current,
                        item.id,
                        accountsInGroup.map((entry) => entry.id),
                        account.id,
                        direction,
                      ))}
                    />
                  </li>
                ))}
              </ol>
            )}
            {accountsInGroup.length === 0 && (
              <p className="group-sort-empty">
                {tone === "index" ? "No accounts of this type." : "No accounts in this group."}
              </p>
            )}
          </div>
        );
      })}
    </div>
  );
}

function SyncStatus({ state, onRetry }: {
  state: ReturnType<typeof usePlan>["accountPreferencesSync"];
  onRetry: () => void;
}) {
  if (!state.message && state.phase === "idle") return null;
  return (
    <div
      className={`account-sync-status account-sync-status-${state.phase}`}
      role={state.phase === "error" || state.phase === "unsupported" ? "alert" : "status"}
      aria-live="polite"
    >
      <span>{state.phase === "saving" ? "● " : ""}{state.message}</span>
      {state.phase === "error" && <button type="button" onClick={onRetry}>Retry save</button>}
    </div>
  );
}

function NewGroupForm({ preferences, onCreate }: {
  preferences: ReturnType<typeof usePlan>["accountPreferencesSync"]["preferences"];
  onCreate: (id: string, name: string) => void;
}) {
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [submitted, setSubmitted] = useState(false);
  const createButtonRef = useRef<HTMLButtonElement>(null);
  const error = customAccountGroupNameError(preferences, name);
  const submit = (event: FormEvent) => {
    event.preventDefault();
    setSubmitted(true);
    if (error) return;
    onCreate(`custom-${crypto.randomUUID()}`, name);
    setName("");
    setSubmitted(false);
    setCreating(false);
    requestAnimationFrame(() => createButtonRef.current?.focus());
  };

  if (!creating) {
    return <button ref={createButtonRef} type="button" className="organizer-secondary-button" onClick={() => setCreating(true)}>+ New group</button>;
  }
  return (
    <form className="custom-group-form" onSubmit={submit}>
      <label htmlFor="new-account-group-name">Group name</label>
      <div className="custom-group-form-row">
        <input
          id="new-account-group-name"
          value={name}
          onChange={(event) => setName(event.target.value)}
          maxLength={100}
          autoFocus
          aria-invalid={submitted && Boolean(error)}
          aria-describedby="new-account-group-hint"
        />
        <button type="submit" className="organizer-primary-button">Create</button>
        <button type="button" className="text-button" onClick={() => {
          setCreating(false); setName(""); setSubmitted(false);
          requestAnimationFrame(() => createButtonRef.current?.focus());
        }}>Cancel</button>
      </div>
      <span id="new-account-group-hint" className={submitted && error ? "organizer-field-error" : "organizer-field-hint"} role={submitted && error ? "alert" : undefined}>
        {submitted && error ? error : "Names must be unique and cannot use a built-in group name."}
      </span>
    </form>
  );
}

function CustomGroupEditor({ group, index, count, accounts, preferences, onUpdate }: {
  group: CustomAccountGroup;
  index: number;
  count: number;
  accounts: Account[];
  preferences: ReturnType<typeof usePlan>["accountPreferencesSync"]["preferences"];
  onUpdate: ReturnType<typeof usePlan>["updateAccountPreferences"];
}) {
  const [renaming, setRenaming] = useState(false);
  const [name, setName] = useState(group.name);
  const [submitted, setSubmitted] = useState(false);
  const [confirmingDelete, setConfirmingDelete] = useState(false);
  const cardRef = useRef<HTMLElement>(null);
  const renameButtonRef = useRef<HTMLButtonElement>(null);
  const deleteButtonRef = useRef<HTMLButtonElement>(null);
  const error = customAccountGroupNameError(preferences, name, group.id);
  const sortedAccounts = useMemo(() => [...accounts].sort((first, second) =>
    Number(first.closed) - Number(second.closed) || accountNameOrder(first, second)), [accounts]);
  const rename = (event: FormEvent) => {
    event.preventDefault();
    setSubmitted(true);
    if (error) return;
    onUpdate((current) => renameCustomAccountGroup(current, group.id, name));
    setRenaming(false);
    setSubmitted(false);
    requestAnimationFrame(() => renameButtonRef.current?.focus());
  };

  const deleteGroup = () => {
    const card = cardRef.current;
    const focusTarget = card?.nextElementSibling ?? card?.previousElementSibling;
    onUpdate((current) => deleteCustomAccountGroup(current, group.id));
    requestAnimationFrame(() => {
      if (focusTarget instanceof HTMLElement && document.contains(focusTarget)) {
        focusTarget.querySelector<HTMLElement>("[data-focus-after-group-delete]")?.focus();
      } else {
        document.querySelector<HTMLElement>(".organizer-secondary-button")?.focus();
      }
    });
  };

  return (
    <article ref={cardRef} className="custom-group-card">
      <div className="custom-group-heading">
        <div>
          <strong>{group.name}</strong>
          <span>{group.account_ids.length} account{group.account_ids.length === 1 ? "" : "s"}</span>
        </div>
        <MoveButtons
          label={group.name}
          first={index === 0}
          last={index === count - 1}
          onMove={(direction) => onUpdate((current) => moveCustomAccountGroup(current, group.id, direction))}
        />
        <button
          ref={renameButtonRef}
          type="button"
          className="text-button"
          data-focus-after-group-delete
          onClick={() => { setName(group.name); setRenaming(true); }}
        >Rename</button>
        <button ref={deleteButtonRef} type="button" className="organizer-danger-link" onClick={() => setConfirmingDelete(true)}>Delete</button>
      </div>
      {renaming && (
        <form className="custom-group-form" onSubmit={rename}>
          <label htmlFor={`rename-${group.id}`}>New name for {group.name}</label>
          <div className="custom-group-form-row">
            <input
              id={`rename-${group.id}`}
              value={name}
              onChange={(event) => setName(event.target.value)}
              maxLength={100}
              autoFocus
              aria-invalid={submitted && Boolean(error)}
            />
            <button type="submit" className="organizer-primary-button">Save name</button>
            <button type="button" className="text-button" onClick={() => {
              setRenaming(false); setSubmitted(false);
              requestAnimationFrame(() => renameButtonRef.current?.focus());
            }}>Cancel</button>
          </div>
          {submitted && error && <span className="organizer-field-error" role="alert">{error}</span>}
        </form>
      )}
      {confirmingDelete && (
        <div className="custom-group-delete-confirm" role="alert">
          <span>Delete {group.name}? Accounts and transactions will not be deleted.</span>
          <div>
            <button type="button" className="text-button" onClick={() => {
              setConfirmingDelete(false);
              requestAnimationFrame(() => deleteButtonRef.current?.focus());
            }}>Cancel</button>
            <button type="button" className="organizer-danger-button" onClick={deleteGroup}>Delete group</button>
          </div>
        </div>
      )}
      <details className="custom-group-members">
        <summary>Choose accounts</summary>
        <AccountCheckboxes
          accounts={sortedAccounts}
          selected={new Set(group.account_ids)}
          legend={`Accounts in ${group.name}`}
          emptyMessage="There are no accounts to add."
          onChange={(accountId, included) => onUpdate((current) =>
            setAccountInCustomGroup(current, group.id, accountId, included))}
        />
      </details>
    </article>
  );
}

function AccountCheckboxes({ accounts, selected, legend, emptyMessage, onChange }: {
  accounts: Account[];
  selected: Set<string>;
  legend: string;
  emptyMessage: string;
  onChange: (accountId: string, included: boolean) => void;
}) {
  return (
    <fieldset className="account-checkboxes">
      <legend className="sr-only">{legend}</legend>
      {accounts.length === 0 ? <p>{emptyMessage}</p> : accounts.map((account) => (
        <label key={account.id}>
          <input
            type="checkbox"
            checked={selected.has(account.id)}
            onChange={(event) => onChange(account.id, event.target.checked)}
          />
          <span>{account.name}{account.closed ? " (closed)" : ""}</span>
        </label>
      ))}
    </fieldset>
  );
}

function MoveButtons({ label, first, last, onMove }: {
  label: string;
  first: boolean;
  last: boolean;
  onMove: (direction: -1 | 1) => void;
}) {
  return (
    <span className="organizer-move-buttons">
      <button type="button" onClick={() => onMove(-1)} disabled={first} aria-label={`Move ${label} up`}>↑</button>
      <button type="button" onClick={() => onMove(1)} disabled={last} aria-label={`Move ${label} down`}>↓</button>
    </span>
  );
}

function UsageStatus({ usage, onRetry }: { usage: AccountUsageState; onRetry: () => void }) {
  if (usage.phase === "loading" || usage.phase === "idle") {
    return <p className="group-sort-note" role="status">Loading 30-day usage…</p>;
  }
  if (usage.phase === "error") {
    return (
      <p className="group-sort-note group-sort-note-error" role="alert">
        30-day usage unavailable: {usage.message} <button type="button" onClick={onRetry}>Retry</button>
      </p>
    );
  }
  return <p className="group-sort-note">Ordered by transactions in the last 30 days.</p>;
}

function accountNameOrder(first: Account, second: Account): number {
  return first.name.localeCompare(second.name, undefined, { numeric: true, sensitivity: "base" })
    || first.id.localeCompare(second.id);
}
