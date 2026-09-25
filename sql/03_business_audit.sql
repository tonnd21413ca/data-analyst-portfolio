/*
Project: Sales Performance Analysis
File: 03_business_audit.sql
Purpose: Collect Stage 2 evidence before finalizing business analysis rules.
*/

-- @step time_coverage_overview
-- Dữ liệu bắt đầu, kết thúc khi nào và có thiếu thời gian không?
SELECT
    COUNT(*) AS clean_rows,
    COUNT(*) FILTER (WHERE InvoiceDate IS NULL) AS invoice_date_missing,
    MIN(InvoiceDate) AS first_observed_timestamp,
    MAX(InvoiceDate) AS last_observed_timestamp
FROM clean_transactions;

-- @step monthly_time_coverage
-- Mỗi tháng có giao dịch từ ngày nào đến ngày nào?
WITH monthly AS (
    SELECT
        CAST(DATE_TRUNC('month', InvoiceDate) AS DATE) AS month_start,
        MIN(CAST(InvoiceDate AS DATE)) AS first_observed_date,
        MAX(CAST(InvoiceDate AS DATE)) AS last_observed_date,
        COUNT(*) AS transaction_rows,
        COUNT(DISTINCT CAST(InvoiceDate AS DATE)) AS observed_transaction_dates
    FROM clean_transactions
    WHERE InvoiceDate IS NOT NULL
    GROUP BY 1
)
SELECT
    *,
    first_observed_date = month_start AS observed_on_first_calendar_day,
    last_observed_date = LAST_DAY(month_start) AS observed_on_last_calendar_day
FROM monthly
ORDER BY month_start;

-- @step dates_without_transactions
-- Query hỗ trợ được tạo bởi AI.
-- Ngày nào trong khoảng quan sát không có giao dịch ghi nhận?
WITH bounds AS (
    SELECT
        MIN(CAST(InvoiceDate AS DATE)) AS first_date,
        MAX(CAST(InvoiceDate AS DATE)) AS last_date
    FROM clean_transactions
),
calendar AS (
    SELECT CAST(day AS DATE) AS calendar_date
    FROM bounds,
         GENERATE_SERIES(
             first_date,
             last_date,
             INTERVAL 1 DAY
         ) AS dates(day)
),
observed_dates AS (
    SELECT DISTINCT
        CAST(InvoiceDate AS DATE) AS calendar_date
    FROM clean_transactions
)
SELECT
    c.calendar_date,
    DAYNAME(c.calendar_date) AS day_name
FROM calendar c
LEFT JOIN observed_dates o USING (calendar_date)
WHERE o.calendar_date IS NULL
ORDER BY c.calendar_date;

-- @step identifier_format_summary
-- InvoiceNo, StockCode và CustomerID có những dạng nào?

WITH identifier_patterns AS (
    SELECT
        'InvoiceNo' AS identifier_name,
        InvoiceNo AS identifier_value,
        CASE
            WHEN InvoiceNo IS NULL THEN 'missing'
            WHEN REGEXP_FULL_MATCH(InvoiceNo, '[0-9]+')
                THEN 'digits_only'
            WHEN REGEXP_FULL_MATCH(UPPER(InvoiceNo), 'C[0-9]+')
                THEN 'c_prefix_plus_digits'
            ELSE 'other'
        END AS format_group
    FROM clean_transactions
	UNION ALL
    SELECT
        'StockCode',
        StockCode,
        CASE
            WHEN StockCode IS NULL THEN 'missing'
            WHEN REGEXP_FULL_MATCH(StockCode, '[0-9]+')
                THEN 'digits_only'
            WHEN REGEXP_FULL_MATCH(UPPER(StockCode), '[0-9]+[A-Z]+')
                THEN 'digits_plus_letters'
            ELSE 'other'
        END
    FROM clean_transactions
    UNION ALL
    SELECT
        'CustomerID',
        CustomerID,
        CASE
            WHEN CustomerID IS NULL THEN 'missing'
            WHEN REGEXP_FULL_MATCH(CustomerID, '[0-9]+')
                THEN 'digits_only'
            ELSE 'other'
        END
    FROM clean_transactions
)
SELECT
    identifier_name,
    format_group,
    COUNT(*) AS row_count,
    COUNT(DISTINCT identifier_value) AS distinct_value_count,
    MIN(LENGTH(identifier_value)) AS min_length,
    MAX(LENGTH(identifier_value)) AS max_length
FROM identifier_patterns
GROUP BY
    identifier_name,
    format_group
ORDER BY
    identifier_name,
    format_group;

-- @step identifier_other_values
-- Các identifier thuộc nhóm other xuất hiện trong ngữ cảnh nào?

WITH identifier_exceptions AS (
    SELECT
        'InvoiceNo' AS identifier_name,
        InvoiceNo AS identifier_value,
        InvoiceNo,
        StockCode,
        Description,
        InvoiceDate
    FROM clean_transactions
    WHERE InvoiceNo IS NOT NULL
      AND NOT REGEXP_FULL_MATCH(InvoiceNo, '[0-9]+')
      AND NOT REGEXP_FULL_MATCH(UPPER(InvoiceNo), 'C[0-9]+')
    UNION ALL
    SELECT
        'StockCode',
        StockCode,
        InvoiceNo,
        StockCode,
        Description,
        InvoiceDate
    FROM clean_transactions
    WHERE StockCode IS NOT NULL
      AND NOT REGEXP_FULL_MATCH(StockCode, '[0-9]+')
      AND NOT REGEXP_FULL_MATCH(
          UPPER(StockCode),
          '[0-9]+[A-Z]+'
      )
)
SELECT
    identifier_name,
    identifier_value,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS distinct_invoice_count,
    COUNT(DISTINCT StockCode) AS distinct_stock_code_count,
    COUNT(DISTINCT Description) AS distinct_description_count,
    MIN(Description) AS example_description,
    MIN(InvoiceDate) AS first_seen,
    MAX(InvoiceDate) AS last_seen
FROM identifier_exceptions
GROUP BY
    identifier_name,
    identifier_value
ORDER BY
    identifier_name,
    row_count DESC,
    identifier_value;

-- @step identifier_case_collisions
-- Identifier nào có nhiều cách viết hoa/thường?

WITH identifier_values AS (
    SELECT
        'InvoiceNo' AS identifier_name,
        InvoiceNo AS identifier_value
    FROM clean_transactions
    WHERE InvoiceNo IS NOT NULL
    UNION ALL
    SELECT
        'StockCode',
        StockCode
    FROM clean_transactions
    WHERE StockCode IS NOT NULL
    UNION ALL
    SELECT
        'CustomerID',
        CustomerID
    FROM clean_transactions
    WHERE CustomerID IS NOT NULL
)
SELECT
    identifier_name,
    UPPER(identifier_value) AS normalized_value,
    COUNT(DISTINCT identifier_value) AS observed_variant_count,
    STRING_AGG(
        DISTINCT identifier_value,
        ', ' ORDER BY identifier_value
    ) AS observed_variants,
    COUNT(*) AS row_count
FROM identifier_values
GROUP BY
    identifier_name,
    UPPER(identifier_value)
HAVING COUNT(DISTINCT identifier_value) > 1
ORDER BY
    identifier_name,
    normalized_value;

-- @step stock_code_case_variant_context
-- Các biến thể hoa/thường có cùng mô tả sản phẩm không?

WITH collision_codes AS (
    SELECT
        UPPER(StockCode) AS normalized_stock_code
    FROM clean_transactions
    WHERE StockCode IS NOT NULL
    GROUP BY
        UPPER(StockCode)
    HAVING COUNT(DISTINCT StockCode) > 1
)
SELECT
    UPPER(t.StockCode) AS normalized_stock_code,
    t.StockCode AS observed_stock_code,
    COUNT(*) AS row_count,
    COUNT(DISTINCT t.Description) AS distinct_description_count,
    SUM(
        CASE
            WHEN t.Description IS NULL THEN 1
            ELSE 0
        END
    ) AS missing_description_rows,
    MIN(t.Description) AS min_description,
    MAX(t.Description) AS max_description,
    MIN(t.InvoiceDate) AS first_seen,
    MAX(t.InvoiceDate) AS last_seen
FROM clean_transactions AS t
INNER JOIN collision_codes AS c
    ON UPPER(t.StockCode) = c.normalized_stock_code
GROUP BY
    UPPER(t.StockCode),
    t.StockCode
ORDER BY
    normalized_stock_code,
    observed_stock_code;

-- @step invoice_identifier_consistency
-- Một InvoiceNo có gắn với nhiều customer, country hoặc timestamp không?

WITH invoice_summary AS (
    SELECT
        InvoiceNo,
        COUNT(*) AS row_count,
        COUNT(DISTINCT CustomerID) AS distinct_customer_count,
        SUM(
            CASE
                WHEN CustomerID IS NULL THEN 1
                ELSE 0
            END
        ) AS missing_customer_rows,
        COUNT(DISTINCT Country) AS distinct_country_count,
        COUNT(DISTINCT InvoiceDate) AS distinct_timestamp_count,
        MIN(CustomerID) AS min_customer_id,
        MAX(CustomerID) AS max_customer_id,
        MIN(Country) AS min_country,
        MAX(Country) AS max_country,
        MIN(InvoiceDate) AS first_timestamp,
        MAX(InvoiceDate) AS last_timestamp
    FROM clean_transactions
    GROUP BY
        InvoiceNo
)
SELECT
    *
FROM invoice_summary
WHERE distinct_customer_count > 1
   OR (
        distinct_customer_count = 1
        AND missing_customer_rows > 0
   )
   OR distinct_country_count > 1
   OR distinct_timestamp_count > 1
ORDER BY
    InvoiceNo;

-- @step invoice_timestamp_pattern
-- Các invoice có nhiều timestamp chênh nhau bao lâu
-- và có vượt qua ngày lịch khác không?

WITH multi_timestamp_invoices AS (
    SELECT
        InvoiceNo,
        COUNT(*) AS row_count,
        COUNT(DISTINCT InvoiceDate) AS distinct_timestamp_count,
        COUNT(
            DISTINCT CAST(InvoiceDate AS DATE)
        ) AS distinct_date_count,
        DATE_DIFF(
            'minute',
            MIN(InvoiceDate),
            MAX(InvoiceDate)
        ) AS timestamp_span_minutes
    FROM clean_transactions
    GROUP BY
        InvoiceNo
    HAVING COUNT(DISTINCT InvoiceDate) > 1
)
SELECT
    distinct_timestamp_count,
    distinct_date_count,
    timestamp_span_minutes,
    COUNT(*) AS invoice_count,
    MIN(row_count) AS min_rows_per_invoice,
    MAX(row_count) AS max_rows_per_invoice
FROM multi_timestamp_invoices
GROUP BY
    distinct_timestamp_count,
    distinct_date_count,
    timestamp_span_minutes
ORDER BY
    distinct_date_count DESC,
    timestamp_span_minutes DESC;

-- @step sales_eligibility_summary
-- Invoice prefix, Quantity và UnitPrice kết hợp thế nào?

WITH classified_lines AS (
    SELECT
        InvoiceNo,
        Quantity,
        UnitPrice,
        CASE
            WHEN InvoiceNo IS NULL THEN 'missing'
            WHEN UPPER(InvoiceNo) LIKE 'C%' THEN 'c_prefix'
            ELSE 'non_c_prefix'
        END AS invoice_group,
        CASE
            WHEN Quantity IS NULL THEN 'missing'
            WHEN Quantity < 0 THEN 'negative'
            WHEN Quantity = 0 THEN 'zero'
            ELSE 'positive'
        END AS quantity_sign,
        CASE
            WHEN UnitPrice IS NULL THEN 'missing'
            WHEN UnitPrice < 0 THEN 'negative'
            WHEN UnitPrice = 0 THEN 'zero'
            ELSE 'positive'
        END AS unit_price_sign
    FROM clean_transactions
)
SELECT
    invoice_group,
    quantity_sign,
    unit_price_sign,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS invoice_count,
    MIN(Quantity) AS min_quantity,
    MAX(Quantity) AS max_quantity,
    MIN(UnitPrice) AS min_unit_price,
    MAX(UnitPrice) AS max_unit_price,
    MAX(ABS(Quantity * UnitPrice)) AS max_absolute_line_value
FROM classified_lines
GROUP BY
    invoice_group,
    quantity_sign,
    unit_price_sign
ORDER BY
    invoice_group,
    quantity_sign,
    unit_price_sign;

-- @step unusual_line_magnitudes
-- Những dòng nào có Quantity × UnitPrice lớn nhất
-- theo giá trị tuyệt đối?

SELECT
    source_row_number,
    InvoiceNo,
    StockCode,
    Description,
    Quantity,
    UnitPrice,
    Quantity * UnitPrice AS line_value,
    InvoiceDate,
    CustomerID,
    Country
FROM clean_transactions
ORDER BY
    ABS(Quantity * UnitPrice) DESC,
    source_row_number
LIMIT 20;

-- @step nonstandard_sales_candidate_codes
-- StockCode không theo định dạng thông thường nào
-- vượt qua quy tắc sales dự kiến?

SELECT
    UPPER(StockCode) AS normalized_stock_code,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS invoice_count,
    COUNT(DISTINCT Description) AS description_count,
    MIN(Description) AS example_description,
    MIN(UnitPrice) AS min_unit_price,
    MAX(UnitPrice) AS max_unit_price,
    MAX(Quantity * UnitPrice) AS max_line_value
FROM clean_transactions
WHERE InvoiceNo IS NOT NULL
  AND UPPER(InvoiceNo) NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0
  AND StockCode IS NOT NULL
  AND NOT REGEXP_FULL_MATCH(StockCode, '[0-9]+')
  AND NOT REGEXP_FULL_MATCH(
      UPPER(StockCode),
      '[0-9]+[A-Z]+'
  )
GROUP BY
    UPPER(StockCode)
ORDER BY
    max_line_value DESC,
    normalized_stock_code;

-- @step stock_code_description_summary
-- Mỗi StockCode có bao nhiêu Description
-- trên toàn bộ bảng sạch?

WITH stock_code_summary AS (
    SELECT
        UPPER(StockCode) AS normalized_stock_code,
        COUNT(*) AS row_count,
        COUNT(DISTINCT Description) AS description_count,
        SUM(
            CASE
                WHEN Description IS NULL THEN 1
                ELSE 0
            END
        ) AS missing_description_rows
    FROM clean_transactions
    WHERE StockCode IS NOT NULL
    GROUP BY
        UPPER(StockCode)
)
SELECT
    CASE
        WHEN description_count = 0 THEN 'no_description'
        WHEN description_count = 1 THEN 'one_description'
        ELSE 'multiple_descriptions'
    END AS relationship_group,
    COUNT(*) AS stock_code_count,
    MAX(description_count) AS max_description_count,
    SUM(
        CASE
            WHEN missing_description_rows > 0 THEN 1
            ELSE 0
        END
    ) AS codes_with_missing_description_rows
FROM stock_code_summary
GROUP BY
    relationship_group
ORDER BY
    relationship_group;

-- @step stock_codes_with_multiple_descriptions
-- StockCode nào có nhiều Description nhất?

SELECT
    UPPER(StockCode) AS normalized_stock_code,
    COUNT(*) AS row_count,
    COUNT(DISTINCT Description) AS description_count,
    SUM(
        CASE
            WHEN Description IS NULL THEN 1
            ELSE 0
        END
    ) AS missing_description_rows,
    MIN(Description) AS min_description,
    MAX(Description) AS max_description
FROM clean_transactions
WHERE StockCode IS NOT NULL
GROUP BY
    UPPER(StockCode)
HAVING
    COUNT(DISTINCT Description) > 1
ORDER BY
    description_count DESC,
    row_count DESC,
    normalized_stock_code
LIMIT 20;

-- @step sales_candidate_description_variants
-- StockCode nào vẫn có nhiều Description
-- trong population sales dự kiến?

SELECT
    UPPER(StockCode) AS normalized_stock_code,
    COUNT(*) AS row_count,
    COUNT(DISTINCT Description) AS description_count,
    MIN(Description) AS min_description,
    MAX(Description) AS max_description
FROM clean_transactions
WHERE InvoiceNo IS NOT NULL
  AND UPPER(InvoiceNo) NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0
  AND Description IS NOT NULL
  AND StockCode IS NOT NULL
GROUP BY
    UPPER(StockCode)
HAVING
    COUNT(DISTINCT Description) > 1
ORDER BY
    description_count DESC,
    row_count DESC,
    normalized_stock_code
LIMIT 20;

-- @step sales_candidate_description_frequency
-- Mỗi Description xuất hiện bao nhiêu lần
-- trong sales candidates của cùng StockCode?

WITH description_counts AS (
    SELECT
        UPPER(StockCode) AS normalized_stock_code,
        Description,
        COUNT(*) AS row_count,
        MIN(InvoiceDate) AS first_seen,
        MAX(InvoiceDate) AS last_seen
    FROM clean_transactions
    WHERE InvoiceNo IS NOT NULL
      AND UPPER(InvoiceNo) NOT LIKE 'C%'
      AND Quantity > 0
      AND UnitPrice > 0
      AND Description IS NOT NULL
      AND StockCode IS NOT NULL
    GROUP BY
        UPPER(StockCode),
        Description
),
ranked_descriptions AS (
    SELECT
        *,
        COUNT(*) OVER (
            PARTITION BY normalized_stock_code
        ) AS description_count,
        RANK() OVER (
            PARTITION BY normalized_stock_code
            ORDER BY row_count DESC
        ) AS frequency_rank
    FROM description_counts
)
SELECT
    normalized_stock_code,
    Description,
    row_count,
    first_seen,
    last_seen,
    description_count,
    frequency_rank
FROM ranked_descriptions
WHERE description_count > 1
ORDER BY
    description_count DESC,
    normalized_stock_code,
    frequency_rank,
    Description
LIMIT 100;

-- @step top_description_frequency_ties
-- StockCode nào có nhiều Description
-- đồng hạng phổ biến nhất?

WITH description_counts AS (
    SELECT
        UPPER(StockCode) AS normalized_stock_code,
        Description,
        COUNT(*) AS row_count
    FROM clean_transactions
    WHERE InvoiceNo IS NOT NULL
      AND UPPER(InvoiceNo) NOT LIKE 'C%'
      AND Quantity > 0
      AND UnitPrice > 0
      AND Description IS NOT NULL
      AND StockCode IS NOT NULL
    GROUP BY
        UPPER(StockCode),
        Description
),
ranked_descriptions AS (
    SELECT
        *,
        RANK() OVER (
            PARTITION BY normalized_stock_code
            ORDER BY row_count DESC
        ) AS frequency_rank
    FROM description_counts
)
SELECT
    normalized_stock_code,
    COUNT(*) AS tied_description_count,
    MAX(row_count) AS rows_per_description,
    MIN(Description) AS min_description,
    MAX(Description) AS max_description
FROM ranked_descriptions
WHERE frequency_rank = 1
GROUP BY
    normalized_stock_code
HAVING
    COUNT(*) > 1
ORDER BY
    tied_description_count DESC,
    normalized_stock_code;

-- @step top_description_tie_context
-- Các Description đồng hạng xuất hiện khi nào?

SELECT
    UPPER(StockCode) AS normalized_stock_code,
    Description,
    COUNT(*) AS row_count,
    MIN(InvoiceDate) AS first_seen,
    MAX(InvoiceDate) AS last_seen
FROM clean_transactions
WHERE InvoiceNo IS NOT NULL
  AND UPPER(InvoiceNo) NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0
  AND Description IS NOT NULL
  AND UPPER(StockCode) IN (
      '35817P',
      '81950V',
      '90014C'
  )
GROUP BY
    UPPER(StockCode),
    Description
ORDER BY
    normalized_stock_code,
    row_count DESC,
    last_seen DESC,
    Description;

-- @step sales_candidate_codes_without_description
-- StockCode nào trong sales candidates
-- hoàn toàn không có Description?

SELECT
    UPPER(StockCode) AS normalized_stock_code,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS invoice_count,
    MIN(InvoiceDate) AS first_seen,
    MAX(InvoiceDate) AS last_seen
FROM clean_transactions
WHERE InvoiceNo IS NOT NULL
  AND UPPER(InvoiceNo) NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0
  AND StockCode IS NOT NULL
GROUP BY
    UPPER(StockCode)
HAVING
    COUNT(DISTINCT Description) = 0
ORDER BY
    row_count DESC,
    normalized_stock_code;

-- @step possible_non_merchandise_sales_candidates
-- Các mã có vẻ không phải hàng hóa đóng góp thế nào
-- trong sales candidates?

SELECT
    UPPER(StockCode) AS normalized_stock_code,
    MIN(Description) AS description,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS invoice_count,
    COUNT(DISTINCT Country) AS country_count,
    SUM(Quantity) AS provisional_quantity,
    SUM(Quantity * UnitPrice) AS provisional_line_value,
    MIN(InvoiceDate) AS first_seen,
    MAX(InvoiceDate) AS last_seen
FROM clean_transactions
WHERE InvoiceNo IS NOT NULL
  AND UPPER(InvoiceNo) NOT LIKE 'C%'
  AND Quantity > 0
  AND UnitPrice > 0
  AND (
      UPPER(StockCode) IN (
          'AMAZONFEE',
          'B',
          'BANK CHARGES',
          'C2',
          'DOT',
          'M',
          'POST',
          'S'
      )
      OR UPPER(StockCode) LIKE 'GIFT_%'
  )
GROUP BY
    UPPER(StockCode)
ORDER BY
    provisional_line_value DESC,
    normalized_stock_code;

-- @step manual_code_context
-- Mã Manual xuất hiện trong những tổ hợp dấu nào
-- và có mức giá ổn định không?

SELECT
    UPPER(InvoiceNo) LIKE 'C%' AS is_c_prefix,
    Quantity > 0 AS positive_quantity,
    UnitPrice > 0 AS positive_unit_price,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS invoice_count,
    COUNT(DISTINCT UnitPrice) AS unit_price_count,
    MIN(Quantity) AS min_quantity,
    MAX(Quantity) AS max_quantity,
    MIN(UnitPrice) AS min_unit_price,
    MAX(UnitPrice) AS max_unit_price,
    SUM(Quantity * UnitPrice) AS provisional_line_value
FROM clean_transactions
WHERE UPPER(StockCode) = 'M'
GROUP BY
    is_c_prefix,
    positive_quantity,
    positive_unit_price
ORDER BY
    is_c_prefix,
    positive_quantity,
    positive_unit_price;

-- @step sales_population_decision_summary
-- Mỗi dòng clean được chấp nhận hay loại vì lý do chính nào?

WITH normalized_lines AS (
    SELECT
        source_row_number,
        UPPER(TRIM(InvoiceNo)) AS normalized_invoice_no,
        UPPER(TRIM(StockCode)) AS product_key,
        InvoiceNo,
        Quantity,
        UnitPrice
    FROM clean_transactions
),
classified_lines AS (
    SELECT
        *,
        CASE
            WHEN normalized_invoice_no IS NULL
                THEN 'excluded_missing_invoice'
            WHEN normalized_invoice_no LIKE 'C%'
                THEN 'excluded_cancellation'
            WHEN Quantity IS NULL OR Quantity <= 0
                THEN 'excluded_non_positive_quantity'
            WHEN UnitPrice IS NULL OR UnitPrice <= 0
                THEN 'excluded_non_positive_unit_price'
            WHEN product_key IS NULL
                THEN 'excluded_missing_product_code'
            WHEN product_key IN (
                'AMAZONFEE',
                'B',
                'BANK CHARGES',
                'C2',
                'DOT',
                'M',
                'POST',
                'S'
            )
            OR product_key LIKE 'GIFT!_%' ESCAPE '!'
                THEN 'excluded_non_merchandise'
            ELSE 'accepted_sale'
        END AS population_status
    FROM normalized_lines
)
SELECT
    population_status,
    COUNT(*) AS row_count,
    COUNT(DISTINCT InvoiceNo) AS invoice_count,
    SUM(Quantity) AS total_quantity,
    SUM(Quantity * UnitPrice) AS total_line_value,
    SUM(COUNT(*)) OVER () AS classified_row_count
FROM classified_lines
GROUP BY population_status
ORDER BY
    CASE population_status
        WHEN 'accepted_sale' THEN 1
        ELSE 2
    END,
    row_count DESC;

-- @step country_dimension_candidates
-- Country có nhãn trùng, khác hoa/thường hoặc giá trị cần xem xét không?

WITH country_values AS (
    SELECT
        UPPER(Country) AS normalized_country,
        Country AS observed_country,
        COUNT(*) AS row_count,
        COUNT(DISTINCT InvoiceNo) AS invoice_count,
        MIN(CAST(InvoiceDate AS DATE)) AS first_seen,
        MAX(CAST(InvoiceDate AS DATE)) AS last_seen
    FROM clean_transactions
    WHERE InvoiceDate >= DATE '2010-12-01'
      AND InvoiceDate < DATE '2011-12-01'
    GROUP BY
        UPPER(Country),
        Country
)
SELECT
    normalized_country,
    observed_country,
    row_count,
    invoice_count,
    first_seen,
    last_seen,
    COUNT(*) OVER (
        PARTITION BY normalized_country
    ) AS observed_variant_count
FROM country_values
ORDER BY
    normalized_country,
    observed_country;