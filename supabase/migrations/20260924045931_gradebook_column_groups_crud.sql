-- Gradebook column groups, part 2: editing them.
--
-- 20260924033840_gradebook_column_groups made a group a row. This adds what an instructor needs
-- to change groups from the gradebook: create a group from columns, move a column into or out of
-- a group, move a whole group left or right, and a Move Left / Move Right on columns that keeps
-- them inside their group. Renaming and deleting a group need no RPC; they are plain UPDATE and
-- DELETE on gradebook_column_groups under the "instructors CRUD" policy.
--
-- The rule every function here keeps: reordering never changes membership. Membership changes
-- only through gradebook_column_group_create and gradebook_column_set_group, and a group's
-- members are always adjacent afterwards.

-- ---------------------------------------------------------------------------------------------
-- One definition of display order
-- ---------------------------------------------------------------------------------------------

-- Columns in the order the gradebook draws them: a group sits where its first member is, its
-- members follow in sort_order, and everything else keeps its sort_order. NULL sort_order counts
-- as 0, as it does in the client (groupGradebookColumns). `unit` is what moves as one piece:
-- a whole group ('g' || group_id) or an ungrouped column ('c' || id).
CREATE OR REPLACE FUNCTION public.gradebook_columns_display_order(p_gradebook_id bigint)
RETURNS TABLE (id bigint, group_id bigint, pos bigint, unit text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    a.id,
    a.group_id,
    row_number() OVER (ORDER BY a.anchor, a.sort_order, a.id) AS pos,
    COALESCE('g' || a.group_id, 'c' || a.id) AS unit
  FROM (
    SELECT
      gc.id,
      gc.group_id,
      COALESCE(gc.sort_order, 0) AS sort_order,
      CASE
        WHEN gc.group_id IS NULL THEN COALESCE(gc.sort_order, 0)
        ELSE min(COALESCE(gc.sort_order, 0)) OVER (PARTITION BY gc.group_id)
      END AS anchor
    FROM public.gradebook_columns gc
    WHERE gc.gradebook_id = p_gradebook_id
  ) a
  ORDER BY pos;
$$;

-- Redefined on top of display order, so the renumbering and the client agree about NULLs.
CREATE OR REPLACE FUNCTION public.gradebook_columns_make_groups_contiguous(p_gradebook_id bigint)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  UPDATE public.gradebook_columns gc
  SET sort_order = (d.pos - 1)::integer
  FROM public.gradebook_columns_display_order(p_gradebook_id) d
  WHERE gc.id = d.id
    AND gc.sort_order IS DISTINCT FROM (d.pos - 1)::integer;
$$;

-- Write a full left-to-right order of a gradebook's columns, then close up any group it split.
-- Callers check authorization and hold pg_advisory_xact_lock(gradebook_id).
CREATE OR REPLACE FUNCTION public.gradebook_columns_apply_order(p_gradebook_id bigint, p_ordered_ids bigint[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'true', true);
  BEGIN
    UPDATE public.gradebook_columns gc
    SET sort_order = (t.ord - 1)::integer
    FROM unnest(p_ordered_ids) WITH ORDINALITY AS t(id, ord)
    WHERE gc.id = t.id
      AND gc.gradebook_id = p_gradebook_id
      AND gc.sort_order IS DISTINCT FROM (t.ord - 1)::integer;

    PERFORM public.gradebook_columns_make_groups_contiguous(p_gradebook_id);
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'false', true);
      RAISE;
  END;
  PERFORM set_config('pawtograder.bypass_sort_order_trigger_' || p_gradebook_id::text, 'false', true);
END;
$$;

-- Same check as gradebook_columns_reorder: signed in, and an instructor of the gradebook's class.
CREATE OR REPLACE FUNCTION public.gradebook_column_groups_authorize(p_gradebook_id bigint)
RETURNS bigint
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_class_id bigint;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT class_id INTO v_class_id FROM public.gradebooks WHERE id = p_gradebook_id;
  IF v_class_id IS NULL THEN
    RAISE EXCEPTION 'gradebook % not found', p_gradebook_id;
  END IF;

  IF NOT public.authorizeforclassinstructor(v_class_id) THEN
    RAISE EXCEPTION 'insufficient permissions: instructor access required for class %', v_class_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN v_class_id;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- A group always has a member
-- ---------------------------------------------------------------------------------------------

-- A group with no columns has no position (it sits where its first member is), so it would be
-- invisible and still hold its name. Delete it as soon as its last column leaves or is deleted.
CREATE OR REPLACE FUNCTION public.gradebook_column_groups_drop_empty()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  DELETE FROM public.gradebook_column_groups g
  WHERE g.id = OLD.group_id
    AND NOT EXISTS (SELECT 1 FROM public.gradebook_columns gc WHERE gc.group_id = OLD.group_id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER gradebook_columns_drop_empty_group_tr
  AFTER UPDATE OF group_id OR DELETE ON public.gradebook_columns
  FOR EACH ROW
  WHEN (OLD.group_id IS NOT NULL)
  EXECUTE FUNCTION public.gradebook_column_groups_drop_empty();

-- ---------------------------------------------------------------------------------------------
-- Membership
-- ---------------------------------------------------------------------------------------------

-- Create a group from one or more columns. The columns leave whatever group they were in and
-- become one block where the first of them (in display order) was. Returns the new group's id.
-- A duplicate name fails on gradebook_column_groups_gradebook_name_key (SQLSTATE 23505).
CREATE OR REPLACE FUNCTION public.gradebook_column_group_create(
  p_gradebook_id bigint,
  p_name text,
  p_column_ids bigint[]
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_class_id bigint;
  v_group_id bigint;
  v_first_pos bigint;
  v_order bigint[];
BEGIN
  v_class_id := public.gradebook_column_groups_authorize(p_gradebook_id);

  IF COALESCE(cardinality(p_column_ids), 0) = 0 THEN
    RAISE EXCEPTION 'A group needs at least one column';
  END IF;

  IF (
    SELECT count(*) FROM public.gradebook_columns
    WHERE gradebook_id = p_gradebook_id AND id = ANY (p_column_ids)
  ) <> (SELECT count(DISTINCT x) FROM unnest(p_column_ids) AS x) THEN
    RAISE EXCEPTION 'One or more columns do not belong to this gradebook';
  END IF;

  PERFORM pg_advisory_xact_lock(p_gradebook_id);

  -- Order is decided before membership changes, because display order depends on membership.
  SELECT min(d.pos) INTO v_first_pos
  FROM public.gradebook_columns_display_order(p_gradebook_id) d
  WHERE d.id = ANY (p_column_ids);

  SELECT array_agg(d.id ORDER BY CASE WHEN d.id = ANY (p_column_ids) THEN v_first_pos ELSE d.pos END, d.pos)
  INTO v_order
  FROM public.gradebook_columns_display_order(p_gradebook_id) d;

  INSERT INTO public.gradebook_column_groups (class_id, gradebook_id, name)
  VALUES (v_class_id, p_gradebook_id, btrim(p_name))
  RETURNING id INTO v_group_id;

  UPDATE public.gradebook_columns SET group_id = v_group_id WHERE id = ANY (p_column_ids);

  PERFORM public.gradebook_columns_apply_order(p_gradebook_id, v_order);
  RETURN v_group_id;
END;
$$;

-- Move a column into a group (p_group_id) or out of its group (p_group_id NULL). A column that
-- joins a group goes after the group's last member; a column that leaves goes just after the
-- group it left. Nothing else moves.
CREATE OR REPLACE FUNCTION public.gradebook_column_set_group(p_column_id bigint, p_group_id bigint DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_col public.gradebook_columns;
  v_after_pos bigint;
  v_order bigint[];
BEGIN
  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id;
  IF v_col.id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_column_id;
  END IF;

  PERFORM public.gradebook_column_groups_authorize(v_col.gradebook_id);

  IF p_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gradebook_column_groups WHERE id = p_group_id AND gradebook_id = v_col.gradebook_id
  ) THEN
    RAISE EXCEPTION 'Column group % is not in this gradebook', p_group_id;
  END IF;

  IF v_col.group_id IS NOT DISTINCT FROM p_group_id THEN
    RETURN;
  END IF;

  PERFORM pg_advisory_xact_lock(v_col.gradebook_id);

  SELECT max(d.pos) INTO v_after_pos
  FROM public.gradebook_columns_display_order(v_col.gradebook_id) d
  WHERE d.group_id = COALESCE(p_group_id, v_col.group_id)
    AND d.id <> p_column_id;

  -- Positions are doubled so the moved column can sit in the odd slot just after v_after_pos.
  -- If there is no such member (it was a group of one, now leaving), it stays where it is.
  SELECT array_agg(d.id ORDER BY
    CASE WHEN d.id = p_column_id AND v_after_pos IS NOT NULL THEN v_after_pos * 2 + 1 ELSE d.pos * 2 END)
  INTO v_order
  FROM public.gradebook_columns_display_order(v_col.gradebook_id) d;

  UPDATE public.gradebook_columns SET group_id = p_group_id WHERE id = p_column_id;

  PERFORM public.gradebook_columns_apply_order(v_col.gradebook_id, v_order);
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reordering that keeps membership
-- ---------------------------------------------------------------------------------------------

-- Swap a unit (a whole group, or an ungrouped column) with its neighbor unit on one side.
-- Returns false when there is nothing on that side.
CREATE OR REPLACE FUNCTION public.gradebook_columns_swap_unit(p_gradebook_id bigint, p_unit text, p_direction integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order bigint[];
BEGIN
  WITH d AS (
    SELECT * FROM public.gradebook_columns_display_order(p_gradebook_id)
  ),
  u AS (
    SELECT d.unit, row_number() OVER (ORDER BY min(d.pos)) AS r FROM d GROUP BY d.unit
  ),
  me AS (SELECT r FROM u WHERE u.unit = p_unit),
  nb AS (SELECT u.r FROM u, me WHERE u.r = me.r + sign(p_direction))
  SELECT array_agg(d.id ORDER BY
    CASE WHEN u.r = me.r THEN nb.r WHEN u.r = nb.r THEN me.r ELSE u.r END, d.pos)
  INTO v_order
  FROM d JOIN u ON u.unit = d.unit CROSS JOIN me CROSS JOIN nb;

  IF v_order IS NULL THEN
    RETURN false;
  END IF;

  PERFORM public.gradebook_columns_apply_order(p_gradebook_id, v_order);
  RETURN true;
END;
$$;

-- Move a whole group one unit left (p_direction < 0) or right (> 0), past an ungrouped column or
-- past a whole neighboring group. Returns false at the edge of the gradebook.
CREATE OR REPLACE FUNCTION public.gradebook_column_group_move(p_group_id bigint, p_direction integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_gradebook_id bigint;
BEGIN
  SELECT gradebook_id INTO v_gradebook_id FROM public.gradebook_column_groups WHERE id = p_group_id;
  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'column group % not found', p_group_id;
  END IF;

  PERFORM public.gradebook_column_groups_authorize(v_gradebook_id);
  PERFORM pg_advisory_xact_lock(v_gradebook_id);

  RETURN public.gradebook_columns_swap_unit(v_gradebook_id, 'g' || p_group_id, p_direction);
END;
$$;

-- Move one column one step left or right. A grouped column swaps with its neighbor inside the
-- group and stops at the group's edge; an ungrouped column steps past its neighbor unit, which
-- may be a whole group. Returns false when it did not move.
CREATE OR REPLACE FUNCTION public.gradebook_column_step(p_column_id bigint, p_direction integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_col public.gradebook_columns;
  v_order bigint[];
BEGIN
  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id;
  IF v_col.id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_column_id;
  END IF;

  PERFORM public.gradebook_column_groups_authorize(v_col.gradebook_id);
  PERFORM pg_advisory_xact_lock(v_col.gradebook_id);

  IF v_col.group_id IS NULL THEN
    RETURN public.gradebook_columns_swap_unit(v_col.gradebook_id, 'c' || p_column_id, p_direction);
  END IF;

  WITH d AS (
    SELECT * FROM public.gradebook_columns_display_order(v_col.gradebook_id)
  ),
  me AS (SELECT pos FROM d WHERE d.id = p_column_id),
  nb AS (
    SELECT d.id, d.pos FROM d, me
    WHERE d.group_id = v_col.group_id
      AND ((p_direction < 0 AND d.pos < me.pos) OR (p_direction > 0 AND d.pos > me.pos))
    ORDER BY abs(d.pos - me.pos)
    LIMIT 1
  )
  SELECT array_agg(d.id ORDER BY
    CASE WHEN d.id = p_column_id THEN nb.pos WHEN d.id = nb.id THEN me.pos ELSE d.pos END)
  INTO v_order
  FROM d CROSS JOIN me CROSS JOIN nb;

  IF v_order IS NULL THEN
    RETURN false;
  END IF;

  PERFORM public.gradebook_columns_apply_order(v_col.gradebook_id, v_order);
  RETURN true;
END;
$$;

-- The column menu's Move Left / Move Right keep their signatures and return the moved row, as
-- before. They used to swap with the neighbor by sort_order, which could carry a column out of
-- its group in sort_order while the display kept drawing it inside.
CREATE OR REPLACE FUNCTION public.gradebook_column_move_left(p_column_id bigint)
RETURNS public.gradebook_columns
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_col public.gradebook_columns;
BEGIN
  PERFORM public.gradebook_column_step(p_column_id, -1);
  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id;
  RETURN v_col;
END;
$$;

CREATE OR REPLACE FUNCTION public.gradebook_column_move_right(p_column_id bigint)
RETURNS public.gradebook_columns
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  v_col public.gradebook_columns;
BEGIN
  PERFORM public.gradebook_column_step(p_column_id, 1);
  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id;
  RETURN v_col;
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges: the four RPCs the app calls are for signed-in users (they check for an instructor
-- themselves); the helpers are internal.
-- ---------------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.gradebook_columns_display_order(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gradebook_columns_apply_order(bigint, bigint[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gradebook_column_groups_authorize(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gradebook_columns_swap_unit(bigint, text, integer) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.gradebook_column_group_create(bigint, text, bigint[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gradebook_column_set_group(bigint, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gradebook_column_group_move(bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gradebook_column_step(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gradebook_column_group_create(bigint, text, bigint[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gradebook_column_set_group(bigint, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gradebook_column_group_move(bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gradebook_column_step(bigint, integer) TO authenticated, service_role;
