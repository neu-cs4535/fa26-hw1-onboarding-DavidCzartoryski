"use client";
import { useCallback, useEffect, useRef, useState } from "react";

type StoredCollapseState = { seen: string[]; collapsed: string[] };

function readStored(storageKey: string | undefined): StoredCollapseState | null {
  if (!storageKey || typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<StoredCollapseState>;
    if (!Array.isArray(parsed.seen) || !Array.isArray(parsed.collapsed)) return null;
    return {
      seen: parsed.seen.filter((k): k is string => typeof k === "string"),
      collapsed: parsed.collapsed.filter((k): k is string => typeof k === "string")
    };
  } catch {
    return null;
  }
}

function writeStored(storageKey: string | undefined, seen: ReadonlySet<string>, collapsed: ReadonlySet<string>) {
  if (!storageKey || typeof window === "undefined") return;
  try {
    window.localStorage.setItem(storageKey, JSON.stringify({ seen: [...seen], collapsed: [...collapsed] }));
  } catch {
    // Storage full or disabled: collapse state just won't survive a reload.
  }
}

/**
 * Collapse state for a gradebook's column groups, shared by the instructor table and the student
 * what-if view. Keyed by group key ("group-<id>"), so renaming a group, here or by another
 * instructor, keeps its state.
 *
 * A group starts collapsed the first time this browser sees it; after that it keeps whatever
 * state the user left it in. With `storageKey`, that survives a reload (localStorage).
 */
export function useColumnGroupCollapse(groupKeys: readonly string[], storageKey?: string) {
  const [collapsedGroups, setCollapsedGroups] = useState<ReadonlySet<string>>(() => new Set());
  const collapsedRef = useRef<ReadonlySet<string>>(collapsedGroups);
  const seenRef = useRef<Set<string> | null>(null);

  const commit = useCallback(
    (next: ReadonlySet<string>) => {
      collapsedRef.current = next;
      setCollapsedGroups(next);
      if (seenRef.current) writeStored(storageKey, seenRef.current, next);
    },
    [storageKey]
  );

  const signature = groupKeys.join("|");
  useEffect(() => {
    let changed = false;
    if (seenRef.current === null) {
      const stored = readStored(storageKey);
      seenRef.current = new Set(stored?.seen ?? []);
      if (stored) {
        collapsedRef.current = new Set(stored.collapsed);
        changed = true;
      }
    }
    const seen = seenRef.current;
    const next = new Set(collapsedRef.current);
    for (const key of signature ? signature.split("|") : []) {
      if (!seen.has(key)) {
        seen.add(key);
        next.add(key);
        changed = true;
      }
    }
    if (changed) commit(next);
  }, [signature, storageKey, commit]);

  const toggleGroup = useCallback(
    (groupKey: string) => {
      const next = new Set(collapsedRef.current);
      if (next.has(groupKey)) next.delete(groupKey);
      else next.add(groupKey);
      commit(next);
    },
    [commit]
  );

  const expandAll = useCallback(() => commit(new Set()), [commit]);
  const collapseAll = useCallback(() => commit(new Set(signature ? signature.split("|") : [])), [commit, signature]);

  return { collapsedGroups, toggleGroup, expandAll, collapseAll };
}
