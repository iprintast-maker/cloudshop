alter role authenticator set pgrst.db_pre_request = 'public.staff_request_guard';
notify pgrst, 'reload config';