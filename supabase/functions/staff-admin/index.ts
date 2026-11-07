// Логины сотрудников: список, создание, изменение, отключение, удаление.
// Вызывать может только вошедший администратор (staff_accounts.role = 'admin').
// Логин превращается во внутренний адрес login@STAFF_EMAIL_DOMAIN; писем на него не отправляется.
import { createClient } from "jsr:@supabase/supabase-js@2";

const STAFF_EMAIL_DOMAIN = "staff.cloudshop.local";
const LOGIN_RE = /^[a-z0-9._-]{3,40}$/;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });
const fail = (error: string, status = 400) => json({ error }, status);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return fail("Метод не поддерживается", 405);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: who } = await db.auth.getUser(jwt);
  if (!who?.user) return fail("Требуется вход", 401);
  const { data: me } = await db.from("staff_accounts").select("role,active").eq("user_id", who.user.id).maybeSingle();
  if (!me?.active || me.role !== "admin") return fail("Только для администратора", 403);

  let b: Record<string, unknown>;
  try { b = await req.json(); } catch { return fail("Неверный запрос"); }
  const role = b.role === "admin" ? "admin" : "staff";
  const name = typeof b.name === "string" ? b.name.trim() : "";
  const password = typeof b.password === "string" ? b.password : "";
  const personId = Number(b.person_id) || null;
  const userId = typeof b.user_id === "string" ? b.user_id : "";
  if (userId && userId === who.user.id && (b.action === "delete" || b.active === false || (b.role && role !== "admin"))) {
    return fail("Нельзя отключить или понизить собственную учётную запись");
  }

  switch (b.action) {
    case "list": {
      const { data, error } = await db.from("staff_accounts").select("*").order("role").order("name");
      if (error) return fail(error.message, 500);
      const users = await db.auth.admin.listUsers({ perPage: 1000 });
      const seen = new Map((users.data?.users ?? []).map((u) => [u.id, u.last_sign_in_at]));
      return json({ accounts: (data ?? []).map((a) => ({ ...a, last_sign_in_at: seen.get(a.user_id) ?? null })) });
    }
    case "create": {
      const login = String(b.login ?? "").trim().toLowerCase();
      if (!LOGIN_RE.test(login)) return fail("Логин: от 3 символов, латиница, цифры, точка, дефис");
      if (password.length < 8) return fail("Пароль должен быть не короче 8 символов");
      if (!name) return fail("Укажите имя");
      const exists = await db.from("staff_accounts").select("user_id").eq("login", login).maybeSingle();
      if (exists.data) return fail("Такой логин уже есть");
      const created = await db.auth.admin.createUser({
        email: `${login}@${STAFF_EMAIL_DOMAIN}`, password, email_confirm: true, user_metadata: { login, name },
      });
      if (created.error || !created.data.user) return fail(created.error?.message ?? "Не удалось создать логин", 500);
      const ins = await db.from("staff_accounts").insert({ user_id: created.data.user.id, login, name, role, person_id: personId });
      if (ins.error) {
        await db.auth.admin.deleteUser(created.data.user.id);
        return fail(ins.error.message, 500);
      }
      return json({ ok: true, user_id: created.data.user.id });
    }
    case "update": {
      if (!userId) return fail("Не указан сотрудник");
      const patch: Record<string, unknown> = {};
      if (name) patch.name = name;
      if (b.role) patch.role = role;
      if ("person_id" in b) patch.person_id = personId;
      if (typeof b.active === "boolean") patch.active = b.active;
      if (password) {
        if (password.length < 8) return fail("Пароль должен быть не короче 8 символов");
        const r = await db.auth.admin.updateUserById(userId, { password });
        if (r.error) return fail(r.error.message, 500);
      }
      if (typeof b.active === "boolean") {
        // Отключённый сотрудник выходит отовсюду: блокируем вход и уже выданные сессии.
        const r = await db.auth.admin.updateUserById(userId, { ban_duration: b.active ? "none" : "876000h" });
        if (r.error) return fail(r.error.message, 500);
      }
      if (Object.keys(patch).length) {
        const r = await db.from("staff_accounts").update(patch).eq("user_id", userId);
        if (r.error) return fail(r.error.message, 500);
      }
      return json({ ok: true });
    }
    case "delete": {
      if (!userId) return fail("Не указан сотрудник");
      const r = await db.auth.admin.deleteUser(userId); // строка staff_accounts удалится каскадом
      if (r.error) return fail(r.error.message, 500);
      return json({ ok: true });
    }
    default:
      return fail("Неизвестное действие");
  }
});
