-- =============================================================================
-- pgvector schema — spark-sovereign memory + RAG web cache
-- Runs once on container first start.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- Lessons learned from agent sessions and web search
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lessons (
    id          BIGSERIAL PRIMARY KEY,
    content     TEXT NOT NULL,
    outcome     TEXT CHECK (outcome IN ('success','failure','preference','decision')),
    domain      TEXT,
    importance  FLOAT DEFAULT 0.8,
    embedding   VECTOR(768) NOT NULL,            -- nomic-embed-v1.5 dimensions
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    last_used   TIMESTAMPTZ DEFAULT NOW(),
    use_count   INT DEFAULT 0,
    source      TEXT DEFAULT 'agent'             -- 'agent' | 'web_search'
);

-- ---------------------------------------------------------------------------
-- RAG cache — SearXNG web results that the agent confirmed as correct
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rag_cache (
    id          BIGSERIAL PRIMARY KEY,
    query       TEXT NOT NULL,
    result      TEXT NOT NULL,
    source_url  TEXT,
    verified    BOOLEAN DEFAULT FALSE,           -- TRUE when agent confirms correct
    confidence  FLOAT DEFAULT 0.7,
    embedding   VECTOR(768) NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    used_count  INT DEFAULT 0
);

-- ---------------------------------------------------------------------------
-- HNSW indexes for fast cosine similarity search
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS lessons_hnsw
    ON lessons USING hnsw (embedding vector_cosine_ops)
    WITH (m=16, ef_construction=64);

CREATE INDEX IF NOT EXISTS rag_hnsw
    ON rag_cache USING hnsw (embedding vector_cosine_ops)
    WITH (m=16, ef_construction=64);

-- ---------------------------------------------------------------------------
-- Scalar filter indexes
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS lessons_outcome    ON lessons (outcome, domain);
CREATE INDEX IF NOT EXISTS lessons_importance ON lessons (importance DESC);
CREATE INDEX IF NOT EXISTS rag_verified       ON rag_cache (verified, confidence DESC);
