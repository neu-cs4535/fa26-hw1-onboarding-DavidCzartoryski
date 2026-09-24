/**
 * Unit tests for `groupGradebookColumns`, which turns stored group membership into the header
 * groups the instructor gradebook and the student what-if view render. The point of the function
 * is that it only lays out rows it was handed: none of these cases can be decided from a slug.
 */
import {
  columnGroupIdFromKey,
  columnNameStem,
  dependencyKey,
  groupGradebookColumns,
  groupKeyByColumnId,
  isColumnGroupKey,
  pickCollapsedGroupColumnId,
  suggestColumnGroups,
  validDropGaps
} from "@/lib/gradebookColumnGroups";

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

  it("tells a stored group of one from an ungrouped column", () => {
    // Both have one column; only the stored group gets a header and a group menu.
    const grouping = groupGradebookColumns([col(1, 0, 1), col(2, 1, null)], groups);
    expect(Object.keys(grouping).map((key) => [key, isColumnGroupKey(key), columnGroupIdFromKey(key)])).toEqual([
      ["group-1", true, 1],
      ["column-2", false, null]
    ]);
  });

  it("builds a column -> group key lookup", () => {
    const grouping = groupGradebookColumns([col(1, 0, 1), col(2, 1, null)], groups);
    expect([...groupKeyByColumnId(grouping)]).toEqual([
      [1, "group-1"],
      [2, "column-2"]
    ]);
  });
});

describe("ordering matches gradebook_columns_display_order", () => {
  const groups = [{ id: 1, name: "Exam" }];

  it("does not interleave a group with an ungrouped column that ties with its first column", () => {
    // exam-1 (id 31) and attendance (id 39) share sort_order 8: the group is drawn whole first.
    const columns = [col(31, 8, 1), col(39, 8, null), col(32, 9, 1), col(33, 10, 1)];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([
      ["group-1", "Exam", [31, 32, 33]],
      ["column-39", "Column 39", [39]]
    ]);
  });

  it("treats a NULL sort_order as 0 and breaks the tie by id", () => {
    const columns = [col(5, 1, null), col(7, null, 1), col(3, 0, 1)];
    expect(shape(groupGradebookColumns(columns, groups))).toEqual([
      ["group-1", "Exam", [3, 7]],
      ["column-5", "Column 5", [5]]
    ]);
  });
});

describe("pickCollapsedGroupColumnId", () => {
  const cols = [{ id: 1 }, { id: 2 }, { id: 3 }];
  it("picks the last column with a score", () => {
    expect(pickCollapsedGroupColumnId(cols, (id) => id <= 2)).toBe(2);
  });
  it("falls back to the last column when nothing is scored", () => {
    expect(pickCollapsedGroupColumnId(cols, () => false)).toBe(3);
  });
  it("returns undefined for an empty group", () => {
    expect(pickCollapsedGroupColumnId([], () => true)).toBeUndefined();
  });
});

describe("validDropGaps", () => {
  // Units: ungrouped A, expanded group g (two columns), collapsed group (one unit), ungrouped B.
  const units = [null, "group-1", "group-1", null, null];

  it("keeps a member of an expanded group inside it, edges included", () => {
    expect(validDropGaps(units, "group-1")).toEqual([false, true, true, true, false, false]);
  });
  it("keeps everything else out of the inside of an expanded group", () => {
    expect(validDropGaps(units, null)).toEqual([true, true, false, true, true, true]);
  });
  it("allows the boundary between two expanded groups", () => {
    expect(validDropGaps(["group-1", "group-2"], null)).toEqual([true, true, true]);
  });
});

describe("columnNameStem", () => {
  it.each([
    ["Lab 1 (Group)", "Lab"],
    ["Skill #12", "Skill"],
    ["AI Usage Log 2", "AI Usage Log"],
    ["Quiz (2) 1", "Quiz (2)"],
    ["Participation", "Participation"]
  ])("%s -> %s", (name, stem) => {
    expect(columnNameStem(name)).toBe(stem);
  });
});

describe("dependencyKey", () => {
  it("normalizes a gradebook_columns dependency list", () => {
    expect(dependencyKey({ gradebook_columns: [3, 1, 3, 2] })).toBe("1,2,3");
  });
  it("ignores anything that is not a column id", () => {
    expect(dependencyKey({ gradebook_columns: ["x", 1.5, null, 4] })).toBe("4");
    expect(dependencyKey({ assignments: [1] })).toBeNull();
    expect(dependencyKey(null)).toBeNull();
  });
});

describe("suggestColumnGroups", () => {
  const groups = [
    { id: 1, name: "Skill" },
    { id: 2, name: "Skill summary" },
    { id: 3, name: "Quiz" }
  ];
  const skills = { gradebook_columns: [10, 11] };
  const columns = [
    { ...col(10, 0, 1), dependencies: null },
    { ...col(11, 1, 1), dependencies: null },
    { ...col(20, 2, 2), dependencies: skills },
    { ...col(21, 3, 2), dependencies: skills },
    { ...col(30, 4, null), dependencies: null },
    { ...col(40, 5, null), dependencies: skills },
    { ...col(50, 6, 3), dependencies: null }
  ];

  it("offers the group computed from the same inputs first, then the neighbors' groups", () => {
    // Column 40 tallies the same skills as the Skill summary, with column 30 in between.
    expect(suggestColumnGroups(columns[5], columns, groups)).toEqual([2, 3]);
  });
  it("never offers the column's own group", () => {
    expect(suggestColumnGroups(columns[2], columns, groups)).toEqual([1]);
  });
});
