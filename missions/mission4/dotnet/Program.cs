using Microsoft.Data.SqlClient;
using Microsoft.SemanticKernel;
using Microsoft.SemanticKernel.ChatCompletion;
using System.Text.Json;

// Load configuration from dab-config.json and .env
var dabConfig = JsonSerializer.Deserialize<JsonElement>(File.ReadAllText("dab-config.json"));
var connectionString = dabConfig.GetProperty("data-source").GetProperty("connection-string").GetString()
    ?? throw new InvalidOperationException("Connection string not found in dab-config.json");

// Load AI settings from .env
DotNetEnv.Env.Load("../.env");
var aoaiEndpoint = Environment.GetEnvironmentVariable("AZURE_OPENAI_ENDPOINT") 
    ?? Environment.GetEnvironmentVariable("MODEL_ENDPOINT_URL")
    ?? throw new InvalidOperationException("AZURE_OPENAI_ENDPOINT not set");
var apiKey = Environment.GetEnvironmentVariable("MODEL_API_KEY") 
    ?? throw new InvalidOperationException("MODEL_API_KEY not set");

// Extract entity configuration from DAB
var entities = dabConfig.GetProperty("entities");
var productsEntity = entities.GetProperty("Products");
var productsTable = productsEntity.GetProperty("source").GetProperty("object").GetString();

var builder = WebApplication.CreateBuilder(args);

// Configure to use port 5001 (DAB uses 5000)
builder.WebHost.UseUrls("http://localhost:5001");

// Add services
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        policy.WithOrigins("http://localhost:3000", "http://localhost:5173")
              .AllowAnyHeader()
              .AllowAnyMethod();
    });
});

// Configure Semantic Kernel
var kernelBuilder = Kernel.CreateBuilder();
kernelBuilder.AddAzureOpenAIChatCompletion("gpt-4.1", aoaiEndpoint, apiKey);
var kernel = kernelBuilder.Build();
builder.Services.AddSingleton(kernel);

var app = builder.Build();

// Configure middleware
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}
app.UseCors();

// Serve static files from frontend folder
var frontendPath = Path.Combine(Directory.GetCurrentDirectory(), "..", "frontend");
if (Directory.Exists(frontendPath))
{
    app.UseStaticFiles(new StaticFileOptions
    {
        FileProvider = new Microsoft.Extensions.FileProviders.PhysicalFileProvider(frontendPath),
        RequestPath = ""
    });
    
    // Serve index.html as default
    app.MapGet("/app", async context =>
    {
        var indexPath = Path.Combine(frontendPath, "index.html");
        context.Response.ContentType = "text/html";
        await context.Response.SendFileAsync(indexPath);
    });
}

// =============================================================================
// API Endpoints
// =============================================================================

// Health check
app.MapGet("/", () => Results.Ok(new { status = "healthy", service = "SQL AI API" }))
   .WithName("HealthCheck")
   .WithOpenApi();

// Get all products (paginated)
app.MapGet("/api/products", (int page = 1, int pageSize = 10) =>
{
    var products = new List<Dictionary<string, object>>();
    
    using var connection = new SqlConnection(connectionString);
    connection.Open();
    
    var offset = (page - 1) * pageSize;
    var query = $@"
        SELECT id, item_id, product_name, product_category, price_retail, price_current
        FROM {productsTable}
        ORDER BY id
        OFFSET {offset} ROWS FETCH NEXT {pageSize} ROWS ONLY";
    
    using var command = new SqlCommand(query, connection);
    using var reader = command.ExecuteReader();
    
    while (reader.Read())
    {
        var product = new Dictionary<string, object>();
        for (int i = 0; i < reader.FieldCount; i++)
        {
            product[reader.GetName(i)] = reader.IsDBNull(i) ? null! : reader.GetValue(i);
        }
        products.Add(product);
    }
    
    return Results.Ok(new { page, pageSize, products });
})
.WithName("GetProducts")
.WithOpenApi();

// Search products using vector similarity
app.MapGet("/api/products/search", (string query) =>
{
    var results = new List<Dictionary<string, object>>();
    
    using var connection = new SqlConnection(connectionString);
    connection.Open();
    
    using var command = new SqlCommand();
    command.Connection = connection;
    command.CommandText = @"
        SET NOCOUNT ON;
        DECLARE @out nvarchar(max);
        EXEC [dbo].[get_similar_items] @inputText = @searchTerm, @error = @out OUTPUT;
        SELECT @out AS error;";
    command.Parameters.AddWithValue("@searchTerm", query);
    
    using var reader = command.ExecuteReader();
    do
    {
        while (reader.Read())
        {
            var row = new Dictionary<string, object>();
            for (int i = 0; i < reader.FieldCount; i++)
            {
                row[reader.GetName(i)] = reader.IsDBNull(i) ? null! : reader.GetValue(i);
            }
            results.Add(row);
        }
    } while (reader.NextResult());
    
    return Results.Ok(new { query, results });
})
.WithName("SearchProducts")
.WithOpenApi();

// AI-powered product assistant chat
app.MapPost("/api/chat", async (ChatRequest request, Kernel kernel) =>
{
    // First, search for relevant products
    var productResults = SearchProducts(request.Message, connectionString);
    
    // Create context with product data
    var systemPrompt = $"""
        You are a helpful product assistant. Use the following product catalog data to answer user questions.
        Be concise and helpful. Only recommend products from the provided data.
        
        Available Products:
        {productResults}
        
        If no relevant products are found, politely inform the user.
        """;
    
    var chatService = kernel.GetRequiredService<IChatCompletionService>();
    var chatHistory = new ChatHistory(systemPrompt);
    chatHistory.AddUserMessage(request.Message);
    
    var response = await chatService.GetChatMessageContentAsync(chatHistory);
    
    return Results.Ok(new 
    { 
        userMessage = request.Message, 
        assistantResponse = response.Content,
        productsFound = !string.IsNullOrWhiteSpace(productResults)
    });
})
.WithName("Chat")
.WithOpenApi();

// Chat with structured JSON output
app.MapPost("/api/chat/structured", async (ChatRequest request, Kernel kernel) =>
{
    var productResults = SearchProducts(request.Message, connectionString);
    
    var systemPrompt = $$"""
        You are a product recommendation assistant. Analyze the user's request and the available products.
        Return a JSON response with the following structure:
        {
            "recommendations": [
                {
                    "productName": "string",
                    "reason": "string",
                    "confidence": "high|medium|low"
                }
            ],
            "summary": "Brief summary of recommendations"
        }
        
        Available Products:
        {{productResults}}
        """;
    
    var chatService = kernel.GetRequiredService<IChatCompletionService>();
    var chatHistory = new ChatHistory(systemPrompt);
    chatHistory.AddUserMessage(request.Message);
    
    var response = await chatService.GetChatMessageContentAsync(chatHistory);
    
    // Try to parse as JSON, return raw if parsing fails
    try
    {
        var jsonResponse = JsonSerializer.Deserialize<object>(response.Content ?? "{}");
        return Results.Ok(jsonResponse);
    }
    catch
    {
        return Results.Ok(new { rawResponse = response.Content });
    }
})
.WithName("ChatStructured")
.WithOpenApi();

app.Run();

// =============================================================================
// Helper Functions
// =============================================================================

static string SearchProducts(string searchTerm, string connString)
{
    var results = new List<string>();
    
    using var connection = new SqlConnection(connString);
    connection.Open();
    
    using var command = new SqlCommand();
    command.Connection = connection;
    command.CommandText = @"
        SET NOCOUNT ON;
        DECLARE @out nvarchar(max);
        EXEC [dbo].[get_similar_items] @inputText = @searchTerm, @error = @out OUTPUT;
        SELECT @out AS error;";
    command.Parameters.AddWithValue("@searchTerm", searchTerm);
    
    using var reader = command.ExecuteReader();
    do
    {
        while (reader.Read())
        {
            var row = new List<string>();
            for (int i = 0; i < reader.FieldCount; i++)
            {
                row.Add($"{reader.GetName(i)}: {reader[i]}");
            }
            results.Add(string.Join(", ", row));
        }
    } while (reader.NextResult());
    
    return string.Join("\n", results);
}

// =============================================================================
// Request/Response Models
// =============================================================================

public record ChatRequest(string Message);
