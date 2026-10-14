SET enable_profile=true; SET auto_profile_threshold_ms=0;-- 先成功完成 setup.sql 并确认写入可见。此文件只读，可以重复查询。
USE doris_book;
SHOW CREATE TABLE orders_intro_v1;
SELECT * FROM orders_intro_v1 ORDER BY order_date, order_id;
SELECT COUNT(*) AS total_rows FROM orders_intro_v1;

SELECT city, COUNT(*) AS order_count, SUM(amount) AS revenue,
       COUNT(DISTINCT user_id) AS buyers
FROM orders_intro_v1
WHERE order_date = '2026-10-01' AND status = 'PAID'
GROUP BY city
ORDER BY city;

SELECT COUNT(*) AS paid_orders, SUM(amount) AS revenue,
       COUNT(DISTINCT user_id) AS buyers
FROM orders_intro_v1
WHERE order_date = '2026-10-01' AND status = 'PAID';

EXPLAIN
SELECT city, COUNT(*) AS order_count, SUM(amount) AS revenue,
       COUNT(DISTINCT user_id) AS buyers
FROM orders_intro_v1
WHERE order_date = '2026-10-01' AND status = 'PAID'
GROUP BY city
ORDER BY city;

