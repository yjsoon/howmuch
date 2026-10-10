INSERT INTO plans(id,name) VALUES ('p','Plan');
INSERT INTO accounts(id,plan_id,name) VALUES ('cash','p','Cash'),('card','p','Card');
INSERT INTO payees(id,plan_id,name) VALUES ('grocer','p','Grocer');
INSERT INTO category_groups(id,plan_id,name) VALUES ('g','p','Living');
INSERT INTO categories(id,plan_id,category_group_id,name) VALUES ('food','p','g','Food');
INSERT INTO ynab_raw_objects(plan_id,object_type,object_id,payload_json,deleted) VALUES
 ('p','month','2026-01-01','{"month":"2026-01-01"}',0),
 ('p','scheduled_transaction','s1','{"id":"s1","account_id":"cash","date_first":"2026-01-01","date_next":"2026-11-01","frequency":"monthly","amount":-500,"payee_id":"grocer","category_id":"food","deleted":false}',0),
 ('p','scheduled_transaction','s2','{"id":"s2","account_id":"card","date_first":"2026-02-01","date_next":"2026-11-02","frequency":"weekly","amount":-300,"payee_id":"ghost","category_id":null,"deleted":false}',0),
 ('p','scheduled_subtransaction','s2:a','{"id":"a","scheduled_transaction_id":"s2","amount":-100,"category_id":"food","deleted":false}',0),
 ('p','scheduled_subtransaction','s2:b','{"id":"b","scheduled_transaction_id":"s2","amount":-200,"category_id":"food","deleted":false}',0),
 ('p','scheduled_subtransaction','s2:c','{"id":"c","scheduled_transaction_id":"s2","amount":-9,"category_id":"food","deleted":true}',0),
 ('p','scheduled_transaction','s3','{"id":"s3","account_id":"cash","date_first":"2026-03-01","date_next":"2026-12-01","frequency":"yearly","amount":-1,"deleted":true}',1);
