from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import dotenv
import mssql_python
from langchain_azure_ai.chat_models import AzureAIChatCompletionsModel
from langchain.schema import HumanMessage, SystemMessage
import json

# Load environment variables
dotenv.load_dotenv("../.env")

connection_string = dotenv.get_key("../.env", "SERVER_CONNECTION_STRING")
endpoint = dotenv.get_key("../.env", "MODEL_ENDPOINT_URL")
api_key = dotenv.get_key("../.env", "MODEL_API_KEY")

# Initialize FastAPI app
app = FastAPI(
    title="SQL AI API",
    description="AI-powered product search and chat API",
    version="1.0.0"
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:3000", "http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize AI model
chat_model = AzureAIChatCompletionsModel(
    endpoint=endpoint,
    credential=api_key,
    model="gpt-4.1",
)


# =============================================================================
# Request/Response Models
# =============================================================================

class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    user_message: str
    assistant_response: str
    products_found: bool


class ProductSearchResponse(BaseModel):
    query: str
    results: list


# =============================================================================
# Helper Functions
# =============================================================================

def get_connection():
    """Create a new database connection."""
    return mssql_python.connect(connection_string)


def find_products(search_term: str) -> str:
    """Search the product catalog using vector similarity."""
    connection = get_connection()
    cursor = connection.cursor()
    
    sql = """SET NOCOUNT ON;
    DECLARE @out nvarchar(max);
    EXEC [dbo].[get_similar_items] @inputText = ?, @error = @out OUTPUT;
    SELECT @out AS error;"""
    
    cursor.execute(sql, (search_term,))
    results = []
    
    while True:
        rows = cursor.fetchall()
        results.extend(rows)
        if not cursor.nextset():
            break
    
    cursor.close()
    connection.close()
    return str(results)


# =============================================================================
# API Endpoints
# =============================================================================

@app.get("/")
def health_check():
    """Health check endpoint."""
    return {"status": "healthy", "service": "SQL AI API"}


@app.get("/api/products")
def get_products(page: int = 1, page_size: int = 10):
    """Get paginated list of products."""
    connection = get_connection()
    cursor = connection.cursor()
    
    offset = (page - 1) * page_size
    query = f"""
        SELECT id, item_id, product_name, product_category, price_retail, price_current
        FROM dbo.walmart_ecommerce_product_details
        ORDER BY id
        OFFSET {offset} ROWS FETCH NEXT {page_size} ROWS ONLY
    """
    
    cursor.execute(query)
    columns = [desc[0] for desc in cursor.description]
    products = [dict(zip(columns, row)) for row in cursor.fetchall()]
    
    cursor.close()
    connection.close()
    
    return {"page": page, "page_size": page_size, "products": products}


@app.get("/api/products/search")
def search_products(query: str) -> ProductSearchResponse:
    """Search products using vector similarity."""
    connection = get_connection()
    cursor = connection.cursor()
    
    sql = """SET NOCOUNT ON;
    DECLARE @out nvarchar(max);
    EXEC [dbo].[get_similar_items] @inputText = ?, @error = @out OUTPUT;
    SELECT @out AS error;"""
    
    cursor.execute(sql, (query,))
    results = []
    
    while True:
        rows = cursor.fetchall()
        if cursor.description:
            columns = [desc[0] for desc in cursor.description]
            results.extend([dict(zip(columns, row)) for row in rows])
        if not cursor.nextset():
            break
    
    cursor.close()
    connection.close()
    
    return ProductSearchResponse(query=query, results=results)


@app.post("/api/chat")
def chat(request: ChatRequest) -> ChatResponse:
    """AI-powered product assistant chat."""
    # Search for relevant products
    product_results = find_products(request.message)
    
    system_prompt = f"""You are a helpful product assistant. Use the following product catalog data to answer user questions.
Be concise and helpful. Only recommend products from the provided data.

Available Products:
{product_results}

If no relevant products are found, politely inform the user."""
    
    messages = [
        SystemMessage(content=system_prompt),
        HumanMessage(content=request.message)
    ]
    
    response = chat_model.invoke(messages)
    
    return ChatResponse(
        user_message=request.message,
        assistant_response=response.content,
        products_found=bool(product_results and product_results != "[]")
    )


@app.post("/api/chat/structured")
def chat_structured(request: ChatRequest):
    """AI chat with structured JSON output."""
    product_results = find_products(request.message)
    
    system_prompt = f"""You are a product recommendation assistant. Analyze the user's request and the available products.
Return a JSON response with the following structure:
{{
    "recommendations": [
        {{
            "productName": "string",
            "reason": "string",
            "confidence": "high|medium|low"
        }}
    ],
    "summary": "Brief summary of recommendations"
}}

Available Products:
{product_results}"""
    
    messages = [
        SystemMessage(content=system_prompt),
        HumanMessage(content=request.message)
    ]
    
    response = chat_model.invoke(messages)
    
    # Try to parse as JSON
    try:
        return json.loads(response.content)
    except json.JSONDecodeError:
        return {"raw_response": response.content}


# =============================================================================
# Run the app
# =============================================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
