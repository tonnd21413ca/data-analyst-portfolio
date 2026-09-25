/*
Project: Sales Performance Analysis
Scope: Business analysis and priority-product evidence.
Execution: Read-only against data/local/analytics.duckdb.
Reporting period: 2010-12-01 through 2011-11-30.
Priority rule: highest full-period sales value; stock_code ascending breaks ties.
*/

-- @step 57_analysis_overall_kpis.csv
-- Các metric chính và phạm vi kỳ báo cáo là gì?
SELECT
    MIN(transaction_date) AS reporting_start,
    MAX(transaction_date) AS reporting_end,
    SUM(sales_value) AS sales_value,
    SUM(sales_quantity) AS sales_quantity,
    COUNT(DISTINCT stock_code) AS product_count,
    COUNT(DISTINCT country) AS country_count
FROM fact_sales;

-- @step 58_analysis_product_ranking.csv
-- Sản phẩm nào đóng góp nhiều nhất vào Sales Value?
WITH product_totals AS (
    SELECT
        f.stock_code,
        p.product_description,
        SUM(f.sales_value) AS sales_value,
        SUM(f.sales_quantity) AS sales_quantity
    FROM fact_sales f
    INNER JOIN dim_product p USING (stock_code)
    GROUP BY f.stock_code, p.product_description
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY sales_value DESC, stock_code
    ) AS sales_value_rank,
    stock_code,
    product_description,
    sales_value,
    sales_quantity,
    ROUND(
        100.0 * sales_value
        / NULLIF(SUM(sales_value) OVER (), 0),
        6
    ) AS sales_value_contribution_pct
FROM product_totals
ORDER BY sales_value_rank;

-- @step 59_analysis_country_ranking.csv
-- Quốc gia nào đóng góp nhiều nhất vào Sales Value?
WITH country_totals AS (
    SELECT
        f.country,
        c.country_label,
        SUM(f.sales_value) AS sales_value,
        SUM(f.sales_quantity) AS sales_quantity
    FROM fact_sales f
    INNER JOIN dim_country c USING (country)
    GROUP BY f.country, c.country_label
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY sales_value DESC, country
    ) AS sales_value_rank,
    country,
    country_label,
    sales_value,
    sales_quantity,
    ROUND(
        100.0 * sales_value
        / NULLIF(SUM(sales_value) OVER (), 0),
        6
    ) AS sales_value_contribution_pct
FROM country_totals
ORDER BY sales_value_rank;

-- @step 60_analysis_monthly_sales.csv
-- Sales Value, Sales Quantity và tỷ trọng toàn kỳ thay đổi thế nào theo tháng?
WITH reporting_months AS (
    SELECT DISTINCT month_start
    FROM dim_date
),
monthly_metrics AS (
    SELECT
        d.month_start,
        SUM(f.sales_value) AS sales_value,
        SUM(f.sales_quantity) AS sales_quantity
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start
),
complete_months AS (
    SELECT
        m.month_start,
        COALESCE(x.sales_value, 0) AS sales_value,
        COALESCE(x.sales_quantity, 0) AS sales_quantity
    FROM reporting_months m
    LEFT JOIN monthly_metrics x USING (month_start)
),
with_previous AS (
    SELECT
        *,
        LAG(sales_value) OVER (
            ORDER BY month_start
        ) AS previous_month_sales_value,
        SUM(sales_value) OVER () AS reporting_period_sales_value
    FROM complete_months
)
SELECT
    month_start,
    sales_value,
    sales_quantity,
    ROUND(
        100.0 * sales_value
        / NULLIF(reporting_period_sales_value, 0),
        6
    ) AS reporting_period_contribution_pct,
    previous_month_sales_value,
    sales_value - previous_month_sales_value
        AS monthly_sales_value_change,
    ROUND(
        (sales_value - previous_month_sales_value)
        / NULLIF(previous_month_sales_value, 0),
        6
    ) AS monthly_sales_value_change_ratio
FROM with_previous
ORDER BY month_start;

-- @step 61_analysis_priority_product_summary.csv
-- Sản phẩm nào là trường hợp ưu tiên và có bối cảnh toàn kỳ thế nào?
WITH product_totals AS (
    SELECT
        stock_code,
        SUM(sales_value) AS sales_value,
        SUM(sales_quantity) AS sales_quantity
    FROM fact_sales
    GROUP BY stock_code
),
priority_product AS (
    SELECT *
    FROM product_totals
    ORDER BY sales_value DESC, stock_code
    LIMIT 1
),
monthly_product AS (
    SELECT
        f.stock_code,
        d.month_start,
        SUM(f.sales_value) AS sales_value
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    INNER JOIN priority_product p USING (stock_code)
    GROUP BY f.stock_code, d.month_start
),
peak_month AS (
    SELECT *
    FROM monthly_product
    ORDER BY sales_value DESC, month_start
    LIMIT 1
),
monthly_total AS (
    SELECT
        d.month_start,
        SUM(f.sales_value) AS sales_value
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start
),
invoice_context AS (
    SELECT
        a.product_key AS stock_code,
        COUNT(DISTINCT a.InvoiceNo) AS accepted_invoice_count,
        COUNT(DISTINCT a.CustomerID) FILTER (
            WHERE a.CustomerID IS NOT NULL
        ) AS identified_customer_count
    FROM accepted_sales_lines a
    INNER JOIN priority_product p
        ON a.product_key = p.stock_code
    WHERE a.transaction_date >= DATE '2010-12-01'
      AND a.transaction_date < DATE '2011-12-01'
    GROUP BY a.product_key
)
SELECT
    p.stock_code,
    d.product_description,
    p.sales_value,
    p.sales_quantity,
    ROUND(
        100.0 * p.sales_value
        / NULLIF((SELECT SUM(sales_value) FROM fact_sales), 0),
        6
    ) AS reporting_period_contribution_pct,
    (SELECT COUNT(*) FROM monthly_product) AS active_month_count,
    i.accepted_invoice_count,
    i.identified_customer_count,
    pm.month_start AS peak_month,
    pm.sales_value AS peak_month_sales_value,
    ROUND(
        100.0 * pm.sales_value
        / NULLIF(mt.sales_value, 0),
        6
    ) AS peak_month_product_contribution_pct
FROM priority_product p
INNER JOIN dim_product d USING (stock_code)
INNER JOIN invoice_context i USING (stock_code)
CROSS JOIN peak_month pm
INNER JOIN monthly_total mt USING (month_start);

-- @step 62_analysis_priority_product_monthly.csv
-- Sản phẩm ưu tiên có kết quả và mức đóng góp thế nào trong từng tháng lịch?
WITH product_totals AS (
    SELECT
        stock_code,
        SUM(sales_value) AS sales_value
    FROM fact_sales
    GROUP BY stock_code
),
priority_product AS (
    SELECT stock_code
    FROM product_totals
    ORDER BY sales_value DESC, stock_code
    LIMIT 1
),
reporting_months AS (
    SELECT DISTINCT month_start
    FROM dim_date
),
monthly_product AS (
    SELECT
        d.month_start,
        SUM(f.sales_value) AS sales_value,
        SUM(f.sales_quantity) AS sales_quantity
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    INNER JOIN priority_product p USING (stock_code)
    GROUP BY d.month_start
),
monthly_total AS (
    SELECT
        d.month_start,
        SUM(f.sales_value) AS sales_value
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    GROUP BY d.month_start
),
complete_months AS (
    SELECT
        m.month_start,
        COALESCE(p.sales_value, 0) AS sales_value,
        COALESCE(p.sales_quantity, 0) AS sales_quantity,
        t.sales_value AS total_month_sales_value
    FROM reporting_months m
    LEFT JOIN monthly_product p USING (month_start)
    INNER JOIN monthly_total t USING (month_start)
),
with_previous AS (
    SELECT
        *,
        LAG(sales_value) OVER (
            ORDER BY month_start
        ) AS previous_month_sales_value
    FROM complete_months
)
SELECT
    (SELECT stock_code FROM priority_product) AS stock_code,
    month_start,
    sales_value,
    sales_quantity,
    ROUND(
        100.0 * sales_value
        / NULLIF(total_month_sales_value, 0),
        6
    ) AS product_contribution_pct,
    previous_month_sales_value,
    sales_value - previous_month_sales_value
        AS monthly_sales_value_change,
    ROUND(
        (sales_value - previous_month_sales_value)
        / NULLIF(previous_month_sales_value, 0),
        6
    ) AS monthly_sales_value_change_ratio
FROM with_previous
ORDER BY month_start;

-- @step 63_analysis_priority_product_invoice_concentration.csv
-- Invoice nào đóng góp nhiều nhất trong tháng cao nhất của sản phẩm ưu tiên?
WITH product_totals AS (
    SELECT
        stock_code,
        SUM(sales_value) AS sales_value
    FROM fact_sales
    GROUP BY stock_code
),
priority_product AS (
    SELECT stock_code
    FROM product_totals
    ORDER BY sales_value DESC, stock_code
    LIMIT 1
),
priority_monthly AS (
    SELECT
        f.stock_code,
        d.month_start,
        SUM(f.sales_value) AS sales_value
    FROM fact_sales f
    INNER JOIN dim_date d
        ON f.transaction_date = d.calendar_date
    INNER JOIN priority_product p USING (stock_code)
    GROUP BY f.stock_code, d.month_start
),
priority_peak_month AS (
    SELECT *
    FROM priority_monthly
    ORDER BY sales_value DESC, month_start
    LIMIT 1
),
invoice_totals AS (
    SELECT
        a.product_key AS stock_code,
        a.InvoiceNo,
        MIN(a.transaction_date) AS transaction_date,
        MIN(a.Country) AS country,
        MIN(a.CustomerID) AS customer_id,
        SUM(a.sales_value) AS sales_value,
        SUM(a.Quantity) AS sales_quantity
    FROM accepted_sales_lines a
    INNER JOIN priority_product p
        ON a.product_key = p.stock_code
    INNER JOIN priority_peak_month m
        ON a.product_key = m.stock_code
       AND DATE_TRUNC('month', a.transaction_date)::DATE = m.month_start
    GROUP BY a.product_key, a.InvoiceNo
),
ranked AS (
    SELECT
        *,
        ROW_NUMBER() OVER (
            ORDER BY sales_value DESC, InvoiceNo
        ) AS invoice_peak_month_rank,
        SUM(sales_value) OVER () AS peak_month_product_sales_value
    FROM invoice_totals
)
SELECT
    'priority_product_peak_month' AS concentration_scope,
    invoice_peak_month_rank,
    r.stock_code,
    m.month_start AS priority_peak_month,
    r.InvoiceNo,
    r.transaction_date,
    r.country,
    r.customer_id,
    r.sales_value,
    r.sales_quantity,
    ROUND(
        100.0 * r.sales_value
        / NULLIF(r.peak_month_product_sales_value, 0),
        6
    ) AS peak_month_product_sales_value_contribution_pct,
    ROUND(
        100.0 * SUM(r.sales_value) OVER (
            ORDER BY invoice_peak_month_rank
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) / NULLIF(r.peak_month_product_sales_value, 0),
        6
    ) AS cumulative_peak_month_product_sales_value_contribution_pct,
    ROUND(
        100.0 * r.sales_value
        / NULLIF(p.sales_value, 0),
        6
    ) AS full_period_product_sales_value_contribution_pct
FROM ranked r
CROSS JOIN priority_peak_month m
INNER JOIN product_totals p
    ON r.stock_code = p.stock_code
WHERE invoice_peak_month_rank <= 20
ORDER BY invoice_peak_month_rank;

-- @step 64_analysis_priority_product_top_transactions.csv
-- Dòng giao dịch được chấp nhận nào lớn nhất đối với sản phẩm ưu tiên?
WITH product_totals AS (
    SELECT
        stock_code,
        SUM(sales_value) AS sales_value
    FROM fact_sales
    GROUP BY stock_code
),
priority_product AS (
    SELECT stock_code
    FROM product_totals
    ORDER BY sales_value DESC, stock_code
    LIMIT 1
)
SELECT
    ROW_NUMBER() OVER (
        ORDER BY a.sales_value DESC, a.source_row_number
    ) AS line_sales_value_rank,
    a.source_row_number,
    a.InvoiceNo,
    a.InvoiceDate,
    a.transaction_date,
    a.product_key AS stock_code,
    a.StockCode AS source_stock_code,
    a.Description,
    a.Quantity,
    a.UnitPrice,
    a.sales_value,
    a.CustomerID,
    a.Country
FROM accepted_sales_lines a
INNER JOIN priority_product p
    ON a.product_key = p.stock_code
WHERE a.transaction_date >= DATE '2010-12-01'
  AND a.transaction_date < DATE '2011-12-01'
ORDER BY a.sales_value DESC, a.source_row_number
LIMIT 20;
