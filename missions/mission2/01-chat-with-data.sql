-- =============================================================================
-- Mission 2: Chat with Data using RAG
-- =============================================================================
-- Description: Implements Retrieval-Augmented Generation (RAG) by combining
--              vector search results with a language model to generate natural
--              language responses grounded in actual product data.
--
-- Prerequisites:
--   - Mission 1 completed (similar_items table populated)
--   - Azure OpenAI gpt-5-mini model deployed
--   - Database-scoped credentials configured for OpenAI endpoint
--
-- Configuration:
--   Replace <FOUNDRY_RESOURCE_NAME> with your Azure OpenAI resource name
--
-- How It Works:
--   1. Retrieves products from similar_items table (from vector search)
--   2. Formats products as JSON array for context
--   3. Constructs a prompt with system instructions and product data
--   4. Calls Azure OpenAI Responses API to generate a natural language response
--   5. Extracts response from $.result.output[1].content[0].text path
--
-- Prompt Structure:
--   - System: Instructions for product recommendation behavior
--   - Assistant: Product catalog data in JSON format
--   - User: The original search query/request
--
-- API Format:
--   Uses Azure OpenAI Responses API (api-version=2025-04-01-preview)
--   Response path: $.result.output[1].content[0].text
--
-- Output:
--   Natural language response with product recommendations and explanations
-- =============================================================================


-- -----------------------------------------------------------------------------
-- SECTION 1: Define User Request
-- -----------------------------------------------------------------------------
USE ProductDB;
GO

DECLARE @request NVARCHAR(MAX) = 'anything for a teenager boy passionate about racing cars? he owns an XBOX, he likes to build stuff';


-- -----------------------------------------------------------------------------
-- SECTION 2: Retrieve Products from Vector Search Results
-- -----------------------------------------------------------------------------
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


-- -----------------------------------------------------------------------------
-- SECTION 3: Build Chat Prompt with System Instructions
-- -----------------------------------------------------------------------------
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


-- -----------------------------------------------------------------------------
-- SECTION 4: Call Chat Completion API (Supports GitHub Models or Azure Foundry)
-- -----------------------------------------------------------------------------
-- CONFIGURATION: Set @provider to choose the model provider
--   'GITHUB'  - Use GitHub Models (models.github.ai)
--   'FOUNDRY' - Use Azure AI Foundry (requires <FOUNDRY_RESOURCE_NAME> and <OPENAI_URL>)
-- -----------------------------------------------------------------------------
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

-- Call the API
EXEC @retval = sp_invoke_external_rest_endpoint
    @url = @url,
    @headers = '{"Content-Type":"application/json"}',
    @method = 'POST',
    @credential = @credential,
    @timeout = 120,
    @payload = @prompt,
    @response = @response OUTPUT
    WITH RESULT SETS NONE;


-- -----------------------------------------------------------------------------
-- SECTION 5: Display Results
-- -----------------------------------------------------------------------------
-- Raw response
SELECT @response AS raw_response;

-- Extracted chat message (different JSON paths per provider)
IF @provider = 'GITHUB'
BEGIN
    -- GitHub Models response path: $.result.choices[].message.content
    SELECT m.content AS chat_response
    FROM OPENJSON(@response, '$.result.choices')
    WITH (
        content NVARCHAR(MAX) '$.message.content'
    ) AS m;
END
ELSE IF @provider = 'FOUNDRY'
BEGIN
    -- Azure Foundry response path: $.result.output[1].content[].text
    SELECT o.[text] AS chat_response
    FROM OPENJSON(@response, '$.result.output[1].content') 
    WITH ([text] NVARCHAR(MAX)) AS o;
END
