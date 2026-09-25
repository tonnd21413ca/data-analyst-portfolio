/*
===============================================================================
Project: Sales Performance Analysis
File: 01_data_audit.sql
Purpose: Inspect source data before cleaning; one result per numbered query.
===============================================================================
*/

-- @step source_preview
/*=============================================================================
1. Kiểm tra 10 dòng đầu dữ liệu
=============================================================================*/

SELECT *
FROM read_csv('data/raw/online_retail.csv')
LIMIT 10;

-- @step source_inferred_schema
/*=============================================================================
2. DuckDB suy luận kiểu dữ liệu của từng cột như thế nào?
=============================================================================*/

DESCRIBE 'data/raw/online_retail.csv';

-- @step source_missing_values
/*=============================================================================
3. Kiểm tra thêm về độ sạch của dữ liệu trước khi tạo TABLE.
=============================================================================*/

WITH source_data AS (
	SELECT *
	FROM read_csv(
		'data/raw/online_retail.csv',
		HEADER = TRUE,
		all_varchar = TRUE
	)
)
SELECT
    COUNT(*) AS total_rows,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(InvoiceNo), '') IS NULL
    ) AS invoice_no_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(StockCode), '') IS NULL
    ) AS stock_code_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(Description), '') IS NULL
    ) AS description_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(Quantity), '') IS NULL
    ) AS quantity_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(InvoiceDate), '') IS NULL
    ) AS invoice_date_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(UnitPrice), '') IS NULL
    ) AS unit_price_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(CustomerID), '') IS NULL
    ) AS customer_id_missing,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(Country), '') IS NULL
    ) AS country_missing
FROM source_data;

-- @step source_sign_counts
/*=============================================================================
4. Quantity, UnitPrice và CustomerID có giá trị âm hoặc bằng zero?
=============================================================================*/

SELECT
	COUNT(*) FILTER (WHERE Quantity < 0) AS negative_quantity,
	COUNT(*) FILTER (WHERE UnitPrice < 0) AS negative_unit_price,
	COUNT(*) FILTER (WHERE CustomerID < 0) AS negative_customer_id,
	COUNT(*) FILTER (WHERE Quantity = 0) AS zero_quantity,
	COUNT(*) FILTER (WHERE UnitPrice = 0) AS zero_unit_price,
	COUNT(*) FILTER (WHERE CustomerID = 0) AS zero_customer_id
FROM read_csv('data/raw/online_retail.csv');

-- @step non_c_negative_quantity_count
-- Có bao nhiêu dòng Quantity âm ngoài hóa đơn có tiền tố C?
SELECT COUNT(*)
FROM read_csv('data/raw/online_retail.csv')
WHERE UPPER(TRIM(InvoiceNo)) NOT LIKE 'C%'
AND Quantity < 0;
-- @step zero_unit_price_examples
-- Các dòng mẫu có UnitPrice bằng zero trông như thế nào?
SELECT *
FROM read_csv('data/raw/online_retail.csv')
WHERE UnitPrice = 0
LIMIT 10;
-- @step negative_unit_price_rows
-- Những dòng nào có UnitPrice âm?
SELECT *
FROM read_csv('data/raw/online_retail.csv')
WHERE UnitPrice < 0;
-- @step source_rows
/*=============================================================================
5. Xem toàn bộ dữ liệu để kiểm tra chi tiết và sắp xếp trong SQL client.
=============================================================================*/

SELECT *
FROM read_csv('data/raw/online_retail.csv');

-- @step source_duplicate_groups
/*=============================================================================
6. Kiểm tra dòng trùng nhau
=============================================================================*/

SELECT
    COUNT(*) AS duplicate_count,
    *
FROM read_csv('data/raw/online_retail.csv')
GROUP BY ALL
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;
