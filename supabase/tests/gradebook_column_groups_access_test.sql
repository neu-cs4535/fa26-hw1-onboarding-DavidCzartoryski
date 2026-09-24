-- Column groups: who can see and change them, what the RPCs do, and what realtime sends.
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
CREATE FUNCTION pg_temp.layout(p_class_slug text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(CASE WHEN g.id IS NULL THEN gc.slug ELSE g.name || ':' || gc.slug END, ' '
                    ORDER BY COALESCE(gc.sort_order, 0), gc.id)
  FROM public.gradebook_columns gc
  LEFT JOIN public.gradebook_column_groups g ON g.id = gc.group_id
  WHERE gc.gradebook_id = pg_temp.gid(p_class_slug)
$$;
CREATE FUNCTION pg_temp.add(p_class_slug text, p_slug text, p_name text) RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO public.gradebook_columns (class_id, gradebook_id, name, slug, max_score)
  VALUES (pg_temp.cid(p_class_slug), pg_temp.gid(p_class_slug), p_name, p_slug, 10)
  RETURNING id
$$;

-- Run one statement as a signed-in user, returning its first column as text, 'ok' when it
-- returns nothing, or 'error <SQLSTATE>'. The role is reset before pgTAP records the result.
CREATE FUNCTION pg_temp.as_user(p_user uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_result text;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO v_result;
    v_result := COALESCE(v_result, 'ok');
  EXCEPTION WHEN OTHERS THEN
    v_result := 'error ' || SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_result;
END;
$$;
CREATE FUNCTION pg_temp.as_anon(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_result text;
BEGIN
  EXECUTE 'SET LOCAL ROLE anon';
  BEGIN
    EXECUTE p_sql INTO v_result;
    v_result := COALESCE(v_result, 'ok');
  EXCEPTION WHEN OTHERS THEN
    v_result := 'error ' || SQLSTATE;
  END;
  EXECUTE 'RESET ROLE';
  RETURN v_result;
END;
$$;

-- Capture realtime traffic instead of sending it.
CREATE TEMP TABLE broadcasts (payload jsonb, channel text);
GRANT ALL ON broadcasts TO authenticated;
CREATE OR REPLACE FUNCTION public.safe_broadcast(p_payload jsonb, p_event text, p_channel text, p_private boolean)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pg_temp.broadcasts VALUES (p_payload, p_channel)
$$;

-- People. Authorization reads user_privileges; the realtime fan-out reads user_roles (inserted
-- below with replication-role triggers off, so they need no auth users or profiles).
INSERT INTO public.classes (name, slug) VALUES ('Access course', 'test-access'), ('Other course', 'test-other');

-- Real users rows: the audit trigger records auth.uid() with a foreign key to public.users.
-- Inserted with triggers off, so no auth account or profile is needed.
SET LOCAL session_replication_role = replica;
INSERT INTO public.users (user_id, email) VALUES
  ('00000000-0000-0000-0000-00000000000a', 'groups-instructor@test.invalid'),
  ('00000000-0000-0000-0000-00000000000b', 'groups-grader@test.invalid'),
  ('00000000-0000-0000-0000-00000000000c', 'groups-student@test.invalid'),
  ('00000000-0000-0000-0000-00000000000d', 'groups-other-instructor@test.invalid');
SET LOCAL session_replication_role = origin;

INSERT INTO public.user_privileges (user_id, class_id, role) VALUES
  ('00000000-0000-0000-0000-00000000000a', pg_temp.cid('test-access'), 'instructor'),
  ('00000000-0000-0000-0000-00000000000b', pg_temp.cid('test-access'), 'grader'),
  ('00000000-0000-0000-0000-00000000000c', pg_temp.cid('test-access'), 'student'),
  ('00000000-0000-0000-0000-00000000000d', pg_temp.cid('test-other'), 'instructor');

-- Columns: appended in order, so the insert-time default groups the homework.
SELECT pg_temp.add('test-access', 'hw-1', 'HW 1');
SELECT pg_temp.add('test-access', 'hw-2', 'HW 2');
SELECT pg_temp.add('test-access', 'hw-3', 'HW 3');
SELECT pg_temp.add('test-access', 'exam-1', 'Exam 1');
SELECT pg_temp.add('test-access', 'exam-2', 'Exam 2');
SELECT pg_temp.add('test-access', 'curve', 'Curve');
SELECT pg_temp.add('test-access', 'participation', 'Participation');
SELECT pg_temp.add('test-other', 'hw-1', 'HW 1');
SELECT pg_temp.add('test-other', 'hw-2', 'HW 2');

SELECT is(pg_temp.layout('test-access'), 'HW:hw-1 HW:hw-2 HW:hw-3 Exam:exam-1 Exam:exam-2 curve participation',
          'setup: the insert-time default grouped the families');

-- Three students for the realtime fan-out, added after the columns (a new column creates a cell
-- per student, and these students have no profiles).
SET LOCAL session_replication_role = replica;
INSERT INTO public.user_roles (user_id, class_id, role, public_profile_id, private_profile_id)
SELECT gen_random_uuid(), pg_temp.cid('test-access'), 'student', gen_random_uuid(), gen_random_uuid()
FROM generate_series(1, 3);
SET LOCAL session_replication_role = origin;

-- A staff-only group: its only column is instructor_only and unreleased.
UPDATE public.gradebook_columns SET instructor_only = true, released = false WHERE id = pg_temp.col('test-access', 'curve');
SELECT pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_group_create(%s, %L, ARRAY[%s]::bigint[])::text',
         pg_temp.gid('test-access'), 'Staff only', pg_temp.col('test-access', 'curve')));

-- ---------------------------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------------------------

SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  $$SELECT count(*)::text FROM public.gradebook_column_groups WHERE class_id = pg_temp.cid('test-access')$$),
  '3', 'the instructor sees every group');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000b',
  $$SELECT count(*)::text FROM public.gradebook_column_groups WHERE class_id = pg_temp.cid('test-access')$$),
  '3', 'a grader sees every group');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000c',
  $$SELECT string_agg(name, ',' ORDER BY name) FROM public.gradebook_column_groups WHERE class_id = pg_temp.cid('test-access')$$),
  'Exam,HW', 'a student does not see a group made only of staff-only columns');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000d',
  $$SELECT count(*)::text FROM public.gradebook_column_groups WHERE class_id = pg_temp.cid('test-access')$$),
  '0', 'another course''s instructor sees none of this course''s groups');
SELECT is(pg_temp.as_anon($$SELECT count(*)::text FROM public.gradebook_column_groups$$),
  'error 42501', 'anon has no access');

-- ---------------------------------------------------------------------------------------------
-- Writing directly
-- ---------------------------------------------------------------------------------------------

SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format($$INSERT INTO public.gradebook_column_groups (class_id, gradebook_id, name) VALUES (%s, %s, 'Direct')$$,
         pg_temp.cid('test-access'), pg_temp.gid('test-access'))),
  'error 42501', 'nobody can insert a group directly (it would have no columns)');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format($$UPDATE public.gradebook_column_groups SET class_id = %s WHERE id = %s$$,
         pg_temp.cid('test-other'), pg_temp.grp('test-access', 'HW'))),
  'error 42501', 'only a group''s name can be updated');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format($$WITH u AS (UPDATE public.gradebook_column_groups SET name = 'Homework' WHERE id = %s RETURNING 1) SELECT count(*)::text FROM u$$,
         pg_temp.grp('test-access', 'HW'))),
  '1', 'the instructor can rename a group');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000b',
  format($$WITH u AS (UPDATE public.gradebook_column_groups SET name = 'Grader' WHERE id = %s RETURNING 1) SELECT count(*)::text FROM u$$,
         pg_temp.grp('test-access', 'Homework'))),
  '0', 'a grader cannot rename');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000c',
  format($$WITH d AS (DELETE FROM public.gradebook_column_groups WHERE id = %s RETURNING 1) SELECT count(*)::text FROM d$$,
         pg_temp.grp('test-access', 'Homework'))),
  '0', 'a student cannot delete');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000d',
  format($$WITH d AS (DELETE FROM public.gradebook_column_groups WHERE id = %s RETURNING 1) SELECT count(*)::text FROM d$$,
         pg_temp.grp('test-access', 'Homework'))),
  '0', 'another course''s instructor cannot delete');

-- ---------------------------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------------------------

SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000c',
  format('SELECT public.gradebook_column_step(%s, 1)::text', pg_temp.col('test-access', 'participation'))),
  'error 42501', 'a student cannot reorder');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000b',
  format('SELECT public.gradebook_column_group_move(%s, 1)::text', pg_temp.grp('test-access', 'Exam'))),
  'error 42501', 'a grader cannot move a group');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000d',
  format($$SELECT public.gradebook_column_group_create(%s, 'Mine', ARRAY[%s]::bigint[])::text$$,
         pg_temp.gid('test-access'), pg_temp.col('test-access', 'participation'))),
  'error 42501', 'another course''s instructor cannot create a group here');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  $$SELECT public.gradebook_columns_apply_order(1, '{}'::bigint[])::text$$),
  'error 42501', 'internal helpers are not callable');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  $$SELECT public.gradebook_column_family('hw-1')$$),
  'error 42501', 'the slug helpers are not callable');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_step(%s, 0)::text', pg_temp.col('test-access', 'participation'))),
  'error 22023', 'a direction other than -1 or 1 is rejected');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format($$SELECT public.gradebook_column_group_create(%s, '   ', ARRAY[%s]::bigint[])::text$$,
         pg_temp.gid('test-access'), pg_temp.col('test-access', 'participation'))),
  'error 23514', 'a blank group name is rejected');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format($$SELECT public.gradebook_column_group_create(%s, 'X', ARRAY[%s]::bigint[])::text$$,
         pg_temp.gid('test-access'), pg_temp.col('test-other', 'hw-1'))),
  'error P0001', 'a group cannot take a column from another gradebook');

-- Behavior, as the instructor.
SELECT pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format($$SELECT public.gradebook_column_group_create(%s, '  Midterms  ', ARRAY[%s]::bigint[])::text$$,
         pg_temp.gid('test-access'), pg_temp.col('test-access', 'exam-2')));
SELECT is(pg_temp.layout('test-access'),
  'Homework:hw-1 Homework:hw-2 Homework:hw-3 Exam:exam-1 Midterms:exam-2 Staff only:curve participation',
  'create: the name is trimmed and the column leaves its old group in place');

SELECT pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_set_group(%s, %s)', pg_temp.col('test-access', 'hw-1'), pg_temp.grp('test-access', 'Midterms')));
SELECT is(pg_temp.layout('test-access'),
  'Homework:hw-2 Homework:hw-3 Exam:exam-1 Midterms:exam-2 Midterms:hw-1 Staff only:curve participation',
  'set_group: a column joining a group goes to its end');

SELECT pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_set_group(%s)', pg_temp.col('test-access', 'exam-1')));
SELECT is(pg_temp.grp('test-access', 'Exam'), NULL, 'set_group: taking the last column out deletes the group');

SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_step(%s, -1)::text', pg_temp.col('test-access', 'hw-2'))),
  'false', 'step: a column at the edge of its group does not leave it');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_step(%s, -1)::text', pg_temp.col('test-access', 'participation'))),
  'true', 'step: an ungrouped column moves');
SELECT is(pg_temp.layout('test-access'),
  'Homework:hw-2 Homework:hw-3 exam-1 Midterms:exam-2 Midterms:hw-1 participation Staff only:curve',
  'step: an ungrouped column steps past a whole group');

SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_group_move(%s, -1)::text', pg_temp.grp('test-access', 'Midterms'))),
  'true', 'group_move moves');
SELECT is(pg_temp.layout('test-access'),
  'Homework:hw-2 Homework:hw-3 Midterms:exam-2 Midterms:hw-1 exam-1 participation Staff only:curve',
  'group_move: the whole group moves past its neighbor');

-- ---------------------------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------------------------

DELETE FROM broadcasts;
SELECT pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_column_group_move(%s, 1)::text', pg_temp.grp('test-access', 'Homework')));
SELECT is((SELECT count(*) FROM broadcasts WHERE payload->>'table' = 'gradebook_columns' AND channel LIKE '%:staff'),
  1::bigint, 'a group move sends one column message to staff');
SELECT is((SELECT count(*) FROM broadcasts WHERE payload->>'table' = 'gradebook_columns' AND channel LIKE '%:user:%'),
  3::bigint, 'and one to each student, not one per moved row');
SELECT is((SELECT jsonb_array_length(payload->'row_ids') FROM broadcasts WHERE channel LIKE '%:staff' AND payload->>'table' = 'gradebook_columns'),
  4, 'listing the four columns that moved');

DELETE FROM broadcasts;
SELECT pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_columns_reorder(%L::bigint[])',
         (SELECT array_agg(id ORDER BY CASE WHEN rn = n THEN n - 1 WHEN rn = n - 1 THEN n ELSE rn END)
          FROM (SELECT id, row_number() OVER (ORDER BY sort_order) rn, count(*) OVER () n
                FROM public.gradebook_columns WHERE gradebook_id = pg_temp.gid('test-access')) z)));
SELECT is((SELECT jsonb_array_length(payload->'row_ids') FROM broadcasts WHERE channel LIKE '%:staff' AND payload->>'table' = 'gradebook_columns'),
  2, 'a one-place drag through gradebook_columns_reorder touches only the two columns that swap');
SELECT is((SELECT count(*) FROM broadcasts b, jsonb_array_elements_text(b.payload->'row_ids') r
           WHERE b.channel LIKE '%:user:%' AND r::bigint = pg_temp.col('test-access', 'curve')),
  0::bigint, 'students are not told a staff-only column moved');

DELETE FROM broadcasts;
UPDATE public.gradebook_columns SET name = 'Curve (secret)' WHERE id = pg_temp.col('test-access', 'curve');
SELECT is((SELECT count(*) FROM broadcasts WHERE channel LIKE '%:user:%'), 0::bigint,
  'an edit to a staff-only column is not sent to students');
SELECT is((SELECT count(*) FROM broadcasts WHERE channel LIKE '%:staff'), 1::bigint, 'it is sent to staff');

DELETE FROM broadcasts;
UPDATE public.gradebook_columns SET instructor_only = true, released = false WHERE id = pg_temp.col('test-access', 'participation');
SELECT is((SELECT count(*) FROM broadcasts WHERE channel LIKE '%:user:%' AND payload->>'operation' = 'DELETE' AND NOT payload ? 'data'),
  3::bigint, 'a column that becomes staff-only is removed from students without its data');

DELETE FROM broadcasts;
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000a',
  format('SELECT public.gradebook_auto_layout(%s)', pg_temp.gid('test-access'))),
  '', 'auto-layout runs for the instructor (it returns void)');
SELECT ok(NOT public.gradebook_column_groups_torn(pg_temp.gid('test-access')), 'auto-layout keeps every group whole');
SELECT ok((SELECT count(*) FROM broadcasts WHERE payload->>'table' = 'gradebook_columns' AND channel LIKE '%:staff') <= 1,
  'auto-layout announces its moves in at most one message per channel');
SELECT is(pg_temp.as_user('00000000-0000-0000-0000-00000000000b',
  format('SELECT public.gradebook_auto_layout(%s)', pg_temp.gid('test-access'))),
  'error P0001', 'a grader cannot run auto-layout');

SELECT * FROM finish();
ROLLBACK;
