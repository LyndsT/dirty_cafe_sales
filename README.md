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
> No issues found on this column. Since this column also has a unique value per entry, it's what we will be using as key for the whole database.

### 2. raw_payment_type, raw_store_location, raw_sale_date

For these columns, there is little to nothing that we can do regarding missing data, hence the decision to fix them together in one go. 

### 3. raw_unit_qty, raw_unit_price, raw_total_amount

With a short look on the data, one can see that there are instances wherein only one of the three values are missing. For these cases, we can simply compute for their values using the other two values. This will be a bit bloody so bear with me:

```sql
SELECT 
    raw_transaction_id,
	CASE
	    -- 1. If quantity is already a valid integer, keep it
	    WHEN raw_item_qty ~ '^\d+$' 
	        THEN raw_item_qty::NUMERIC
	    -- 2. If quantity is dirty BUT price and total are valid numbers, calculate quantity
	    WHEN raw_unit_price ~ '^[0-9\.]+$' 
	     AND raw_total_amount ~ '^[0-9\.]+$' 
	     AND raw_unit_price::NUMERIC > 0  -- Prevents division by zero
	        THEN ROUND(raw_total_amount::NUMERIC / raw_unit_price::NUMERIC)::NUMERIC
	    -- 3. If quantity cannot be kept or calculated, default to NULL
	    ELSE NULL
	END AS clean_item_qty,
	CASE
	    -- 1. If unit_price is already a valid number/decimal, keep it as NUMERIC
	    WHEN raw_unit_price ~ '^[0-9\.]+$' 
	        THEN raw_unit_price::NUMERIC
	    -- 2. If unit_price is missing/dirty BUT total and qty are valid, calculate price
	    WHEN raw_item_qty ~ '^\d+$' 
	     AND raw_total_amount ~ '^[0-9\.]+$' 
	     AND raw_item_qty::NUMERIC > 0  -- Prevents division by zero
	        THEN TRIM_SCALE(raw_total_amount::NUMERIC / raw_item_qty::NUMERIC)
	    -- 3. Fallback to NULL if uncalculable
	    ELSE NULL
	END AS clean_unit_price,
	CASE
	    -- 1. If total_amount is already a valid decimal/number, keep it as NUMERIC
	    WHEN raw_total_amount ~ '^[0-9\.]+$' 
	        THEN TRIM_SCALE(raw_total_amount::NUMERIC)
	    -- 2. If total_amount is missing/dirty BUT qty and unit_price are valid numbers, calculate it
	    WHEN raw_item_qty ~ '^\d+$' 
	     AND raw_unit_price ~ '^[0-9\.]+$' 
	        THEN TRIM_SCALE(raw_item_qty::NUMERIC * raw_unit_price::NUMERIC)
	    -- 3. Fallback to NULL if uncalculable
	    ELSE NULL
	END AS clean_total_amount
FROM cafe.raw_sales;
```

OUT:

| raw_transaction_id | clean_item_qty | clean_item_price | clean_total_amount |
|--------------------|----------------|------------------|--------------------|
| "TXN_4271903"      | 4              | 1                | 4                  |
| "TXN_3522028"      | 5              | 4                | 20                 |
| "TXN_7958992"      | 3              | 4                | 12                 |
| "TXN_8927252"      | 2              | 1                | 2                  |
| "TXN_6650263"      | 2              | 1.5              | 3                  |
| "TXN_5522862"      | 2              | 1                | 2                  |
| "TXN_3578141"      | 5              | 3                | 15                 |
| "TXN_2080895"      | 1              | 3                | 3                  |
| "TXN_4987129"      | 3              | —                | —                  |
| "TXN_8501819"      | 2              | 3                | 6                  |

Note: That's a lot better. We have significantly lessened the errors and missing data, cleaned up the numbers, and converted the functional numbers to NUMERIC, all while keeping the data integrity of the database. We will be setting this aside as we'll make use of this as a CTE for the next one.

### 4. raw_item_name

There are a lot of of errors to fix with this column. Checking to see if some entries are salvageable, especially with the help of the cleaned database. Realistically, one would cross-check the price changes throughout the timeline but for this particular project, the data host has disclosed that the prices are consistent throughout. Although, it never hurts to double check for inconsistencies.

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

### 5. Compilation

```sql
WITH clean_values AS(
	SELECT 
	    raw_transaction_id,
		CASE
		    -- 1. If quantity is already a valid integer, keep it
		    WHEN raw_item_qty ~ '^\d+$' 
		        THEN raw_item_qty::NUMERIC
		    -- 2. If quantity is dirty BUT price and total are valid numbers, calculate quantity
		    WHEN raw_unit_price ~ '^[0-9\.]+$' 
		     AND raw_total_amount ~ '^[0-9\.]+$' 
		     AND raw_unit_price::NUMERIC > 0  -- Prevents division by zero
		        THEN ROUND(raw_total_amount::NUMERIC / raw_unit_price::NUMERIC)::NUMERIC
		    -- 3. If quantity cannot be kept or calculated, default to NULL
		    ELSE NULL
		END AS clean_item_qty,
		CASE
		    -- 1. If unit_price is already a valid number/decimal, keep it as NUMERIC
		    WHEN raw_unit_price ~ '^[0-9\.]+$' 
		        THEN raw_unit_price::NUMERIC
		    -- 2. If unit_price is missing/dirty BUT total and qty are valid, calculate price
		    WHEN raw_item_qty ~ '^\d+$' 
		     AND raw_total_amount ~ '^[0-9\.]+$' 
		     AND raw_item_qty::NUMERIC > 0  -- Prevents division by zero
		        THEN TRIM_SCALE(raw_total_amount::NUMERIC / raw_item_qty::NUMERIC)
		    -- 3. Fallback to NULL if uncalculable
		    ELSE NULL
		END AS clean_unit_price,
		CASE
		    -- 1. If total_amount is already a valid decimal/number, keep it as NUMERIC
		    WHEN raw_total_amount ~ '^[0-9\.]+$' 
		        THEN TRIM_SCALE(raw_total_amount::NUMERIC)
		    -- 2. If total_amount is missing/dirty BUT qty and unit_price are valid numbers, calculate it
		    WHEN raw_item_qty ~ '^\d+$' 
		     AND raw_unit_price ~ '^[0-9\.]+$' 
		        THEN TRIM_SCALE(raw_item_qty::NUMERIC * raw_unit_price::NUMERIC)
		    -- 3. Fallback to NULL if uncalculable
		    ELSE NULL
		END AS clean_total_amount
	FROM cafe.raw_sales
)

SELECT 
    raw.raw_transaction_id AS transaction_id,
    raw.raw_item_name,
    cv.clean_unit_price AS unit_price,
CASE
    -- 1. If the item name is already valid, keep it
    WHEN raw.raw_item_name IN ('Cookie', 'Tea', 'Coffee', 'Juice', 'Cake', 'Sandwich', 'Smoothie', 'Salad') 
        THEN raw.raw_item_name
    -- 2. If item name is bad/missing, infer from text price matching
    WHEN COALESCE(raw.raw_item_name, '') IN ('', 'ERROR', 'UNKNOWN') THEN
        CASE raw.raw_unit_price
            WHEN '1'     THEN 'Cookie'
			WHEN '1.0'   THEN 'Cookie'
            WHEN '1.5'   THEN 'Tea'
            WHEN '1.50'  THEN 'Tea'
            WHEN '2'     THEN 'Coffee'
            WHEN '2.00'  THEN 'Coffee'
            WHEN '3'     THEN 'Juice/Cake'
            WHEN '3.00'  THEN 'Juice/Cake'
            WHEN '4'     THEN 'Sandwich/Smoothie'
            WHEN '4.00'  THEN 'Sandwich/Smoothie'
            WHEN '5'     THEN 'Salad'
            WHEN '5.00'  THEN 'Salad'
        END
    ELSE NULL
END AS clean_item_name
FROM cafe.raw_sales AS raw
LEFT JOIN clean_values cv 
       ON raw.raw_transaction_id = cv.raw_transaction_id;
```
