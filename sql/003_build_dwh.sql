truncate table
    dwh.dim_order_type,
    dwh.dim_category,
    dwh.dim_dish,
    dwh.dim_modifier,
    dwh.fact_receipt_line,
    dwh.fact_receipt,
    dwh.fact_daily_plan_channel,
    dq.receipt_multi_accounting_date,
    dq.modifier_dish_lines
cascade;

insert into dwh.dim_order_type (order_type_id, order_type_name)
select
    'ot_' || substring(md5(order_type_name), 1, 16) as order_type_id,
    order_type_name
from (
    select distinct order_type_name
    from stg.sales_lines
    where order_type_name <> ''
) src;

insert into dwh.dim_category (category_id, category_name)
select
    'cat_' || substring(md5(category_name), 1, 16) as category_id,
    category_name
from (
    select distinct category_name
    from stg.sales_lines
    where category_name <> ''
) src;

insert into dwh.dim_dish (dish_id, dish_name, category_id)
select
    'dish_' || substring(md5(concat_ws('|', s.dish_name, c.category_id)), 1, 16) as dish_id,
    s.dish_name,
    c.category_id
from (
    select distinct dish_name, category_name
    from stg.sales_lines
    where dish_name <> ''
      and line_item_type = 'dish'
) s
left join dwh.dim_category c
    on c.category_name = s.category_name;

insert into dwh.dim_modifier (modifier_id, modifier_name, category_id)
select
    'mod_' || substring(md5(concat_ws('|', s.dish_name, c.category_id)), 1, 16) as modifier_id,
    s.dish_name as modifier_name,
    c.category_id
from (
    select distinct dish_name, category_name
    from stg.sales_lines
    where dish_name <> ''
      and line_item_type = 'modifier'
) s
left join dwh.dim_category c
    on c.category_name = s.category_name;

insert into dwh.fact_receipt_line (
    receipt_line_id,
    receipt_id,
    accounting_date,
    opened_at,
    closed_at,
    dish_id,
    modifier_id,
    category_id,
    order_type_id,
    dish_qty,
    guest_qty,
    net_amount,
    line_item_type,
    is_modifier,
    is_zero_amount,
    is_negative_amount,
    source_sheet,
    source_row_number
)
select
    s.receipt_line_id,
    replace(s.receipt_nk, 'rnk_', 'receipt_') as receipt_id,
    s.accounting_date,
    s.opened_at,
    s.closed_at,
    d.dish_id,
    m.modifier_id,
    c.category_id,
    ot.order_type_id,
    s.dish_qty,
    s.guest_qty,
    s.net_amount,
    s.line_item_type,
    s.is_modifier,
    s.net_amount = 0 as is_zero_amount,
    s.net_amount < 0 as is_negative_amount,
    s.source_sheet,
    s.source_row_number
from stg.sales_lines s
left join dwh.dim_category c
    on c.category_name = s.category_name
left join dwh.dim_dish d
    on d.dish_name = s.dish_name
   and d.category_id is not distinct from c.category_id
   and s.line_item_type = 'dish'
left join dwh.dim_modifier m
    on m.modifier_name = s.dish_name
   and m.category_id is not distinct from c.category_id
   and s.line_item_type = 'modifier'
left join dwh.dim_order_type ot
    on ot.order_type_name = s.order_type_name
where not s.exclude_from_marts;

insert into dwh.fact_receipt (
    receipt_id,
    accounting_date,
    opened_at,
    closed_at,
    order_type_id,
    guest_qty,
    total_dish_qty,
    total_net_amount,
    line_count
)
select
    receipt_id,
    max(accounting_date) as accounting_date,
    min(opened_at) as opened_at,
    max(closed_at) as closed_at,
    min(order_type_id) as order_type_id,
    max(guest_qty) as guest_qty,
    sum(dish_qty) as total_dish_qty,
    sum(net_amount) as total_net_amount,
    count(*) as line_count
from dwh.fact_receipt_line
group by receipt_id;

with plan_typed as (
    select
        case
            when accounting_date ~ '^\d{4}-\d{2}-\d{2}'
                then accounting_date::timestamp::date
            else null
        end as accounting_date,
        nullif(replace(trim(planned_total_amount), ',', '.'), '')::numeric as planned_total_amount,
        nullif(replace(trim(restaurant), ',', '.'), '')::numeric as restaurant,
        nullif(replace(trim(banquet_own), ',', '.'), '')::numeric as banquet_own,
        nullif(replace(trim(banquet_cb), ',', '.'), '')::numeric as banquet_cb,
        nullif(replace(trim(aggregator), ',', '.'), '')::numeric as aggregator,
        nullif(replace(trim(pickup), ',', '.'), '')::numeric as pickup,
        nullif(replace(trim(delivery), ',', '.'), '')::numeric as delivery
    from raw.daily_plan
),
plan_long as (
    select accounting_date, planned_total_amount, 'restaurant' as plan_channel, restaurant as planned_amount
    from plan_typed
    union all
    select accounting_date, planned_total_amount, 'banquet_own', banquet_own
    from plan_typed
    union all
    select accounting_date, planned_total_amount, 'banquet_cb', banquet_cb
    from plan_typed
    union all
    select accounting_date, planned_total_amount, 'aggregator', aggregator
    from plan_typed
    union all
    select accounting_date, planned_total_amount, 'pickup', pickup
    from plan_typed
    union all
    select accounting_date, planned_total_amount, 'delivery', delivery
    from plan_typed
)
insert into dwh.fact_daily_plan_channel (
    plan_id,
    accounting_date,
    plan_channel,
    planned_amount,
    planned_total_amount
)
select
    'plan_' || substring(md5(concat_ws('|', accounting_date, plan_channel)), 1, 16) as plan_id,
    accounting_date,
    plan_channel,
    planned_amount,
    planned_total_amount
from plan_long
where accounting_date is not null;

insert into dq.receipt_multi_accounting_date (
    receipt_id,
    receipt_number,
    accounting_date,
    opened_at,
    closed_at,
    dish_name,
    dish_qty,
    guest_qty,
    net_amount,
    exclude_from_marts,
    dq_issue,
    source_sheet,
    source_row_number
)
select
    replace(receipt_nk, 'rnk_', 'receipt_') as receipt_id,
    receipt_number,
    accounting_date,
    opened_at,
    closed_at,
    dish_name,
    dish_qty,
    guest_qty,
    net_amount,
    exclude_from_marts,
    dq_issue,
    source_sheet,
    source_row_number
from stg.sales_lines
where accounting_dates_count > 1;

insert into dq.modifier_dish_lines (
    receipt_id,
    receipt_number,
    accounting_date,
    opened_at,
    dish_name,
    category_name,
    dish_qty,
    net_amount,
    source_sheet,
    source_row_number
)
select
    replace(receipt_nk, 'rnk_', 'receipt_') as receipt_id,
    receipt_number,
    accounting_date,
    opened_at,
    dish_name,
    category_name,
    dish_qty,
    net_amount,
    source_sheet,
    source_row_number
from stg.sales_lines
where is_modifier;
