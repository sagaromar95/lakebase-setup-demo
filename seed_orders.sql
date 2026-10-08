-- Data on Tap — demo orders for the analytics post (Post 3)
-- =========================================================
-- Loads a realistic set of orders + line items so the analytics queries
-- (best-sellers, revenue by branch, VAT collected) return real numbers.
--
-- Run AFTER schema.sql + seed.sql (needs branches, menu, customers).
-- Deterministic: no random(), so every run produces the SAME figures and
-- your screenshots stay stable. Safe to re-run — it clears prior orders first.
--
-- Counts are fixed at 30 orders and 90 line items. Pizzas are weighted so sales
-- vary and "best-seller" has a clear winner (by units sold):
--   Pepperoni > Margherita > BBQ Chicken > Veggie Supreme > Four Cheese > Vegan Garden.
--
-- Note: this intentionally does NOT decrement `inventory`. It keeps the seed
-- simple, avoids negative stock, and leaves the 36 inventory rows (and the
-- Post 2 branching demo) untouched.

BEGIN;

-- Idempotent: wipe any existing orders so counts don't double on re-run.
DELETE FROM order_items;
DELETE FROM orders;
ALTER SEQUENCE orders_order_id_seq RESTART WITH 500001;

-- 1) Orders: 30, spread across the 6 branches, 5 customers, and the last ~2 weeks.
--    Money columns are placeholders here; step 3 fills them from the line items.
INSERT INTO orders (branch_id, customer_id, partner_id, order_time,
                    delivery_mode, subtotal, vat_percent, vat_amount, total_price, status)
SELECT
    ((i - 1) % 6) + 1                                        AS branch_id,
    100001 + (i * 7 % 5)                                     AS customer_id,
    CASE WHEN i % 3 = 0 THEN 5001 + (i % 4) END              AS partner_id,
    now() - ((i % 14) || ' days')::interval
          - ((i * 37 % 600) || ' minutes')::interval         AS order_time,
    CASE WHEN i % 3 = 0 THEN 'delivery' ELSE 'pickup' END    AS delivery_mode,
    0, 12.00, 0, 0,                                          -- filled in step 3
    CASE WHEN i % 14 >= 2 THEN 'delivered' ELSE 'preparing' END AS status
FROM generate_series(1, 30) AS g(i);

-- 2) Line items: 90 total, weighted so pizzas sell different amounts.
--    item_counts sums to 90 (= 30 orders x 3 items). Quantities cycle 1-3.
--    Items are interleaved across rounds so each order gets a mix of pizzas,
--    then grouped three-to-an-order onto order_id 500001..500030.
WITH item_counts(menu_id, n) AS (
    VALUES (5, 20), (1, 18), (6, 16), (3, 14), (2, 12), (4, 10)   -- 20+18+16+14+12+10 = 90
),
rounds AS (
    SELECT ic.menu_id,
           gs.k                   AS round,
           1 + ((gs.k - 1) % 3)   AS quantity          -- 1,2,3,1,2,3,...
    FROM item_counts ic
    CROSS JOIN LATERAL generate_series(1, ic.n) AS gs(k)
),
numbered AS (
    SELECT menu_id, quantity,
           row_number() OVER (ORDER BY round, menu_id) AS rn
    FROM rounds
)
INSERT INTO order_items (order_id, menu_id, quantity, unit_price, line_total)
SELECT 500001 + ((n.rn - 1) / 3),            -- 3 items per order -> 500001..500030
       n.menu_id, n.quantity, m.price, n.quantity * m.price
FROM numbered n
JOIN menu m ON m.id = n.menu_id;

-- 3) Roll the line items up into each order's money columns (VAT = 12%, Sweden).
UPDATE orders o
SET subtotal    = s.subtotal,
    vat_amount  = ROUND(s.subtotal * o.vat_percent / 100, 2),
    total_price = s.subtotal + ROUND(s.subtotal * o.vat_percent / 100, 2)
FROM (
    SELECT order_id, SUM(line_total) AS subtotal
    FROM order_items
    GROUP BY order_id
) s
WHERE s.order_id = o.order_id;

COMMIT;

-- Sanity check (optional): 30 orders, 90 line items, and a best-seller ranking.
-- SELECT (SELECT count(*) FROM orders) AS orders,
--        (SELECT count(*) FROM order_items) AS order_items;
-- SELECT m.pizza_name, SUM(oi.quantity) AS pizzas_sold
-- FROM order_items oi JOIN menu m ON m.id = oi.menu_id
-- GROUP BY m.pizza_name ORDER BY pizzas_sold DESC;
