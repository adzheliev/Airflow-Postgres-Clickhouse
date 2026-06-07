# Модель DWH и архитектура

Документ описывает целевую структуру DWH, слои данных, гранулярность фактов и
основные решения, принятые при моделировании.

## Поток данных

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

## Слои

### raw

Слой `raw` хранит данные максимально близко к исходному файлу. Большинство
полей сохраняется как `text`, чтобы не потерять исходные значения до приведения
типов, валидации и применения бизнес-правил.

Таблицы:

```text
raw.sales_lines
raw.daily_plan
```

### stg

Слой `stg` выполняет техническую стандартизацию:

- приводит даты, timestamp, числовые значения и счетчики к нужным типам;
- очищает текстовые поля от лишних пробелов;
- строит детерминированные технические ключи;
- классифицирует строки чека через `line_item_type`;
- отмечает версии чеков, попавшие на несколько учетных дат;
- выставляет флаги строк, исключаемых из аналитических фактов.

Основная таблица:

```text
stg.sales_lines
```

### dwh

Слой `dwh` содержит размерную модель. Гранулярность центрального факта:

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

`dwh.fact_receipt` является агрегатом на уровне чека, построенным из строк
чека.

### dq

Слой `dq` хранит детальные проблемные строки и агрегированные результаты
проверок качества данных.

Таблицы:

```text
dq.receipt_multi_accounting_date
dq.modifier_dish_lines
dq.check_results
```

### mart

Слой `mart` содержит финальные аналитические таблицы для отчетности.

Текущая витрина:

```text
mart.daily_plan_fact
```

Она сравнивает дневной план и факт продаж по учетной дате.

### ClickHouse

ClickHouse используется как serving/OLAP слой для готовых витрин. Основные DWH
трансформации остаются в PostgreSQL.

Текущая таблица ClickHouse:

```text
italy_mart.daily_plan_fact
```

## Звезда

Центральный факт:

```text
dwh.fact_receipt_line
```

Измерения:

```text
dwh.dim_order_type
dwh.dim_category
dwh.dim_dish
dwh.dim_modifier
```

`dim_dish` хранит самостоятельные блюда меню. Исходные строки, описывающие
добавки, варианты приготовления, модификаторы и допы, отделяются в
`dim_modifier` и связываются с фактом через `modifier_id`.

Строки чека классифицируются через `line_item_type`:

```text
dish
modifier
promotion
staff
service_charge
marketing
```

Только строки `dish` связываются с `dim_dish`. Только строки `modifier`
связываются с `dim_modifier`. Операционные типы строк, такие как промо,
питание персонала, сервисный сбор и маркетинговые позиции, остаются в
`fact_receipt_line` для финансовой полноты, но не загрязняют аналитику блюд.

## Владение трансформациями

Python используется только для ingestion в `raw`: чтение Excel, создание CSV
landing и загрузка raw-таблиц.

DWH-логика реализована SQL-скриптами:

```text
002_build_staging.sql
003_build_dwh.sql
004_quality_checks.sql
005_marts.sql
```

Так бизнес-правила остаются явными и удобными для проверки.

## Модель плана

План хранится в длинном формате:

```text
dwh.fact_daily_plan_channel
```

Так проще сравнивать план и факт по каналам и расширять модель при появлении
новых каналов планирования.

## Индексы и партиционирование

Партиционирование добавлено для растущих fact/mart-таблиц, где естественным
ключом отбора является учетная дата:

```text
dwh.fact_receipt_line partition by range(accounting_date)
dwh.fact_receipt partition by range(accounting_date)
dwh.fact_daily_plan_channel partition by range(accounting_date)
mart.daily_plan_fact partition by range(accounting_date)
```

В тестовых данных явно созданы месячные партиции для доступных периодов:

```text
2025-02
2025-03
2026-02
```

Также добавлены default-партиции. Они нужны как safety net: если в исходной
выгрузке появится дата вне ожидаемых месяцев, пайплайн не упадет на insert, а
строка попадет в default partition и будет дополнительно видна через DQ.

Справочники `dim_*` не партиционируются, потому что они небольшие и не являются
основными растущими таблицами. Для них достаточно primary key и unique
constraints.

Индексы добавлены на основные поля фильтрации и соединений:

```text
receipt_id
receipt_nk
accounting_date
line_item_type
dish_id
modifier_id
category_id
order_type_id
plan_channel
```

Primary key и unique constraints также создают индексы автоматически. Ручные
индексы добавлены там, где ожидаются частые join/filter сценарии: анализ по
датам, проверка чеков, меню-аналитика, разрезы по категориям и типам строк.

## Публикация витрины

После построения `mart.daily_plan_fact` основной DAG триггерит:

```text
italy_publish_marts_to_clickhouse
```

ClickHouse DAG публикует PostgreSQL-витрину в:

```text
italy_mart.daily_plan_fact
```
