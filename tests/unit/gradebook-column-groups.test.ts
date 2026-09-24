/**
 * Unit tests for `groupGradebookColumns`, which turns stored group membership into the header
 * groups the instructor gradebook and the student what-if view render. The point of the function
 * is that it only lays out rows it was handed: none of these cases can be decided from a slug.
 */
import { groupGradebookColumns, groupKeyByColumnId } from "@/lib/gradebookColumnGroups";

type Col = { id: number; name: string; slug: string; sort_order: number | null; group_id: number | null };

const col = (id: number, sort_order: number | null, group_id: number | null, slug = `c-${id}`): Col => ({
  id,
  name: `Column ${id}`,
  slug,
  sort_order,
  group_id
});

const shape = (grouping: ReturnType<typeof groupGradebookColumns<Col>>) =>
  Object.entries(grouping).map(([key, g]) => [key, g.groupName, g.columns.map((c) => c.id)]);

describe("groupGradebookColumns", () => {
  const groups = [
    { id: 1, name: "Quiz" },
    { id: 2, name: "Exam" }
  ];

  it("groups by group_id, in sort_order, regardless of holes in sort_order", () => {
    // The render-time heuristic split this into two "Quiz" groups at the 12 -> 14 hole.
    const columns = [col(11, 11, 1), col(12, 12, 1), col(14, 14, 1), col(15, 15, 1)];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([["group-1", "Quiz", [11, 12, 14, 15]]]);
  });

  it("ignores slugs entirely", () => {
    // Same prefix, different groups; different prefixes, same group.
    const columns = [
      col(1, 0, 1, "quiz-1"),
      col(2, 1, 2, "quiz-2"),
      col(3, 2, 2, "meets-expectations"),
      col(4, 3, 2, "approaching-expectations")
    ];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([
      ["group-1", "Quiz", [1]],
      ["group-2", "Exam", [2, 3, 4]]
    ]);
  });

  it("draws ungrouped columns as groups of one named after the column", () => {
    const columns = [col(1, 0, null), col(2, 1, 1), col(3, 2, 1), col(4, 3, null)];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([
      ["column-1", "Column 1", [1]],
      ["group-1", "Quiz", [2, 3]],
      ["column-4", "Column 4", [4]]
    ]);
  });

  it("anchors a group at its first member if its members are not adjacent", () => {
    const columns = [col(1, 0, 1), col(2, 1, null), col(3, 2, 1)];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([
      ["group-1", "Quiz", [1, 3]],
      ["column-2", "Column 2", [2]]
    ]);
  });

  it("draws a column alone when its group row is not visible", () => {
    const columns = [col(1, 0, 99), col(2, 1, 99)];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([
      ["column-1", "Column 1", [1]],
      ["column-2", "Column 2", [2]]
    ]);
  });

  it("only groups the columns it was given (students never see staff-only members)", () => {
    const visibleToStudent = [col(1, 0, 2), col(3, 2, 2)];
    expect(shape(groupGradebookColumns(visibleToStudent, groups))).toEqual([["group-2", "Exam", [1, 3]]]);
  });

  it("keeps display order when ids look like integers", () => {
    // Integer-like object keys would be reordered by the JS engine; keys are always prefixed.
    const columns = [col(30, 0, null), col(2, 1, null), col(10, 2, null)];
    expect(Object.keys(groupGradebookColumns(columns, groups))).toEqual(["column-30", "column-2", "column-10"]);
  });

  it("builds a column -> group key lookup", () => {
    const grouping = groupGradebookColumns([col(1, 0, 1), col(2, 1, null)], groups);
    expect([...groupKeyByColumnId(grouping)]).toEqual([
      [1, "group-1"],
      [2, "column-2"]
    ]);
  });
});
