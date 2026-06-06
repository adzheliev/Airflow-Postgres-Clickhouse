truncate table dq.check_results;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'sales_rows_outside_expected_month',
    'warning',
    count(*),
    'Rows from February fact sheets where accounting_date is not in February of source_year.'
from stg.sales_lines
where extract(month from accounting_date) <> 2
   or extract(year from accounting_date) <> source_year;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'multi_accounting_date_receipts',
    'warning',
    count(distinct receipt_nk),
    'Receipt natural keys having more than one accounting_date.'
from stg.sales_lines
where accounting_dates_count > 1;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'negative_amount_rows',
    'info',
    count(*),
    'Negative net_amount rows, mostly technical rounding rows.'
from stg.sales_lines
where net_amount < 0;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'modifier_lines_in_dish_source_field',
    'warning',
    count(*),
    'Rows where the source dish field contains a modifier rather than a standalone dish.'
from stg.sales_lines
where is_modifier;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'classified_non_dish_line_items',
    'info',
    count(*),
    'Rows classified as modifier, promotion, staff, service charge, or marketing instead of regular dish sales.'
from stg.sales_lines
where line_item_type <> 'dish';

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'closed_before_opened',
    'error',
    count(*),
    'Rows where closed_at is earlier than opened_at.'
from stg.sales_lines
where closed_at < opened_at;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'opened_hour_mismatch',
    'error',
    count(*),
    'Rows where opened_hour does not match opened_at hour.'
from stg.sales_lines
where extract(hour from opened_at) <> opened_hour;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'closed_hour_mismatch',
    'error',
    count(*),
    'Rows where closed_hour does not match closed_at hour.'
from stg.sales_lines
where extract(hour from closed_at) <> closed_hour;

insert into dq.check_results (check_name, severity, failed_rows, comment)
select
    'excluded_zero_versions',
    'info',
    count(*),
    'Zero technical versions excluded from analytical facts.'
from stg.sales_lines
where exclude_from_marts;
