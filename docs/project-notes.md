# Project notes

Nội dung dưới đây được AI hỗ trợ ghi chú và tóm tắt từ các quy tắc, quyết định và kết quả đã được thực hiện trong dự án.

- UnitPrice column type chuyển từ DOUBLE sang DECIMAL mặc định (18,3).
- InvoiceNo, StockCode và CustomerID dùng VARCHAR; Quantity dùng BIGINT; InvoiceDate dùng TIMESTAMP.
- Description thiếu, rỗng hoặc chỉ có khoảng trắng chuyển sang NULL.
- CustomerID thiếu chuyển sang NULL; không loại dòng vì thiếu Description hoặc CustomerID.
- TRIM InvoiceNo, StockCode, Description, CustomerID và Country khi tạo TABLE sạch; chỉ bỏ khoảng trắng đầu/cuối.
- InvoiceNo không bắt đầu bằng C sau UPPER/TRIM, kết hợp Quantity < 0, gắn nhãn non_c_negative_quantity.
- UnitPrice = 0 gắn nhãn zero_unit_price.
- UnitPrice < 0 gắn nhãn accounting_adjustment; chưa khẳng định bản chất kế toán.
- Tạo ba column BOOLEAN ở cuối cho các nhãn trên; gắn độc lập, giữ dòng mang nhãn.
- Loại dòng giống hệt nhau trên tám column nguồn trước chuyển kiểu.
- Giữ dòng đầu theo source_row_number và giữ raw để truy vết. Loại trùng là giả định xử lý.

## Time coverage audit

- `clean_transactions` không thiếu `InvoiceDate`; khoảng quan sát từ `2010-12-01 08:26:00` đến `2011-12-09 12:50:00`. [SQL](../sql/03_business_audit.sql), [overview](../outputs/evidence/16_time_coverage_overview.csv)
- Ngày không có giao dịch chủ yếu rơi vào thứ Bảy hoặc các cụm nghỉ ngắn; không mặc định coi là dữ liệu thiếu. [Dates without transactions](../outputs/evidence/18_dates_without_transactions.csv)
- Kỳ báo cáo từ `2010-12-01` đến hết `2011-11-30`. [Monthly coverage](../outputs/evidence/17_monthly_time_coverage.csv)
- Tháng `2011-12` không nằm trong reporting fact, dimensions và metrics vì nguồn kết thúc ở ngày 9.
- Các dòng tháng `2011-12` vẫn được giữ trong clean và sales-population evidence để truy vết.

## Identifier audit

- Regex chỉ mô tả định dạng identifier, không dùng để loại dòng. [Format summary](../outputs/evidence/19_identifier_format_summary.csv), [other values](../outputs/evidence/20_identifier_other_values.csv)
- Các `InvoiceNo` dạng `A...` và nhiều `StockCode` khác mẫu vẫn có ngữ cảnh nghiệp vụ rõ ràng.
- Case collision chỉ xuất hiện ở `StockCode`; các biến thể hoa/thường cùng chỉ một sản phẩm. [Case collisions](../outputs/evidence/21_identifier_case_collisions.csv), [case variant context](../outputs/evidence/22_stock_code_case_variant_context.csv)
- Product key dùng `UPPER(StockCode)`; accepted sales giữ `StockCode` gốc để truy vết. [Reporting model SQL](../sql/04_reporting_model.sql)
- `InvoiceNo` nhất quán về `CustomerID` và `Country`. [Invoice consistency](../outputs/evidence/23_invoice_identifier_consistency.csv)
- Có 43 invoice mang hai timestamp trong cùng ngày, cách nhau một phút. Giữ timestamp của từng dòng và dùng ngày của dòng cho reporting grain. [Timestamp pattern](../outputs/evidence/24_invoice_timestamp_pattern.csv)
- Quy tắc chọn Description và phân loại mã phi hàng hóa nằm trong product-code audit.
- Không loại dòng chỉ vì Description là ghi chú vận hành hoặc bị thiếu. [SQL](../sql/03_business_audit.sql)

## Sales eligibility and magnitude audit

- Sales candidate gồm InvoiceNo không C-prefixed, Quantity dương và UnitPrice dương. [Eligibility summary](../outputs/evidence/25_sales_eligibility_summary.csv)
- C-prefixed, Quantity không dương hoặc UnitPrice không dương nằm ngoài sales population.
- Các dòng có absolute line value lớn nhất gồm cặp bán–hủy đối ứng và các khoản phí hoặc điều chỉnh. [Unusual magnitudes](../outputs/evidence/26_unusual_line_magnitudes.csv)
- Không loại dòng chỉ vì độ lớn. Sales Value giữ dòng bán được chấp nhận và không net dòng hủy.

## Product code and description audit

- StockCode khác định dạng thông thường gồm cả hàng hóa và mã vận hành; không dùng định dạng để loại dòng. [Nonstandard candidates](../outputs/evidence/27_nonstandard_sales_candidate_codes.csv)
- Giữ các mã hàng hóa `DCGS...`, `DCGSSBOY`, `DCGSSGIRL` và `PADS`.
- Description trong bảng sạch có thể là tên sản phẩm hoặc ghi chú vận hành. [Relationship summary](../outputs/evidence/28_stock_code_description_summary.csv), [all-line examples](../outputs/evidence/29_stock_codes_with_multiple_descriptions.csv)
- Description của sales candidates chủ yếu khác nhau do đổi tên hoặc cách viết. [Sales-candidate variants](../outputs/evidence/30_sales_candidate_description_variants.csv)
- Product label dùng Description không NULL xuất hiện nhiều nhất; tie-break theo `last_seen` gần nhất rồi thứ tự chữ cái. [Frequency context](../outputs/evidence/31_sales_candidate_description_frequency.csv), [frequency ties](../outputs/evidence/32_top_description_frequency_ties.csv), [tie context](../outputs/evidence/33_top_description_tie_context.csv)
- Không có StockCode nào trong sales candidates thiếu toàn bộ Description. [Missing-description check](../outputs/evidence/34_sales_candidate_codes_without_description.csv)
- Giữ các dòng riêng lẻ thiếu Description.
- Product key dùng `UPPER(StockCode)`; accepted sales giữ StockCode gốc để truy vết.
- Loại `AMAZONFEE`, `B`, `BANK CHARGES`, `C2`, `DOT`, `M`, `POST`, `S` và `GIFT_%` khỏi product sales.
- Các mã bị loại đại diện phí, điều chỉnh, vận chuyển, sample hoặc voucher. [Possible non-merchandise codes](../outputs/evidence/35_possible_non_merchandise_sales_candidates.csv)
- Mã `M` có nhiều mức giá, lượng và cả dòng bán/hủy; không dùng làm product key ổn định. [Manual context](../outputs/evidence/36_manual_code_context.csv)

## Accepted sales population decision

- Mỗi dòng clean nhận đúng một trạng thái theo thứ tự ưu tiên; các lý do loại không đếm chồng.
- Toàn bộ 536641 dòng clean đã được phân loại; 522540 dòng được chấp nhận. [SQL](../sql/03_business_audit.sql), [decision summary](../outputs/evidence/37_sales_population_decision_summary.csv)
- Population evidence bao phủ toàn bộ nguồn.
- Reporting period chỉ được áp dụng khi tạo reporting model.

## Dimension keys and labels decision

- Product dimension chỉ dùng product key và accepted sales trong kỳ báo cáo.
- Tháng `2011-12` không nằm trong fact và dimensions.
- Product label dùng quy tắc tần suất, `last_seen` và thứ tự chữ cái đã chốt. [Reporting model SQL](../sql/04_reporting_model.sql)
- Country key và label dùng trực tiếp Country đã TRIM; audit không ghi nhận giá trị thiếu hoặc case variant cho cùng một key. [Country candidates](../outputs/evidence/38_country_dimension_candidates.csv)
- Giữ `European Community`, `Unspecified` và các nhãn Country khác như nguồn; không coi đây là danh mục quốc gia đã chuẩn hóa. [Reporting model SQL](../sql/04_reporting_model.sql)
- Date dimension giữ lịch liên tục trong kỳ báo cáo với `calendar_date`, `year_number`, `month_number` và `month_start`.
- `month_start` là ngày đầu tháng, dùng làm trục thời gian; nhãn tháng được định dạng trực tiếp trong Power BI. [Reporting model SQL](../sql/04_reporting_model.sql)
- Product, Country và Date dimensions kết nối một-nhiều với `fact_sales`; mỗi dimension lọc `fact_sales` theo một chiều.
- `accepted_sales_lines` chỉ nằm trong DuckDB để truy vết; không đưa hai fact-like tables vào cùng reporting model.

## Metrics and time basis decision

- Metrics dùng accepted sales trong reporting period và thời gian ghi nhận của từng dòng. [Validation SQL](../sql/05_validate_metrics_model.sql)
- Zero biểu diễn filter context hợp lệ không có accepted sales.
- Undefined áp dụng khi contribution có tổng bằng zero, tháng không có kỳ trước trong phạm vi, hoặc change ratio có giá trị tháng trước bằng zero.
- So sánh dùng tháng lịch liền trước, kể cả khi tháng đó không có giao dịch.

## Model validation

- Sales-population statuses đối chiếu đủ toàn bộ clean. [Population reconciliation](../outputs/evidence/50_sales_population_reconciliation.csv)
- Accepted-sales membership khớp các quy tắc đã chốt. [Validation SQL](../sql/05_validate_metrics_model.sql), [membership](../outputs/evidence/51_accepted_sales_membership.csv)
- Sales Value và Sales Quantity khớp từ accepted sales sang fact ở total, date, product và country. [Metric reconciliation](../outputs/evidence/52_metric_reconciliation.csv)
- Fact grain, dimension keys, key coverage và joins không ghi nhận lỗi. [Model integrity](../outputs/evidence/53_model_integrity_validation.csv)
- Contribution denominator, selected filter scope và zero denominator vượt kiểm chứng. [Contribution validation](../outputs/evidence/54_contribution_validation.csv)
- Chuỗi tháng và monthly-comparison logic vượt kiểm chứng. [Month sequence](../outputs/evidence/55_month_sequence_validation.csv), [monthly logic test](../outputs/evidence/56_monthly_comparison_logic_test.csv)
- Monthly-comparison test dùng dữ liệu giả lập nhỏ để kiểm chứng logic, không phải bằng chứng kinh doanh.

## Business analysis

- `22423 · REGENCY CAKESTAND 3 TIER` là priority case theo rule Sales Value cao nhất toàn kỳ; tie-break bằng `stock_code` tăng dần. [Analysis SQL](../sql/06_business_analysis.sql), [priority summary](../outputs/evidence/61_analysis_priority_product_summary.csv)
- Sản phẩm ghi nhận `£168,162.420`, `13,402` units và `1.745740%` Sales Value.
- Đây là tín hiệu ưu tiên mô tả, không phải bằng chứng về margin hoặc nguyên nhân nhu cầu.
- Sản phẩm xuất hiện trong cả 12 tháng; peak month là December 2010 với `£27,694.760`. [Monthly evidence](../outputs/evidence/62_analysis_priority_product_monthly.csv)
- December 2010 là tháng đầu reporting period nên không có tháng lịch liền trước trong model để so sánh like-for-like.
- Năm invoices lớn nhất chiếm `33.249575%` Sales Value của sản phẩm trong peak month. [Invoice concentration](../outputs/evidence/63_analysis_priority_product_invoice_concentration.csv)
- Hai invoices trong nhóm thiếu CustomerID. [Top transaction lines](../outputs/evidence/64_analysis_priority_product_top_transactions.csv)
- Cần xác minh order status, fulfilment, customer, unit price, quantity và product master trước khi thay đổi pricing, inventory hoặc campaign.

## Power BI report

- Report một trang gồm Month range, Product và Country slicers; hai KPI cards; monthly trend; Top-10 product/country bars; product comparison; month-over-month change chart.
- File báo cáo được lưu tại [Power BI report](../powerbi/SalesPerformance.pbix); ảnh preview được lưu tại [dashboard image](../outputs/previews/SalesPerformance.png).
