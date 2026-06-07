create schema if not exists mart;

drop table if exists mart.daily_plan_fact;

create table mart.daily_plan_fact (
    accounting_date date not null,
    planned_total_amount numeric,
    fact_amount numeric,
    plan_fact_delta numeric,
    plan_completion_rate numeric,
    receipt_count bigint,
    primary key (accounting_date)
) partition by range (accounting_date);

create table mart.daily_plan_fact_2025_02
    partition of mart.daily_plan_fact
    for values from ('2025-02-01') to ('2025-03-01');

create table mart.daily_plan_fact_2025_03
    partition of mart.daily_plan_fact
    for values from ('2025-03-01') to ('2025-04-01');

create table mart.daily_plan_fact_2026_02
    partition of mart.daily_plan_fact
    for values from ('2026-02-01') to ('2026-03-01');

create table mart.daily_plan_fact_default
    partition of mart.daily_plan_fact default;

insert into mart.daily_plan_fact (
    accounting_date,
    planned_total_amount,
    fact_amount,
    plan_fact_delta,
    plan_completion_rate,
    receipt_count
)
with fact_daily as (
    select
        accounting_date,
        sum(net_amount) as fact_amount,
        count(distinct receipt_id) as receipt_count,
        max(guest_qty) as max_guest_qty_in_receipt_lines
    from dwh.fact_receipt_line
    group by accounting_date
),
plan_daily as (
    select
        accounting_date,
        max(planned_total_amount) as planned_total_amount
    from dwh.fact_daily_plan_channel
    group by accounting_date
)
select
    coalesce(p.accounting_date, f.accounting_date) as accounting_date,
    p.planned_total_amount,
    f.fact_amount,
    f.fact_amount - p.planned_total_amount as plan_fact_delta,
    case
        when p.planned_total_amount = 0 then null
        else f.fact_amount / p.planned_total_amount
    end as plan_completion_rate,
    f.receipt_count
from plan_daily p
full join fact_daily f using (accounting_date);

comment on table mart.daily_plan_fact is
    'Daily analytical mart comparing planned sales amount with actual sales amount by accounting date. Missing plan values mean that no plan was provided for that date in the source data.';

create index idx_daily_plan_fact_accounting_date on mart.daily_plan_fact (accounting_date);
