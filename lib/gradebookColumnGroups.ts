/**
 * Shapes gradebook columns into the header groups the gradebook renders.
 *
 * Which group a column is in is data (`gradebook_columns.group_id` → `gradebook_column_groups`);
 * nothing here looks at slugs. This only decides layout: a group is drawn where its first member
 * is, with all of its members after it in `sort_order` order, and an ungrouped column is drawn
 * as a group of one, which the gradebook renders without a header.
 *
 * The database keeps each group's members adjacent in `sort_order` (see
 * `gradebook_columns_make_groups_contiguous`), so anchoring at the first member only changes
 * anything when that invariant is momentarily broken, e.g. between a reorder and its refetch.
 */

export type GradebookColumnGroupRow = { id: number; name: string };

export type GroupableGradebookColumn = {
  id: number;
  name: string;
  sort_order: number | null;
  group_id: number | null;
};

export type GradebookColumnGrouping<C> = Record<string, { groupName: string; columns: C[] }>;

/** Record keys are never integer-like, so JS object key order is insertion (display) order. */
export function gradebookGroupKey(column: Pick<GroupableGradebookColumn, "id" | "group_id">, hasGroup: boolean) {
  return hasGroup && column.group_id != null ? `group-${column.group_id}` : `column-${column.id}`;
}

export function groupGradebookColumns<C extends GroupableGradebookColumn>(
  columns: readonly C[],
  groups: readonly GradebookColumnGroupRow[]
): GradebookColumnGrouping<C> {
  const groupNameById = new Map(groups.map((g) => [g.id, g.name]));
  const ordered = [...columns].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0) || a.id - b.id);

  const result: GradebookColumnGrouping<C> = {};
  for (const col of ordered) {
    // A column whose group row we can't see (not loaded yet, or hidden by RLS) is drawn alone.
    const groupName = col.group_id != null ? groupNameById.get(col.group_id) : undefined;
    const key = gradebookGroupKey(col, groupName !== undefined);
    if (!result[key]) {
      result[key] = { groupName: groupName ?? col.name, columns: [] };
    }
    result[key].columns.push(col);
  }
  return result;
}

/** Inverse lookup for the render paths that start from a column and need its group. */
export function groupKeyByColumnId<C extends { id: number }>(grouping: GradebookColumnGrouping<C>) {
  const map = new Map<number, string>();
  for (const [key, group] of Object.entries(grouping)) {
    for (const col of group.columns) map.set(col.id, key);
  }
  return map;
}
