-- One-use invitations for explicitly approved Telegram usernames.
CREATE TABLE IF NOT EXISTS public.telegram_recipient_invites (
 username text PRIMARY KEY CHECK (username=lower(username)),
 recipient_name text NOT NULL,
 expires_at timestamptz NOT NULL DEFAULT now()+interval '7 days',
 claimed_chat_id bigint,
 claimed_at timestamptz
);
ALTER TABLE public.telegram_recipient_invites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.telegram_recipient_invites FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.telegram_claim_recipient(p_username text,p_chat_id bigint,p_user_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE invite public.telegram_recipient_invites%ROWTYPE;
BEGIN
 IF p_chat_id IS NULL OR p_chat_id<=0 OR p_chat_id IS DISTINCT FROM p_user_id THEN RETURN false; END IF;
 SELECT * INTO invite FROM public.telegram_recipient_invites
 WHERE username=lower(p_username) AND expires_at>now() FOR UPDATE;
 IF NOT FOUND THEN RETURN false; END IF;
 IF invite.claimed_chat_id IS NOT NULL THEN RETURN false; END IF;
 INSERT INTO public.report_recipients(chat_id,name,active) VALUES(p_chat_id,invite.recipient_name,true)
 ON CONFLICT(chat_id) DO UPDATE SET name=EXCLUDED.name,active=true;
 UPDATE public.telegram_recipient_invites SET claimed_chat_id=p_chat_id,claimed_at=now() WHERE username=invite.username;
 RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.telegram_claim_recipient(text,bigint,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.telegram_claim_recipient(text,bigint,bigint) TO service_role;
