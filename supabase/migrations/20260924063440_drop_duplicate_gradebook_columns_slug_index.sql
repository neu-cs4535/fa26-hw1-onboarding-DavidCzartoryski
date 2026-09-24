-- gradebook_columns has two identical unique indexes on (class_id, slug): the constraint
-- gradebook_columns_class_id_slug_key from 20250614231720_gradebook, and
-- idx_gradebook_columns_unique_class_slug, added again by 20250822193218_code-walk-rubrics. Every
-- insert and every slug-touching update maintains both. The constraint stays: the gradebook UI
-- recognizes its name in the duplicate-slug error ("slug_key"), which it can't do when the other
-- index is the one that reports the violation. ON CONFLICT (class_id, slug) in
-- create_gradebook_column_for_code_walk_rubric infers the constraint's index just as well.
DROP INDEX IF EXISTS public.idx_gradebook_columns_unique_class_slug;
