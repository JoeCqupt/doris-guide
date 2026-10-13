-- Step 11: only run once for a new table; no DROP/TRUNCATE.
CREATE DATABASE IF NOT EXISTS doris_learning;
USE doris_learning;
CREATE TABLE step11_orders (
    order_date DATE NOT NULL,
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    city VARCHAR(32) NOT NULL,
    amount DECIMAL(10,2) NOT NULL,
    status VARCHAR(16) NOT NULL
)
DUPLICATE KEY(order_date, order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 1
PROPERTIES ("replication_num" = "1");

INSERT INTO step11_orders VALUES
('2026-10-08', 1001, 101, 'Beijing', 100.00, 'PAID'),
('2026-10-08', 1002, 101, 'Beijing',  50.00, 'PAID'),
('2026-10-08', 1003, 102, 'Beijing',  80.00, 'PAID'),
('2026-10-08', 1004, 103, 'Shanghai',120.00, 'PAID'),
('2026-10-08', 1005, 103, 'Shanghai', 30.00, 'PAID'),
('2026-10-08', 1006, 101, 'Shanghai', 90.00, 'PAID'),
('2026-10-08', 1007, 104, 'Beijing', 999.00, 'UNPAID'),
('2026-10-07', 1008, 105, 'Shanghai',500.00, 'PAID');

SELECT * FROM step11_orders ORDER BY order_date, order_id;
