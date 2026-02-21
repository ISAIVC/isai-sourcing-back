-- Migration: Create vectorized table for company embeddings
-- Requires the pgvector extension for vector similarity search

-- Enable pgvector extension
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;

-- Create the company_embeddings table
CREATE TABLE IF NOT EXISTS public.company_embeddings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  domain TEXT NOT NULL UNIQUE REFERENCES public.companies(domain) ON DELETE CASCADE,

  solution_and_use_cases_embedding vector(1536)
  full_embedding vector(1536),
);

-- Enable RLS
ALTER TABLE public.company_embeddings ENABLE ROW LEVEL SECURITY;

-- Trigger for updated_at
CREATE TRIGGER set_company_embeddings_updated_at
  BEFORE UPDATE ON public.company_embeddings
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();