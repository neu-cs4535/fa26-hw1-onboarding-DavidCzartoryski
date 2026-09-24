-- Rollback for supabase/migrations/20260924033840_gradebook_column_groups.sql and
-- 20260924045931_gradebook_column_groups_crud.sql, undone together, newest first.
--
-- Supabase migrations only run forward, so this is not picked up by `db reset` or `db push`.
-- To undo the change on a database the migration has already run on:
--
--   1. Roll the web app back first. The previous frontend never reads group_id or
--      gradebook_column_groups, so it runs unchanged against the migrated schema; the reverse
--      is not true, because this frontend breaks without the table.
--   2. Run this file with psql as the database owner, in one transaction.
--   3. Ship the undo in the repo as a new forward migration with this body, so staging and
--      fresh installs stop replaying the original.
--
-- It archives before it drops: any group an instructor created or renamed since the migration
-- ran is kept in rollback_archive, a schema PostgREST does not expose (config.toml lists
-- public, graphql_public, pgmq_public), so re-applying later can restore edits instead of
-- re-deriving them from slugs.
--
-- Nothing else is lost: columns keep their sort_order (the current left-to-right order), and
-- the four functions the migrations replaced (reorder, auto-layout, Move Left, Move Right) go
-- back to their previous bodies, identical apart from the punctuation of one comment.

BEGIN;

CREATE SCHEMA IF NOT EXISTS rollback_archive;
REVOKE ALL ON SCHEMA rollback_archive FROM PUBLIC, anon, authenticated;

CREATE TABLE rollback_archive.gradebook_column_groups_20260924 AS
SELECT
  g.id AS group_id,
  g.class_id,
  g.gradebook_id,
  g.name,
  g.created_at,
  array_agg(gc.id ORDER BY gc.sort_order) FILTER (WHERE gc.id IS NOT NULL) AS column_ids,
  now() AS archived_at
FROM public.gradebook_column_groups g
LEFT JOIN public.gradebook_columns gc ON gc.group_id = g.id
GROUP BY g.id;

-- 20260924045931_gradebook_column_groups_crud

DROP TRIGGER gradebook_columns_drop_empty_group_tr ON public.gradebook_columns;
DROP FUNCTION public.gradebook_column_groups_drop_empty();

-- Previous bodies of Move Left / Move Right.
CREATE OR REPLACE FUNCTION public.gradebook_column_move_left(p_column_id bigint)
 RETURNS gradebook_columns
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_gradebook_id bigint;
  v_col public.gradebook_columns;
  v_neighbor_id bigint;
  v_self_order integer;
  v_neighbor_order integer;
  v_max integer;
BEGIN
  SELECT gradebook_id INTO v_gradebook_id
    FROM public.gradebook_columns
   WHERE id = p_column_id;

  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_column_id;
  END IF;

  PERFORM pg_advisory_xact_lock(v_gradebook_id);

  IF EXISTS (
    SELECT 1
      FROM public.gradebook_columns
     WHERE gradebook_id = v_gradebook_id
       AND sort_order IS NULL
  ) THEN
    PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'true', true);
    BEGIN
      SELECT COALESCE(MAX(sort_order), -1) INTO v_max
        FROM public.gradebook_columns
       WHERE gradebook_id = v_gradebook_id;

      WITH numbered AS (
        SELECT
          id,
          ROW_NUMBER() OVER (ORDER BY id) AS rn
        FROM public.gradebook_columns
        WHERE gradebook_id = v_gradebook_id
          AND sort_order IS NULL
      )
      UPDATE public.gradebook_columns gc
         SET sort_order = v_max + numbered.rn
        FROM numbered
       WHERE gc.id = numbered.id;
    EXCEPTION
      WHEN OTHERS THEN
        PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
        RAISE;
    END;
    PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
  END IF;

  SELECT * INTO v_col
    FROM public.gradebook_columns
   WHERE id = p_column_id
   FOR UPDATE;

  WITH ordered AS (
    SELECT
      id,
      ROW_NUMBER() OVER (ORDER BY sort_order ASC NULLS LAST, id ASC) AS rn
    FROM public.gradebook_columns
    WHERE gradebook_id = v_gradebook_id
  )
  SELECT o2.id
    INTO v_neighbor_id
    FROM ordered o1
    JOIN ordered o2 ON o2.rn = o1.rn - 1
   WHERE o1.id = p_column_id;

  IF v_neighbor_id IS NULL THEN
    RETURN v_col;
  END IF;

  SELECT sort_order INTO v_neighbor_order
    FROM public.gradebook_columns
   WHERE id = v_neighbor_id
   FOR UPDATE;

  v_self_order := v_col.sort_order;

  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'true', true);
  BEGIN
    UPDATE public.gradebook_columns
       SET sort_order = v_neighbor_order
     WHERE id = p_column_id;

    UPDATE public.gradebook_columns
       SET sort_order = v_self_order
     WHERE id = v_neighbor_id;
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
      RAISE;
  END;
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);

  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id;
  RETURN v_col;
END;
$function$

;
CREATE OR REPLACE FUNCTION public.gradebook_column_move_right(p_column_id bigint)
 RETURNS gradebook_columns
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_gradebook_id bigint;
  v_col public.gradebook_columns;
  v_neighbor_id bigint;
  v_self_order integer;
  v_neighbor_order integer;
  v_max integer;
BEGIN
  SELECT gradebook_id INTO v_gradebook_id
    FROM public.gradebook_columns
   WHERE id = p_column_id;

  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_column_id;
  END IF;

  PERFORM pg_advisory_xact_lock(v_gradebook_id);

  IF EXISTS (
    SELECT 1
      FROM public.gradebook_columns
     WHERE gradebook_id = v_gradebook_id
       AND sort_order IS NULL
  ) THEN
    PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'true', true);
    BEGIN
      SELECT COALESCE(MAX(sort_order), -1) INTO v_max
        FROM public.gradebook_columns
       WHERE gradebook_id = v_gradebook_id;

      WITH numbered AS (
        SELECT
          id,
          ROW_NUMBER() OVER (ORDER BY id) AS rn
        FROM public.gradebook_columns
        WHERE gradebook_id = v_gradebook_id
          AND sort_order IS NULL
      )
      UPDATE public.gradebook_columns gc
         SET sort_order = v_max + numbered.rn
        FROM numbered
       WHERE gc.id = numbered.id;
    EXCEPTION
      WHEN OTHERS THEN
        PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
        RAISE;
    END;
    PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
  END IF;

  SELECT * INTO v_col
    FROM public.gradebook_columns
   WHERE id = p_column_id
   FOR UPDATE;

  WITH ordered AS (
    SELECT
      id,
      ROW_NUMBER() OVER (ORDER BY sort_order ASC NULLS LAST, id ASC) AS rn
    FROM public.gradebook_columns
    WHERE gradebook_id = v_gradebook_id
  )
  SELECT o2.id
    INTO v_neighbor_id
    FROM ordered o1
    JOIN ordered o2 ON o2.rn = o1.rn + 1
   WHERE o1.id = p_column_id;

  IF v_neighbor_id IS NULL THEN
    RETURN v_col;
  END IF;

  SELECT sort_order INTO v_neighbor_order
    FROM public.gradebook_columns
   WHERE id = v_neighbor_id
   FOR UPDATE;

  v_self_order := v_col.sort_order;

  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'true', true);
  BEGIN
    UPDATE public.gradebook_columns
       SET sort_order = v_neighbor_order
     WHERE id = p_column_id;

    UPDATE public.gradebook_columns
       SET sort_order = v_self_order
     WHERE id = v_neighbor_id;
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
      RAISE;
  END;
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);

  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id;
  RETURN v_col;
END;
$function$

;


DROP FUNCTION public.gradebook_column_group_create(bigint, text, bigint[]);
DROP FUNCTION public.gradebook_column_set_group(bigint, bigint);
DROP FUNCTION public.gradebook_column_group_move(bigint, integer);
DROP FUNCTION public.gradebook_column_step(bigint, integer);
DROP FUNCTION public.gradebook_columns_swap_unit(bigint, text, integer);
DROP FUNCTION public.gradebook_columns_apply_order(bigint, bigint[]);
DROP FUNCTION public.gradebook_column_groups_authorize(bigint);
DROP FUNCTION public.gradebook_columns_display_order(bigint);

-- 20260924033840_gradebook_column_groups

DROP TRIGGER gradebook_columns_inherit_group_tr ON public.gradebook_columns;
DROP FUNCTION public.gradebook_columns_inherit_group();

-- Previous bodies of the two functions the migration replaced.
CREATE OR REPLACE FUNCTION public.gradebook_columns_reorder(p_ordered_column_ids bigint[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_gradebook_id bigint;
  v_class_id bigint;
  v_expected_count integer;
  v_payload_count integer;
  v_distinct_payload integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  v_payload_count := COALESCE(array_length(p_ordered_column_ids, 1), 0);

  IF v_payload_count = 0 THEN
    RETURN;
  END IF;

  SELECT COUNT(DISTINCT x) INTO v_distinct_payload
  FROM unnest(p_ordered_column_ids) AS x;

  IF v_distinct_payload <> v_payload_count THEN
    RAISE EXCEPTION 'Duplicate column IDs in reorder payload';
  END IF;

  SELECT gc.gradebook_id INTO v_gradebook_id
  FROM public.gradebook_columns AS gc
  WHERE gc.id = p_ordered_column_ids[1];

  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_ordered_column_ids[1];
  END IF;

  SELECT class_id INTO v_class_id
  FROM public.gradebooks
  WHERE id = v_gradebook_id;

  IF v_class_id IS NULL THEN
    RAISE EXCEPTION 'gradebook % not found', v_gradebook_id;
  END IF;

  IF NOT public.authorizeforclassinstructor(v_class_id) THEN
    RAISE EXCEPTION 'insufficient permissions: instructor access required for class %', v_class_id;
  END IF;

  SELECT COUNT(*)::integer INTO v_expected_count
  FROM public.gradebook_columns
  WHERE gradebook_id = v_gradebook_id;

  IF v_expected_count <> v_payload_count THEN
    RAISE EXCEPTION 'Payload count (%) does not match gradebook column count (%)', v_payload_count, v_expected_count;
  END IF;

  IF (
    SELECT COUNT(*)::integer
    FROM public.gradebook_columns
    WHERE gradebook_id = v_gradebook_id
      AND id = ANY (p_ordered_column_ids)
  ) <> v_payload_count THEN
    RAISE EXCEPTION 'One or more column IDs do not belong to this gradebook';
  END IF;

  -- Single-key form (bigint); the two-key form requires (integer, integer), not (int, bigint).
  -- Same namespace as gradebook_column_move_left/right; serializes all column-order updates per gradebook.
  PERFORM pg_advisory_xact_lock(v_gradebook_id);
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'true', true);

  BEGIN
    UPDATE public.gradebook_columns AS gc
    SET sort_order = ord.new_order
    FROM (
      SELECT id, (ordinality - 1)::integer AS new_order
      FROM unnest(p_ordered_column_ids) WITH ORDINALITY AS t(id, ordinality)
    ) AS ord
    WHERE gc.id = ord.id
      AND gc.gradebook_id = v_gradebook_id;
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
      RAISE;
  END;

  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || v_gradebook_id::text, 'false', true);
END;
$function$

;
CREATE OR REPLACE FUNCTION public.gradebook_auto_layout(p_gradebook_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- function body continues here
DECLARE
  v_col record;
  v_dep_col_id bigint;
  v_max_dep_order integer;
  v_new_order integer;
  v_processed_ids bigint[] := '{}';
  v_remaining_count integer;
  v_prev_remaining_count integer := -1;
  v_class_id bigint;
BEGIN
  -- Get the class_id for this gradebook and check authorization
  SELECT class_id INTO v_class_id
  FROM public.gradebooks
  WHERE id = p_gradebook_id;

  IF v_class_id IS NULL THEN
    RAISE EXCEPTION 'gradebook % not found', p_gradebook_id;
  END IF;

  -- Check if user is authorized as class instructor
  IF NOT public.authorizeforclassinstructor(v_class_id) THEN
    RAISE EXCEPTION 'insufficient permissions: instructor access required for class %', v_class_id;
  END IF;

  -- Serialize per-gradebook to avoid race conditions
  -- Namespace 17031 chosen arbitrarily for "gradebook_auto_layout"
  -- FIXED: Use two-integer version of pg_advisory_xact_lock
  PERFORM pg_advisory_xact_lock(17031, p_gradebook_id::int);
  -- Temporarily bypass the sort order trigger for this specific gradebook during bulk operations
  -- This avoids ACCESS EXCLUSIVE locks that would block concurrent operations on other gradebooks
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'true', true);

  BEGIN
    -- Step 1: Initial alphanumeric sort by slug (lab-2 before lab-10)
    -- Start with a clean 0-based sequence
    WITH ordered_cols AS (
      SELECT id, (ROW_NUMBER() OVER (ORDER BY 
        -- Natural sort: extract text and numeric parts separately
        regexp_replace(slug, '\d+', '', 'g'), -- text part first
        COALESCE(
          (regexp_match(slug, '\d+'))[1]::integer, -- first number found
          0
        ),
        slug -- fallback to original slug for ties
      ) - 1) AS temp_sort_order
      FROM public.gradebook_columns
      WHERE gradebook_id = p_gradebook_id
    )
    UPDATE public.gradebook_columns gc
    SET sort_order = oc.temp_sort_order
    FROM ordered_cols oc
    WHERE gc.id = oc.id;

    -- Step 2: Topological sort to respect gradebook_column dependencies
    -- Process columns until all are handled or we detect a cycle
    LOOP
      SELECT COUNT(*) INTO v_remaining_count
      FROM public.gradebook_columns
      WHERE gradebook_id = p_gradebook_id
        AND id <> ALL(v_processed_ids);

      -- Exit if no more columns to process
      EXIT WHEN v_remaining_count = 0;

      -- Detect infinite loop (circular dependencies)
      IF v_remaining_count = v_prev_remaining_count THEN
        RAISE WARNING 'Circular dependency detected in gradebook %. Stopping topological sort.', p_gradebook_id;
        EXIT;
      END IF;
      v_prev_remaining_count := v_remaining_count;

      -- Process columns that either have no gradebook_column dependencies 
      -- or all their dependencies are already processed
      FOR v_col IN
        SELECT id, slug, dependencies, sort_order
        FROM public.gradebook_columns
        WHERE gradebook_id = p_gradebook_id
          AND id <> ALL(v_processed_ids)
        ORDER BY sort_order NULLS LAST, id
      LOOP
        -- Check if this column has gradebook_column dependencies
        IF v_col.dependencies ? 'gradebook_columns' AND 
           jsonb_array_length(v_col.dependencies->'gradebook_columns') > 0 THEN
          
          -- Find the maximum sort_order among its dependencies that are already processed
          v_max_dep_order := -1;
          
          -- Check each dependency
          FOR v_dep_col_id IN
            SELECT jsonb_array_elements_text(v_col.dependencies->'gradebook_columns')::bigint
          LOOP
            -- Only consider dependencies that are in the same gradebook and already processed
            IF v_dep_col_id = ANY(v_processed_ids) THEN
              SELECT sort_order INTO v_new_order
              FROM public.gradebook_columns
              WHERE id = v_dep_col_id AND gradebook_id = p_gradebook_id;
              
              IF v_new_order IS NOT NULL AND v_new_order > v_max_dep_order THEN
                v_max_dep_order := v_new_order;
              END IF;
            END IF;
          END LOOP;
          
          -- Check if all dependencies are processed
          IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(v_col.dependencies->'gradebook_columns') AS dep_id
            WHERE dep_id::bigint <> ALL(v_processed_ids)
              AND EXISTS (
                SELECT 1 FROM public.gradebook_columns 
                WHERE id = dep_id::bigint AND gradebook_id = p_gradebook_id
              )
          ) THEN
            -- Not all dependencies processed yet, skip this column for now
            CONTINUE;
          END IF;
          
          -- Place this column immediately after its highest dependency
          IF v_max_dep_order >= 0 THEN
            v_new_order := v_max_dep_order + 1;
            
            -- The AFTER trigger should handle conflicts by shifting other columns
            -- when multiple columns try to occupy the same position
            UPDATE public.gradebook_columns
            SET sort_order = v_new_order
            WHERE id = v_col.id;
          END IF;
        END IF;
        
        -- Mark this column as processed
        v_processed_ids := array_append(v_processed_ids, v_col.id);
      END LOOP;
    END LOOP;

    -- Final pass: compact to contiguous 0-based sequence (0,1,2,3...) without gaps
    -- Process in dependency order to maintain relationships
    WITH ordered_final AS (
      SELECT id, ROW_NUMBER() OVER (ORDER BY sort_order, id) - 1 AS final_sort_order
      FROM public.gradebook_columns
      WHERE gradebook_id = p_gradebook_id
    )
    UPDATE public.gradebook_columns gc
    SET sort_order = of.final_sort_order
    FROM ordered_final of
    WHERE gc.id = of.id;

  EXCEPTION
    WHEN OTHERS THEN
      -- Always reset the bypass setting for this gradebook, even if there was an error
      PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'false', true);
      RAISE;
  END;

  -- Reset the bypass setting to re-enable normal trigger enforcement for this gradebook
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'false', true);

END;
$function$

;

DROP FUNCTION public.gradebook_columns_make_groups_contiguous(bigint);
DROP FUNCTION public.gradebook_column_groups_backfill(bigint);
DROP FUNCTION public.gradebook_column_family_title(text);
DROP FUNCTION public.gradebook_column_name_stem(text);
DROP FUNCTION public.gradebook_column_family(text);

-- Dropping a column is DDL and fires no row triggers, so unlike the backfill this sends no
-- realtime traffic.
-- The table goes before the column: its "everyone in class can view" policy reads
-- gradebook_columns.group_id, and the foreign key goes before the table.
ALTER TABLE public.gradebook_columns DROP CONSTRAINT gradebook_columns_group_fkey;
DROP TABLE public.gradebook_column_groups;
DROP FUNCTION public.broadcast_gradebook_column_groups_change();

DROP INDEX public.gradebook_columns_group_id_idx;
ALTER TABLE public.gradebook_columns DROP COLUMN group_id;

ALTER TABLE public.gradebooks DROP CONSTRAINT gradebooks_id_class_id_key;

COMMIT;
