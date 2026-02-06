USE ProductDB;
GO

-- Required before creating database scoped credentials
IF NOT EXISTS (SELECT * FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(DB_MASTER_KEY_PASSWORD)';
END
GO

IF NOT EXISTS (SELECT * FROM sys.database_scoped_credentials WHERE [name] = 'https://models.github.ai/inference')
BEGIN
    CREATE DATABASE SCOPED CREDENTIAL [https://models.github.ai/inference]
    WITH IDENTITY = 'HTTPEndpointHeaders', 
         SECRET = '{"Authorization":"Bearer $(GITHUB_MODELS_TOKEN)"}';
END
GO


SELECT * FROM sys.database_scoped_credentials WHERE [name] = 'https://models.github.ai/inference';
GO

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

SELECT AI_GENERATE_EMBEDDINGS('Test text' USE MODEL MyEmbeddingModel);