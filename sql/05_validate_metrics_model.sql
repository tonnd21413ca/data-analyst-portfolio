/*
Project: Sales Performance Analysis
File: 05_validate_metrics_model.sql
Purpose: Validate the Stage 4 metrics and reporting-model logic.
Implementation note: AI assists with this SQL; each validation step and
material decision is reviewed and approved by the user before execution.
*/

-- Sales-population rules được định nghĩa một lần để hai validation cùng dùng.
CREATE OR REPLACE TEMP VIEW stage_4_sales_population_classification AS
WITH normalized_lines AS (
    SELECT
        source_row_number,
        UPPER(TRIM(InvoiceNo)) AS normalized_invoice_no,
        Quantity,
        UnitPrice,
        UPPER(TRIM(StockCode)) AS product_key
    FROM clean_transactions
)
SELECT
    source_row_number,
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
            'AMAZONFEE', 'B', 'BANK CHARGES', 'C2',
            'DOT', 'M', 'POST', 'S'
        )
        OR product_key LIKE 'GIFT!_%' ESCAPE '!'
            THEN 'excluded_non_merchandise'
        ELSE 'accepted_sale'
    END AS population_status
FROM normalized_lines;

-- @step sales_population_reconciliation
-- Mỗi dòng clean có được tính đúng một lần trong sales population không?
WITH expected_statuses (population_status, sort_order) AS (
    VALUES
        ('accepted_sale', 1),
        ('excluded_missing_invoice', 2),
        ('excluded_cancellation', 3),
        ('excluded_non_positive_quantity', 4),
        ('excluded_non_positive_unit_price', 5),
        ('excluded_missing_product_code', 6),
        ('excluded_non_merchandise', 7)
),
status_counts AS (
    SELECT
        population_status,
        COUNT(*) AS row_count
    FROM stage_4_sales_population_classification
    GROUP BY population_status
)
SELECT
    e.population_status,
    COALESCE(c.row_count, 0) AS row_count,
    SUM(COALESCE(c.row_count, 0)) OVER () AS classified_row_count,
    (SELECT COUNT(*) FROM clean_transactions) AS clean_row_count
FROM expected_statuses e
LEFT JOIN status_counts c USING (population_status)
ORDER BY e.sort_order;

-- @step accepted_sales_membership
-- Accepted sales có chứa chính xác các dòng đáp ứng sales-population rules không?
WITH expected_accepted_rows AS (
    SELECT source_row_number
    FROM stage_4_sales_population_classification
    WHERE population_status = 'accepted_sale'
),
missing_expected_rows AS (
    SELECT source_row_number FROM expected_accepted_rows
    EXCEPT ALL
    SELECT source_row_number FROM accepted_sales_lines
),
unexpected_accepted_rows AS (
    SELECT source_row_number FROM accepted_sales_lines
    EXCEPT ALL
    SELECT source_row_number FROM expected_accepted_rows
)
SELECT
    (SELECT COUNT(*) FROM missing_expected_rows) AS missing_expected_rows,
    (SELECT COUNT(*) FROM unexpected_accepted_rows) AS unexpected_accepted_rows;

-- @step metric_reconciliation
-- Metric có khớp từ accepted sales sang fact ở các scope cần thiết không?
WITH accepted_reporting_lines AS (
    SELECT *
    FROM accepted_sales_lines
    WHERE transaction_date >= DATE '2010-12-01'
      AND transaction_date < DATE '2011-12-01'
),
accepted_metrics AS (
    SELECT
        'total' AS validation_scope,
        'all' AS group_key,
        SUM(sales_value) AS sales_value,
        SUM(Quantity) AS sales_quantity
    FROM accepted_reporting_lines

    UNION ALL

    SELECT
        'date',
        CAST(transaction_date AS VARCHAR),
        SUM(sales_value),
        SUM(Quantity)
    FROM accepted_reporting_lines
    GROUP BY transaction_date

    UNION ALL

    SELECT
        'product',
        product_key,
        SUM(sales_value),
        SUM(Quantity)
    FROM accepted_reporting_lines
    GROUP BY product_key

    UNION ALL

    SELECT
        'country',
        Country,
        SUM(sales_value),
        SUM(Quantity)
    FROM accepted_reporting_lines
    GROUP BY Country
),
fact_metrics AS (
    SELECT
        'total' AS validation_scope,
        'all' AS group_key,
        SUM(sales_value) AS sales_value,
        SUM(sales_quantity) AS sales_quantity
    FROM fact_sales

    UNION ALL

    SELECT
        'date',
        CAST(transaction_date AS VARCHAR),
        SUM(sales_value),
        SUM(sales_quantity)
    FROM fact_sales
    GROUP BY transaction_date

    UNION ALL

    SELECT
        'product',
        stock_code,
        SUM(sales_value),
        SUM(sales_quantity)
    FROM fact_sales
    GROUP BY stock_code

    UNION ALL

    SELECT
        'country',
        country,
        SUM(sales_value),
        SUM(sales_quantity)
    FROM fact_sales
    GROUP BY country
),
comparison AS (
    SELECT
        COALESCE(a.validation_scope, f.validation_scope)
            AS validation_scope,
        a.validation_scope IS NULL AS unexpected_fact_group,
        f.validation_scope IS NULL AS missing_fact_group,
        a.sales_value IS DISTINCT FROM f.sales_value
            OR a.sales_quantity IS DISTINCT FROM f.sales_quantity
            AS metric_mismatch
    FROM accepted_metrics a
    FULL OUTER JOIN fact_metrics f
        ON a.validation_scope = f.validation_scope
       AND a.group_key = f.group_key
),
validation AS (
    SELECT
        validation_scope,
        COUNT(*) AS compared_groups,
        COUNT(*) FILTER (
            WHERE missing_fact_group
        ) AS missing_fact_groups,
        COUNT(*) FILTER (
            WHERE unexpected_fact_group
        ) AS unexpected_fact_groups,
        COUNT(*) FILTER (
            WHERE NOT missing_fact_group
              AND NOT unexpected_fact_group
              AND metric_mismatch
        ) AS metric_mismatch_groups
    FROM comparison
    GROUP BY validation_scope
)
SELECT
    *,
    missing_fact_groups = 0
        AND unexpected_fact_groups = 0
        AND metric_mismatch_groups = 0 AS passed
FROM validation
ORDER BY
    CASE validation_scope
        WHEN 'total' THEN 1
        WHEN 'date' THEN 2
        WHEN 'product' THEN 3
        WHEN 'country' THEN 4
    END;

-- @step model_integrity_validation
-- Keys và joins của reporting model có bảo toàn grain và metrics không?
WITH joined_fact AS (
    SELECT
        d.calendar_date AS transaction_date,
        p.stock_code,
        c.country,
        f.sales_value,
        f.sales_quantity
    FROM fact_sales f
    INNER JOIN dim_product p
        ON f.stock_code = p.stock_code
    INNER JOIN dim_country c
        ON f.country = c.country
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
),
fact_metrics AS (
    SELECT 'total' AS validation_scope, 'all' AS group_key,
           SUM(sales_value) AS sales_value,
           SUM(sales_quantity) AS sales_quantity
    FROM fact_sales
    UNION ALL
    SELECT 'date', CAST(transaction_date AS VARCHAR),
           SUM(sales_value), SUM(sales_quantity)
    FROM fact_sales GROUP BY transaction_date
    UNION ALL
    SELECT 'product', stock_code,
           SUM(sales_value), SUM(sales_quantity)
    FROM fact_sales GROUP BY stock_code
    UNION ALL
    SELECT 'country', country,
           SUM(sales_value), SUM(sales_quantity)
    FROM fact_sales GROUP BY country
),
joined_metrics AS (
    SELECT 'total' AS validation_scope, 'all' AS group_key,
           SUM(sales_value) AS sales_value,
           SUM(sales_quantity) AS sales_quantity
    FROM joined_fact
    UNION ALL
    SELECT 'date', CAST(transaction_date AS VARCHAR),
           SUM(sales_value), SUM(sales_quantity)
    FROM joined_fact GROUP BY transaction_date
    UNION ALL
    SELECT 'product', stock_code,
           SUM(sales_value), SUM(sales_quantity)
    FROM joined_fact GROUP BY stock_code
    UNION ALL
    SELECT 'country', country,
           SUM(sales_value), SUM(sales_quantity)
    FROM joined_fact GROUP BY country
),
join_validation AS (
    SELECT
        'join_' || COALESCE(f.validation_scope, j.validation_scope)
            AS check_name,
        COUNT(*) FILTER (
            WHERE f.validation_scope IS NULL
               OR j.validation_scope IS NULL
               OR f.sales_value IS DISTINCT FROM j.sales_value
               OR f.sales_quantity IS DISTINCT FROM j.sales_quantity
        ) AS error_rows
    FROM fact_metrics f
    FULL OUTER JOIN joined_metrics j
        ON f.validation_scope = j.validation_scope
       AND f.group_key = j.group_key
    GROUP BY COALESCE(f.validation_scope, j.validation_scope)
),
checks AS (
    SELECT 'fact_grain_uniqueness' AS check_name, COUNT(*) AS error_rows
    FROM (
        SELECT transaction_date, stock_code, country
        FROM fact_sales
        GROUP BY transaction_date, stock_code, country
        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT 'product_key_uniqueness', COUNT(*)
    FROM (
        SELECT stock_code
        FROM dim_product
        GROUP BY stock_code
        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT 'country_key_uniqueness', COUNT(*)
    FROM (
        SELECT country
        FROM dim_country
        GROUP BY country
        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT 'date_key_uniqueness', COUNT(*)
    FROM (
        SELECT calendar_date
        FROM dim_date
        GROUP BY calendar_date
        HAVING COUNT(*) > 1
    )

    UNION ALL

    SELECT 'product_key_coverage', COUNT(*)
    FROM fact_sales f
    LEFT JOIN dim_product p
        ON f.stock_code = p.stock_code
    WHERE p.stock_code IS NULL

    UNION ALL

    SELECT 'country_key_coverage', COUNT(*)
    FROM fact_sales f
    LEFT JOIN dim_country c
        ON f.country = c.country
    WHERE c.country IS NULL

    UNION ALL

    SELECT 'date_key_coverage', COUNT(*)
    FROM fact_sales f
    LEFT JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    WHERE d.calendar_date IS NULL

    UNION ALL

    SELECT check_name, error_rows
    FROM join_validation
)
SELECT
    check_name,
    error_rows,
    error_rows = 0 AS passed
FROM checks
ORDER BY check_name;

-- @step contribution_validation
-- Contribution denominator và zero case có đúng định nghĩa không?
WITH product_values AS (
    SELECT
        d.month_start,
        f.country,
        f.stock_code,
        SUM(f.sales_value) AS sales_value
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start, f.country, f.stock_code
),
product_denominator_from_rows AS (
    SELECT
        month_start,
        country,
        SUM(sales_value) AS denominator
    FROM product_values
    GROUP BY month_start, country
),
product_denominator_direct AS (
    SELECT
        d.month_start,
        f.country,
        SUM(f.sales_value) AS denominator
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start, f.country
),
country_values AS (
    SELECT
        d.month_start,
        f.stock_code,
        f.country,
        SUM(f.sales_value) AS sales_value
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start, f.stock_code, f.country
),
country_denominator_from_rows AS (
    SELECT
        month_start,
        stock_code,
        SUM(sales_value) AS denominator
    FROM country_values
    GROUP BY month_start, stock_code
),
country_denominator_direct AS (
    SELECT
        d.month_start,
        f.stock_code,
        SUM(f.sales_value) AS denominator
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start, f.stock_code
),
selected_scope_rows (
    selected_by_slicer,
    matching_month,
    matching_other_filter,
    sales_value
) AS (
    VALUES
        (TRUE,  TRUE,  TRUE,  30.000),
        (TRUE,  TRUE,  TRUE,  70.000),
        (FALSE, TRUE,  TRUE, 100.000),
        (TRUE,  FALSE, TRUE,  50.000),
        (TRUE,  TRUE,  FALSE, 20.000)
),
selected_scope AS (
    SELECT
        SUM(sales_value) FILTER (
            WHERE selected_by_slicer
              AND matching_month
              AND matching_other_filter
        ) AS denominator
    FROM selected_scope_rows
),
checks AS (
    SELECT
        'product_denominator_scope' AS check_name,
        COUNT(*) AS relevant_rows,
        COUNT(*) FILTER (
            WHERE p.month_start IS NULL
               OR d.month_start IS NULL
               OR p.denominator IS DISTINCT FROM d.denominator
        ) AS error_rows
    FROM product_denominator_from_rows p
    FULL OUTER JOIN product_denominator_direct d
        ON p.month_start = d.month_start
       AND p.country = d.country

    UNION ALL

    SELECT
        'country_denominator_scope',
        COUNT(*),
        COUNT(*) FILTER (
            WHERE c.month_start IS NULL
               OR d.month_start IS NULL
               OR c.denominator IS DISTINCT FROM d.denominator
        )
    FROM country_denominator_from_rows c
    FULL OUTER JOIN country_denominator_direct d
        ON c.month_start = d.month_start
       AND c.stock_code = d.stock_code

    UNION ALL

    SELECT
        'selected_scope_denominator',
        1,
        CASE
            WHEN denominator = 100.000 THEN 0
            ELSE 1
        END
    FROM selected_scope

    UNION ALL

    SELECT
        'zero_denominator_returns_null',
        1,
        CASE
            WHEN 0.0 / NULLIF(0, 0) IS NULL THEN 0
            ELSE 1
        END
)
SELECT
    check_name,
    relevant_rows,
    error_rows,
    error_rows = 0 AS passed
FROM checks
ORDER BY check_name;

-- @step month_sequence_validation
-- Reporting months có liên tục từ 2010-12 đến 2011-11 không?
WITH reporting_months AS (
    SELECT DISTINCT month_start
    FROM dim_date
),
linked_months AS (
    SELECT
        month_start,
        LAG(month_start) OVER (ORDER BY month_start) AS previous_month
    FROM reporting_months
)
SELECT
    COUNT(*) AS month_count,
    MIN(month_start) AS first_month,
    MAX(month_start) AS last_month,
    COUNT(*) FILTER (
        WHERE month_start = DATE '2010-12-01'
          AND previous_month IS NOT NULL
    )
    + COUNT(*) FILTER (
        WHERE month_start > DATE '2010-12-01'
          AND previous_month
              IS DISTINCT FROM CAST(
                  month_start - INTERVAL 1 MONTH AS DATE
              )
    ) AS invalid_previous_month_links
FROM linked_months;

-- @step monthly_comparison_logic_test
-- Monthly comparison có dùng tháng lịch liền trước trong đúng filter context không?
WITH calendar_months (month_start) AS (
    VALUES
        (DATE '2020-01-01'),
        (DATE '2020-02-01'),
        (DATE '2020-03-01')
),
test_fact (
    month_start,
    stock_code,
    country,
    sales_value,
    sales_quantity
) AS (
    VALUES
        (DATE '2020-01-01', 'A', 'UK',     100.000, 10),
        (DATE '2020-03-01', 'A', 'UK',      50.000,  5),
        (DATE '2020-02-01', 'B', 'UK',     500.000, 50),
        (DATE '2020-02-01', 'A', 'France', 400.000, 40)
),
filtered_monthly_sales AS (
    SELECT
        month_start,
        SUM(sales_value) AS sales_value,
        SUM(sales_quantity) AS sales_quantity
    FROM test_fact
    WHERE stock_code = 'A'
      AND country = 'UK'
    GROUP BY month_start
),
complete_months AS (
    SELECT
        c.month_start,
        COALESCE(s.sales_value, 0) AS sales_value,
        COALESCE(s.sales_quantity, 0) AS sales_quantity
    FROM calendar_months c
    LEFT JOIN filtered_monthly_sales s USING (month_start)
),
with_previous_month AS (
    SELECT
        month_start,
        sales_value,
        sales_quantity,
        LAG(sales_value) OVER (
            ORDER BY month_start
        ) AS previous_sales_value
    FROM complete_months
),
calculated AS (
    SELECT
        month_start,
        sales_value,
        sales_quantity,
        previous_sales_value,
        sales_value - previous_sales_value AS sales_value_change,
        CAST(
            (sales_value - previous_sales_value)
            / NULLIF(previous_sales_value, 0)
            AS DECIMAL(18,3)
        ) AS sales_value_change_ratio
    FROM with_previous_month
),
expected (
    month_start,
    sales_value,
    sales_quantity,
    previous_sales_value,
    sales_value_change,
    sales_value_change_ratio
) AS (
    VALUES
        (DATE '2020-01-01', 100.000, 10, NULL,    NULL, NULL),
        (DATE '2020-02-01',   0.000,  0, 100.000, -100.000, -1.000),
        (DATE '2020-03-01',  50.000,  5,   0.000,   50.000, NULL)
)
SELECT
    c.*,
    c.sales_value IS NOT DISTINCT FROM e.sales_value
        AND c.sales_quantity IS NOT DISTINCT FROM e.sales_quantity
        AND c.previous_sales_value
            IS NOT DISTINCT FROM e.previous_sales_value
        AND c.sales_value_change
            IS NOT DISTINCT FROM e.sales_value_change
        AND c.sales_value_change_ratio
            IS NOT DISTINCT FROM e.sales_value_change_ratio AS passed
FROM calculated c
INNER JOIN expected e USING (month_start)
ORDER BY c.month_start;
