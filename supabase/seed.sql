-- ============================================================================
-- MailChat — development seed
-- ----------------------------------------------------------------------------
-- Creates two demo users and a direct conversation so the chat list is not
-- empty in local development.
--
-- These accounts use REAL auth users with a known password. Never run this
-- against staging or production.
--
--   email:    alice@example.com  /  bob@example.com
--   password: MailChat123!
-- ============================================================================

do $$
declare
  alice_id uuid := '11111111-1111-4111-8111-111111111111';
  bob_id   uuid := '22222222-2222-4222-8222-222222222222';
  conv_id  uuid := '33333333-3333-4333-8333-333333333333';
begin
  -- Auth users. The password is hashed by crypt() the same way GoTrue does it;
  -- email_confirmed_at is set so local logins work without a mail server.
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data
  )
  values
    (alice_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'alice@example.com', crypt('MailChat123!', gen_salt('bf')),
     now(), now(), now(), '{"provider":"email","providers":["email"]}',
     '{"username":"alice","display_name":"Alice Anderson"}'),
    (bob_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'bob@example.com', crypt('MailChat123!', gen_salt('bf')),
     now(), now(), now(), '{"provider":"email","providers":["email"]}',
     '{"username":"bob","display_name":"Bob Brown"}')
  on conflict (id) do nothing;

  -- Profiles (the signup trigger only fires for new auth users).
  insert into public.profiles (id, username, display_name, bio)
  values
    (alice_id, 'alice', 'Alice Anderson', 'Demo account'),
    (bob_id, 'bob', 'Bob Brown', 'Demo account')
  on conflict (id) do nothing;

  -- Direct conversation.
  insert into public.conversations (id, type, created_by)
  values (conv_id, 'direct', alice_id)
  on conflict (id) do nothing;

  insert into public.conversation_members (conversation_id, user_id, role)
  values (conv_id, alice_id, 'member'), (conv_id, bob_id, 'member')
  on conflict do nothing;

  insert into public.messages (conversation_id, sender_id, type, text, created_at)
  values
    (conv_id, alice_id, 'text', 'Hey Bob, welcome to MailChat!', now() - interval '2 hours'),
    (conv_id, bob_id, 'text', 'Thanks Alice — no phone number needed!', now() - interval '1 hour')
  on conflict do nothing;
end
$$;
