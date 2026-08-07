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

```sql
SELECT 
    raw_transaction_id,
	CASE 
	    WHEN raw_payment_type IS NULL 
	      OR UPPER(TRIM(raw_payment_type)) IN ('ERROR', 'UNKNOWN') 
	    THEN NULL
	    ELSE raw_payment_type
	END AS clean_payment_type,
	CASE 
	    WHEN raw_store_location IS NULL 
	      OR UPPER(TRIM(raw_store_location)) IN ('ERROR', 'UNKNOWN') 
	    THEN NULL
	    ELSE raw_store_location
	END AS clean_store_location,
	CASE
	    WHEN raw_sale_date IS NULL 
	      OR UPPER(TRIM(raw_sale_date)) IN ('ERROR', 'UNKNOWN') 
	    THEN NULL
	    ELSE raw_sale_date
	END AS clean_sale_date
FROM cafe.raw_sales;
```

OUT:
| raw_transaction_id | clean_payment_type | clean_store_location | clean_sale_date |
|--------------------|--------------------|----------------------|-----------------|
| "TXN_1961373"      | "Credit Card"      | "Takeaway"           | "9/8/2023"      |
| "TXN_4977031"      | "Cash"             | "In-store"           | "5/16/2023"     |
| "TXN_4271903"      | "Credit Card"      | "In-store"           | "7/19/2023"     |
| "TXN_7034554"      |                    |                      | "4/27/2023"     |
| "TXN_3160411"      | "Digital Wallet"   | "In-store"           | "6/11/2023"     |
| "TXN_2602893"      | "Credit Card"      |                      | "3/31/2023"     |
| "TXN_4433211"      |                    | "Takeaway"           | "10/6/2023"     |
| "TXN_6699534"      | "Cash"             |                      | "10/28/2023"    |
| "TXN_4717867"      |                    | "Takeaway"           | "7/28/2023"     |
| "TXN_2064365"      |                    | "In-store"           | "12/31/2023"    |

The date is still non-functional due to formatting issues, which we will fix later on. However, the rest of the data are functional as is.

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
Now all of the Cookies, Tea, Coffee, and Salad are easily identifiable due to their prices; we will be replacing those with the same price their corresponding item names. However, for Coffee and Cake, they have the same price, as well as for Sandwich and Smoothie. With these ambiguous items, we will be leaving them as NULL to avoid data inaccuracies.

### 5. Compilation

Initially, I have splitted both step 2 and step 3 to have their own CTEs but later realized that they don't need to be. Since the initial plan would use more resources, I opted to only use a single CTE. Below is the final compiled result:

```sql
WITH clean_values AS (
    SELECT 
        raw_transaction_id,
        raw_item_name,
        
        -- 1. Quantity: Keep valid integer OR calculate from total/price
        CASE
            WHEN raw_item_qty ~ '^\d+$' 
                THEN raw_item_qty::NUMERIC
            WHEN raw_unit_price ~ '^\d+(\.\d+)?$' 
             AND raw_total_amount ~ '^\d+(\.\d+)?$' 
             AND raw_unit_price::NUMERIC > 0 
                THEN ROUND(raw_total_amount::NUMERIC / raw_unit_price::NUMERIC)::NUMERIC
            ELSE NULL
        END AS clean_item_qty,

        -- 2. Unit Price: Keep valid numeric OR calculate from total/qty
        CASE
            WHEN raw_unit_price ~ '^\d+(\.\d+)?$' 
                THEN raw_unit_price::NUMERIC
            WHEN raw_item_qty ~ '^\d+$' 
             AND raw_total_amount ~ '^\d+(\.\d+)?$' 
             AND raw_item_qty::NUMERIC > 0 
                THEN TRIM_SCALE(raw_total_amount::NUMERIC / raw_item_qty::NUMERIC)
            ELSE NULL
        END AS clean_unit_price,

        -- 3. Total Amount: Keep valid numeric OR calculate from qty*price
        CASE
            WHEN raw_total_amount ~ '^\d+(\.\d+)?$' 
                THEN TRIM_SCALE(raw_total_amount::NUMERIC)
            WHEN raw_item_qty ~ '^\d+$' 
             AND raw_unit_price ~ '^\d+(\.\d+)?$' 
                THEN TRIM_SCALE(raw_item_qty::NUMERIC * raw_unit_price::NUMERIC)
            ELSE NULL
        END AS clean_total_amount,

        -- 4. Text Dimensions: Standardize empty/error strings to NULL
        CASE 
            WHEN UPPER(TRIM(raw_payment_type)) IN ('ERROR', 'UNKNOWN', '') THEN NULL 
            ELSE raw_payment_type 
        END AS clean_payment_type,
        
        CASE 
            WHEN UPPER(TRIM(raw_store_location)) IN ('ERROR', 'UNKNOWN', '') THEN NULL 
            ELSE raw_store_location 
        END AS clean_store_location,
        
        CASE 
            WHEN UPPER(TRIM(raw_sale_date)) IN ('ERROR', 'UNKNOWN', '') THEN NULL 
            ELSE raw_sale_date 
        END AS clean_sale_date

    FROM cafe.raw_sales
)

SELECT 
    raw_transaction_id AS transaction_id,

    -- Item Name Inference
    CASE
        WHEN raw_item_name IN ('Cookie', 'Tea', 'Coffee', 'Juice', 'Cake', 'Sandwich', 'Smoothie', 'Salad') 
            THEN raw_item_name
        WHEN COALESCE(raw_item_name, '') IN ('', 'ERROR', 'UNKNOWN') THEN
            CASE clean_unit_price
                WHEN 1.00 THEN 'Cookie'
                WHEN 1.50 THEN 'Tea'
                WHEN 2.00 THEN 'Coffee'
                WHEN 5.00 THEN 'Salad'
                ELSE NULL -- Leaves ambiguous $3/$4 prices as NULL rather than bad strings
            END
        ELSE NULL
    END AS item_name,

    clean_item_qty AS item_qty,
    clean_unit_price AS unit_price,
    clean_total_amount AS total_amount,
    clean_payment_type AS payment_type,
    clean_store_location AS store_location,
    TO_DATE(clean_sale_date, 'FMMM-FMDD-YYYY') AS sale_date  -- Safe Date Cast

FROM clean_values;
```

OUT:
| transaction_id | item_name  | item_qty | unit_price | total_amount | payment_type     | store_location | sale_date    |
|----------------|------------|----------|------------|--------------|------------------|----------------|--------------|
| "TXN_1000555"  | "Tea"      | 1        | 1.5        | 1.5          | "Credit Card"    | "In-store"     | "2023-10-19" |
| "TXN_1001832"  | "Salad"    | 2        | 5          | 10           | "Cash"           | "Takeaway"     |              |
| "TXN_1002457"  | "Cookie"   | 5        | 1          | 5            | "Digital Wallet" | "Takeaway"     | "2023-09-29" |
| "TXN_1003246"  | "Juice"    | 2        | 3          | 6            | "2023-02-15"     |                |              |
| "TXN_1004184"  | "Smoothie" | 1        | 4          | 4            | "Credit Card"    | "In-store"     | "2023-05-18" |
| "TXN_1004563"  | "Tea"      | 5        | 1.5        | 7.5          | "Credit Card"    | "In-store"     | "2023-10-28" |
| "TXN_1005331"  | "Coffee"   | 1        | 2          | 2            | "Digital Wallet" | "Takeaway"     | "2023-11-04" |
| "TXN_1005377"  | "Cake"     | 5        | 3          | 15           | "Digital Wallet" | "Takeaway"     | "2023-06-03" |
| "TXN_1005472"  | "Coffee"   | 4        | 2          | 8            | "Credit Card"    |                | "2023-04-21" |
| "TXN_1006942"  | "Salad"    | 1        | 5          | 5            | "Credit Card"    | "In-store"     | "2023-11-30" |

Note: 
That finalizes the cleaning of the dirty_cafe_sales.csv and its conversion to having functional data. The next step would be making insights and presentation.
