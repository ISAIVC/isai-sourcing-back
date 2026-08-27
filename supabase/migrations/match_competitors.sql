-- ---------------------------------------------------------------------------
-- Semantic competitor search: "find the companies that do the same thing".
--
-- Uses company_embeddings.solution_and_use_cases_embedding (detailed_solution +
-- use_cases, embedded with task type CLASSIFICATION) rather than full_embedding
-- (which also carries the marketing description, and pulls in companies that
-- *talk* alike rather than companies that *do* the same thing).
--
-- The source vector is read straight from the table: no embedding API call, so
-- the whole thing is a single indexed ANN query.
-- Idempotent.
-- ---------------------------------------------------------------------------

-- HNSW index on the solution/use-cases axis (full_embedding already has one on
-- sourcing_mv). Cosine, to match the <=> operator used below.
CREATE INDEX IF NOT EXISTS company_embeddings_solution_hnsw
  ON public.company_embeddings
  USING hnsw (solution_and_use_cases_embedding extensions.vector_cosine_ops);

-- p_domain          : companies.domain (= sourcing_mv.website)
-- p_limit           : rows returned after the similarity floor
-- p_min_similarity  : cosine floor, 0..1. Calibrate on a few known companies:
--                     without it the ANN always returns p_limit rows, competitors
--                     or not.
CREATE OR REPLACE FUNCTION public.match_competitors(
  p_domain         text,
  p_limit          int      DEFAULT 20,
  p_min_similarity float8   DEFAULT 0.5
)
RETURNS TABLE (
  website               text,
  name                  text,
  logo                  text,
  description           text,
  hq_country            text[],
  vc_current_stage      text,
  inc_date              integer,
  total_amount_raised   numeric,
  last_funding_date     date,
  headcount             integer,
  business_mapping      text,
  primary_sector_served_cg text,
  global_fund_score     integer,
  present_in_attio      boolean,
  last_stage_in_attio   text,
  similarity            float8
)
LANGUAGE plpgsql
STABLE
-- SECURITY DEFINER: company_embeddings has RLS enabled with no permissive
-- policy, so authenticated users can only reach the vectors through this
-- function.
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_embedding extensions.vector(768);
BEGIN
  SELECT ce.solution_and_use_cases_embedding
    INTO v_embedding
    FROM public.company_embeddings ce
   WHERE ce.domain = p_domain;

  -- Unknown domain, or a company the pipeline has not embedded yet.
  IF v_embedding IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH neighbours AS (
    -- Over-fetch: the similarity floor and the join to sourcing_mv both drop
    -- rows, and the LIMIT is what lets the planner use the HNSW index.
    SELECT ce.domain,
           1 - (ce.solution_and_use_cases_embedding <=> v_embedding) AS similarity
      FROM public.company_embeddings ce
     WHERE ce.solution_and_use_cases_embedding IS NOT NULL
       AND ce.domain <> p_domain
     ORDER BY ce.solution_and_use_cases_embedding <=> v_embedding
     LIMIT GREATEST(p_limit * 5, 100)
  )
  SELECT sv.website, sv.name, sv.logo, sv.description, sv.hq_country,
         sv.vc_current_stage, sv.inc_date, sv.total_amount_raised,
         sv.last_funding_date, sv.headcount, sv.business_mapping,
         sv.primary_sector_served_cg, sv.global_fund_score,
         sv.present_in_attio, sv.last_stage_in_attio, n.similarity
    FROM neighbours n
    JOIN public.sourcing_mv sv ON sv.website = n.domain
   WHERE n.similarity >= p_min_similarity
   ORDER BY n.similarity DESC
   LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.match_competitors(text, int, float8) FROM anon;
GRANT EXECUTE ON FUNCTION public.match_competitors(text, int, float8) TO authenticated;
