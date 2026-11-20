const {PGlite}=require('@electric-sql/pglite'),fs=require('node:fs'),assert=require('node:assert/strict');
(async()=>{
 const db=new PGlite();await db.waitReady;
 await db.exec(`create role anon;create role authenticated;create role service_role;create role authenticator;create schema storage;create table storage.buckets(id text primary key,name text,public boolean);create table storage.objects(id uuid,bucket_id text);create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create function auth.role() returns text language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claim.role',true),''),'authenticated')$$;`);
 for(const file of ['client_01_tables.sql','client_02_constraints.sql','client_03_functions_a.sql','client_04_functions_b.sql','client_05_functions_c.sql','client_06_functions_d.sql','client_07_triggers_policies.sql','client_10_sales_clients.sql','client_13_catalog_unit.sql']){
  try{await db.exec(fs.readFileSync('supabase/bootstrap/'+file,'utf8'));}catch(e){console.error('Bootstrap',file,e.message);throw e;}
 }
 await db.exec(fs.readFileSync('supabase/migrations/20261120_iprint_sales_workflow.sql','utf8'));await db.exec(fs.readFileSync('supabase/migrations/20261120_iprint_admin_report_sync.sql','utf8'));
 const user='11111111-1111-4111-8111-111111111111';
 await db.exec(`insert into auth.users values('${user}');insert into staff_accounts(user_id,login,name,role,active) values('${user}','test','Test employee','staff',true);select set_config('request.jwt.claim.sub','${user}',false);insert into sales_branches(id,name) values(101,'Тест рабочего филиала');insert into sales_people(id,name) values(101,'Первый сотрудник'),(102,'Другой сотрудник');insert into sales_employees(id,branch_id,person_id,name) values(101,101,101,'Первый сотрудник'),(102,101,102,'Другой сотрудник');insert into sales_shifts(id,branch_id,employee_id) values(101,101,101);insert into sales_shift_employees(shift_id,employee_id) values(101,101),(101,102);insert into sales_catalog(id,name,item_type,price,unit) values(101,'Фото 10х15','product',10,'pcs'),(102,'Ретушь','service',100,'pcs');`);
 const one=async(q,p=[])=>(await db.query(q,p)).rows[0];
 const args=[crypto.randomUUID(),null,101,101,'cash','Исходная продажа',JSON.stringify([{catalog_id:101,quantity:10,unit_price:10}])];
 let created=await one('select iprint_create_sale($1,$2,$3,$4,$5,$6,$7,p_cash_receipt_issued:=true) n',args);let sale=await one('select * from sales where order_number=$1',[created.n]);assert.equal(sale.cash_receipt_issued,true);
 await db.query('select iprint_set_cash_receipt($1,101,false)',[sale.id]);
 await one('select iprint_create_sale($1,$2,$3,$4,$5,$6,$7,p_cash_receipt_issued:=true) n',args);assert.equal((await one('select * from sales where id=$1',[sale.id])).cash_receipt_issued,false,'retry cannot overwrite a later receipt change');
 await db.exec(`insert into stock_materials(id,name,unit) values(101,'Бумага','шт');insert into stock_norms(material_id,catalog_id,qty,active) values(101,101,1,true);`);
 await db.exec(`insert into auth.users values('22222222-2222-4222-8222-222222222222');insert into staff_accounts(user_id,login,name,role,person_id,active) values('22222222-2222-4222-8222-222222222222','other','Другой сотрудник','staff',102,true);select set_config('request.jwt.claim.sub','22222222-2222-4222-8222-222222222222',false);`);
 const get=async()=>(await one('select iprint_get_sale($1,101) value',[sale.id])).value;
 let detail=await get();assert.equal(detail.editable,true);
 const items=JSON.stringify([{id:detail.items[0].id,catalog_id:101,quantity:20,unit_price:10}]);
 await db.query(`select iprint_edit_sale($1,101,$2,$3,0,0,'card','[]','Изменённый заказ',true)`,[sale.id,detail.sale.edit_version,items]);
 let updated=await one('select * from sales where id=$1',[sale.id]);assert.equal(Number(updated.total),200);assert.equal(updated.order_number,sale.order_number);assert.equal(updated.employee_id,sale.employee_id);assert.equal(updated.cash_receipt_issued,true);assert.equal(Number((await one('select sum(qty) q from stock_moves where sale_id=$1 and cancelled_at is null',[sale.id])).q),-20);
 let denied=false;try{await db.query(`select iprint_edit_sale($1,101,$2,$3,0,0,'cash','[]','stale',false)`,[sale.id,detail.sale.edit_version,items]);}catch(e){denied=e.message.includes('другим сотрудником');}assert.equal(denied,true);
 const sync=(await one('select iprint_sync_reports(101) value')).value;assert.equal(sync.synced,1);assert.equal(sync.errors.length,0);let view=(await one('select report_staff_view(101) value')).value;assert.equal(Number(view.data.rows[String(view.row)].D.v),200);
 detail=await get();await db.query(`select iprint_edit_sale($1,101,$2,$3,0,0,'cash','[]','Ещё правка',false)`,[sale.id,detail.sale.edit_version,JSON.stringify([{catalog_id:101,quantity:30,unit_price:10}])]);view=(await one('select report_staff_view(101) value')).value;assert.equal(Number(view.data.rows[String(view.row)].D.v),300,'already transferred report follows corrected sale');

 // Upgrade a populated legacy report, then exercise repeated synchronization and manual fields.
 await db.query("select report_staff_set(101,'R','\"Сохранённый комментарий\"'::jsonb)");
 await db.exec(fs.readFileSync('supabase/migrations/20261121000100_iprint_report_columns.sql','utf8'));
 view=(await one('select report_fill_shift(101,\'auto\') value')).value;
 assert.equal(Number(view.data.ncols),16);assert.equal(Number(view.data.rows[String(view.row)].C.v),300);
 assert.equal(view.data.rows[String(view.row)].N.v,'Сохранённый комментарий');
 assert.deepEqual(view.cols,['E','L','M','N','O','P']);
 assert.equal(view.data.rows[String(view.from)].P.v,'Факт в кассе');assert.equal(view.data.rows[String(view.from)].G.v,'Счет');assert.equal(view.data.rows[String(view.to)].C.v,300);assert.equal(view.data.rows[String(view.row)].J.v,1);

 for(const col of view.cols) await db.query('select report_staff_set(101,$1,$2::jsonb)',[col,JSON.stringify(col==='N'?'Комментарий':17)]);
 await db.query('select report_fill_shift(101,\'manual\')');
 view=(await one('select report_staff_view(101) value')).value;
 for(const col of view.cols) assert.equal(view.data.rows[String(view.row)][col].v,col==='N'?'Комментарий':17);
 let autoDenied=false;try{await db.query("select report_staff_set(101,'C','999'::jsonb)");}catch{autoDenied=true;}assert.equal(autoDenied,true);
 assert.equal((await one('select count(*) n from iprint_private.report_layout_backup')).n,1);
 const prior=await one('select data from report_sheets where branch_id=101');await db.query('select iprint_report_prepare(101)');assert.deepEqual((await one('select data from report_sheets where branch_id=101')).data,prior.data,'repeating prepare preserves existing cells');
 await db.exec(`insert into sales_shifts(id,branch_id,employee_id,started_at,status,ended_at) values(102,101,102,'2027-01-15T10:00:00Z','closed','2027-01-15T18:00:00Z');`);await db.query('select iprint_report_prepare(102)');assert.deepEqual((await one('select data from report_sheets where branch_id=101')).data.rows[String(view.row)],prior.data.rows[String(view.row)],'new month preserves old data');

 await db.exec(`insert into loyalty_customers(name,phone) values('Тест клиента','79000000001');insert into loyalty_transactions(customer_id,transaction_type,order_amount,points,comment,available_at) select id,'adjustment',0,50,'Тестовый баланс',now() from loyalty_customers where phone='79000000001';`);
 const club=(await one("select id from loyalty_customers where phone='79000000001'")).id;
 const clubOrder=(await one("select iprint_create_sale($1,null,101,102,'bank_account','Клубная продажа',$2,p_loyalty_customer_id:=$3,p_loyalty_points:=10) n",[crypto.randomUUID(),JSON.stringify([{catalog_id:101,quantity:10,unit_price:10}]),club])).n;
 const cs=await one('select * from sales where order_number=$1',[clubOrder]);
 await db.query("select iprint_edit_sale($1,101,0,$2,0,20,'bank_account','[]','Изменено',true)",[cs.id,JSON.stringify([{catalog_id:101,quantity:20,unit_price:10}])]);
 const account=await one('select * from loyalty_get_customer($1)',[club]);assert.equal(Number(account.balance),30);assert.equal(Number(account.pending_points),10);assert.equal(Number(account.order_count),1,'editing is not another loyalty purchase');assert.equal(Number((await one('select amount from customer_debts where sale_id=$1',[cs.id])).amount),180);
 const previous=await one('select total,edit_version from sales where id=$1',[cs.id]);denied=false;try{await db.query("select iprint_edit_sale($1,101,$2,$3,0,20,'split',$4,'bad split',false)",[cs.id,previous.edit_version,JSON.stringify([{catalog_id:101,quantity:20,unit_price:10}]),JSON.stringify([{method:'cash',amount:1},{method:'card',amount:1}])]);}catch{denied=true;}assert.equal(denied,true);assert.deepEqual(await one('select total,edit_version from sales where id=$1',[cs.id]),previous,'invalid edit rolls back completely');

 await db.exec("select set_config('request.jwt.claim.sub','',false)");denied=false;try{await get();}catch(e){denied=e.message.includes('Требуется вход');}assert.equal(denied,true);
 assert.equal((await one("select has_function_privilege('anon','public.iprint_get_sale(bigint,bigint)','execute') p")).p,false);
 console.log('PASS iПринт DB: atomic creation/receipt replay, any creator, version conflicts, stock/payment updates, revenue report repair + refresh, new month preservation, auth restrictions.');await db.close();
})().catch(e=>{console.error(e.message,e.where||'');process.exit(1)});
