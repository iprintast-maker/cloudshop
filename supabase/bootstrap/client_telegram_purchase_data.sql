ALTER TABLE public.stock_requests ADD COLUMN IF NOT EXISTS urgent boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.telegram_purchase_data(p_chat_id bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.report_recipients WHERE chat_id=p_chat_id AND active) THEN RETURN NULL; END IF;
  RETURN (SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'name',r.name,'qty',r.qty,'unit',m.unit,'code',m.purchase_code,
    'branch',b.name,'urgent',r.urgent,'comment',r.comment
  ) ORDER BY r.urgent DESC,r.created_at,r.id),'[]'::jsonb)
  FROM public.stock_requests r LEFT JOIN public.stock_materials m ON m.id=r.material_id
  LEFT JOIN public.sales_branches b ON b.id=r.branch_id WHERE r.status<>'bought');
END $$;
REVOKE ALL ON FUNCTION public.telegram_purchase_data(bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.telegram_purchase_data(bigint) TO service_role;
