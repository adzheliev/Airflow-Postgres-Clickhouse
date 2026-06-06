from __future__ import annotations

from datetime import datetime
from typing import Any

import pandas as pd
from airflow.decorators import dag, task
from airflow.hooks.base import BaseHook
from airflow.providers.postgres.hooks.postgres import PostgresHook


POSTGRES_CONN_ID = "italy_postgres_connection"
CLICKHOUSE_CONN_ID = "italy_clickhouse_connection"

DAG_DESCRIPTION = """
# Italy ClickHouse mart publishing

This DAG publishes analytical marts from PostgreSQL to ClickHouse.

The PostgreSQL DWH remains the system of record for modeled data. ClickHouse is
used as a serving layer for fast analytical reads and dashboard-oriented access.

The DAG reads the `mart.daily_plan_fact` mart from PostgreSQL and replaces the
corresponding ClickHouse table in an idempotent way.
"""


def clickhouse_client() -> Any:
    """Create a ClickHouse client from the configured Airflow Connection.

    Returns:
        A clickhouse-connect client bound to the target ClickHouse database.
    """
    import clickhouse_connect

    conn = BaseHook.get_connection(CLICKHOUSE_CONN_ID)
    return clickhouse_connect.get_client(
        host=conn.host,
        port=conn.port or 8123,
        username=conn.login,
        password=conn.password,
        database=conn.schema or "default",
    )


@dag(
    dag_id="italy_publish_marts_to_clickhouse",
    start_date=datetime(2026, 2, 1),
    schedule=None,
    catchup=False,
    tags=["italy", "clickhouse", "mart"],
)
def italy_publish_marts_to_clickhouse() -> None:
    """Define the Airflow DAG that publishes marts to ClickHouse."""
    @task
    def create_clickhouse_tables() -> None:
        """Create ClickHouse serving tables if they do not exist."""
        client = clickhouse_client()
        client.command(
            """
            create table if not exists daily_plan_fact (
                accounting_date Date,
                planned_total_amount Nullable(Float64),
                fact_amount Nullable(Float64),
                plan_fact_delta Nullable(Float64),
                plan_completion_rate Nullable(Float64),
                receipt_count Nullable(Int64),
                loaded_at DateTime default now()
            )
            engine = ReplacingMergeTree(loaded_at)
            order by accounting_date
            comment 'Daily plan versus actual sales mart published from PostgreSQL for analytical reads.'
            """
        )

    @task
    def publish_daily_plan_fact() -> None:
        """Replace the ClickHouse daily plan fact table with PostgreSQL mart data."""
        postgres = PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)
        frame = postgres.get_pandas_df(
            """
            select
                accounting_date,
                planned_total_amount::float8 as planned_total_amount,
                fact_amount::float8 as fact_amount,
                plan_fact_delta::float8 as plan_fact_delta,
                plan_completion_rate::float8 as plan_completion_rate,
                receipt_count::bigint as receipt_count
            from mart.daily_plan_fact
            order by accounting_date
            """
        )

        frame["accounting_date"] = pd.to_datetime(frame["accounting_date"]).dt.date
        frame = frame.astype(object).where(pd.notna(frame), None)

        client = clickhouse_client()
        client.command("truncate table daily_plan_fact")
        client.insert_df("daily_plan_fact", frame)
        print(f"Published {len(frame)} rows to ClickHouse daily_plan_fact")

    create_clickhouse_tables() >> publish_daily_plan_fact()


italy_publish_marts_to_clickhouse_dag = italy_publish_marts_to_clickhouse()
italy_publish_marts_to_clickhouse_dag.doc_md = DAG_DESCRIPTION
