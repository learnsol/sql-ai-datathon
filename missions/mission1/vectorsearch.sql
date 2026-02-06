-- =============================================================================
-- Semantic Search with AI_GENERATE_EMBEDDINGS
-- =============================================================================
-- Description: Performs end-to-end semantic similarity search by:
--              1. Generating a vector embedding from a natural language query
--              2. Using VECTOR_SEARCH to find similar products
--              Uses AI_GENERATE_EMBEDDINGS() with the MyEmbeddingModel external model.
--
-- Prerequisites:
--   - 03-create-http-credentials.sql must be executed first (creates External Model)
--   - Product table with embeddings populated (from 02-load-table.sql)
--
-- How It Works:
--   1. Takes a natural language search query (e.g., "racing car toys for teenagers")
--   2. Calls AI_GENERATE_EMBEDDINGS(@text USE MODEL MyEmbeddingModel)
--   3. Uses VECTOR_SEARCH to find nearest neighbors in embedding space
--   4. Returns products with similarity above threshold
--
-- Key SQL Server 2025 Functions:
--   - AI_GENERATE_EMBEDDINGS() - Generates embeddings via External Model
--   - VECTOR_SEARCH() - Performs approximate nearest neighbor search
--
-- Output:
--   - similar_items table with matching products and similarity scores
-- =============================================================================

-- -----------------------------------------------------------------------------
-- SECTION 1: Test Embedding Generation (Optional - can run separately)
-- -----------------------------------------------------------------------------
-- This standalone query tests that the embedding model is working
SELECT AI_GENERATE_EMBEDDINGS('test' USE MODEL MyEmbeddingModel) AS test_embedding;
GO


-- -----------------------------------------------------------------------------
-- SECTION 2: Search Similar Items (Run as a single batch)
-- -----------------------------------------------------------------------------
-- ⚠️ IMPORTANT: Select ALL code below and run together as one batch

USE ProductDB;
GO

IF NOT EXISTS (
    SELECT 1
    FROM sys.indexes
    WHERE name = 'IX_walmart_embedding'
      AND object_id = OBJECT_ID('dbo.walmart_ecommerce_product_details')
)
BEGIN
    CREATE VECTOR INDEX IX_walmart_embedding
    ON dbo.walmart_ecommerce_product_details(embedding)
    WITH (METRIC = 'cosine');
END;
GO

DECLARE @text NVARCHAR(MAX) = 'what would be a nice house warming gift for a friend who loves cooking and has a modern kitchen?';
DECLARE @top INT = 50;
DECLARE @min_similarity DECIMAL(19,16) = 0.3;
DECLARE @qv VECTOR(1536) = AI_GENERATE_EMBEDDINGS(@text USE MODEL MyEmbeddingModel);

DROP TABLE IF EXISTS similar_items;

SELECT TOP (10) 
    w.id,
    w.product_name,
    w.description,
    w.category,
    r.distance,
    1 - r.distance AS similarity
INTO similar_items
FROM VECTOR_SEARCH(
    TABLE = dbo.walmart_ecommerce_product_details AS w,
    COLUMN = embedding,
    SIMILAR_TO = @qv,
    METRIC = 'cosine',
    TOP_N = 10
) AS r
WHERE r.distance <= 1 - @min_similarity
ORDER BY r.distance;

SELECT * FROM similar_items;
GO


-- -----------------------------------------------------------------------------
-- SECTION 3: Stored Procedure Alternative (Recommended)
-- -----------------------------------------------------------------------------
-- This stored procedure encapsulates the search logic, avoiding batch issues
-- Run this once to create the procedure, then call it anytime

CREATE OR ALTER PROCEDURE dbo.search_similar_items
    @search_text NVARCHAR(MAX),
    @top_n INT = 10,
    @min_similarity DECIMAL(19,16) = 0.3
AS
BEGIN
    SET NOCOUNT ON;
    
    DECLARE @qv VECTOR(1536) = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL MyEmbeddingModel);
    
    DROP TABLE IF EXISTS #similar_items;
    
    SELECT TOP (@top_n)
        w.id,
        w.product_name,
        w.description,
        w.category,
        r.distance,
        1 - r.distance AS similarity
    INTO #similar_items
    FROM VECTOR_SEARCH(
        TABLE = dbo.walmart_ecommerce_product_details AS w,
        COLUMN = embedding,
        SIMILAR_TO = @qv,
        METRIC = 'cosine',
        TOP_N = @top_n
    ) AS r
    WHERE r.distance <= 1 - @min_similarity
    ORDER BY r.distance;
    
    SELECT * FROM similar_items;
END;
GO


-- -----------------------------------------------------------------------------
-- SECTION 4: Example Usage of Stored Procedure
-- -----------------------------------------------------------------------------
-- After creating the procedure, you can run searches easily:

EXEC dbo.search_similar_items 
    @search_text = 'anything for a teenager boy passionate about racing cars? he owns an XBOX, he likes to build stuff';
GO

-- With custom parameters:
EXEC dbo.search_similar_items 
    @search_text = 'wireless headphones for music',
    @top_n = 5,
    @min_similarity = 0.5;
GO