CREATE TABLE IF NOT EXISTS public.authorized_riders (
    slot smallint PRIMARY KEY DEFAULT 1 CHECK (slot = 1),
    user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE
);

ALTER TABLE public.authorized_riders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.authorized_riders FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.authorized_riders IS
    'Private allowlist for the single rider account. Manage only through trusted SQL.';
