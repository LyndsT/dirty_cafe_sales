## Data Ingestion Setup (pgAdmin 4)

Follow these steps to import the raw CSV into PostgreSQL using `file_fdw`.

### 1. File Preparation
Create a public directory and move your raw CSV dataset into place:

- **Target Directory:** `C:\Users\Public\PostgreSQL`
- **File Path:** `C:\Users\Public\PostgreSQL\dirty_cafe_sales.csv`

### 2. Database Creation
1. Open **pgAdmin 4** $\rightarrow$ Navigate to **Object Explorer**.
2. Right-click **Databases** under your PostgreSQL server instance.
3. Select **Create** $\rightarrow$ **Database...**
4. Set **Database Name** to `cafe_db` and save.

### 3. Database & Schema Initialization
Open the **Query Tool** on `cafe_db` and execute the setup script:

```sql
-- 1. Create dedicated schema
CREATE SCHEMA IF NOT EXISTS cafe;

-- 2. Enable Foreign Data Wrapper extension & server
CREATE EXTENSION IF NOT EXISTS file_fdw;

CREATE SERVER IF NOT EXISTS csv_server 
FOREIGN DATA WRAPPER file_fdw;

-- 3. Create raw foreign table mapping (NOTE: all columns imported as TEXT, cols renamed for shorthand)
CREATE FOREIGN TABLE cafe.raw_sales (
    raw_transaction_id   TEXT,
    raw_item_name        TEXT,  -- Renamed from 'item'
    raw_item_qty         TEXT,  -- Renamed from 'quantity'
    raw_unit_price       TEXT,  -- Renamed from 'price_per_unit'
    raw_total_amount     TEXT,  -- Renamed from 'total_spent'
    raw_payment_type     TEXT,  -- Renamed from 'payment_method'
    raw_store_location   TEXT,  -- Renamed from 'location'
    raw_sale_date        TEXT   -- Renamed from 'transaction_date'
)
SERVER csv_server
OPTIONS (
    filename 'C:/Users/Public/PostgreSQL/dirty_cafe_sales.csv',
    format 'csv',
    header 'true',
    delimiter ','
);
```

### 3.5 If file relocation is necessary:

```sql
ALTER FOREIGN TABLE cafe.raw_sales 
OPTIONS (SET filename 'D:/DataProjects/cafe_sales.csv');
```

---

## Cleaning the data

### 1. raw_transaction_id

```sql
SELECT raw_transaction_id,
	COUNT(raw_transaction_id)
FROM cafe.raw_sales
GROUP BY raw_transaction_id
HAVING COUNT(raw_transaction_id) <> 1;
```

OUT:
| raw_transaction_id | count |
| :----------------: | :---: |
| *(no duplicate records found)* | — |

NOTE:
> No issues found

### 2. raw_item_name

Checking for Errors:

```sql
SELECT DISTINCT 
    raw_item_name,
    raw_unit_price
FROM cafe.raw_sales
ORDER BY raw_item_name;
```

OUT:

| raw_item_name | raw_unit_price |
|---------------|----------------|
| "Cake"        | "3"            |
| "Cake"        |                |
| "Cake"        | "ERROR"        |
| "Cake"        | "UNKNOWN"      |
| "Coffee"      |                |
| "Coffee"      | "2"            |
| "Coffee"      | "UNKNOWN"      |
| "Coffee"      | "ERROR"        |

NOTE:
> Lots of errors to fix. Checking to see if some entries are salvageable. Realistically, one would cross-check the price changes throughout the timeline but for this particular project, the data host has disclosed that the prices are consistent throughout. Although, it never hurts to double check for inconsistencies.

```sql
SELECT 
    raw_item_name,
    COUNT(DISTINCT raw_unit_price) AS distinct_price_count
FROM cafe.raw_sales
WHERE raw_unit_price ~ '^[0-9\.\,\$]+$'
  AND raw_item_name IS NOT NULL
  AND raw_item_name NOT IN ('UNKNOWN', 'ERROR')
GROUP BY raw_item_name
HAVING COUNT(DISTINCT raw_unit_price) > 1
ORDER BY distinct_price_count DESC;
```

OUT:
| raw_item_name | distinct_price_count |
| :-----------: | :------------------: |
| *(no duplicate records found)* | — |

NOTE: Since no items have 2 difference amounts (outside of errors, nulls, and unknowns), it's safe to assume that prices corresponding with the items are their actual prices.

```sql
SELECT DISTINCT 
    raw_item_name,
    raw_unit_price
FROM cafe.raw_sales
WHERE raw_unit_price ~ '^[0-9\.\,\$]+$'
  AND raw_item_name IS NOT NULL
  AND raw_item_name != 'UNKNOWN'
  AND raw_item_name != 'ERROR'
ORDER BY raw_unit_price;
```

OUT:

| raw_item_name | raw_unit_price |
|---------------|----------------|
| "Cookie"      | "1"            |
| "Tea"         | "1.5"          |
| "Coffee"      | "2"            |
| "Juice"       | "3"            |
| "Cake"        | "3"            |
| "Sandwich"    | "4"            |
| "Smoothie"    | "4"            |
| "Salad"       | "5"            |

NOTE:
Now all of the Cookies, Tea, Coffee, and Salad are easily identifiable due to their prices; we will be replacing those with the same price their corresponding item names. However, for Coffee and Cake, they have the same price, as well as for Sandwich and Smoothie. With these 4 items, we will be labelling them as 'Coffee/Cake' and 'Sandwich/Smoothie' to avoid data inaccuracies.

### 3. raw_unit_qty, raw_unit_price, raw_total_amount (SWAP WITH 2.)

With a short look on the data, one can see that there are instances wherein only one of the three values are missing. For these cases, we can simply compute for their values using the other two values:

