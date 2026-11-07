CREATE TRIGGER customer_debts_from_payment AFTER INSERT ON public.sale_payments FOR EACH ROW EXECUTE FUNCTION customer_debts_from_payment();
CREATE TRIGGER stock_sale AFTER UPDATE OF status, created_at ON public.sales FOR EACH ROW EXECUTE FUNCTION stock_trg_sale();
CREATE TRIGGER announcement_track AFTER INSERT OR UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION announcement_track_products();
CREATE TRIGGER announcement_track AFTER INSERT OR UPDATE ON public.sales_catalog FOR EACH ROW EXECUTE FUNCTION announcement_track_catalog();
CREATE TRIGGER stock_sale_item AFTER INSERT OR UPDATE OF quantity, catalog_id, variant_material_id ON public.sale_items FOR EACH ROW EXECUTE FUNCTION stock_trg_sale_item();

do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname='public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- helper: standard policies
do $$
declare r record;
begin
  -- staff read
  for r in select unnest(array['announcement_reads','announcements','guide_questions','guide_test_results','message_templates','pickup_orders','plotter_film_prices','products','sale_items','sale_payments','sales','sales_branch_order_counters','sales_branches','sales_catalog','sales_employees','sales_pay_rates','sales_people','sales_person_tasks','sales_returns','sales_shift_employees','sales_shift_task_completions','sales_shift_tasks','sales_shifts','sales_upsell_rules','schedule_columns','schedule_months','schedule_requests','schedule_rules','sheet_lamination_price_rules','sheet_material_price_rules','sheet_print_price_rules','sheet_service_price_rules','shirt_print_price_rules','stock_materials','stock_moves','stock_norms','stock_purchase_hide','stock_purchase_lists','stock_requests','test_questions','tests']) t loop
    execute format('create policy %I on public.%I for select to authenticated using (public.is_staff())', r.t||'_read', r.t);
  end loop;
  -- admin read
  for r in select unnest(array['announcement_changes','loyalty_customers','loyalty_gift_rules','loyalty_transactions','report_fills','report_sheets','schedule_cells','test_answers','test_attempts']) t loop
    execute format('create policy %I on public.%I for select to authenticated using (public.is_admin())', r.t||'_admin_read', r.t);
  end loop;
  -- admin insert
  for r in select unnest(array['announcements','guide_questions','loyalty_gift_rules','products','report_sheets','sales_branch_order_counters','sales_branches','sales_catalog','sales_employees','sales_pay_rates','sales_people','sales_person_tasks','sales_shift_tasks','sales_upsell_rules','schedule_cells','schedule_columns','schedule_months','schedule_requests','schedule_rules','sheet_lamination_price_rules','sheet_material_price_rules','sheet_print_price_rules','sheet_service_price_rules','test_questions','tests']) t loop
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_admin())', r.t||'_admin_insert', r.t);
  end loop;
  -- admin update
  for r in select unnest(array['announcement_changes','announcements','guide_questions','loyalty_customers','loyalty_gift_rules','products','report_sheets','sales_branch_order_counters','sales_branches','sales_catalog','sales_employees','sales_pay_rates','sales_people','sales_person_tasks','sales_shift_tasks','sales_upsell_rules','schedule_cells','schedule_columns','schedule_months','schedule_requests','schedule_rules','sheet_lamination_price_rules','sheet_material_price_rules','sheet_print_price_rules','sheet_service_price_rules','test_questions','tests']) t loop
    execute format('create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())', r.t||'_admin_update', r.t);
  end loop;
  -- admin delete
  for r in select unnest(array['announcements','guide_questions','guide_test_results','loyalty_customers','loyalty_gift_rules','products','sales_branches','sales_catalog','sales_employees','sales_pay_rates','sales_people','sales_person_tasks','sales_shift_tasks','sales_upsell_rules','sheet_lamination_price_rules','sheet_material_price_rules','sheet_print_price_rules','sheet_service_price_rules','test_questions','tests']) t loop
    execute format('create policy %I on public.%I for delete to authenticated using (public.is_admin())', r.t||'_admin_delete', r.t);
  end loop;
  -- admin all
  for r in select unnest(array['message_templates','plotter_film_prices','shirt_print_price_rules','stock_materials','stock_norms']) t loop
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', r.t||'_admin_all', r.t);
  end loop;
  -- staff insert
  for r in select unnest(array['sale_items','sale_payments','sales','sales_returns','sales_shift_employees','sales_shift_task_completions','sales_shifts','test_answers','test_attempts']) t loop
    execute format('create policy %I on public.%I for insert to authenticated with check (public.is_staff())', r.t||'_staff_insert', r.t);
  end loop;
  -- staff update
  for r in select unnest(array['sale_payments','sales','sales_shift_employees','sales_shift_task_completions','sales_shifts']) t loop
    execute format('create policy %I on public.%I for update to authenticated using (public.is_staff()) with check (public.is_staff())', r.t||'_staff_update', r.t);
  end loop;
end $$;

create policy branch_checks_read on public.branch_checks for select to authenticated using (is_staff());
create policy branch_checks_insert on public.branch_checks for insert to authenticated with check (is_staff());
create policy branch_checks_update on public.branch_checks for update to authenticated using (is_staff()) with check (is_staff());
create policy branch_checks_del on public.branch_checks for delete to authenticated using (is_staff());
create policy guide_test_results_insert on public.guide_test_results for insert to authenticated with check ((score >= 0) AND (total > 0) AND (score <= total) AND is_staff());
create policy schedule_cells_read_published on public.schedule_cells for select to authenticated using ((EXISTS ( SELECT 1 FROM schedule_months m WHERE ((m.month = (date_trunc('month'::text, (schedule_cells.work_date)::timestamp with time zone))::date) AND m.published))) AND is_staff());
create policy staff_accounts_read on public.staff_accounts for select to authenticated using ((user_id = auth.uid()) OR is_admin());

insert into storage.buckets(id,name,public) values('product-images','product-images',true) on conflict do nothing;
create policy images_public_read on storage.objects for select to public using (bucket_id = 'product-images');
create policy images_admin_insert on storage.objects for insert to authenticated with check ((bucket_id = 'product-images') AND public.is_admin());
create policy images_admin_update on storage.objects for update to authenticated using ((bucket_id = 'product-images') AND public.is_admin()) with check ((bucket_id = 'product-images') AND public.is_admin());
create policy images_admin_del on storage.objects for delete to authenticated using ((bucket_id = 'product-images') AND public.is_admin());

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;
grant execute on function public.staff_request_guard() to anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;