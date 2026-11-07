-- PostgREST invokes the pre-request guard as the request role.
-- Trusted server functions need permission to enter this guard as service_role.
-- The guard already explicitly permits service_role; no user permissions change.
GRANT EXECUTE ON FUNCTION public.staff_request_guard() TO service_role;
