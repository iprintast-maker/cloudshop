-- Already applied to the client project. For a fresh installation only:
-- first create and confirm admin@staff.cloudshop.local in Supabase Auth.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE email = 'admin@staff.cloudshop.local' AND email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Create the confirmed admin user first';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff_accounts) OR EXISTS (SELECT 1 FROM public.sales_branches) THEN
    RAISE EXCEPTION 'Initial setup already exists';
  END IF;
END $$;
WITH branch AS (
  INSERT INTO public.sales_branches(name,is_active,is_test,is_workshop)
  VALUES ('Основной филиал',true,false,false) RETURNING id
), person AS (
  INSERT INTO public.sales_people(name,is_active)
  VALUES ('Администратор',true) RETURNING id
), employee AS (
  INSERT INTO public.sales_employees(branch_id,person_id,name,is_active)
  SELECT branch.id,person.id,'Администратор',true FROM branch CROSS JOIN person
  RETURNING person_id
)
INSERT INTO public.staff_accounts(user_id,login,name,role,active,person_id)
SELECT u.id,'admin','Администратор','admin',true,e.person_id
FROM auth.users u CROSS JOIN employee e WHERE u.email = 'admin@staff.cloudshop.local';
COMMIT;
