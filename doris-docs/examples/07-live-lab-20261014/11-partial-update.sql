SET enable_unique_key_partial_update=true; SET enable_insert_strict=true; INSERT INTO doris_book.unique_updates(id,score,seq) VALUES(7,30,110); SELECT * FROM doris_book.unique_updates ORDER BY id;
