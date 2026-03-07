# Market Basket Analysis — Construction Materials Distribution
### External Commercial Strategy & Analytics Consulting Project

---

## Client

Materiales Jordan is a company with over 30 years in the heavy construction materials market in Mexico. Their product mix spans the steel industry — corrugated rebar, wire rod, and wire — through to cement and concrete.

---

## Business Problem

We were engaged as external consultants to answer a specific question: which products can be offered together in a way that makes customers willing to spend more to take them home?

The objective of the project was to give stakeholders greater visibility into customer behavior and product dynamics, and to deliver actionable strategies capable of strengthening margins.

> *"Which products are frequently bought together, and which ones should we promote as bundles?"*

**Scope:** Identify product associations, recommend product combinations, and provide commercial insight. This was a recommendation-oriented engagement — implementation and A/B testing remain with the client.

---

## Dataset

| Attribute | Value |
|---|---|
| Total rows | 36,448 |
| Unique transactions | 14,780 |
| Unique products | 139 |
| Avg. items per sale | 2.47 |
| Date range | Jul 2024 – Mar 2026 |

---

## Technical Pipeline

```
BigQuery (source)
      │
      ▼
dbt-core + DuckDB adapter (Cursor)
  ├── stg_sale_products  (view)   → parse malformed JSON, flatten product arrays
  ├── dim_product        (table)  → clean product master (price, cost, category)
  └── mart_sales         (table)  → join staging + dimension, compute unit profit/margin
      │
      ▼
DuckDB (local materialization)
      │
      ▼
Google Colab — Python analysis
  ├── TransactionEncoder → binary basket matrix (14,780 × 139)
  ├── Apriori → 55 frequent itemsets
  ├── Association rules → 16 rules filtered by support / confidence / lift
  └── Profit simulation → incremental profit per rule (1→1 rules only)
```

---

## Data Engineering — dbt + DuckDB

### Setup

The project used "dbt-core with DuckDB as the local adapter". BigQuery was attached as a read-only source directly via DuckDB's BigQuery community extension, eliminating the need to export CSVs manually.

```yaml
# dbt_project.yml
on-run-start:
  - "INSTALL bigquery FROM community;"
  - "LOAD bigquery;"
  - "ATTACH 'project=materialesjordan' AS bq (TYPE bigquery, READ_ONLY);"

models:
  jordan:
    +materialized: table
```

dbt reads from BigQuery at runtime, transforms the data, and materializes results as local DuckDB tables. Written and executed in **Cursor**.

---

### Model 1 — `stg_sale_products` (view)

Products were stored as a JSON string with single quotes inside each sale record — not valid JSON. This model parses and flattens them into one row per product per sale.

```sql
{{ config(materialized='view') }}

with sale_base as (
  select
    s.id         as sale_id,
    s.customerid,
    date(s.date) as sale_date,
    s.subtotal,
    s.total,
    safe.parse_json(regexp_replace(s.products, r"'", '"')) as products_j
  from {{ source('fuente_bd', 'sale') }} s
)
select * from sale_base
```

**Key decisions:**
- `REGEXP_REPLACE` converts single quotes → double quotes to produce valid JSON
- `SAFE.PARSE_JSON` avoids pipeline failures on malformed records
- Materialized as `view` since it is an intermediate staging layer

---

### Model 2 — `dim_product` (table)

Product master table with catalog pricing and cost, used as the dimension for profitability calculations.

```sql
{{ config(materialized='table') }}

select
  p.id                               as product_id,
  safe_cast(p.price     as numeric)  as product_price_catalog,
  safe_cast(p.costprice as numeric)  as product_cost_price,
  p.category                         as product_category
from {{ source('fuente_bd', 'product') }} p
```

---

### Model 3 — `mart_sales` (table)

Final analytical model. Joins staging sales with the product dimension and computes unit-level profitability metrics.

```sql
{{ config(materialized='table') }}

with sp as (select * from {{ ref('stg_sale_products') }}),
     pd as (select * from {{ ref('dim_product') }})

select
  sp.*,
  pd.product_price_catalog,
  pd.product_cost_price,
  pd.product_category,
  (pd.product_price_catalog - pd.product_cost_price)         as unit_gross_profit,
  safe_divide(
    (pd.product_price_catalog - pd.product_cost_price),
    pd.product_price_catalog
  )                                                          as unit_gross_margin
from sp
left join pd on sp.product_id = pd.product_id
order by sp.sale_date desc
```

> **Note:** The `LEFT JOIN` results in ~12,333 nulls for catalog fields — products present in transactions but missing from the product master table. Handled downstream in Python with `.fillna()`.

---

## Analysis — Python (Google Colab)

### Cleaning & Standardization

```python
def canon_id(x):
    return str(x).strip().lower().replace("{","").replace("}","").replace('"',"").replace("'","")

df["product_id"] = df["product_id"].apply(canon_id)

# Price source: catalog preferred, transaction price as fallback
df["price_used"] = df["product_price_catalog"].fillna(df["product_price"])
df["unit_profit_used"] = df["price_used"] - df["cost_used"]
```

### Basket Construction

```python
basket = df.groupby("sale_id")["product_id"].apply(list)
te = TransactionEncoder()
basket_df = pd.DataFrame(te.fit(basket).transform(basket), columns=te.columns_)
# Result: 14,780 × 139 binary matrix
```

### Apriori + Association Rules

```python
frequent_itemsets = apriori(basket_df, min_support=0.02, use_colnames=True, max_len=3)

rules = association_rules(frequent_itemsets, metric="lift", min_threshold=1.0)
rules = rules[(rules["confidence"] >= 0.30) & (rules["lift"] >= 1.20)]
```

**Parameter rationale:**
- `min_support=0.02` → minimum ~296 transactions. Low enough to capture real patterns, high enough to exclude noise
- `confidence >= 0.30` → consequent appears in at least 30% of transactions containing the antecedent
- `lift >= 1.20` → association is at least 20% stronger than random chance

### Profit Simulation

```python
DISCOUNT = 0.05  # 5% reference scenario on consequent product

rules_1to1["expected_new_sales"] = (
    rules_1to1["support_A"] * n_sales * (1 - rules_1to1["confidence"])
).round(0)

rules_1to1["incremental_profit"] = (
    rules_1to1["expected_new_sales"] * rules_1to1["discounted_profit_per_unit"]
)
```

> The 5% discount is a reference scenario, not a calibrated estimate. The model assumes static behavior — a dynamic version would require behavioral data and logistics cost structure per product category.

---

## Visualizations

### 1. Product Correlation Heatmap — Validating associations before modeling

Before running Apriori, a correlation matrix was computed on the binary basket matrix for the top 20 most frequent products. This served as a visual sanity check: if no correlation existed between products, running an association algorithm would be pointless.

```python
corr_top = basket_df[top_products].corr()
sns.heatmap(corr_top, cmap="coolwarm", center=0, annot=False)

```
<img src="Images/heatmap_correlation.png" width="700">
The heatmap confirmed several product clusters with positive correlation — most notably the rebar/wire group and the cement/sand/aggregate group — giving confidence that the Apriori algorithm would find meaningful patterns.

---

### 2. Revenue vs Profit Over Time — Understanding the margin reality

```python
revenue = df.groupby("sale_date")["product_price"].sum().reset_index()
profit  = df.groupby("sale_date")["unit_gross_profit"].sum().reset_index()

plt.plot(revenue["sale_date"], revenue["product_price"], label="Revenue")
plt.plot(profit["sale_date"],  profit["unit_gross_profit"], label="Profit")

```
<img src="Images/profit_comparison_plot.png" width="700">
This chart reveals a critical business context: **profit is consistently a small fraction of revenue**. The gap between the two lines is large and persistent. This directly motivates the cross-selling strategy — when margins are structurally thin, increasing basket size is more impactful than optimizing individual product pricing.

---

### 3. Current Profit vs Future Profit — The business case for bundling

The final visualization compares each product's current total profit against its projected future profit after applying the incremental profit simulation.

```python
plot_data = top_products_to_plot.melt(
    id_vars=["product_name"],
    value_vars=["total_profit", "future_profit"]
)
sns.barplot(x="product_name", y="Profit Amount", hue="Profit Type", data=plot_data)

```
<img src="Images/top_products_bar.png" width="700">
| Product | Current Profit | Incremental Profit | Future Profit |
|---|---|---|---|
| CEMENTO GRIS MONTERREY | $120,348 | $162,043 | $282,391 |
| CARGO POR ENTREGA 200 ZONA 1 | $180,156 | $51,095 | $231,251 |

Two products show significant upside. The rest show no incremental profit — meaning they are standalone drivers not meaningfully affected by association-based strategies. This distinction is what makes the recommendation actionable: focus the bundling strategy on cement and delivery, not the entire catalog.

---

## Key Findings

The analysis revealed two distinct commercial strategies operating in parallel — not one.

### Strategy 1 — Cement as the anchor product (13 of 16 rules)

`CEMENTO GRIS MONTERREY EXTRA 50KG` appears as a consequent in **13 of 16 rules**. It structurally organizes customer purchase decisions — not just a top seller, but a behavioral driver. Nearly every complementary product (sand, rebar, wire, aggregates) has a statistically meaningful link back to cement.

This means the cross-selling strategy is not about pushing cement — it is about using cement as a trigger to expand the basket around it.

### Strategy 2 — The structural bundle: Rebar + Wire (2 rules, highest lift in the dataset)

This finding was not the original focus of the engagement, but the data made it impossible to ignore.

| Antecedent | Consequent | Lift | Confidence |
|---|---|---|---|
| ALAMBRE RECOCIDO 16 | VARILLA 3/8 PIEZA | 4.14 | 46.0% |
| VARILLA 3/8 PIEZA | ALAMBRE RECOCIDO 16 | 4.14 | 36.4% |

A lift of **4.14 is the strongest association in the entire dataset** — meaning customers who buy rebar are 4x more likely to also buy wire than a random customer. This relationship is bidirectional and consistent.

The key insight here is different from the cement strategy: **this bundle does not need an incentive — it needs visibility.** These customers already intend to buy both products. The opportunity is to present them together at the point of quotation so neither gets forgotten, reducing the chance the second product is purchased elsewhere.

### Full association rules (by lift)

| Antecedent | Consequent | Lift | Confidence |
|---|---|---|---|
| VARILLA 1/2 PIEZA | VARILLA 3/8 PIEZA | 4.32 | 48.0% |
| ALAMBRE RECOCIDO 16 | VARILLA 3/8 PIEZA | 4.14 | 46.0% |
| VARILLA 3/8 PIEZA | ALAMBRE RECOCIDO 16 | 4.14 | 36.4% |
| MIXTO METRO CUBICO | CEMENTO GRIS MONTERREY | 1.86 | 50.3% |
| ARENA #5 METRO CUBICO | CARGO POR ENTREGA 200 | 1.81 | 30.5% |

---

## Commercial Recommendation

**Do not discount cement.**

It is the anchor. Discounting it erodes margin on your highest-confidence driver without changing behavior.

**Use cement as a trigger for conditional logistics incentives.**

When a customer's quotation includes cement, identify high-lift complementary products (rebar, wire, sand) and offer a logistics discount if they add those products to the order.

This approach:
- Protects core margin on cement
- Expands average basket size
- Leverages behavioral economics (the incentive feels like a reward, not a discount)
- Uses logistics — already the highest-margin category in the dataset

**Recommended next steps for the client:**
1. Validate logistics cost structure to enable dynamic discount calibration per product
2. Run A/B test: standard quotation vs. quotation with conditional logistics incentive
3. Monitor basket size and gross margin per order, not just revenue

---

## Outputs

| File | Description |
|---|---|
| `rules_1to1_with_profit.csv` | 16 association rules with profit simulation |
| `frequent_itemsets.csv` | 55 frequent itemsets (pairs + triplets) |

---

## Stack

| Layer | Tool |
|---|---|
| Editor | Cursor |
| Data source | BigQuery |
| Transformation & orchestration | dbt-core |
| Local materialization | DuckDB (BigQuery community extension) |
| Analysis | Python · Google Colab |
| Libraries | pandas · mlxtend · seaborn · matplotlib |
