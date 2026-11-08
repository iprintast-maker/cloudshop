-- Server-side staff-admin validates the Auth user and requires an active admin account.
-- These permissions belong only to the server service_role, never the browser.
GRANT SELECT, INSERT, UPDATE ON TABLE public.staff_accounts TO service_role;
