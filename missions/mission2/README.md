# Mission 2: Retrieval Augmented Generation (RAG)

This mission demonstrates how to build production-ready AI applications that combine the semantic understanding of embeddings with the generative capabilities of large language models. Retrieval augmented generation (RAG) is a fundamental pattern for creating trustworthy AI systems that answer questions based on your specific domain knowledge.

The techniques learned here enable you to build chatbots, knowledge assistants, and intelligent search systems that provide accurate, source-backed responses.

You will be guided through implementing retrieval augmented generation (RAG) capabilities using embedding models and SQL Database. In this mission, you will:

## Learning Objectives
- **Implement RAG Pipeline**: Build an end-to-end retrieval-augmented generation workflow in SQL
- **Query with Context**: Use vector similarity search to find relevant documents based on user questions
- **Generate Informed Responses**: Feed retrieved context to a language model to produce accurate, grounded answers


## Prerequisites
Mission 1 completed: 
    - `similar_items` table populated, 
    - External Model `MyEmbeddingModel` created,
    - Embedding model access,
    - Completion model access

## Walkthrough

### Step 1: Chatting with Data

This script implements RAG by combining vector search results with a language model to generate natural language responses grounded in actual product data (see <a href="https://github.com/microsoft/sql-ai-datathon/blob/main/missions/mission2/01-chat-with-data.sql" target="_blank">01-chat-with-data.sql</a>).

The script supports two providers. Set `@provider` to choose:
- `'GITHUB'` - Use GitHub Models (models.github.ai)
- `'FOUNDRY'` - Use Azure AI Foundry

```sql
USE ProductDB;
GO

DECLARE @request NVARCHAR(MAX) = 'anything for a teenager boy passionate about racing cars? he owns an XBOX, he likes to build stuff';

DECLARE @products JSON =
(
    SELECT 
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'id': [id],
                'name': [product_name],
                'description': [description]
            )
        )
    FROM 
        dbo.similar_items
);

DECLARE @prompt NVARCHAR(MAX) = JSON_OBJECT(
    'messages': JSON_ARRAY(
        JSON_OBJECT(
            'role': 'system',
            'content': '
                You as a system assistant who helps users find the best products available in the catalog to satisfy the requested ask.
                Products are provided in an assitant message using a JSON Array with the following format: [{id, name, description}].                 
                Use only the provided products to help you answer the question.        
                Use only the information available in the provided JSON to answer the question.
                Return the top ten products that best answer the question.
                For each returned product add a short explanation of why the product has been suggested. Put the explanation in parenthesis and start with "Thoughts:"
                Make sure to use details, notes, and description that are provided in each product are used only with that product.                
                If the question cannot be answered by the provided samples, don''t return any result.
                If asked question is about topics you don''t know, don''t return any result.
                If no products are provided, don''t return any result.                
            '
        ),
        JSON_OBJECT(
            'role': 'assistant',
            'content': 'The available products are the following:'
        ),
        JSON_OBJECT(
            'role': 'assistant',
            'content': COALESCE(CAST(@products AS NVARCHAR(MAX)), '')
        ),
        JSON_OBJECT(
            'role': 'user',
            'content': @request
        )
    ),    
    'model': 'gpt-5-mini'
);

-- CONFIGURATION: Set @provider to choose the model provider
DECLARE @provider NVARCHAR(20) = 'GITHUB';  -- Change to 'FOUNDRY' for Azure AI Foundry

DECLARE @retval INT, @response NVARCHAR(MAX);
DECLARE @url NVARCHAR(500), @credential NVARCHAR(200);

-- Set URL and credential based on provider
IF @provider = 'GITHUB'
BEGIN
    SET @url = 'https://models.github.ai/inference/chat/completions';
    SET @credential = 'https://models.github.ai/inference';
END
ELSE IF @provider = 'FOUNDRY'
BEGIN
    -- Replace <FOUNDRY_RESOURCE_NAME> with your Azure AI Foundry resource name
    SET @url = 'https://<FOUNDRY_RESOURCE_NAME>.cognitiveservices.azure.com/openai/deployments/gpt-5-mini/chat/completions?api-version=2025-04-01-preview';
    SET @credential = '<ENDPOINT_URL>';
END

EXEC @retval = sp_invoke_external_rest_endpoint
    @url = @url,
    @headers = '{"Content-Type":"application/json"}',
    @method = 'POST',
    @credential = @credential,
    @timeout = 120,
    @payload = @prompt,
    @response = @response OUTPUT
    WITH RESULT SETS NONE;

-- Extract chat response (different JSON paths per provider)
IF @provider = 'GITHUB'
BEGIN
    -- GitHub Models: $.result.choices[].message.content
    SELECT m.content AS chat_response
    FROM OPENJSON(@response, '$.result.choices')
    WITH (content NVARCHAR(MAX) '$.message.content') AS m;
END
ELSE IF @provider = 'FOUNDRY'
BEGIN
    -- Azure Foundry: $.result.output[1].content[].text
    SELECT o.[text] AS chat_response
    FROM OPENJSON(@response, '$.result.output[1].content') 
    WITH ([text] NVARCHAR(MAX)) AS o;
END
```

### Step 2: Structured Output from Chat

This script extends RAG to return structured JSON output instead of free-form text, making it easier to process programmatically (see <a href="https://github.com/microsoft/sql-ai-datathon/blob/main/missions/mission2/02-chat-with-data-structured-output.sql" target="_blank">02-chat-with-data-structured-output.sql</a>).

The script supports two providers:
- `'FOUNDRY'` - Use Microsoft Foundry
- `'GITHUB'` - Use GitHub Models

The JSON schema enforces this output format:
```json
{
  "products": [
    {
      "result_position": 1,
      "id": 123,
      "description": "Brief summary (max 10 words)",
      "thoughts": "Explanation of why selected"
    }
  ]
}
```

Set `@provider` to `'FOUNDRY'` or `'GITHUB'` in SECTION 5 of the script and replace the appropriate placeholders before running. Note that each provider uses slightly different prompt structures and response JSON paths.

### Step 3: Setting up Stored Procedures

Create reusable stored procedures that encapsulate the RAG logic (see <a href="https://github.com/microsoft/sql-ai-datathon/blob/main/missions/mission2/03-stored-procedures.sql" target="_blank">03-stored-procedures.sql</a>).

#### Procedure 1: Generate Embeddings

This procedure uses `AI_GENERATE_EMBEDDINGS()` with the external model for efficient embedding generation:

```sql
CREATE OR ALTER PROCEDURE [dbo].[get_embedding]
@inputText NVARCHAR(MAX),
@embedding VECTOR(1536) OUTPUT,
@error NVARCHAR(MAX) = NULL OUTPUT
AS
-- Use AI_GENERATE_EMBEDDINGS with the external model
SET @embedding = AI_GENERATE_EMBEDDINGS(@inputText USE MODEL MyEmbeddingModel);

IF @embedding IS NULL
BEGIN
    SET @error = JSON_OBJECT(
        'code': 'EmbeddingGenerationFailed',
        'message': 'Failed to generate embedding for the input text.'
    );
    RETURN -1;
END;
GO
```

#### Procedure 2: Find Similar Items

```sql
CREATE OR ALTER PROCEDURE [dbo].[get_similar_items]
@inputText NVARCHAR(MAX),
@result NVARCHAR(MAX) = NULL OUTPUT,
@error NVARCHAR(MAX) = NULL OUTPUT
AS
DECLARE @top INT = 10
DECLARE @min_similarity DECIMAL(19,16) = 0.75
DECLARE @embedding VECTOR(1536)

-- Generate embedding using the get_embedding procedure
EXEC dbo.get_embedding @inputText = @inputText, @embedding = @embedding OUTPUT, @error = @error OUTPUT

IF @error IS NOT NULL
    RETURN -1

-- Perform vector similarity search
SELECT @result = (
    SELECT  
        w.id,
        w.product_name AS name,
        w.description,
        w.category,
        w.sale_price
    FROM VECTOR_SEARCH(
             TABLE = dbo.walmart_ecommerce_product_details AS w,
             COLUMN = embedding,
             SIMILAR_TO = @embedding,
             METRIC = 'cosine',
             TOP_N = @top
         ) AS r
    WHERE r.distance <= 1 - @min_similarity
    ORDER BY r.distance
    FOR JSON PATH
);

SELECT @result AS result;
GO
```

#### Test the Stored Procedures

```sql
DECLARE @embedding VECTOR(1536), @error NVARCHAR(MAX);
EXEC dbo.get_embedding @inputText = 'wireless headphones', @embedding = @embedding OUTPUT, @error = @error OUTPUT;
SELECT @embedding, @error;
```

```sql
DECLARE @result NVARCHAR(MAX), @error NVARCHAR(MAX);
EXEC dbo.get_similar_items @inputText = 'wireless headphones', @result = @result OUTPUT, @error = @error OUTPUT;
SELECT @result, @error;
```


## Next Steps
After completing this mission, you will have implemented a robust RAG pipeline that can answer questions based on your SQL data.

Proceed to [Mission 3: Orchestrate SQL + AI workflows](../mission3/README.md) to learn how to build complex, multi-step AI workflows that integrate RAG with other SQL and AI capabilities.