-- Enable pg_trgm extension for trigram-based fuzzy string matching
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE OR REPLACE FUNCTION public.search_companies(
  search_query         TEXT,
  similarity_threshold FLOAT DEFAULT 0.15,
  max_results          INT   DEFAULT 50
)
RETURNS SETOF public.sourcing_view
LANGUAGE sql
STABLE
SECURITY INVOKER
AS $$
  SELECT sv.*
  FROM   public.sourcing_view sv
  WHERE
    similarity(search_query, sv.name)    > similarity_threshold
    OR similarity(search_query, sv.website) > similarity_threshold
  ORDER BY
    GREATEST(
      similarity(search_query, sv.name),
      similarity(search_query, sv.website)
    ) DESC
  LIMIT max_results;
$$;

GRANT EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.search_companies(TEXT, FLOAT, INT) FROM anon;
