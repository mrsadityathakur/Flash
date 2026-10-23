# Security Policy

## Reporting a Vulnerability

Please report suspected security issues privately through GitHub's Security Advisories for this repository, if private reporting is enabled. Otherwise, contact the repository owner privately. Do not include credentials, ride PINs, or customer data in a public issue.

Reports should include the affected feature, steps to reproduce, and the potential impact. Please allow maintainers reasonable time to investigate and release a fix before publicly disclosing the issue.

## Security Notes

- The browser uses only the Supabase publishable key. Never add a service-role key or OAuth client secret to frontend files.
- Driver access is controlled by the private `public.authorized_riders` allowlist and backend functions. The separate `admin.html` panel lets the verified app administrator choose one driver account. If the panel is not configured, an operator can add a verified account's Auth UUID in the Supabase SQL editor:

  ```sql
  INSERT INTO public.authorized_riders (user_id)
  VALUES ('<authorized-rider-auth-user-uuid>');
  ```

  The driver can then sign in and switch to driver mode. Do not add an account based on a client-supplied role or email without verifying its Auth user UUID.
- Admin setup: the designated admin email is checked only inside `supabase/functions/flash-admin/index.ts`. Deploy that function after changing the admin identity. The admin must register that same email in FLASH and verify it before signing in at `/admin.html`. The panel authenticates through Supabase Auth and checks authorization server-side. It can view app accounts and rides, designate the single driver, create or dispatch rides, read and send ride-chat messages, and cancel active rides. Admin changes and rider/customer messages flow through Supabase Realtime. Supabase project settings, secrets, and billing remain restricted to the Supabase Dashboard.
- The browser contains only the Supabase publishable key. Never put an admin passcode, service-role key, or OAuth client secret in `index.html` or `admin.html`. The administrator signs in with the Supabase account password; there is no shared client-side master passcode.
- Configure Supabase Auth email delivery and enable leaked-password protection in the dashboard. The code cannot change project billing or Auth dashboard settings.
- Review RLS policies and Supabase security advisors after database changes.
