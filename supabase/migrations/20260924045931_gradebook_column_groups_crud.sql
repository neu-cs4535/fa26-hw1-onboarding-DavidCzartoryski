-- Gradebook column groups, part 2: editing them.
--
-- 20260924033840_gradebook_column_groups made a group a row and gave the database one definition
-- of column order (gradebook_columns_display_order) and one way to write it
-- (gradebook_columns_apply_order). This adds what an instructor needs to change groups from the
-- gradebook: create a group from columns, move a column into or out of a group, move a whole
-- group left or right, and a Move Left / Move Right on columns that keeps them inside their
-- group. Renaming and deleting a group need no RPC; they are plain UPDATE (of name only) and
-- DELETE on gradebook_column_groups under the "instructors CRUD" policy.
--
-- The rule every function here keeps: reordering never changes membership. Membership changes
-- only through gradebook_column_group_create and gradebook_column_set_group, and a group's
-- members are always adjacent afterwards.
--
-- Every RPC takes pg_advisory_xact_lock(gradebook_id) before it reads anything it will act on,
-- so two instructors editing the same gradebook are serialized.

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

CREATE OR REPLACE FUNCTION public.gradebook_column_groups_check_direction(p_direction integer)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'direction must be -1 (left) or 1 (right), got %', p_direction
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
END;
$$;

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
  v_bypass_key text := 'pawtograder.bypass_sort_order_trigger_' || p_gradebook_id;
  v_prev_bypass text;
  v_class_id bigint;
  v_name text := public.gradebook_column_group_clean_name(p_name);
  v_group_id bigint;
  v_order bigint[];
BEGIN
  v_class_id := public.gradebook_column_groups_authorize(p_gradebook_id);
  PERFORM pg_advisory_xact_lock(p_gradebook_id);

  IF v_name IS NULL OR v_name = '' THEN
    RAISE EXCEPTION 'A group needs a name' USING ERRCODE = 'check_violation';
  END IF;

  IF COALESCE(cardinality(p_column_ids), 0) = 0 THEN
    RAISE EXCEPTION 'A group needs at least one column';
  END IF;

  IF (
    SELECT count(*) FROM public.gradebook_columns
    WHERE gradebook_id = p_gradebook_id AND id = ANY (p_column_ids)
  ) <> (SELECT count(DISTINCT x) FROM unnest(p_column_ids) AS x) THEN
    RAISE EXCEPTION 'One or more columns do not belong to this gradebook';
  END IF;

  -- The order is decided before membership changes, because display order depends on
  -- membership: the chosen columns form one block where the first of them is now.
  WITH d AS (
    SELECT * FROM public.gradebook_columns_display_order(p_gradebook_id)
  ),
  first_chosen AS (
    SELECT min(d.pos) AS pos FROM d WHERE d.id = ANY (p_column_ids)
  )
  SELECT array_agg(d.id ORDER BY CASE WHEN d.id = ANY (p_column_ids) THEN first_chosen.pos ELSE d.pos END, d.pos)
  INTO v_order
  FROM d CROSS JOIN first_chosen;

  INSERT INTO public.gradebook_column_groups (class_id, gradebook_id, name)
  VALUES (v_class_id, p_gradebook_id, v_name)
  RETURNING id INTO v_group_id;

  -- Holding the sort_order bypass tells the repair trigger that this function places the columns.
  v_prev_bypass := COALESCE(NULLIF(current_setting(v_bypass_key, true), ''), 'false');
  PERFORM set_config(v_bypass_key, 'true', true);
  UPDATE public.gradebook_columns SET group_id = v_group_id WHERE id = ANY (p_column_ids);
  PERFORM public.gradebook_columns_apply_order(p_gradebook_id, v_order);
  PERFORM set_config(v_bypass_key, v_prev_bypass, true);

  RETURN v_group_id;
END;
$$;

-- Move a column into a group (p_group_id) or out of its group (p_group_id omitted or NULL). A
-- column that joins a group goes after the group's last member; a column that leaves goes just
-- after the group it left. Nothing else moves.
CREATE OR REPLACE FUNCTION public.gradebook_column_set_group(p_column_id bigint, p_group_id bigint DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_gradebook_id bigint;
  v_bypass_key text;
  v_prev_bypass text;
  v_col public.gradebook_columns;
  v_order bigint[];
BEGIN
  SELECT gradebook_id INTO v_gradebook_id FROM public.gradebook_columns WHERE id = p_column_id;
  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_column_id;
  END IF;

  PERFORM public.gradebook_column_groups_authorize(v_gradebook_id);
  PERFORM pg_advisory_xact_lock(v_gradebook_id);

  -- Re-read under the lock: a concurrent edit may have moved the column since the first read.
  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id FOR UPDATE;

  IF p_group_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.gradebook_column_groups WHERE id = p_group_id AND gradebook_id = v_col.gradebook_id
  ) THEN
    RAISE EXCEPTION 'Column group % is not in this gradebook', p_group_id;
  END IF;

  IF v_col.group_id IS NOT DISTINCT FROM p_group_id THEN
    RETURN;
  END IF;

  -- Positions are doubled so the moved column can sit in the odd slot just after the last other
  -- member of the group it joins or leaves. If there is no such member (it was a group of one,
  -- now leaving), it stays where it is.
  WITH d AS (
    SELECT * FROM public.gradebook_columns_display_order(v_col.gradebook_id)
  ),
  anchor AS (
    SELECT max(d.pos) AS pos FROM d
    WHERE d.group_id = COALESCE(p_group_id, v_col.group_id) AND d.id <> p_column_id
  )
  SELECT array_agg(d.id ORDER BY
    CASE WHEN d.id = p_column_id AND anchor.pos IS NOT NULL THEN anchor.pos * 2 + 1 ELSE d.pos * 2 END)
  INTO v_order
  FROM d CROSS JOIN anchor;

  v_bypass_key := 'pawtograder.bypass_sort_order_trigger_' || v_col.gradebook_id;
  v_prev_bypass := COALESCE(NULLIF(current_setting(v_bypass_key, true), ''), 'false');
  PERFORM set_config(v_bypass_key, 'true', true);
  UPDATE public.gradebook_columns SET group_id = p_group_id WHERE id = p_column_id;
  PERFORM public.gradebook_columns_apply_order(v_col.gradebook_id, v_order);
  PERFORM set_config(v_bypass_key, v_prev_bypass, true);
END;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reordering that keeps membership
-- ---------------------------------------------------------------------------------------------

-- Swap a unit (a whole group, or an ungrouped column) with its neighbor unit on one side.
-- Returns false when there is nothing on that side. Callers check authorization and the
-- direction, and hold the lock.
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
  nb AS (SELECT u.r FROM u, me WHERE u.r = me.r + p_direction)
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

-- Move a whole group one unit left (-1) or right (1), past an ungrouped column or past a whole
-- neighboring group. Returns false at the edge of the gradebook.
CREATE OR REPLACE FUNCTION public.gradebook_column_group_move(p_group_id bigint, p_direction integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_gradebook_id bigint;
BEGIN
  PERFORM public.gradebook_column_groups_check_direction(p_direction);

  -- A group's gradebook_id can't change (authenticated may only update its name).
  SELECT gradebook_id INTO v_gradebook_id FROM public.gradebook_column_groups WHERE id = p_group_id;
  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'column group % not found', p_group_id;
  END IF;

  PERFORM public.gradebook_column_groups_authorize(v_gradebook_id);
  PERFORM pg_advisory_xact_lock(v_gradebook_id);

  -- Re-check under the lock: a concurrent edit may have emptied (and so deleted) the group.
  IF NOT EXISTS (SELECT 1 FROM public.gradebook_column_groups WHERE id = p_group_id) THEN
    RAISE EXCEPTION 'column group % not found', p_group_id;
  END IF;

  RETURN public.gradebook_columns_swap_unit(v_gradebook_id, 'g' || p_group_id, p_direction);
END;
$$;

-- Move one column one step left (-1) or right (1). A grouped column swaps with its neighbor
-- inside the group and stops at the group's edge; an ungrouped column steps past its neighbor
-- unit, which may be a whole group. Returns whether it moved.
CREATE OR REPLACE FUNCTION public.gradebook_column_step(p_column_id bigint, p_direction integer)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_gradebook_id bigint;
  v_col public.gradebook_columns;
  v_order bigint[];
BEGIN
  PERFORM public.gradebook_column_groups_check_direction(p_direction);

  SELECT gradebook_id INTO v_gradebook_id FROM public.gradebook_columns WHERE id = p_column_id;
  IF v_gradebook_id IS NULL THEN
    RAISE EXCEPTION 'gradebook column % not found', p_column_id;
  END IF;

  PERFORM public.gradebook_column_groups_authorize(v_gradebook_id);
  PERFORM pg_advisory_xact_lock(v_gradebook_id);

  -- Re-read under the lock: a concurrent edit may have changed the column's group.
  SELECT * INTO v_col FROM public.gradebook_columns WHERE id = p_column_id FOR UPDATE;

  IF v_col.group_id IS NULL THEN
    RETURN public.gradebook_columns_swap_unit(v_col.gradebook_id, 'c' || p_column_id, p_direction);
  END IF;

  -- Groups are contiguous in display order, so the neighbor inside the group is the column one
  -- position over, if that column is in the same group.
  WITH d AS (
    SELECT * FROM public.gradebook_columns_display_order(v_col.gradebook_id)
  ),
  me AS (SELECT pos FROM d WHERE d.id = p_column_id),
  nb AS (
    SELECT d.id, d.pos FROM d, me
    WHERE d.group_id = v_col.group_id
      AND d.pos = me.pos + p_direction
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
-- its group in sort_order while the display kept drawing it inside. The gradebook itself calls
-- gradebook_column_step, which also says whether the column moved.
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

REVOKE ALL ON FUNCTION public.gradebook_column_groups_authorize(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gradebook_column_groups_check_direction(integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gradebook_columns_swap_unit(bigint, text, integer) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.gradebook_column_group_create(bigint, text, bigint[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gradebook_column_set_group(bigint, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gradebook_column_group_move(bigint, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gradebook_column_step(bigint, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gradebook_column_group_create(bigint, text, bigint[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gradebook_column_set_group(bigint, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gradebook_column_group_move(bigint, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gradebook_column_step(bigint, integer) TO authenticated, service_role;
