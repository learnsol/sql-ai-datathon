BULK INSERT [dbo].[walmart_ecommerce_product_details]
FROM '/workspace/walmart-product-with-embeddings-dataset-usa-text-3-small/walmart-product-with-embeddings-dataset-usa-text-3-small.csv'
WITH (
    FIRSTROW = 2,
    FORMAT = 'CSV',
    FIELDQUOTE = '"',
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '\n',
    TABLOCK
);