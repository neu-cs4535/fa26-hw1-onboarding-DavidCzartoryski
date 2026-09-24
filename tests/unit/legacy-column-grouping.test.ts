/**
 * The render-time grouping heuristic this change replaced, ported verbatim from the
 * groupedColumns memo that manage/gradebook/gradebookTable.tsx and gradebook/whatIf.tsx used to
 * run on every render. These tests pin down what it did in the cases the PR lists (the "before"
 * column of the table in the PR description); supabase/tests/gradebook_column_groups_backfill_test.sql
 * checks what the backfill does with the same shapes (the "after" column).
 */

type LegacyColumn = { id: number; slug: string; sort_order: number | null };

function legacyGroupedColumns(input: LegacyColumn[]) {
  const groups: Record<string, { groupName: string; columns: LegacyColumn[] }> = {};
  const columns = [...input].sort((a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0));
  let currentGroupKey = "";
  let currentGroupIndex = 0;
  let lastSortOrder = -1;
  for (const col of columns) {
    const slugParts = col.slug.split("-");
    const baseGroupName =
      slugParts[0] === "assignment" && slugParts.length >= 3
        ? `${slugParts[0]}-${slugParts[1]}`
        : slugParts[0] || "other";
    const currentSortOrder = col.sort_order ?? 0;
    const isContiguous = lastSortOrder === -1 || currentSortOrder === lastSortOrder + 1;
    if (!isContiguous || baseGroupName !== currentGroupKey) {
      currentGroupKey = baseGroupName;
      currentGroupIndex++;
    }
    const groupKey = `${baseGroupName}-${currentGroupIndex}`;
    if (!groups[groupKey]) {
      let displayName: string;
      if (baseGroupName === "other") displayName = "Other";
      else if (baseGroupName.startsWith("assignment-")) {
        const subType = baseGroupName.split("-")[1];
        displayName = `${subType.charAt(0).toUpperCase() + subType.slice(1)}`;
      } else displayName = baseGroupName.charAt(0).toUpperCase() + baseGroupName.slice(1);
      groups[groupKey] = { groupName: displayName, columns: [] };
    }
    groups[groupKey].columns.push(col);
    lastSortOrder = currentSortOrder;
  }
  return groups;
}

/** "Name[slug,slug]" for each rendered group of two or more, and "slug" for the rest. */
function rendered(columns: LegacyColumn[]) {
  return Object.values(legacyGroupedColumns(columns)).map((g) =>
    g.columns.length > 1 ? `${g.groupName}[${g.columns.map((c) => c.slug).join(",")}]` : g.columns[0].slug
  );
}

let nextId = 1;
const c = (slug: string, sort_order: number | null): LegacyColumn => ({ id: nextId++, slug, sort_order });

describe("the render-time heuristic this change replaced", () => {
  it("F1: a hole in sort_order splits a family into two groups with the same title", () => {
    expect(rendered([c("quiz-1", 11), c("quiz-2", 12), c("quiz-4", 14), c("quiz-5", 15)])).toEqual([
      "Quiz[quiz-1,quiz-2]",
      "Quiz[quiz-4,quiz-5]"
    ]);
  });

  it("F2: those two groups share one title, and collapse state was keyed by title", () => {
    const titles = Object.values(legacyGroupedColumns([c("quiz-1", 0), c("quiz-2", 1), c("quiz-4", 3), c("quiz-5", 4)]))
      .filter((g) => g.columns.length > 1)
      .map((g) => g.groupName);
    expect(new Set(titles).size).toBeLessThan(titles.length);
  });

  it("F3: the title comes from the slug, not the column names", () => {
    expect(rendered([c("ai-usage-log-1", 37), c("ai-usage-log-2", 38)])).toEqual(["Ai[ai-usage-log-1,ai-usage-log-2]"]);
  });

  it("F4: columns computed from the same inputs scatter into groups of one", () => {
    expect(
      rendered([c("meets-expectations", 28), c("approaching-expectations", 29), c("does-not-meet-expectations", 30)])
    ).toEqual(["meets-expectations", "approaching-expectations", "does-not-meet-expectations"]);
  });

  it("F6: a NULL sort_order collides with the column at 0 and splits the family", () => {
    expect(
      rendered([
        c("assignment-assignment-1", 0),
        c("assignment-assignment-1-code-walk", null),
        c("assignment-assignment-2", 1)
      ])
    ).toEqual(["assignment-assignment-1", "Assignment[assignment-assignment-1-code-walk,assignment-assignment-2]"]);
  });

  it("F8: every two-part assignment slug lands in one family, whatever the assignment", () => {
    expect(rendered([c("assignment-hw1", 0), c("assignment-hw2", 1), c("assignment-final", 2)])).toEqual([
      "Assignment[assignment-hw1,assignment-hw2,assignment-final]"
    ]);
  });

  it("F9: a final grade computed from the final exam is grouped with it as a sibling", () => {
    expect(rendered([c("final-exam", 0), c("final-grade", 1)])).toEqual(["Final[final-exam,final-grade]"]);
  });
});
