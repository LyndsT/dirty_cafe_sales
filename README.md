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

### 1. Double check transaction ID errors

```sql
SELECT raw_transaction_id,
	COUNT(raw_transaction_id)
FROM cafe.raw_sales
GROUP BY raw_transaction_id
HAVING COUNT(raw_transaction_id) <> 1;
```

OUT:
> | raw_transaction_id | count |
> | ------------------ | ----- |
> |                    |       |

