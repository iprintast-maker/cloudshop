import { createHandler } from './handler.ts';

// This function verifies the main site's JWT and active admin role itself.
// The gateway cannot verify a token issued by a different Supabase project.
Deno.serve(createHandler({
  clientUrl:Deno.env.get('SUPABASE_URL'),
  clientServiceKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
  publisherUrl:'https://tmxluzvymwldtxbaiekn.supabase.co',
  publisherKey:'sb_publishable_seHlOPu_cbFZOCmqG9UCzQ_9411endl',
  allowedOrigins:['https://polaroidstav76-cloud.github.io'],
}));
