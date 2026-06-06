truncate table stg.sales_lines;

with typed_sales as (
    select
        source_sheet,
        source_year,
        source_row_number,
        case
            when accounting_date ~ '^\d{4}-\d{2}-\d{2}'
                then accounting_date::timestamp::date
            else null
        end as accounting_date,
        nullif(trim(receipt_number), '')::bigint as receipt_number,
        case
            when opened_at ~ '^\d{4}-\d{2}-\d{2}'
                then opened_at::timestamp
            else null
        end as opened_at,
        nullif(trim(opened_hour), '')::int as opened_hour,
        case
            when closed_at ~ '^\d{4}-\d{2}-\d{2}'
                then closed_at::timestamp
            else null
        end as closed_at,
        nullif(trim(closed_hour), '')::int as closed_hour,
        trim(coalesce(dish_name, '')) as dish_name,
        trim(coalesce(category_name, '')) as category_name,
        trim(coalesce(order_type_name, '')) as order_type_name,
        coalesce(nullif(replace(trim(dish_qty), ',', '.'), '')::numeric, 0) as dish_qty,
        coalesce(nullif(replace(trim(guest_qty), ',', '.'), '')::numeric, 0) as guest_qty,
        coalesce(nullif(replace(trim(net_amount), ',', '.'), '')::numeric, 0) as net_amount,
        case
            when upper(trim(coalesce(category_name, ''))) = 'НАДБАВКА ЗА ОБСЛУЖИВАНИЕ'
                then 'service_charge'
            when upper(trim(coalesce(category_name, ''))) = 'АКЦИИ/ПОДАРКИ'
                then 'promotion'
            when upper(trim(coalesce(category_name, ''))) = 'СТАФФ'
                then 'staff'
            when upper(trim(coalesce(category_name, ''))) = 'МАРКЕТИНГ'
                then 'marketing'
            when trim(coalesce(dish_name, '')) ~ '^\s*-'
              or upper(trim(coalesce(category_name, ''))) in ('МОДИФИКАТОРЫ', 'ДОПЫ')
                then 'modifier'
            else 'dish'
        end as line_item_type,
        (
            trim(coalesce(dish_name, '')) ~ '^\s*-'
            or upper(trim(coalesce(category_name, ''))) in ('МОДИФИКАТОРЫ', 'ДОПЫ')
        ) as is_modifier
    from raw.sales_lines
),
keyed_sales as (
    select
        'rnk_' || substring(
            md5(concat_ws('|', source_year, receipt_number, coalesce(opened_at::text, ''))),
            1,
            16
        ) as receipt_nk,
        'rl_' || substring(
            md5(concat_ws('|', source_sheet, source_row_number, receipt_number, dish_name)),
            1,
            16
        ) as receipt_line_id,
        *
    from typed_sales
),
receipt_versions as (
    select
        receipt_nk,
        accounting_date,
        sum(net_amount) as version_amount,
        sum(dish_qty) as version_qty
    from keyed_sales
    group by receipt_nk, accounting_date
),
receipt_stats as (
    select
        receipt_nk,
        count(distinct accounting_date) as accounting_dates_count,
        bool_or(version_amount <> 0) as has_nonzero_version
    from receipt_versions
    group by receipt_nk
),
version_flags as (
    select
        rv.receipt_nk,
        rv.accounting_date,
        rs.accounting_dates_count,
        (
            rs.accounting_dates_count > 1
            and rs.has_nonzero_version
            and rv.version_amount = 0
            and rv.version_qty = 0
        ) as exclude_from_marts
    from receipt_versions rv
    join receipt_stats rs using (receipt_nk)
)
insert into stg.sales_lines (
    receipt_line_id,
    receipt_nk,
    source_sheet,
    source_year,
    source_row_number,
    accounting_date,
    receipt_number,
    opened_at,
    opened_hour,
    closed_at,
    closed_hour,
    dish_name,
    category_name,
    order_type_name,
    dish_qty,
    guest_qty,
    net_amount,
    line_item_type,
    is_modifier,
    accounting_dates_count,
    exclude_from_marts,
    dq_issue
)
select
    ks.receipt_line_id,
    ks.receipt_nk,
    ks.source_sheet,
    ks.source_year,
    ks.source_row_number,
    ks.accounting_date,
    ks.receipt_number,
    ks.opened_at,
    ks.opened_hour,
    ks.closed_at,
    ks.closed_hour,
    ks.dish_name,
    ks.category_name,
    ks.order_type_name,
    ks.dish_qty,
    ks.guest_qty,
    ks.net_amount,
    ks.line_item_type,
    ks.is_modifier,
    vf.accounting_dates_count,
    vf.exclude_from_marts,
    case
        when vf.exclude_from_marts then 'multi_accounting_date_zero_version'
        else ''
    end as dq_issue
from keyed_sales ks
join version_flags vf
    on vf.receipt_nk = ks.receipt_nk
   and vf.accounting_date is not distinct from ks.accounting_date;
