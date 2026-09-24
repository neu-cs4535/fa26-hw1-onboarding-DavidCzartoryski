/**
 * Shapes gradebook columns into the header groups the gradebook renders.
 *
 * Which group a column is in is data (`gradebook_columns.group_id` → `gradebook_column_groups`);
 * nothing here looks at slugs. This only decides layout: a group is drawn where its first member
 * is, with all of its members after it in `sort_order` order, and an ungrouped column is drawn
 * as a group of one, which the gradebook renders without a header. A stored group always gets a
 * header, even with one member: an instructor made it, so it should be visible and editable.
 *
 * The order matches `gradebook_columns_display_order` in the database exactly: columns sorted by
 * (sort_order, id) with a NULL sort_order as 0, and each group drawn whole at its first column.
 * The database keeps each group's members adjacent in `sort_order`, so anchoring at the first
 * member only changes anything when that invariant is momentarily broken, e.g. between a
 * reorder and its refetch.
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

/** True for a stored group; false for an ungrouped column drawn on its own. */
export function isColumnGroupKey(key: string) {
  return key.startsWith("group-");
}

/** The gradebook_column_groups id behind a group key, or null for an ungrouped column. */
export function columnGroupIdFromKey(key: string): number | null {
  return isColumnGroupKey(key) ? Number(key.slice("group-".length)) : null;
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

/**
 * The column a collapsed group shows: its last column with any score (the newest graded work),
 * or its last column if none has a score yet.
 */
export function pickCollapsedGroupColumnId(
  columns: readonly { id: number }[],
  hasScore: (columnId: number) => boolean
): number | undefined {
  for (let i = columns.length - 1; i >= 0; i--) {
    if (hasScore(columns[i].id)) return columns[i].id;
  }
  return columns[columns.length - 1]?.id;
}

/**
 * Which drop gaps a dragged column may use without changing any group's membership. Gap `i` is
 * the boundary before unit `i` (gap `units.length` is after the last one).
 *
 * `unitGroupKeys[i]` is the group key of unit `i` when it is one column of an expanded group, and
 * null for an ungrouped column or a collapsed group (which moves as one unit).
 * `draggedGroupKey` is the expanded group the dragged column belongs to, or null.
 *
 * A member of an expanded group can be dropped anywhere inside its group, edges included; any
 * other unit can be dropped anywhere except strictly inside an expanded group.
 */
export function validDropGaps(unitGroupKeys: readonly (string | null)[], draggedGroupKey: string | null): boolean[] {
  const n = unitGroupKeys.length;
  return Array.from({ length: n + 1 }, (_, gap) => {
    const left = gap > 0 ? unitGroupKeys[gap - 1] : null;
    const right = gap < n ? unitGroupKeys[gap] : null;
    if (draggedGroupKey !== null) return left === draggedGroupKey || right === draggedGroupKey;
    return !(left !== null && left === right);
  });
}

/**
 * A column's display name without a trailing "(...)" or number: "Lab 1 (Group)" -> "Lab",
 * "Skill #12" -> "Skill". Mirrors `gradebook_column_name_stem` in the database; used to suggest a
 * name for a new group.
 */
export function columnNameStem(name: string): string {
  return name
    .replace(/\s*\([^)]*\)\s*$/, "")
    .replace(/\s*#?\s*\d+\s*$/, "")
    .trim();
}

type SuggestableColumn = GroupableGradebookColumn & { dependencies?: unknown };

/** The column ids a computed column reads (`dependencies.gradebook_columns`), sorted, or null. */
export function dependencyKey(dependencies: unknown): string | null {
  if (!dependencies || typeof dependencies !== "object") return null;
  const ids = (dependencies as { gradebook_columns?: unknown }).gradebook_columns;
  if (!Array.isArray(ids)) return null;
  const numbers = ids.filter((id): id is number => typeof id === "number" && Number.isInteger(id));
  if (numbers.length === 0) return null;
  return [...new Set(numbers)].sort((a, b) => a - b).join(",");
}

/**
 * Groups worth offering first when moving `column` into a group, best first:
 *   1. groups with a column computed from exactly the same inputs (another tally of the same
 *      skills belongs with the others, even when a column sits between them);
 *   2. the groups of the columns right before and after it.
 * Never includes the column's own group.
 */
export function suggestColumnGroups(
  column: SuggestableColumn,
  columns: readonly SuggestableColumn[],
  groups: readonly GradebookColumnGroupRow[]
): number[] {
  const groupIds = new Set(groups.map((g) => g.id));
  const suggestions: number[] = [];
  const add = (groupId: number | null | undefined) => {
    if (groupId == null || groupId === column.group_id || !groupIds.has(groupId)) return;
    if (!suggestions.includes(groupId)) suggestions.push(groupId);
  };

  const key = dependencyKey(column.dependencies);
  if (key !== null) {
    for (const other of columns) {
      if (other.id !== column.id && dependencyKey(other.dependencies) === key) add(other.group_id);
    }
  }

  const ordered = Object.values(groupGradebookColumns(columns, groups)).flatMap((g) => g.columns);
  const index = ordered.findIndex((c) => c.id === column.id);
  if (index > 0) add(ordered[index - 1].group_id);
  if (index >= 0 && index < ordered.length - 1) add(ordered[index + 1].group_id);

  return suggestions;
}
