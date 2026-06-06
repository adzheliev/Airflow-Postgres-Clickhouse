drop schema if exists dq cascade;
drop schema if exists dwh cascade;
drop schema if exists stg cascade;
drop schema if exists raw cascade;
drop schema if exists mart cascade;

create schema raw;
create schema stg;
create schema dwh;
create schema dq;

create table raw.sales_lines (
    source_sheet text not null,
    source_year int not null,
    source_row_number int not null,
    accounting_date text,
    receipt_number text,
    opened_at text,
    opened_hour text,
    closed_at text,
    closed_hour text,
    dish_name text,
    category_name text,
    order_type_name text,
    dish_qty text,
    guest_qty text,
    net_amount text,
    loaded_at timestamptz not null default now()
);

comment on table raw.sales_lines is
    'Raw immutable sales receipt lines loaded from Excel-derived CSV files. All source attributes are stored as text to preserve the original input before validation and typing.';

create table raw.daily_plan (
    source_row_number int not null,
    accounting_date text,
    planned_total_amount text,
    restaurant text,
    banquet_own text,
    banquet_cb text,
    aggregator text,
    pickup text,
    delivery text,
    avg_check_restaurant text,
    avg_check_delivery text,
    avg_guest_restaurant text,
    avg_guest_delivery text,
    avg_guest_banquet text,
    loaded_at timestamptz not null default now()
);

comment on table raw.daily_plan is
    'Raw daily plan data loaded from the Excel plan sheet. Values are stored as text because this layer represents the source file without business transformations.';

create table stg.sales_lines (
    receipt_line_id text primary key,
    receipt_nk text not null,
    source_sheet text not null,
    source_year int not null,
    source_row_number int not null,
    accounting_date date,
    receipt_number bigint,
    opened_at timestamp,
    opened_hour int,
    closed_at timestamp,
    closed_hour int,
    dish_name text,
    category_name text,
    order_type_name text,
    dish_qty numeric(14, 4),
    guest_qty numeric(14, 4),
    net_amount numeric(14, 4),
    line_item_type text not null,
    is_modifier boolean not null default false,
    accounting_dates_count int,
    exclude_from_marts boolean not null default false,
    dq_issue text
);

comment on table stg.sales_lines is
    'Typed and standardized sales receipt lines with deterministic technical keys, line item classification, duplicate-date diagnostics, and flags for rows excluded from analytical marts.';

create table dwh.dim_order_type (
    order_type_id text primary key,
    order_type_name text not null unique
);

comment on table dwh.dim_order_type is
    'Order type dimension containing distinct sales channels or service formats from receipt lines.';

create table dwh.dim_category (
    category_id text primary key,
    category_name text not null unique
);

comment on table dwh.dim_category is
    'Dish category dimension containing distinct menu category names from receipt lines.';

create table dwh.dim_dish (
    dish_id text primary key,
    dish_name text not null,
    category_id text references dwh.dim_category(category_id),
    unique (dish_name, category_id)
);

comment on table dwh.dim_dish is
    'Dish dimension containing unique dish names scoped by category. This table is used to analyze sales at menu item granularity.';

create table dwh.dim_modifier (
    modifier_id text primary key,
    modifier_name text not null,
    category_id text references dwh.dim_category(category_id),
    unique (modifier_name, category_id)
);

comment on table dwh.dim_modifier is
    'Modifier dimension containing source lines that describe dish options, add-ons, preparation variants, or service modifiers rather than standalone menu dishes.';

create table dwh.fact_receipt_line (
    receipt_line_id text primary key,
    receipt_id text not null,
    accounting_date date,
    opened_at timestamp,
    closed_at timestamp,
    dish_id text references dwh.dim_dish(dish_id),
    modifier_id text references dwh.dim_modifier(modifier_id),
    category_id text references dwh.dim_category(category_id),
    order_type_id text references dwh.dim_order_type(order_type_id),
    dish_qty numeric(14, 4),
    guest_qty numeric(14, 4),
    net_amount numeric(14, 4),
    line_item_type text not null,
    is_modifier boolean not null,
    is_zero_amount boolean not null,
    is_negative_amount boolean not null,
    source_sheet text not null,
    source_row_number int not null
);

comment on table dwh.fact_receipt_line is
    'Receipt line fact table at source line grain. Contains cleaned transactional measures, line item classification, and links to dish, modifier, category, and order type dimensions.';

create table dwh.fact_receipt (
    receipt_id text primary key,
    accounting_date date,
    opened_at timestamp,
    closed_at timestamp,
    order_type_id text references dwh.dim_order_type(order_type_id),
    guest_qty numeric(14, 4),
    total_dish_qty numeric(14, 4),
    total_net_amount numeric(14, 4),
    line_count int
);

comment on table dwh.fact_receipt is
    'Receipt header fact table at one row per receipt grain. Measures are aggregated from receipt lines after data quality exclusions.';

create table dwh.fact_daily_plan_channel (
    plan_id text primary key,
    accounting_date date not null,
    plan_channel text not null,
    planned_amount numeric(14, 4),
    planned_total_amount numeric(14, 4),
    unique (accounting_date, plan_channel)
);

comment on table dwh.fact_daily_plan_channel is
    'Daily plan fact table at accounting date and plan channel grain. The table normalizes the wide Excel plan sheet into an analytical structure.';

create table dq.receipt_multi_accounting_date (
    receipt_id text,
    receipt_number bigint,
    accounting_date date,
    opened_at timestamp,
    closed_at timestamp,
    dish_name text,
    dish_qty numeric(14, 4),
    guest_qty numeric(14, 4),
    net_amount numeric(14, 4),
    exclude_from_marts boolean,
    dq_issue text,
    source_sheet text,
    source_row_number int
);

comment on table dq.receipt_multi_accounting_date is
    'Detailed data quality table with receipt lines whose receipt identifier appears on more than one accounting date.';

create table dq.modifier_dish_lines (
    receipt_id text,
    receipt_number bigint,
    accounting_date date,
    opened_at timestamp,
    dish_name text,
    category_name text,
    dish_qty numeric(14, 4),
    net_amount numeric(14, 4),
    source_sheet text,
    source_row_number int
);

comment on table dq.modifier_dish_lines is
    'Detailed data quality table with source lines that look like menu modifiers rather than standalone dishes.';

create table dq.check_results (
    check_name text primary key,
    severity text not null,
    failed_rows int not null,
    comment text,
    checked_at timestamptz not null default now()
);

comment on table dq.check_results is
    'Data quality check summary table. Each row stores one named validation, severity, failed row count, and execution timestamp.';
