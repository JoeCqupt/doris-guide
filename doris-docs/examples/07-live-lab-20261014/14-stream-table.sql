CREATE TABLE doris_book.stream_events(id INT,v INT) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 1 PROPERTIES('replication_num'='1');
