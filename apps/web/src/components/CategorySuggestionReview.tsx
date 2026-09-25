import { CategorySelect } from "./CategorySelect";
import { splitCategoryGroups } from "../lib/categories";
import { appliedReviewItems, type SuggestionReviewRow } from "../lib/category-suggestions";
import { formatMoney } from "../lib/money";

export function CategorySuggestionReview({
  rows,
  groups,
  busy,
  onChange,
  onApply,
  onCancel,
}: {
  rows: SuggestionReviewRow[];
  groups: ReturnType<typeof splitCategoryGroups>;
  busy: boolean;
  onChange: (rows: SuggestionReviewRow[]) => void;
  onApply: () => void;
  onCancel: () => void;
}) {
  const applyCount = appliedReviewItems(rows).length;
  const update = (index: number, patch: Partial<SuggestionReviewRow>) =>
    onChange(rows.map((row, i) => (i === index ? { ...row, ...patch } : row)));

  return (
    <section className="category-suggestions" role="region" aria-labelledby="category-suggestions-heading">
      <div className="category-suggestions-head">
        <h2 id="category-suggestions-heading">Suggested categories</h2>
        <p>
          Suggested by Jev from each payee, memo and amount, and how similar past transactions were categorised. Ticked rows are confident
          suggestions; check them and change any before applying.
        </p>
      </div>
      <div className="table-wrap">
        <table className="ledger-table category-suggestions-table">
          <thead>
            <tr>
              <th scope="col"><span className="sr-only">Apply</span></th>
              <th scope="col">Payee</th>
              <th scope="col">Memo</th>
              <th scope="col" className="num">Amount</th>
              <th scope="col">Category</th>
              <th scope="col" className="num">Confidence</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row, index) => {
              const { transaction, suggestion } = row;
              const label = transaction.payee_name ?? transaction.memo ?? "transaction";
              return (
                <tr key={transaction.id}>
                  <td>
                    <input
                      type="checkbox"
                      checked={row.include}
                      onChange={(event) => update(index, { include: event.target.checked })}
                      disabled={busy || !row.categoryId}
                      aria-label={`Apply category to ${label}`}
                    />
                  </td>
                  <td>{transaction.payee_name ?? ""}</td>
                  <td className="muted">{transaction.memo ?? ""}</td>
                  <td className="num">{formatMoney(transaction.amount, { sign: true })}</td>
                  <td>
                    <CategorySelect
                      aria-label={`Category for ${label}`}
                      value={row.categoryId}
                      onChange={(categoryId) => update(index, { categoryId, include: Boolean(categoryId) })}
                      groups={groups}
                      emptyLabel={suggestion && !suggestion.suggestion ? "No match, choose…" : "Uncategorised"}
                      disabled={busy}
                    />
                  </td>
                  <td className="num muted">
                    {suggestion ? `${Math.round(suggestion.confidence * 100)}%` : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <div className="category-suggestions-actions">
        <button type="button" className="text-button" onClick={onCancel} disabled={busy}>Cancel</button>
        <button type="button" className="register-compose-save" onClick={onApply} disabled={busy || applyCount === 0}>
          {busy ? "Applying…" : `Apply ${applyCount} categor${applyCount === 1 ? "y" : "ies"}`}
        </button>
      </div>
    </section>
  );
}
