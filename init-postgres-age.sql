-- PostgreSQL initialization for LightRAG with AGE and pgvector extensions
-- This script sets up AGE (Apache AGE) for graph operations and pgvector for vector storage

-- Create extensions (order matters - create them first)
CREATE EXTENSION IF NOT EXISTS age;
CREATE EXTENSION IF NOT EXISTS vector;

-- Load AGE into memory (required for AGE shared libraries)
-- Note: pgvector doesn't require explicit LOAD
LOAD 'age';

-- Set search path to include ag_catalog for AGE functions
SET search_path = ag_catalog, "$user", public;

-- Grant necessary permissions to the postgres user for the database
GRANT ALL PRIVILEGES ON DATABASE lightrag TO postgres;

-- Set default privileges for future objects in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;

-- Grant usage on ag_catalog schema (required for AGE)
GRANT USAGE ON SCHEMA ag_catalog TO postgres;

-- Grant permissions on AGE-related objects
GRANT ALL ON ALL TABLES IN SCHEMA ag_catalog TO postgres;
GRANT ALL ON ALL SEQUENCES IN SCHEMA ag_catalog TO postgres;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA ag_catalog TO postgres;

-- Ensure postgres user can create extensions in the future
ALTER USER postgres CREATEDB;

-- Log completion
DO $$
BEGIN
    RAISE NOTICE 'LightRAG PostgreSQL initialization completed successfully';
    RAISE NOTICE 'Extensions available: AGE (%), pgvector (%)', 
        (SELECT extversion FROM pg_extension WHERE extname = 'age'),
        (SELECT extversion FROM pg_extension WHERE extname = 'vector');
END $$; 