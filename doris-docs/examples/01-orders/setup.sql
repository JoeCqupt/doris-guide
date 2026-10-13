-- 教学示例：未在 Doris 上执行；适用于已有可用 BE 的存算一体开发环境。
-- 先确认 doris_book 数据库名可供本书实验使用，且 orders_intro_v1 不存在。
-- CREATE TABLE 故意不使用 IF NOT EXISTS，避免悄悄复用未知表。
-- 一旦任一句失败就停止，不要在失败后继续 INSERT。
-- 此文件仅初始化一次；重复 INSERT 会在 Duplicate Key 表中追加重复数据。
CREATE DATABASE IF NOT EXISTS doris_book;
USE doris_book;

CREATE TABLE orders_intro_v1 (
    order_date DATE NOT NULL,
    order_id BIGINT NOT NULL,
    user_id BIGINT NOT NULL,
    city VARCHAR(32) NOT NULL,
    amount DECIMAL(12, 2) NOT NULL,
    status VARCHAR(16) NOT NULL
)
ENGINE=OLAP
DUPLICATE KEY(order_date, order_id)
DISTRIBUTED BY HASH(order_id) BUCKETS 2
PROPERTIES ("replication_num" = "1");

INSERT INTO orders_intro_v1 VALUES
('2026-10-01', 1, 101, '北京', 100.00, 'PAID'),
('2026-10-01', 2, 102, '北京',  80.00, 'PAID'),
('2026-10-01', 3, 101, '上海', 120.00, 'PAID'),
('2026-10-01', 4, 103, '上海',  60.00, 'PAID'),
('2026-10-01', 5, 101, '北京',  20.00, 'PAID'),
('2026-10-01', 6, 104, '杭州', 200.00, 'PAID'),
('2026-10-01', 7, 105, '上海',  90.00, 'CANCELLED'),
('2026-10-02', 8, 102, '杭州',  50.00, 'PAID');
