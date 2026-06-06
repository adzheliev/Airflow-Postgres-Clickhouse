from __future__ import annotations

import csv
from datetime import datetime
from io import StringIO
from pathlib import Path
from typing import Any

import pandas as pd
from airflow.decorators import dag, task
from airflow.models import Variable
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.providers.postgres.hooks.postgres import PostgresHook


POSTGRES_CONN_ID = "italy_postgres_connection"
CLICKHOUSE_DAG_ID = "italy_publish_marts_to_clickhouse"
DATA_DIR = Path(Variable.get("italy_data_dir", default_var="/opt/airflow/data"))
SQL_DIR = Path(Variable.get("italy_sql_dir", default_var="/opt/airflow/sql"))
INPUT_XLSX = Path(
    Variable.get(
        "italy_input_xlsx",
        default_var="/opt/airflow/data/input/Тестовое задание data инженер italy.xlsx",
    )
)
LANDING_DIR = Path(Variable.get("italy_landing_dir", default_var=str(DATA_DIR / "landing")))

DAG_DESCRIPTION = """
# Italy DWH pipeline

This DAG builds a small analytical warehouse for the Italy restaurant test task.

Pipeline stages:

1. Extract source Excel sheets into reproducible CSV landing files.
2. Load CSV files into the raw PostgreSQL layer without business transformations.
3. Build typed staging tables and mark data quality issues.
4. Build the DWH star schema dimensions and facts.
5. Run data quality checks and persist check results.
6. Build PostgreSQL marts and trigger the ClickHouse publishing DAG.

The DAG intentionally keeps source ingestion in Python and business transformations
in SQL, so the transformation rules remain explicit and reviewable.
"""

SALES_SHEETS = {
    "факт 02 2026": ("sales_fact_2026_02.csv", 2026),
    "факт 02 2025": ("sales_fact_2025_02.csv", 2025),
}

SALES_RENAME = {
    "Учетный день": "accounting_date",
    "Номер чека": "receipt_number",
    "Время открытия": "opened_at",
    "Час открытия": "opened_hour",
    "Время закрытия": "closed_at",
    "Час закрытия": "closed_hour",
    "Блюдо": "dish_name",
    "Категория блюда": "category_name",
    "Тип заказа": "order_type_name",
    "Количество блюд": "dish_qty",
    "Количество гостей": "guest_qty",
    "Сумма со скидкой, р.": "net_amount",
}


def postgres_hook() -> PostgresHook:
    """Return the PostgreSQL hook configured through an Airflow Connection."""
    return PostgresHook(postgres_conn_id=POSTGRES_CONN_ID)


def write_csv(frame: pd.DataFrame, path: Path) -> None:
    """Write a DataFrame to a CSV landing file.

    Args:
        frame: Source DataFrame to persist.
        path: Destination CSV file path.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    frame.to_csv(path, index=False, quoting=csv.QUOTE_MINIMAL)


def copy_frame(conn: Any, table_name: str, frame: pd.DataFrame) -> None:
    """Copy a DataFrame into PostgreSQL using the native COPY protocol.

    Args:
        conn: Open psycopg2 connection.
        table_name: Fully qualified target table name.
        frame: DataFrame with columns matching the target table column order.
    """
    buffer = StringIO()
    frame.to_csv(buffer, index=False, header=False, na_rep="")
    buffer.seek(0)
    columns = ", ".join(frame.columns)
    with conn.cursor() as cur:
        cur.copy_expert(f"copy {table_name} ({columns}) from stdin with csv", buffer)


def execute_sql_file(file_name: str) -> None:
    """Execute a SQL file from the configured SQL directory.

    Args:
        file_name: SQL file name relative to the Airflow SQL directory.
    """
    path = SQL_DIR / file_name
    postgres_hook().run(path.read_text(encoding="utf-8"))
    print(f"Executed {path}")


def read_sales_landing() -> pd.DataFrame:
    """Read all sales landing CSV files and return one concatenated DataFrame."""
    frames: list[pd.DataFrame] = []
    for file_name, _source_year in SALES_SHEETS.values():
        frames.append(pd.read_csv(LANDING_DIR / file_name, dtype=str))
    return pd.concat(frames, ignore_index=True)


@dag(
    dag_id="italy_dwh_pipeline",
    start_date=datetime(2026, 2, 1),
    schedule=None,
    catchup=False,
    tags=["italy", "dwh", "test"],
)
def italy_dwh_pipeline() -> None:
    """Define the Airflow DAG that builds the PostgreSQL DWH layers."""
    @task
    def prepare_landing() -> None:
        """Extract Excel sheets into reproducible CSV landing files."""
        if not INPUT_XLSX.exists():
            raise FileNotFoundError(f"Input xlsx was not found: {INPUT_XLSX}")

        LANDING_DIR.mkdir(parents=True, exist_ok=True)
        for sheet_name, (file_name, source_year) in SALES_SHEETS.items():
            frame = pd.read_excel(INPUT_XLSX, sheet_name=sheet_name)
            frame = frame.rename(columns=SALES_RENAME)
            frame = frame[list(SALES_RENAME.values())]
            frame.insert(0, "source_row_number", frame.index + 2)
            frame.insert(0, "source_year", source_year)
            frame.insert(0, "source_sheet", sheet_name)
            write_csv(frame, LANDING_DIR / file_name)

        plan = pd.read_excel(INPUT_XLSX, sheet_name="план 02 2026", header=1)
        plan = plan.rename(
            columns={
                "Учетный день": "accounting_date",
                "План на день": "planned_total_amount",
                "Ресторан": "restaurant",
                "БАНКЕТ НАШ": "banquet_own",
                "Банкет C&B": "banquet_cb",
                "Агрегатор": "aggregator",
                "Самовывоз": "pickup",
                "Доставка": "delivery",
            }
        )
        plan = plan.loc[:, ~plan.columns.astype(str).str.startswith("Unnamed")]
        plan.insert(0, "source_row_number", plan.index + 3)
        write_csv(plan, LANDING_DIR / "daily_plan_2026_02.csv")

    @task
    def init_db() -> None:
        """Recreate PostgreSQL schemas and base tables for a repeatable run."""
        execute_sql_file("001_create_schema.sql")

    @task
    def load_raw() -> None:
        """Load landing CSV files into raw tables without business transformations."""
        sales = read_sales_landing()
        plan = pd.read_csv(LANDING_DIR / "daily_plan_2026_02.csv", dtype=str)

        raw_sales_cols = [
            "source_sheet",
            "source_year",
            "source_row_number",
            "accounting_date",
            "receipt_number",
            "opened_at",
            "opened_hour",
            "closed_at",
            "closed_hour",
            "dish_name",
            "category_name",
            "order_type_name",
            "dish_qty",
            "guest_qty",
            "net_amount",
        ]
        raw_plan_cols = [
            "source_row_number",
            "accounting_date",
            "planned_total_amount",
            "restaurant",
            "banquet_own",
            "banquet_cb",
            "aggregator",
            "pickup",
            "delivery",
            "avg_check_restaurant",
            "avg_check_delivery",
            "avg_guest_restaurant",
            "avg_guest_delivery",
            "avg_guest_banquet",
        ]
        for col in raw_plan_cols:
            if col not in plan.columns:
                plan[col] = ""

        with postgres_hook().get_conn() as conn, conn.cursor() as cur:
            cur.execute("truncate table raw.sales_lines, raw.daily_plan;")
            copy_frame(conn, "raw.sales_lines", sales[raw_sales_cols])
            copy_frame(conn, "raw.daily_plan", plan[raw_plan_cols])

    @task
    def build_staging_sql() -> None:
        """Build typed staging sales rows and deterministic technical keys."""
        execute_sql_file("002_build_staging.sql")

    @task
    def build_dwh_sql() -> None:
        """Build DWH dimensions, facts, and detailed DQ helper tables."""
        execute_sql_file("003_build_dwh.sql")

    @task
    def run_quality_checks_sql() -> None:
        """Run data quality checks and persist their results."""
        execute_sql_file("004_quality_checks.sql")

    @task
    def build_marts_sql() -> None:
        """Build PostgreSQL analytical marts from the DWH layer."""
        execute_sql_file("005_marts.sql")

    publish_marts_to_clickhouse = TriggerDagRunOperator(
        task_id="publish_marts_to_clickhouse",
        trigger_dag_id=CLICKHOUSE_DAG_ID,
        wait_for_completion=False,
        reset_dag_run=True,
    )

    (
        prepare_landing()
        >> init_db()
        >> load_raw()
        >> build_staging_sql()
        >> build_dwh_sql()
        >> run_quality_checks_sql()
        >> build_marts_sql()
        >> publish_marts_to_clickhouse
    )


italy_dwh_pipeline_dag = italy_dwh_pipeline()
italy_dwh_pipeline_dag.doc_md = DAG_DESCRIPTION
