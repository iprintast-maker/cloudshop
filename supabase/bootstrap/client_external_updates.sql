-- Offers may be sent from the owner's main site without a separate developer login.
-- Existing client approval RPCs and all financial/staff permissions stay unchanged.
ALTER TABLE public.site_updates ADD COLUMN IF NOT EXISTS publisher_project text;
ALTER TABLE public.site_updates ADD COLUMN IF NOT EXISTS publisher_user_id uuid;
CREATE INDEX IF NOT EXISTS site_updates_publisher_created_idx
  ON public.site_updates(publisher_project,created_at DESC);
COMMENT ON COLUMN public.site_updates.publisher_user_id IS 'User ID in the publisher project, not a local Auth user';
