WITH clean_values AS(
	SELECT 
	    raw_transaction_id,
		CASE
		    -- 1. If quantity is already a valid integer, keep it
		    WHEN raw_item_qty ~ '^\d+$' 
		        THEN raw_item_qty::NUMERIC
		    -- 2. If quantity is dirty BUT price and total are valid numbers, calculate quantity
		    WHEN raw_unit_price ~ '^\d+(\.\d+)?$' 
		     AND raw_total_amount ~ '^\d+(\.\d+)?$' 
		     AND raw_unit_price::NUMERIC > 0  -- Prevents division by zero
		        THEN ROUND(raw_total_amount::NUMERIC / raw_unit_price::NUMERIC)::NUMERIC
		    -- 3. If quantity cannot be kept or calculated, default to NULL
		    ELSE NULL
		END AS clean_item_qty,
		CASE
		    -- 1. If unit_price is already a valid number/decimal, keep it as NUMERIC
		    WHEN raw_unit_price ~ '^\d+(\.\d+)?$' 
		        THEN raw_unit_price::NUMERIC
		    -- 2. If unit_price is missing/dirty BUT total and qty are valid, calculate price
		    WHEN raw_item_qty ~ '^\d+$' 
		     AND raw_total_amount ~ '^\d+(\.\d+)?$' 
		     AND raw_item_qty::NUMERIC > 0  -- Prevents division by zero
		        THEN TRIM_SCALE(raw_total_amount::NUMERIC / raw_item_qty::NUMERIC)
		    -- 3. Fallback to NULL if uncalculable
		    ELSE NULL
		END AS clean_unit_price,
		CASE
		    -- 1. If total_amount is already a valid decimal/number, keep it as NUMERIC
		    WHEN raw_total_amount ~ '^\d+(\.\d+)?$' 
		        THEN TRIM_SCALE(raw_total_amount::NUMERIC)
		    -- 2. If total_amount is missing/dirty BUT qty and unit_price are valid numbers, calculate it
		    WHEN raw_item_qty ~ '^\d+$' 
		     AND raw_unit_price ~ '^\d+(\.\d+)?$' 
		        THEN TRIM_SCALE(raw_item_qty::NUMERIC * raw_unit_price::NUMERIC)
		    -- 3. Fallback to NULL if uncalculable
		    ELSE NULL
		END AS clean_total_amount,
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
	FROM cafe.raw_sales
)

SELECT 
    raw.raw_transaction_id AS transaction_id,
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
	END AS item_name,
	cv.clean_item_qty AS item_qty,
	cv.clean_unit_price AS unit_price,
	cv.clean_total_amount AS total_amount,
	cv.clean_payment_type AS payment_type,
	cv.clean_store_location AS store_location,
	CASE 
        WHEN cv.clean_sale_date IS NULL 
        THEN NULL
        ELSE TO_DATE(clean_sale_date, 'FMMM-FMDD-YYYY')
    END AS sale_date
FROM cafe.raw_sales AS raw
LEFT JOIN clean_values cv
	ON raw.raw_transaction_id = cv.raw_transaction_id