-- =============================================================================
-- Mission 1: Configure Credentials and External Model for Embeddings
-- =============================================================================
-- Description: Creates database-scoped credentials and an external model for 
--              secure access to AI endpoints. The external model is used by 
--              AI_GENERATE_EMBEDDINGS() to generate vector embeddings.
--
-- Supported Providers:
--   - GITHUB MODELS: Uses models.github.ai (GitHub PAT required)
--   - MICROSOFT FOUNDRY: Uses Microsoft Foundry (API key or Managed Identity)
--
-- Configuration:
--   1. Choose your provider by uncommenting the appropriate section
--   2. Replace the placeholders with your values:
--      GitHub Models:
--        - <GITHUB_TOKEN>: Your GitHub Personal Access Token
--      Microsoft Foundry:
--        - <OPENAI_URL>: Your Microsoft Foundry endpoint URL
--        - <OPENAI_API_KEY>: Your Microsoft Foundry API key
--        - <FOUNDRY_RESOURCE_NAME>: Your Microsoft Foundry resource name
--
-- Usage:
--   Run once after database creation, before executing search queries.
--   After running, you can use:
--     AI_GENERATE_EMBEDDINGS(@text USE MODEL MyEmbeddingModel)
-- =============================================================================


USE ProductDB;
GO


-- =============================================================================
-- OPTION A: Microsoft FOUNDRY
-- =============================================================================
-- Uncomment this entire section to use Microsoft Foundry

-- -----------------------------------------------------------------------------
-- SECTION A1: Create HTTP Credentials for Microsoft Foundry (API Key Method)
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.database_scoped_credentials WHERE [name] = '<OPENAI_URL>')
BEGIN
    CREATE DATABASE SCOPED CREDENTIAL [<OPENAI_URL>]
    WITH IDENTITY = 'HTTPEndpointHeaders', 
         SECRET = '{"api-key":"<OPENAI_API_KEY>"}';
END
GO

-- -----------------------------------------------------------------------------
-- SECTION A2: Alternative - Managed Identity (Recommended for Production)
-- -----------------------------------------------------------------------------
-- Use Managed Identity for passwordless authentication. More info:
-- https://devblogs.microsoft.com/azure-sql/go-passwordless-when-calling-azure-openai-from-azure-sql-using-managed-identities/
--
-- IF NOT EXISTS (SELECT * FROM sys.database_scoped_credentials WHERE [name] = '<OPENAI_URL>')
-- BEGIN
--     CREATE DATABASE SCOPED CREDENTIAL [<OPENAI_URL>]
--     WITH IDENTITY = 'Managed Identity', 
--          SECRET = '{"resourceid":"https://cognitiveservices.azure.com"}';
-- END
-- GO

-- -----------------------------------------------------------------------------
-- SECTION A3: Verify Microsoft Foundry Credentials
-- -----------------------------------------------------------------------------
SELECT * FROM sys.database_scoped_credentials WHERE [name] = '<OPENAI_URL>';
GO

-- -----------------------------------------------------------------------------
-- SECTION A4: Create External Model for Microsoft Foundry
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.external_models WHERE [name] = 'MyEmbeddingModel')
BEGIN
    CREATE EXTERNAL MODEL MyEmbeddingModel
    WITH (
          LOCATION = 'https://<FOUNDRY_RESOURCE_NAME>.cognitiveservices.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2023-05-15',
          API_FORMAT = 'Azure OpenAI',
          MODEL_TYPE = EMBEDDINGS,
          MODEL = 'text-embedding-3-small',
          CREDENTIAL = [<OPENAI_URL>],
          PARAMETERS = '{"dimensions":1536}'
    );
END
GO


-- =============================================================================
-- OPTION B: GITHUB MODELS
-- =============================================================================
-- Uncomment this entire section to use GitHub Models instead
/*
-- -----------------------------------------------------------------------------
-- SECTION B1: Create HTTP Credentials for GitHub Models
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.database_scoped_credentials WHERE [name] = 'https://models.github.ai/inference')
BEGIN
    CREATE DATABASE SCOPED CREDENTIAL [https://models.github.ai/inference]
    WITH IDENTITY = 'HTTPEndpointHeaders', 
         SECRET = '{"Authorization":"Bearer <GITHUB_TOKEN>"}';
END
GO

-- -----------------------------------------------------------------------------
-- SECTION B2: Verify GitHub Credentials
-- -----------------------------------------------------------------------------
SELECT * FROM sys.database_scoped_credentials WHERE [name] = 'https://models.github.ai/inference';
GO

-- -----------------------------------------------------------------------------
-- SECTION B3: Create External Model for GitHub Models
-- -----------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.external_models WHERE [name] = 'MyEmbeddingModel')
BEGIN
    CREATE EXTERNAL MODEL MyEmbeddingModel
    WITH (
          LOCATION = 'https://models.github.ai/inference/embeddings',
          API_FORMAT = 'OpenAI',
          MODEL_TYPE = EMBEDDINGS,
          MODEL = 'text-embedding-3-small',
          CREDENTIAL = [https://models.github.ai/inference],
          PARAMETERS = '{"dimensions":1536}'
    );
END
GO
*/


-- =============================================================================
-- SECTION: Test External Model for Embeddings
-- =============================================================================
SELECT AI_GENERATE_EMBEDDINGS('Test text' USE MODEL MyEmbeddingModel);