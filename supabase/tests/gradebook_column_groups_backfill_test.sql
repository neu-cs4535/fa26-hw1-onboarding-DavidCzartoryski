-- Column groups: the backfill, the invariants the database enforces, and column order.
-- Run with `npx supabase test db`. Everything happens in one transaction that is rolled back.
BEGIN;
SET client_min_messages TO error;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT * FROM no_plan();

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

CREATE FUNCTION pg_temp.gid(p_slug text) RETURNS bigint LANGUAGE sql AS $$
  SELECT gradebook_id FROM public.classes WHERE slug = p_slug
$$;
CREATE FUNCTION pg_temp.cid(p_slug text) RETURNS bigint LANGUAGE sql AS $$
  SELECT id FROM public.classes WHERE slug = p_slug
$$;
CREATE FUNCTION pg_temp.col(p_class_slug text, p_slug text) RETURNS bigint LANGUAGE sql AS $$
  SELECT gc.id FROM public.gradebook_columns gc JOIN public.classes c ON c.id = gc.class_id
  WHERE c.slug = p_class_slug AND gc.slug = p_slug
$$;
CREATE FUNCTION pg_temp.grp(p_class_slug text, p_name text) RETURNS bigint LANGUAGE sql AS $$
  SELECT g.id FROM public.gradebook_column_groups g WHERE g.gradebook_id = pg_temp.gid(p_class_slug) AND g.name = p_name
$$;
-- "Group:slug" for grouped columns, "slug" for the rest, left to right as stored.
CREATE FUNCTION pg_temp.layout(p_class_slug text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(CASE WHEN g.id IS NULL THEN gc.slug ELSE g.name || ':' || gc.slug END, ' '
                    ORDER BY COALESCE(gc.sort_order, 0), gc.id)
  FROM public.gradebook_columns gc
  LEFT JOIN public.gradebook_column_groups g ON g.id = gc.group_id
  WHERE gc.gradebook_id = pg_temp.gid(p_class_slug)
$$;
-- Same, but in the order gradebook_columns_display_order draws them.
CREATE FUNCTION pg_temp.display(p_class_slug text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(CASE WHEN g.id IS NULL THEN gc.slug ELSE g.name || ':' || gc.slug END, ' ' ORDER BY d.pos)
  FROM public.gradebook_columns_display_order(pg_temp.gid(p_class_slug)) d
  JOIN public.gradebook_columns gc ON gc.id = d.id
  LEFT JOIN public.gradebook_column_groups g ON g.id = gc.group_id
$$;
CREATE FUNCTION pg_temp.add(p_class_slug text, p_slug text, p_name text, p_sort integer, p_deps jsonb DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO public.gradebook_columns (class_id, gradebook_id, name, slug, max_score, sort_order, dependencies, score_expression)
  VALUES (pg_temp.cid(p_class_slug), pg_temp.gid(p_class_slug), p_name, p_slug, 10, p_sort, p_deps,
          CASE WHEN p_deps IS NULL THEN NULL ELSE 'mean(gradebook_columns("x"))' END)
  RETURNING id
$$;
CREATE FUNCTION pg_temp.deps(p_class_slug text, VARIADIC p_slugs text[]) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('gradebook_columns', jsonb_agg(pg_temp.col(p_class_slug, s)))
  FROM unnest(p_slugs) AS s
$$;

INSERT INTO public.classes (name, slug) VALUES
  ('Legacy course', 'test-legacy'),
  ('Tie course', 'test-ties'),
  ('New course', 'test-new'),
  ('Other course', 'test-other'),
  ('Audit course', 'test-audit');

-- ---------------------------------------------------------------------------------------------
-- The backfill, on a course built the way it would have looked before the migration
-- ---------------------------------------------------------------------------------------------

ALTER TABLE public.gradebook_columns DISABLE TRIGGER gradebook_columns_inherit_group_tr;

SELECT pg_temp.add('test-legacy', 'hw-1', 'HW 1', 0);
SELECT pg_temp.add('test-legacy', 'hw-2', 'HW 2', 1);
SELECT pg_temp.add('test-legacy', 'midterm', 'Midterm', 2);
SELECT pg_temp.add('test-legacy', 'hw-3', 'HW 3', 3);
SELECT pg_temp.add('test-legacy', 'hw-4', 'Homework 4', 4);
SELECT pg_temp.add('test-legacy', 'quiz-1', 'Quiz 1', 5);
SELECT pg_temp.add('test-legacy', 'quiz-2', 'Quiz 2', 6);
SELECT pg_temp.add('test-legacy', 'quiz-4', 'Quiz 4', 8);            -- hole at 7 (F1)
SELECT pg_temp.add('test-legacy', 'bonus', 'Bonus', 9);
SELECT pg_temp.add('test-legacy', 'quiz-5', 'Quiz 5', 10);
SELECT pg_temp.add('test-legacy', 'quiz-6', 'Quiz 6', 11);
SELECT pg_temp.add('test-legacy', 'retake-1', 'Quiz (2) 1', 12);     -- stem "Quiz (2)": collides with a generated name
SELECT pg_temp.add('test-legacy', 'retake-2', 'Quiz (2) 2', 13);
SELECT pg_temp.add('test-legacy', 'ai-usage-log-1', 'AI Usage Log 1', 14);
SELECT pg_temp.add('test-legacy', 'ai-usage-log-2', 'AI Usage Log 2', 15);
SELECT pg_temp.add('test-legacy', 'meets', 'Quiz standing A', 16, pg_temp.deps('test-legacy', 'quiz-1', 'quiz-2', 'quiz-4'));
SELECT pg_temp.add('test-legacy', 'approaching', 'Quiz standing B', 17, pg_temp.deps('test-legacy', 'quiz-4', 'quiz-2', 'quiz-1'));
SELECT pg_temp.add('test-legacy', 'assignment-hw1', 'Homework 1', 18);
SELECT pg_temp.add('test-legacy', 'assignment-hw2', 'Homework 2', 19);
SELECT pg_temp.add('test-legacy', 'assignment-final', 'Final Project', 20);
SELECT pg_temp.add('test-legacy', 'final-exam', 'Final exam', 21);
SELECT pg_temp.add('test-legacy', 'final-grade', 'Final grade', 22, pg_temp.deps('test-legacy', 'final-exam', 'hw-1'));
SELECT pg_temp.add('test-legacy', 'calc', 'Calc', 23, '{"gradebook_columns": ["not-a-number", 3.5, null]}');
SELECT pg_temp.add('test-legacy', 'misc', 'Misc', 24);

CREATE TEMP TABLE legacy_sort_before AS
  SELECT id, sort_order FROM public.gradebook_columns WHERE gradebook_id = pg_temp.gid('test-legacy');

SELECT is(public.gradebook_column_groups_backfill(pg_temp.gid('test-legacy')), 8, 'backfill creates 8 groups');

SELECT is(
  pg_temp.layout('test-legacy'),
  'HW:hw-1 HW:hw-2 midterm Hw (2):hw-3 Hw (2):hw-4 Quiz:quiz-1 Quiz:quiz-2 Quiz:quiz-4 bonus '
  || 'Quiz (2):quiz-5 Quiz (2):quiz-6 Quiz (2) (2):retake-1 Quiz (2) (2):retake-2 '
  || 'AI Usage Log:ai-usage-log-1 AI Usage Log:ai-usage-log-2 Quiz summary:meets Quiz summary:approaching '
  || 'Homework:assignment-hw1 Homework:assignment-hw2 assignment-final final-exam final-grade calc misc',
  'backfill: F1 hole ignored, F2 interrupted run renamed, F3 name from column names, F4 summaries grouped, '
  || 'F8 two-part assignment slugs by type, F9 a computed column leaves its inputs, generated names never collide, '
  || 'malformed dependencies ignored'
);

SELECT is(
  (SELECT count(*) FROM public.gradebook_columns gc JOIN legacy_sort_before b USING (id) WHERE gc.sort_order IS DISTINCT FROM b.sort_order),
  0::bigint,
  'backfill never moves a column'
);

-- The backfill's record: every column it grouped differently from the heuristic, and why.
SELECT is(
  (SELECT string_agg(d.slug || ':' || array_to_string(d.reasons, '+'), ' ' ORDER BY d.sort_order)
   FROM backfill_audit.gradebook_column_group_departures d
   WHERE d.gradebook_id = pg_temp.gid('test-legacy')),
  'quiz-1:F1 quiz-2:F1 quiz-4:F1 meets:F4 approaching:F4 '
  || 'assignment-hw1:F8 assignment-hw2:F8 assignment-final:F8 final-exam:F9 final-grade:F9',
  'the record lists exactly the columns grouped differently from the heuristic, each with its reason'
);

-- "Before" is the heuristic's output in the format of tests/unit/legacy-column-grouping.test.ts.
SELECT is(
  (SELECT string_agg(d.slug || ': ' || d.heuristic_group || ' -> ' || d.backfill_group, ' | ' ORDER BY d.sort_order)
   FROM backfill_audit.gradebook_column_group_departures d
   WHERE d.column_id IN (pg_temp.col('test-legacy', 'quiz-1'), pg_temp.col('test-legacy', 'quiz-4'),
                         pg_temp.col('test-legacy', 'assignment-final'), pg_temp.col('test-legacy', 'final-grade'))),
  'quiz-1: Quiz[quiz-1,quiz-2] -> Quiz[quiz-1,quiz-2,quiz-4] | quiz-4: quiz-4 -> Quiz[quiz-1,quiz-2,quiz-4] | '
  || 'assignment-final: Assignment[assignment-hw1,assignment-hw2,assignment-final] -> assignment-final | '
  || 'final-grade: Final[final-exam,final-grade] -> final-grade',
  'the record shows each column''s group before and after'
);

SELECT is(public.gradebook_column_groups_backfill(pg_temp.gid('test-legacy')), 0, 'a second backfill is a no-op');
SELECT is(
  (SELECT count(*) FROM backfill_audit.gradebook_column_group_departures WHERE gradebook_id = pg_temp.gid('test-legacy')),
  10::bigint,
  'a second backfill leaves the record alone'
);

-- F6: a NULL sort_order counts as 0 but no longer collides with the column that really is at 0.
SELECT set_config('pawtograder.bypass_sort_order_trigger_' || pg_temp.gid('test-ties'), 'true', true);
SELECT pg_temp.add('test-ties', 'quiz-1', 'Quiz 1', 0);
SELECT pg_temp.add('test-ties', 'quiz-2', 'Quiz 2', NULL);
SELECT pg_temp.add('test-ties', 'quiz-3', 'Quiz 3', 1);
SELECT set_config('pawtograder.bypass_sort_order_trigger_' || pg_temp.gid('test-ties'), 'false', true);
SELECT public.gradebook_column_groups_backfill(pg_temp.gid('test-ties'));
SELECT is(pg_temp.layout('test-ties'), 'Quiz:quiz-1 Quiz:quiz-2 Quiz:quiz-3', 'F6: a NULL sort_order does not split a family');
SELECT is(
  (SELECT string_agg(d.slug || ': ' || d.heuristic_group || ' ' || array_to_string(d.reasons, '+'), ' | ' ORDER BY d.column_id)
   FROM backfill_audit.gradebook_column_group_departures d
   WHERE d.gradebook_id = pg_temp.gid('test-ties')),
  'quiz-1: quiz-1 F6 | quiz-2: Quiz[quiz-2,quiz-3] F6 | quiz-3: Quiz[quiz-2,quiz-3] F6',
  'F6 is recorded, and the heuristic side reproduces the NULL collision'
);

-- The check itself: a grouping the heuristic never produced, with no listed reason behind it.
SELECT pg_temp.add('test-audit', 'alpha', 'Alpha', 0);
SELECT pg_temp.add('test-audit', 'beta', 'Beta', 1);
SELECT pg_temp.add('test-audit', 'gamma', 'Gamma', 2);
INSERT INTO public.gradebook_column_groups (class_id, gradebook_id, name)
VALUES (pg_temp.cid('test-audit'), pg_temp.gid('test-audit'), 'Made up');
UPDATE public.gradebook_columns SET group_id = pg_temp.grp('test-audit', 'Made up')
WHERE id IN (pg_temp.col('test-audit', 'alpha'), pg_temp.col('test-audit', 'beta'));
SELECT is(
  (SELECT string_agg(x.slug || ':' || array_to_string(x.reasons, '+'), ' ' ORDER BY x.sort_order)
   FROM backfill_audit.compare_with_heuristic(ARRAY[pg_temp.gid('test-audit')]) x),
  'alpha:unexplained beta:unexplained',
  'the comparison flags a difference no listed failure explains, and only the columns it touches'
);
SELECT throws_ok(
  $$SELECT backfill_audit.record_departures(ARRAY[pg_temp.gid('test-audit')])$$,
  'P0001', NULL, 'an unexplained difference stops the backfill'
);

SELECT ok(
  NOT has_schema_privilege('anon', 'backfill_audit', 'USAGE')
    AND NOT has_schema_privilege('authenticated', 'backfill_audit', 'USAGE'),
  'no API role can reach backfill_audit'
);

ALTER TABLE public.gradebook_columns ENABLE TRIGGER gradebook_columns_inherit_group_tr;

-- ---------------------------------------------------------------------------------------------
-- Invariants
-- ---------------------------------------------------------------------------------------------

SET CONSTRAINTS public.gradebook_column_groups_require_member_tr IMMEDIATE;
SELECT throws_ok(
  $$INSERT INTO public.gradebook_column_groups (class_id, gradebook_id, name)
    VALUES (pg_temp.cid('test-legacy'), pg_temp.gid('test-legacy'), 'Empty')$$,
  '23514', NULL, 'a group without columns is rejected'
);
SET CONSTRAINTS public.gradebook_column_groups_require_member_tr DEFERRED;

SELECT throws_ok(
  $$UPDATE public.gradebook_column_groups SET name = ' Quiz' WHERE id = pg_temp.grp('test-legacy', 'HW')$$,
  '23514', NULL, 'a name with leading whitespace is rejected'
);
SELECT throws_ok(
  $$UPDATE public.gradebook_column_groups SET name = E'Quiz\t' WHERE id = pg_temp.grp('test-legacy', 'HW')$$,
  '23514', NULL, 'a name with trailing whitespace is rejected'
);
SELECT throws_ok(
  $$UPDATE public.gradebook_column_groups SET name = 'quiz' WHERE id = pg_temp.grp('test-legacy', 'HW')$$,
  '23505', NULL, 'names are unique per gradebook, case-insensitively'
);
SELECT throws_ok(
  $$UPDATE public.gradebook_columns SET group_id = pg_temp.grp('test-legacy', 'HW') WHERE id = pg_temp.col('test-ties', 'quiz-1')$$,
  '23503', NULL, 'a column cannot join a group in another gradebook'
);
SELECT throws_ok(
  $$UPDATE public.gradebook_column_groups SET class_id = pg_temp.cid('test-other') WHERE id = pg_temp.grp('test-legacy', 'HW')$$,
  '23503', NULL, 'a group cannot claim a class its gradebook does not belong to'
);

UPDATE public.gradebook_columns SET group_id = NULL WHERE group_id = pg_temp.grp('test-legacy', 'Homework');
SELECT is(pg_temp.grp('test-legacy', 'Homework'), NULL, 'a group is deleted when its last column leaves');

-- A direct write that makes a column join a group, bypassing the RPCs, is repaired.
UPDATE public.gradebook_columns SET group_id = pg_temp.grp('test-legacy', 'Quiz') WHERE id = pg_temp.col('test-legacy', 'misc');
SELECT ok(NOT public.gradebook_column_groups_torn(pg_temp.gid('test-legacy')), 'a direct group_id write does not leave a group split');
SELECT matches(pg_temp.layout('test-legacy'), 'Quiz:quiz-4 Quiz:misc bonus', 'the column is moved to the end of its new group');

-- ---------------------------------------------------------------------------------------------
-- Column order
-- ---------------------------------------------------------------------------------------------

-- A tie between an ungrouped column and a group's first column must not interleave them.
SELECT set_config('pawtograder.bypass_sort_order_trigger_' || pg_temp.gid('test-legacy'), 'true', true);
UPDATE public.gradebook_columns
SET sort_order = (SELECT sort_order FROM public.gradebook_columns WHERE id = pg_temp.col('test-legacy', 'quiz-5'))
WHERE id = pg_temp.col('test-legacy', 'bonus');
SELECT set_config('pawtograder.bypass_sort_order_trigger_' || pg_temp.gid('test-legacy'), 'false', true);
SELECT matches(pg_temp.display('test-legacy'), 'bonus Quiz \(2\):quiz-5 Quiz \(2\):quiz-6', 'display order keeps a group whole across a sort_order tie');
SELECT ok(cardinality(public.gradebook_columns_make_groups_contiguous(pg_temp.gid('test-legacy'))) > 0, 'renumbering resolves the tie');
SELECT is(public.gradebook_columns_make_groups_contiguous(pg_temp.gid('test-legacy')), '{}'::bigint[], 'renumbering is idempotent');
SELECT ok(NOT public.gradebook_column_groups_torn(pg_temp.gid('test-legacy')), 'no group is split after renumbering');

-- make_groups_contiguous sets and restores the sort_order bypass itself.
SELECT is(current_setting('pawtograder.bypass_sort_order_trigger_' || pg_temp.gid('test-legacy'), true), 'false',
          'renumbering leaves the bypass as it found it');

-- ---------------------------------------------------------------------------------------------
-- Default group for new columns (the insert trigger)
-- ---------------------------------------------------------------------------------------------

SELECT pg_temp.add('test-new', 'assignment-hw-1', 'Homework 1', NULL);
SELECT pg_temp.add('test-new', 'assignment-hw-2', 'Homework 2', NULL);
SELECT pg_temp.add('test-new', 'assignment-hw-3', 'Homework 3', NULL);
SELECT pg_temp.add('test-new', 'assignment-lab-1', 'Lab 1', NULL);
SELECT pg_temp.add('test-new', 'assignment-hw-4', 'Homework 4', NULL);
SELECT pg_temp.add('test-new', 'assignment-hw-5', 'Homework 5', NULL);
SELECT pg_temp.add('test-new', 'assignment-hw-avg', 'Homework average', NULL,
                   pg_temp.deps('test-new', 'assignment-hw-4', 'assignment-hw-5'));
SELECT is(
  pg_temp.layout('test-new'),
  'Homework:assignment-hw-1 Homework:assignment-hw-2 Homework:assignment-hw-3 assignment-lab-1 '
  || 'Homework (2):assignment-hw-4 Homework (2):assignment-hw-5 assignment-hw-avg',
  'new columns join their family; an interrupted family gets a new name; a summary of the group stays out'
);

-- Inserted between two members: joins them, whichever order the insert triggers run in.
SELECT pg_temp.add('test-new', 'assignment-hw-2b', 'Homework 2b',
                   (SELECT sort_order FROM public.gradebook_columns WHERE id = pg_temp.col('test-new', 'assignment-hw-3')));
SELECT matches(pg_temp.layout('test-new'), 'Homework:assignment-hw-2 Homework:assignment-hw-2b Homework:assignment-hw-3',
               'a column inserted between two members joins their group');

SELECT * FROM finish();
ROLLBACK;
