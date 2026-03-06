CREATE OR REPLACE FUNCTION public.match_companies_filtered(
  p_embedding vector(768),
  p_filters   jsonb DEFAULT '{}',
  p_limit     int   DEFAULT 1000
)
RETURNS TABLE (
  fund_prime_scope              text,
  logo                          text,
  name                          text,
  website                       text,
  hq_country                    text[],
  hq_city                       text,
  inc_date                      integer,
  description                   text,
  detailed_solution             text,
  use_cases                     text,
  clients_served                text[],
  number_of_clients_identified  bigint,
  global_2000_clients           text[],
  cg_key_platforms              text[],
  by_key_platforms              text[],
  competitors_cg                text[],
  competitors_by                text[],
  affiliates_cg                 text[],
  affiliates_by                 text[],
  gtm_target_cg                 text,
  gtm_target_by                 text,
  vc_current_stage              text,
  first_vc_round_date           date,
  first_vc_round_amount         numeric,
  total_amount_raised           numeric,
  last_funding_amount           numeric,
  last_funding_date             date,
  all_investors                 text[],
  last_round_lead_investors     text[],
  total_nber_of_rounds          integer,
  business_model                text,
  founders_background           text,
  serial_entrepreneur           boolean,
  primary_sector_served_cg      text,
  primary_industry_served_cg    text,
  primary_sector_served_by      text,
  primary_industry_served_by    text,
  all_industries_served         text[],
  business_mapping              text,
  tech_tags                     text[],
  solution_fit_cg               integer,
  solution_fit_by               integer,
  business_fit_cg               integer,
  business_fit_by               integer,
  maturity_fit                  integer,
  equity_score                  integer,
  traction_score                integer,
  global_fund_score             integer,
  present_in_attio              boolean,
  last_stage_in_attio           text,
  last_status_in_attio          text,
  headcount                     integer,
  headcount_growth_l12m         numeric,
  web_traffic                   integer,
  web_traffic_growth_l12m       numeric,
  similarity                    float8
)
LANGUAGE plpgsql STABLE SECURITY INVOKER
AS $$
DECLARE
  v_sql       text;
  v_where     text := '';
  v_filter    jsonb;
  v_col       text;
  v_op        text;
  v_vals      text[];
  v_val_text  text;
  v_val_num   numeric;

  VALID_TAG_COLS      CONSTANT text[] := ARRAY['fund_prime_scope','hq_city','gtm_target_cg','gtm_target_by','vc_current_stage','business_model','primary_sector_served_cg','primary_industry_served_cg','primary_sector_served_by','primary_industry_served_by','business_mapping','last_stage_in_attio','last_status_in_attio'];
  VALID_MULTITAG_COLS CONSTANT text[] := ARRAY['hq_country','global_2000_clients','cg_key_platforms','by_key_platforms','competitors_cg','competitors_by','affiliates_cg','affiliates_by','all_investors','last_round_lead_investors','all_industries_served','tech_tags'];
  VALID_NUMBER_COLS   CONSTANT text[] := ARRAY['inc_date','number_of_clients_identified','first_vc_round_amount','total_amount_raised','last_funding_amount','total_nber_of_rounds','solution_fit_cg','solution_fit_by','business_fit_cg','business_fit_by','maturity_fit','equity_score','traction_score','global_fund_score','headcount','headcount_growth_l12m','web_traffic','web_traffic_growth_l12m'];
  VALID_DATE_COLS     CONSTANT text[] := ARRAY['first_vc_round_date','last_funding_date'];
  VALID_BOOL_COLS     CONSTANT text[] := ARRAY['present_in_attio','serial_entrepreneur'];
BEGIN
  -- tag_filters: op = 'in' | 'not_null'
  FOR v_filter IN SELECT * FROM jsonb_array_elements(COALESCE(p_filters->'tag_filters','[]'))
  LOOP
    v_col := v_filter->>'col'; v_op := v_filter->>'op';
    CONTINUE WHEN NOT (v_col = ANY(VALID_TAG_COLS));
    IF v_op = 'in' THEN
      SELECT array_agg(x) INTO v_vals FROM jsonb_array_elements_text(v_filter->'val') t(x);
      IF v_vals IS NOT NULL AND array_length(v_vals,1) > 0 THEN
        v_where := v_where || format(' AND sv.%I = ANY(%L::text[])', v_col, v_vals);
      END IF;
    ELSIF v_op = 'not_null' THEN
      v_where := v_where || format(' AND sv.%I IS NOT NULL', v_col);
    END IF;
  END LOOP;

  -- multitag_filters: op = 'contains' (overlap) | 'not_empty'
  FOR v_filter IN SELECT * FROM jsonb_array_elements(COALESCE(p_filters->'multitag_filters','[]'))
  LOOP
    v_col := v_filter->>'col'; v_op := v_filter->>'op';
    CONTINUE WHEN NOT (v_col = ANY(VALID_MULTITAG_COLS));
    IF v_op = 'contains' THEN
      SELECT array_agg(x) INTO v_vals FROM jsonb_array_elements_text(v_filter->'val') t(x);
      IF v_vals IS NOT NULL AND array_length(v_vals,1) > 0 THEN
        v_where := v_where || format(' AND sv.%I && %L::text[]', v_col, v_vals);
      END IF;
    ELSIF v_op = 'not_empty' THEN
      v_where := v_where || format(' AND array_length(sv.%I, 1) > 0', v_col);
    END IF;
  END LOOP;

  -- text_filters: op = 'contains' (ilike) | 'not_null'  (domain -> website)
  FOR v_filter IN SELECT * FROM jsonb_array_elements(COALESCE(p_filters->'text_filters','[]'))
  LOOP
    v_col := v_filter->>'col'; v_op := v_filter->>'op';
    IF v_col = 'domain' THEN v_col := 'website'; END IF;
    CONTINUE WHEN NOT (v_col = ANY(ARRAY['name','website']));
    IF v_op = 'contains' THEN
      v_val_text := v_filter->>'val';
      v_where := v_where || format(' AND sv.%I ILIKE %L', v_col, '%' || v_val_text || '%');
    ELSIF v_op = 'not_null' THEN
      v_where := v_where || format(' AND sv.%I IS NOT NULL', v_col);
    END IF;
  END LOOP;

  -- number_filters: op = 'gte' | 'lte' | 'not_null'
  FOR v_filter IN SELECT * FROM jsonb_array_elements(COALESCE(p_filters->'number_filters','[]'))
  LOOP
    v_col := v_filter->>'col'; v_op := v_filter->>'op';
    CONTINUE WHEN NOT (v_col = ANY(VALID_NUMBER_COLS));
    IF v_op = 'not_null' THEN
      v_where := v_where || format(' AND sv.%I IS NOT NULL', v_col);
    ELSIF v_op IN ('gte','lte') THEN
      v_val_num := (v_filter->>'val')::numeric;
      v_where := v_where || format(' AND sv.%I ' || CASE WHEN v_op='gte' THEN '>=' ELSE '<=' END || ' %L', v_col, v_val_num);
    END IF;
  END LOOP;

  -- date_filters: op = 'gte' | 'lte' | 'not_null'
  FOR v_filter IN SELECT * FROM jsonb_array_elements(COALESCE(p_filters->'date_filters','[]'))
  LOOP
    v_col := v_filter->>'col'; v_op := v_filter->>'op';
    CONTINUE WHEN NOT (v_col = ANY(VALID_DATE_COLS));
    IF v_op = 'not_null' THEN
      v_where := v_where || format(' AND sv.%I IS NOT NULL', v_col);
    ELSIF v_op IN ('gte','lte') THEN
      v_val_text := v_filter->>'val';
      v_where := v_where || format(' AND sv.%I ' || CASE WHEN v_op='gte' THEN '>=' ELSE '<=' END || ' %L::date', v_col, v_val_text);
    END IF;
  END LOOP;

  -- bool_filters: eq boolean
  FOR v_filter IN SELECT * FROM jsonb_array_elements(COALESCE(p_filters->'bool_filters','[]'))
  LOOP
    v_col := v_filter->>'col';
    CONTINUE WHEN NOT (v_col = ANY(VALID_BOOL_COLS));
    v_where := v_where || format(' AND sv.%I = %L::boolean', v_col, v_filter->>'val');
  END LOOP;

  -- Query sourcing_mv directly — a pre-materialized flat table with an HNSW
  -- index on full_embedding. No lateral subqueries, no live view joins.
  -- The planner uses the HNSW index for ORDER BY + LIMIT without a full scan.
  v_sql := format(
    'SELECT sv.fund_prime_scope, sv.logo, sv.name, sv.website, sv.hq_country, sv.hq_city,
            sv.inc_date, sv.description, sv.detailed_solution, sv.use_cases,
            sv.clients_served, sv.number_of_clients_identified, sv.global_2000_clients,
            sv.cg_key_platforms, sv.by_key_platforms, sv.competitors_cg, sv.competitors_by,
            sv.affiliates_cg, sv.affiliates_by, sv.gtm_target_cg, sv.gtm_target_by,
            sv.vc_current_stage, sv.first_vc_round_date, sv.first_vc_round_amount,
            sv.total_amount_raised, sv.last_funding_amount, sv.last_funding_date,
            sv.all_investors, sv.last_round_lead_investors, sv.total_nber_of_rounds,
            sv.business_model, sv.founders_background, sv.serial_entrepreneur,
            sv.primary_sector_served_cg, sv.primary_industry_served_cg,
            sv.primary_sector_served_by, sv.primary_industry_served_by,
            sv.all_industries_served, sv.business_mapping, sv.tech_tags,
            sv.solution_fit_cg, sv.solution_fit_by, sv.business_fit_cg, sv.business_fit_by,
            sv.maturity_fit, sv.equity_score, sv.traction_score, sv.global_fund_score,
            sv.present_in_attio, sv.last_stage_in_attio, sv.last_status_in_attio,
            sv.headcount, sv.headcount_growth_l12m, sv.web_traffic, sv.web_traffic_growth_l12m,
            1 - (sv.full_embedding <=> $1) AS similarity
     FROM   public.sourcing_mv sv
     WHERE  sv.full_embedding IS NOT NULL%s
     ORDER BY sv.full_embedding <=> $1
     LIMIT  %s',
    v_where,
    p_limit
  );

  RETURN QUERY EXECUTE v_sql USING p_embedding;
END;
$$;

GRANT EXECUTE ON FUNCTION public.match_companies_filtered(vector, jsonb, int) TO authenticated;
