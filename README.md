# Italy DWH

Проект поднимает локальный
контур из Airflow, PostgreSQL и ClickHouse, загружает исходный Excel, строит
DWH-слои, выполняет SQL-трансформации и публикует готовую витрину в ClickHouse.

Основная идея: Python используется только для ingestion, а бизнес-логика DWH,
очистка, классификация строк, DQ-проверки и витрины описаны SQL-скриптами.
Так правила проще проверять и обсуждать.

## Состав проекта

```text
airflow/dags/italy_dwh_dag.py          Основной DAG: source -> raw -> stg -> dwh -> dq -> mart
airflow/dags/italy_clickhouse_dag.py   DAG публикации витрин в ClickHouse
sql/001_create_schema.sql              Схемы, таблицы, COMMENT ON TABLE
sql/002_build_staging.sql              Приведение типов, ключи, классификация строк
sql/003_build_dwh.sql                  Измерения, факты, детальные DQ-таблицы
sql/004_quality_checks.sql             Сводные DQ-проверки
sql/005_marts.sql                      PostgreSQL-витрины
data/input/                            Исходный Excel-файл
data/landing/                          Воспроизводимый CSV landing
docs/                                  Архитектура и предположения
```

## Документы задания

В задании требуется предложить структуру DWH/DAG и описать предположения,
сделанные во время выполнения. Эти материалы вынесены в отдельные документы:

- [Модель DWH и архитектура](docs/dwh_model.md)
- [Предположения](docs/assumptions.md)

## Архитектура

```text
Excel source
  -> CSV landing
  -> raw
  -> stg
  -> dwh
  -> dq
  -> mart
  -> ClickHouse serving layer
```

В проекте два DAG-а:

```text
italy_dwh_pipeline
italy_publish_marts_to_clickhouse
```

Основной DAG строит хранилище в PostgreSQL и затем триггерит ClickHouse DAG
через `TriggerDagRunOperator`. ClickHouse используется только как serving/OLAP
слой для готовых витрин; core-трансформации остаются в PostgreSQL.

## Источник данных

В задании сказано, что факт приходит из действующих баз, а план ведется в
Excel. В этом тестовом проекте Excel рассматривается как выгрузка из источника
и конвертируется в CSV landing:

```text
data/input/Тестовое задание data инженер italy.xlsx
  -> data/landing/sales_fact_2026_02.csv
  -> data/landing/sales_fact_2025_02.csv
  -> data/landing/daily_plan_2026_02.csv
```

Так пайплайн остается воспроизводимым без внешних credentials. В production
landing-шаг можно заменить на extractor из Google Sheets API или из OLTP-базы
без изменения DWH-модели.

## Слои

### raw

`raw` хранит данные максимально близко к источнику.

Таблицы:

```text
raw.sales_lines
raw.daily_plan
```

Большинство полей хранится как `text`. Это сделано намеренно: слой `raw`
сохраняет исходную форму данных до приведения типов, валидации, фильтрации и
бизнес-правил.

### stg

`stg` выполняет техническую стандартизацию:

- приводит даты, timestamp, числа и счетчики к нужным типам;
- очищает текстовые поля от лишних пробелов;
- создает детерминированные технические ключи;
- классифицирует строки чека через `line_item_type`;
- находит чеки, попавшие на несколько учетных дат;
- помечает технические нулевые версии, которые не должны попадать в
  аналитические факты.

Основная таблица:

```text
stg.sales_lines
```

Важные поля:

```text
receipt_line_id
receipt_nk
line_item_type
is_modifier
accounting_dates_count
exclude_from_marts
dq_issue
```

### dwh

`dwh` содержит размерную модель. Гранулярность центрального факта:

```text
1 строка dwh.fact_receipt_line = 1 исходная строка чека
```

Измерения:

```text
dwh.dim_order_type
dwh.dim_category
dwh.dim_dish
dwh.dim_modifier
```

Факты:

```text
dwh.fact_receipt_line
dwh.fact_receipt
dwh.fact_daily_plan_channel
```

`dwh.fact_receipt` является агрегатом на уровне чека. Он нужен потому, что
исходные данные имеют строковый уровень, а часть аналитики естественно
смотреть на уровне чека.

### dq

`dq` хранит детальные диагностические строки и сводные результаты проверок.

Таблицы:

```text
dq.receipt_multi_accounting_date
dq.modifier_dish_lines
dq.check_results
```

Детальные таблицы позволяют посмотреть проблемные исходные строки, а
`dq.check_results` дает компактный список проверок для ревью.

### mart

`mart` содержит финальные аналитические витрины в PostgreSQL.

Текущая витрина:

```text
mart.daily_plan_fact
```

Она сравнивает план и факт продаж по учетной дате:

```text
accounting_date
planned_total_amount
fact_amount
plan_fact_delta
plan_completion_rate
receipt_count
```

### ClickHouse

ClickHouse получает подготовленные витрины из PostgreSQL.

Текущая таблица ClickHouse:

```text
italy_mart.daily_plan_fact
```

ClickHouse DAG читает `mart.daily_plan_fact` из PostgreSQL и идемпотентно
заменяет содержимое таблицы в ClickHouse.

## Классификация строк чека

Исходное поле `Блюдо` содержит не только блюда меню. В нем также встречаются
модификаторы, допы, сервисные сборы, подарки, стафф и маркетинговые позиции.
Чтобы не загрязнять аналитику блюд и при этом не терять финансовые суммы,
строки классифицируются в `stg.sales_lines.line_item_type`.

Поддерживаемые значения:

```text
dish
modifier
promotion
staff
service_charge
marketing
```

Правила:

- строки `dish` связываются с `dwh.dim_dish`;
- строки `modifier` связываются с `dwh.dim_modifier`;
- строки `promotion`, `staff`, `service_charge` и `marketing` остаются в
  `dwh.fact_receipt_line`, но не получают `dish_id` или `modifier_id`;
- все типы строк остаются в факте, поэтому выручка не теряется.

Так категории `СТАФФ`, `МАРКЕТИНГ`, `АКЦИИ/ПОДАРКИ`,
`НАДБАВКА ЗА ОБСЛУЖИВАНИЕ`, `ДОПЫ` и модификаторы вроде `- теплая` не попадают
в `dwh.dim_dish`.

## Очистка данных и DQ

Пайплайн не удаляет сомнительные данные молча. Он либо классифицирует строку,
либо исключает только очевидные технические дубли из аналитических фактов, либо
сохраняет DQ-след.

Реализованная обработка:

- `receipt_number` не считается глобально уникальным ключом.
- Natural key чека строится как `source_year + receipt_number + opened_at`.
- `accounting_date` намеренно не входит в ключ чека, чтобы находить один и тот
  же чек на нескольких учетных датах.
- Нулевые технические версии чеков, попавших на несколько учетных дат,
  исключаются из аналитических фактов, но сохраняются в `stg` и `dq`.
- Строки за пределами ожидаемого февральского месяца попадают в DQ.
- Отрицательные суммы попадают в DQ и сохраняются, потому что похожи на
  технические корректировки/округления.
- Модификаторы и операционные категории классифицируются через
  `line_item_type`.
- План приводится к типам из Excel-листа плана; недатовые строки вроде итогов
  не попадают в `dwh.fact_daily_plan_channel`.
- Отсутствующий план за 2025 остается `NULL`, а не заменяется на `0`, потому
  что источник не содержит план за 2025.

Сводные DQ-проверки:

```text
sales_rows_outside_expected_month
multi_accounting_date_receipts
negative_amount_rows
modifier_lines_in_dish_source_field
classified_non_dish_line_items
closed_before_opened
opened_hour_mismatch
closed_hour_mismatch
excluded_zero_versions
```

## DAG Flow

Основной DAG:

```text
prepare_landing
  -> init_db
  -> load_raw
  -> build_staging_sql
  -> build_dwh_sql
  -> run_quality_checks_sql
  -> build_marts_sql
  -> publish_marts_to_clickhouse
```

ClickHouse DAG:

```text
create_clickhouse_tables
  -> publish_daily_plan_fact
```

`prepare_landing` и `load_raw` являются Python-задачами. Все DWH-трансформации
после загрузки в `raw` выполняются SQL-файлами.

## Environment и Connections

Проект конфигурируется через переменные окружения Docker Compose.

Airflow metadata database:

```text
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=postgresql+psycopg2://italy:italy@postgres:5432/italy_dwh
```

Airflow Connections в проекте уже задаются через переменные окружения:

```text
AIRFLOW_CONN_ITALY_POSTGRES_CONNECTION=postgresql://italy:italy@postgres:5432/italy_dwh
AIRFLOW_CONN_ITALY_CLICKHOUSE_CONNECTION=http://italy:italy@clickhouse:8123/italy_mart
```

Это означает, что после `docker compose up --build` DAG-и могут использовать
connections без ручного ввода в UI. Если нужно создать или переопределить их
вручную, это делается в Airflow UI:

```text
Admin -> Connections -> + Add a new record
```

Для PostgreSQL:

```text
Connection Id: italy_postgres_connection
Connection Type: Postgres
Description: Italy DWH PostgreSQL connection
Host: postgres
Database/Schema: italy_dwh
Login: italy
Password: italy
Port: 5432
Extra: оставить пустым
```

Для ClickHouse:

```text
Connection Id: italy_clickhouse_connection
Connection Type: HTTP
Description: Italy ClickHouse mart connection
Host: clickhouse
Database/Schema: italy_mart
Login: italy
Password: italy
Port: 8123
Extra: оставить пустым
```

Важно: внутри Docker нужно использовать `postgres:5432` и `clickhouse:8123`, а
не `localhost:5435` и `localhost:8125`. Порты `5435` и `8125` нужны только для
подключения с хост-машины, например из DBeaver.

Airflow Variables:

```text
AIRFLOW_VAR_ITALY_DATA_DIR=/opt/airflow/data
AIRFLOW_VAR_ITALY_SQL_DIR=/opt/airflow/sql
AIRFLOW_VAR_ITALY_LANDING_DIR=/opt/airflow/data/landing
AIRFLOW_VAR_ITALY_INPUT_XLSX=/opt/airflow/data/input/Тестовое задание data инженер italy.xlsx
```

Внутри Docker Airflow подключается к сервисам по именам из Compose:

```text
PostgreSQL host: postgres
ClickHouse host: clickhouse
```

С хост-машины используются опубликованные порты:

```text
PostgreSQL: localhost:5435
ClickHouse HTTP: localhost:8125
ClickHouse native: localhost:9005
Airflow UI: localhost:8080
```

## Запуск проекта

Исходный Excel должен лежать здесь:

```text
data/input/Тестовое задание data инженер italy.xlsx
```

Сборка и запуск сервисов:

```bash
docker compose up --build
```

Airflow:

```text
http://localhost:8080
login: admin
password: admin
```

Запустить основной DAG:

```text
italy_dwh_pipeline
```

Основной DAG триггерит:

```text
italy_publish_marts_to_clickhouse
```

## Подключение к базам

DBeaver/PostgreSQL:

```text
Host: localhost
Port: 5435
Database: italy_dwh
User: italy
Password: italy
```

DBeaver/ClickHouse:

```text
Host: localhost
Port: 8125
Database: italy_mart
User: italy
Password: italy
```

Полезные SQL-проверки:

```sql
select line_item_type, count(*) as lines, sum(net_amount) as amount
from dwh.fact_receipt_line
group by line_item_type
order by lines desc;
```

```sql
select *
from dq.check_results
order by severity, check_name;
```

```sql
select *
from mart.daily_plan_fact
order by accounting_date;
```

## Документация таблиц

У каждой PostgreSQL-таблицы в `raw`, `stg`, `dwh`, `dq` и `mart` есть
`COMMENT ON TABLE` на английском языке. В DAG-ах также есть `doc_md`-описания
для документации в Airflow UI.

## Замечания к данным и допущения

Подробное описание спорных мест в данных и выбранной обработки находится в
[docs/assumptions.md](docs/assumptions.md).

Ключевые решения:

- нулевые технические версии чеков на нескольких учетных датах сохраняются в
  `stg`/`dq`, но исключаются из аналитических фактов;
- строки вне ожидаемого месяца не удаляются, а фиксируются DQ-проверкой;
- модификаторы и допы выносятся в `dwh.dim_modifier`, а не в `dwh.dim_dish`;
- служебные категории остаются в факте как отдельные `line_item_type`;
- отрицательные суммы сохраняются и маркируются как DQ-наблюдение;
- план за 2025 отсутствует, поэтому плановые поля для 2025 остаются `NULL`;
- цена блюда не моделируется как справочный атрибут, потому что в источнике
  есть сумма строки со скидкой, а не стабильная прайсовая цена.
