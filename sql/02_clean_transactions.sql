/*
Project: Sales Performance Analysis
File: 02_clean_transactions.sql
Purpose: Preserve source fields, remove exact source duplicates, type and flag lines.
Run from project root. Manual execution and export are documented in README.md.
Implementation note: AI assisted with this SQL from preparation rules first
documented in docs/project-notes.md and approved by the user before execution.
*/

-- @step prepare_source
BEGIN TRANSACTION;
SET preserve_insertion_order = TRUE;

CREATE OR REPLACE TEMP VIEW source_csv AS
SELECT
    ROW_NUMBER() OVER ()::BIGINT AS source_row_number,
    InvoiceNo, StockCode, Description, Quantity,
    InvoiceDate, UnitPrice, CustomerID, Country
FROM read_csv(
    'data/raw/online_retail.csv',
    header = TRUE,
    all_varchar = TRUE,
    nullstr = '',
    force_not_null = [
        'InvoiceNo', 'StockCode', 'Description', 'Quantity',
        'InvoiceDate', 'UnitPrice', 'CustomerID', 'Country'
    ],
    parallel = FALSE,
    strict_mode = TRUE,
    ignore_errors = FALSE
);

CREATE OR REPLACE TABLE raw_transactions AS
SELECT * FROM source_csv;

CREATE OR REPLACE TEMP VIEW source_typed AS
SELECT
    source_row_number,
    NULLIF(TRIM(Quantity), '') AS quantity_text,
    NULLIF(TRIM(InvoiceDate), '') AS invoice_date_text,
    NULLIF(TRIM(UnitPrice), '') AS unit_price_text,
    TRY_CAST(NULLIF(TRIM(Quantity), '') AS BIGINT) AS typed_quantity,
    TRY_CAST(NULLIF(TRIM(InvoiceDate), '') AS TIMESTAMP) AS typed_invoice_date,
    TRY_CAST(NULLIF(TRIM(UnitPrice), '') AS DECIMAL) AS typed_unit_price
FROM raw_transactions;

CREATE OR REPLACE TEMP VIEW source_cast_checks AS
SELECT
    COUNT(*) AS source_rows,
    COUNT(*) FILTER (WHERE quantity_text IS NULL) AS quantity_missing,
    COUNT(*) FILTER (WHERE invoice_date_text IS NULL) AS invoice_date_missing,
    COUNT(*) FILTER (WHERE unit_price_text IS NULL) AS unit_price_missing,
    COUNT(*) FILTER (
        WHERE quantity_text IS NOT NULL
          AND (NOT regexp_full_match(quantity_text, '[+-]?[0-9]+')
               OR typed_quantity IS NULL)
    ) AS quantity_cast_errors,
    COUNT(*) FILTER (
        WHERE invoice_date_text IS NOT NULL AND typed_invoice_date IS NULL
    ) AS invoice_date_cast_errors,
    COUNT(*) FILTER (
        WHERE unit_price_text IS NOT NULL
          AND NOT regexp_full_match(
              unit_price_text, '[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)'
          )
    ) AS unit_price_format_errors,
    COUNT(*) FILTER (
        WHERE unit_price_text IS NOT NULL AND typed_unit_price IS NULL
    ) AS unit_price_cast_errors,
    COUNT(*) FILTER (
        WHERE regexp_matches(
            SUBSTR(regexp_extract(unit_price_text, '\.([0-9]*)$', 1), 4),
            '[1-9]'
        )
    ) AS unit_price_rounding_rows
FROM source_typed;

-- @step source_cast_checks
-- Các giá trị nguồn có chuyển kiểu chính xác, không overflow hoặc làm tròn?
SELECT * FROM source_cast_checks;

-- @step enforce_source_checks
CREATE OR REPLACE TEMP TABLE source_cast_gate AS
SELECT CASE
    WHEN quantity_cast_errors = 0
     AND invoice_date_cast_errors = 0
     AND unit_price_format_errors = 0
     AND unit_price_cast_errors = 0
     AND unit_price_rounding_rows = 0
    THEN TRUE
    ELSE error('Source cast checks failed. Do not commit; inspect source_cast_checks.')
END AS passed
FROM source_cast_checks;

-- @step create_clean
-- Dòng nguồn nào được giữ khi tám trường nguồn giống hệt nhau?
CREATE OR REPLACE TEMP VIEW distinct_source_transactions AS
SELECT * EXCLUDE (duplicate_rank)
FROM (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY InvoiceNo, StockCode, Description, Quantity,
                     InvoiceDate, UnitPrice, CustomerID, Country
        ORDER BY source_row_number
    ) AS duplicate_rank
    FROM raw_transactions
)
WHERE duplicate_rank = 1;

CREATE OR REPLACE TABLE clean_transactions AS
SELECT
    d.source_row_number,
    TRIM(d.InvoiceNo) AS InvoiceNo,
    TRIM(d.StockCode) AS StockCode,
    NULLIF(TRIM(d.Description), '') AS Description,
    p.typed_quantity AS Quantity,
    p.typed_invoice_date AS InvoiceDate,
    p.typed_unit_price AS UnitPrice,
    NULLIF(TRIM(d.CustomerID), '') AS CustomerID,
    TRIM(d.Country) AS Country,
    COALESCE(
        UPPER(TRIM(d.InvoiceNo)) NOT LIKE 'C%'
        AND p.typed_quantity < 0,
        FALSE
    ) AS non_c_negative_quantity,
    COALESCE(p.typed_unit_price = 0, FALSE) AS zero_unit_price,
    COALESCE(p.typed_unit_price < 0, FALSE) AS accounting_adjustment
FROM distinct_source_transactions d
JOIN source_typed p USING (source_row_number);

-- @step raw_table_schema
-- Raw có giữ identifier và tám trường nguồn ở dạng text?
DESCRIBE raw_transactions;

-- @step clean_table_schema
-- Bảng sạch có đúng kiểu dữ liệu và thứ tự cột?
DESCRIBE clean_transactions;

-- @step prepare_validation
CREATE OR REPLACE TEMP VIEW clean_row_reconciliation AS
WITH raw_summary AS (
    SELECT COUNT(*) AS raw_rows FROM raw_transactions
), distinct_summary AS (
    SELECT
        COUNT(*) AS distinct_source_rows,
        SUM(p.typed_quantity) AS deduplicated_quantity_total,
        SUM(p.typed_quantity * p.typed_unit_price) AS deduplicated_line_value_total
    FROM distinct_source_transactions d
    JOIN source_typed p USING (source_row_number)
), clean_summary AS (
    SELECT
        COUNT(*) AS clean_rows,
        SUM(Quantity) AS clean_quantity_total,
        SUM(Quantity * UnitPrice) AS clean_line_value_total
    FROM clean_transactions
)
SELECT
    raw_rows,
    distinct_source_rows,
    raw_rows - distinct_source_rows AS removed_duplicate_rows,
    clean_rows,
    clean_rows = distinct_source_rows AS row_reconciliation_passed,
    deduplicated_quantity_total,
    clean_quantity_total,
    deduplicated_quantity_total IS NOT DISTINCT FROM clean_quantity_total
        AS quantity_reconciliation_passed,
    deduplicated_line_value_total,
    clean_line_value_total,
    deduplicated_line_value_total IS NOT DISTINCT FROM clean_line_value_total
        AS line_value_reconciliation_passed
FROM raw_summary CROSS JOIN distinct_summary CROSS JOIN clean_summary;

CREATE OR REPLACE TEMP VIEW clean_validation AS
WITH source_differences AS (
    (SELECT * FROM raw_transactions EXCEPT ALL SELECT * FROM source_csv)
    UNION ALL
    (SELECT * FROM source_csv EXCEPT ALL SELECT * FROM raw_transactions)
), field_checks AS (
    SELECT
        COUNT(*) FILTER (
            WHERE c.source_row_number IS NULL OR d.source_row_number IS NULL
        ) AS source_selection_errors,
        COUNT(*) FILTER (
            WHERE c.source_row_number IS NOT NULL
              AND d.source_row_number IS NOT NULL
              AND (
                  c.InvoiceNo IS DISTINCT FROM TRIM(d.InvoiceNo)
                  OR c.StockCode IS DISTINCT FROM TRIM(d.StockCode)
                  OR c.Description IS DISTINCT FROM NULLIF(TRIM(d.Description), '')
                  OR c.Quantity IS DISTINCT FROM p.typed_quantity
                  OR c.InvoiceDate IS DISTINCT FROM p.typed_invoice_date
                  OR c.UnitPrice IS DISTINCT FROM p.typed_unit_price
                  OR c.CustomerID IS DISTINCT FROM NULLIF(TRIM(d.CustomerID), '')
                  OR c.Country IS DISTINCT FROM TRIM(d.Country)
              )
        ) AS field_value_errors,
        COUNT(*) FILTER (
            WHERE c.non_c_negative_quantity IS DISTINCT FROM CASE
                WHEN UPPER(TRIM(d.InvoiceNo)) NOT LIKE 'C%' AND p.typed_quantity < 0
                THEN TRUE ELSE FALSE END
        ) AS non_c_flag_errors,
        COUNT(*) FILTER (
            WHERE c.zero_unit_price IS DISTINCT FROM CASE
                WHEN p.typed_unit_price = 0 THEN TRUE ELSE FALSE END
        ) AS zero_price_flag_errors,
        COUNT(*) FILTER (
            WHERE c.accounting_adjustment IS DISTINCT FROM CASE
                WHEN p.typed_unit_price < 0 THEN TRUE ELSE FALSE END
        ) AS adjustment_flag_errors
    FROM clean_transactions c
    FULL OUTER JOIN distinct_source_transactions d USING (source_row_number)
    LEFT JOIN source_typed p USING (source_row_number)
), expected_clean_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('source_row_number', 'BIGINT', 1),
        ('InvoiceNo', 'VARCHAR', 2),
        ('StockCode', 'VARCHAR', 3),
        ('Description', 'VARCHAR', 4),
        ('Quantity', 'BIGINT', 5),
        ('InvoiceDate', 'TIMESTAMP', 6),
        ('UnitPrice', 'DECIMAL(18,3)', 7),
        ('CustomerID', 'VARCHAR', 8),
        ('Country', 'VARCHAR', 9),
        ('non_c_negative_quantity', 'BOOLEAN', 10),
        ('zero_unit_price', 'BOOLEAN', 11),
        ('accounting_adjustment', 'BOOLEAN', 12)
), expected_raw_schema(column_name, data_type, ordinal_position) AS (
    VALUES
        ('source_row_number', 'BIGINT', 1),
        ('InvoiceNo', 'VARCHAR', 2),
        ('StockCode', 'VARCHAR', 3),
        ('Description', 'VARCHAR', 4),
        ('Quantity', 'VARCHAR', 5),
        ('InvoiceDate', 'VARCHAR', 6),
        ('UnitPrice', 'VARCHAR', 7),
        ('CustomerID', 'VARCHAR', 8),
        ('Country', 'VARCHAR', 9)
), actual_clean_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main' AND table_name = 'clean_transactions'
), actual_raw_schema AS (
    SELECT column_name, data_type, ordinal_position
    FROM information_schema.columns
    WHERE table_catalog = current_database()
      AND table_schema = 'main' AND table_name = 'raw_transactions'
), checks AS (
    SELECT 'raw_source_fidelity' AS check_name, COUNT(*) AS error_rows
    FROM source_differences
    UNION ALL
    SELECT 'raw_row_number_uniqueness',
           COUNT(*) - COUNT(DISTINCT source_row_number) FROM raw_transactions
    UNION ALL
    SELECT 'clean_row_number_uniqueness',
           COUNT(*) - COUNT(DISTINCT source_row_number) FROM clean_transactions
    UNION ALL
    SELECT 'dedup_first_occurrence', source_selection_errors FROM field_checks
    UNION ALL
    SELECT 'clean_field_values', field_value_errors FROM field_checks
    UNION ALL
    SELECT 'non_c_negative_quantity_flag', non_c_flag_errors FROM field_checks
    UNION ALL
    SELECT 'zero_unit_price_flag', zero_price_flag_errors FROM field_checks
    UNION ALL
    SELECT 'accounting_adjustment_flag', adjustment_flag_errors FROM field_checks
    UNION ALL
    SELECT 'blank_descriptions', COUNT(*) FROM clean_transactions
    WHERE Description IS NOT NULL AND TRIM(Description) = ''
    UNION ALL
    SELECT 'raw_schema', COUNT(*)
    FROM expected_raw_schema e FULL OUTER JOIN actual_raw_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT 'clean_schema', COUNT(*)
    FROM expected_clean_schema e FULL OUTER JOIN actual_clean_schema a USING (column_name)
    WHERE e.data_type IS DISTINCT FROM a.data_type
       OR e.ordinal_position IS DISTINCT FROM a.ordinal_position
    UNION ALL
    SELECT 'row_reconciliation', ABS(clean_rows - distinct_source_rows)
    FROM clean_row_reconciliation
    UNION ALL
    SELECT 'quantity_reconciliation', CASE WHEN quantity_reconciliation_passed THEN 0 ELSE 1 END
    FROM clean_row_reconciliation
    UNION ALL
    SELECT 'line_value_reconciliation', CASE WHEN line_value_reconciliation_passed THEN 0 ELSE 1 END
    FROM clean_row_reconciliation
)
SELECT check_name, error_rows, error_rows = 0 AS passed FROM checks;

-- @step clean_row_reconciliation
-- Số dòng, tổng Quantity và tổng giá trị dòng có được bảo toàn sau loại trùng?
-- Tổng giá trị dòng chỉ dùng đối chiếu kỹ thuật, không phải metric bán/hủy.
SELECT * FROM clean_row_reconciliation;

-- @step clean_quality_flags
-- Những tổ hợp nhãn nào xuất hiện trong bảng sạch?
SELECT
    non_c_negative_quantity, zero_unit_price, accounting_adjustment,
    COUNT(*) AS transaction_rows
FROM clean_transactions
GROUP BY ALL
ORDER BY non_c_negative_quantity DESC, zero_unit_price DESC, accounting_adjustment DESC;

-- @step clean_validation
-- Raw, truy vết, loại trùng, giá trị, nhãn và schema có vượt kiểm chứng?
SELECT * FROM clean_validation ORDER BY check_name;

-- @step enforce_clean_validation
CREATE OR REPLACE TEMP TABLE clean_validation_gate AS
SELECT CASE
    WHEN BOOL_AND(passed) THEN TRUE
    ELSE error('Clean validation failed. Do not commit; inspect clean_validation.')
END AS passed
FROM clean_validation;

-- @step clean_transactions
-- Bảng sạch đầy đủ gồm những dòng nào?
SELECT * FROM clean_transactions ORDER BY source_row_number;

-- @step commit_clean
COMMIT;
