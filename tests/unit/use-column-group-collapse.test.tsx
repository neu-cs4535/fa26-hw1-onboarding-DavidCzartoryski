/**
 * Collapse state for column groups (hooks/useColumnGroupCollapse), shared by the instructor table
 * and the student what-if view.
 */
import { act, renderHook } from "@testing-library/react";
import { useColumnGroupCollapse } from "@/hooks/useColumnGroupCollapse";

const STORAGE_KEY = "test:collapse";

beforeEach(() => window.localStorage.clear());

function setup(initialKeys: string[], storageKey?: string) {
  return renderHook(({ keys }) => useColumnGroupCollapse(keys, storageKey), { initialProps: { keys: initialKeys } });
}

const collapsed = (result: { current: ReturnType<typeof useColumnGroupCollapse> }) =>
  [...result.current.collapsedGroups].sort();

describe("useColumnGroupCollapse", () => {
  it("starts every group collapsed the first time it appears", () => {
    const { result } = setup(["group-1", "group-2"]);
    expect(collapsed(result)).toEqual(["group-1", "group-2"]);
  });

  it("keeps an expanded group expanded when the grouping changes around it", () => {
    const { result, rerender } = setup(["group-1", "group-2"]);
    act(() => result.current.expandAll());
    // A column moved, a group was renamed (same key), and a new group appeared.
    rerender({ keys: ["group-2", "group-1", "group-3"] });
    expect(collapsed(result)).toEqual(["group-3"]);
  });

  it("toggles one group", () => {
    const { result } = setup(["group-1", "group-2"]);
    act(() => result.current.toggleGroup("group-1"));
    expect(collapsed(result)).toEqual(["group-2"]);
    act(() => result.current.toggleGroup("group-1"));
    expect(collapsed(result)).toEqual(["group-1", "group-2"]);
  });

  it("collapses every current group", () => {
    const { result } = setup(["group-1", "group-2"]);
    act(() => result.current.expandAll());
    act(() => result.current.collapseAll());
    expect(collapsed(result)).toEqual(["group-1", "group-2"]);
  });

  it("waits for groups that load after the first render", () => {
    const { result, rerender } = setup([]);
    expect(collapsed(result)).toEqual([]);
    rerender({ keys: ["group-1"] });
    expect(collapsed(result)).toEqual(["group-1"]);
  });

  it("remembers the state across a reload when given a storage key", () => {
    const first = setup(["group-1", "group-2"], STORAGE_KEY);
    act(() => first.result.current.toggleGroup("group-1"));
    first.unmount();

    // Groups arrive after the first render, as they do on a real page load.
    const second = setup([], STORAGE_KEY);
    second.rerender({ keys: ["group-1", "group-2", "group-3"] });
    expect(collapsed(second.result)).toEqual(["group-2", "group-3"]);
  });

  it("ignores a corrupt stored value", () => {
    window.localStorage.setItem(STORAGE_KEY, "{not json");
    const { result } = setup(["group-1"], STORAGE_KEY);
    expect(collapsed(result)).toEqual(["group-1"]);
  });
});
