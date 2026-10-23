CREATE TABLE IF NOT EXISTS public.authorized_riders (
    slot smallint PRIMARY KEY DEFAULT 1 CHECK (slot = 1),
    user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE
);

ALTER TABLE public.authorized_riders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.authorized_riders FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.authorized_riders IS
    'Private allowlist for the single rider account. Manage only through trusted SQL.';

UPDATE public.profiles
SET role = 'customer'
WHERE role = 'driver'
  AND NOT EXISTS (
      SELECT 1
      FROM public.authorized_riders
      WHERE user_id = profiles.id
  );

CREATE OR REPLACE FUNCTION public.is_driver(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT p_user_id IS NOT NULL
    AND p_user_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.authorized_riders ar
      JOIN public.profiles p ON p.id = ar.user_id
      WHERE ar.user_id = p_user_id
        AND p.role = 'driver'
    );
$function$;

CREATE OR REPLACE FUNCTION public.switch_user_role(p_role text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in before switching modes.' USING errcode = '28000';
  END IF;
  IF p_role NOT IN ('customer', 'driver') THEN
    RAISE EXCEPTION 'Invalid account role.' USING errcode = '22023';
  END IF;
  IF p_role = 'driver' AND NOT EXISTS (
    SELECT 1 FROM public.authorized_riders WHERE user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'This account is not authorized for rider mode.' USING errcode = '42501';
  END IF;
  IF p_role = 'customer' AND NOT EXISTS (
    SELECT 1 FROM public.customer_security WHERE user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Set your six-digit ride PIN in Profile before switching to customer mode.' USING errcode = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.rides
    WHERE (customer_id = auth.uid() OR driver_id = auth.uid())
      AND status IN ('requested', 'accepted', 'arrived', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'Finish or cancel your active ride before switching modes.' USING errcode = 'P0001';
  END IF;
  UPDATE public.profiles SET role = p_role WHERE id = auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found.' USING errcode = 'P0002';
  END IF;
  RETURN p_role;
END;
$function$;

CREATE OR REPLACE FUNCTION public.accept_ride(p_ride_id text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in before accepting a ride.' USING errcode = '28000';
  END IF;
  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = auth.uid()
  FOR SHARE;
  IF NOT FOUND OR v_profile.role <> 'driver' OR NOT public.is_driver(auth.uid()) THEN
    RAISE EXCEPTION 'This account is not authorized to accept rides.' USING errcode = '42501';
  END IF;
  UPDATE public.rides
  SET status = 'accepted', driver_id = auth.uid(), driver_name = v_profile.name,
      driver_phone = v_profile.phone, accepted_at = now()
  WHERE id = p_ride_id
    AND status = 'requested'
    AND driver_id IS NULL
    AND customer_id <> auth.uid();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'This ride is no longer available.' USING errcode = 'P0001';
  END IF;
  UPDATE public.ride_requests
  SET status = 'accepted', driver_id = auth.uid(), accepted_at = now()
  WHERE id = p_ride_id AND status = 'requested' AND driver_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Ride request is inconsistent.' USING errcode = 'P0001';
  END IF;
  RETURN p_ride_id;
END;
$function$;

ALTER TABLE public.rides DROP CONSTRAINT IF EXISTS rides_phone_check;
ALTER TABLE public.rides
    ADD CONSTRAINT rides_phone_check CHECK (char_length(phone) <= 30);

CREATE UNIQUE INDEX IF NOT EXISTS rides_one_active_ride_per_driver
    ON public.rides (driver_id)
    WHERE driver_id IS NOT NULL
      AND status IN ('accepted', 'arrived', 'in_progress');

CREATE UNIQUE INDEX IF NOT EXISTS rides_one_active_ride_per_customer
    ON public.rides (customer_id)
    WHERE status IN ('requested', 'accepted', 'arrived', 'in_progress');

CREATE OR REPLACE FUNCTION public.create_ride(
  p_id text,
  p_phone text,
  p_pickup text,
  p_destination text,
  p_instructions text,
  p_ride_type text DEFAULT 'bike'::text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_profile public.profiles%rowtype;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in to book a ride.' USING errcode = '28000';
  END IF;
  IF p_id IS NULL OR char_length(p_id) NOT BETWEEN 1 AND 128
    OR coalesce(char_length(p_phone), 0) > 30
    OR p_pickup IS NULL OR char_length(p_pickup) NOT BETWEEN 1 AND 160
    OR p_destination IS NULL OR char_length(p_destination) NOT BETWEEN 1 AND 160
    OR coalesce(char_length(p_instructions), 0) > 300
    OR p_ride_type <> 'bike' THEN
    RAISE EXCEPTION 'Invalid ride details.' USING errcode = '22023';
  END IF;
  SELECT * INTO v_profile
  FROM public.profiles
  WHERE id = auth.uid()
  FOR SHARE;
  IF NOT FOUND OR v_profile.role <> 'customer' THEN
    RAISE EXCEPTION 'Switch to customer mode before booking.' USING errcode = '42501';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.customer_security WHERE user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'Set your six-digit ride PIN in Profile before booking.' USING errcode = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.rides
    WHERE customer_id = auth.uid()
      AND status IN ('requested', 'accepted', 'arrived', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'Finish or cancel your active ride before booking another.' USING errcode = 'P0001';
  END IF;
  INSERT INTO public.rides (
    id, customer_id, customer_name, phone, pickup, destination, ride_type, instructions
  )
  VALUES (
    p_id, auth.uid(), v_profile.name, coalesce(p_phone, ''),
    p_pickup, p_destination, p_ride_type, coalesce(p_instructions, '')
  );
  INSERT INTO public.ride_requests (id, customer_id, pickup, destination, ride_type)
  VALUES (p_id, auth.uid(), p_pickup, p_destination, p_ride_type);
  RETURN p_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_name text := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'FLASH User'
  );
  v_pin text := public.generate_ride_pin();
  v_key text;
BEGIN
  SELECT decrypted_secret INTO STRICT v_key
  FROM vault.decrypted_secrets
  WHERE name = 'flash_ride_pin_encryption_key';

  INSERT INTO public.profiles (id, name, email, phone, role)
  VALUES (
    new.id,
    v_name,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data ->> 'phone', ''),
    'customer'
  );
  INSERT INTO public.customer_security (user_id, ride_pin_hash, ride_pin_ciphertext)
  VALUES (
    new.id,
    extensions.crypt(v_pin, extensions.gen_salt('bf', 12)),
    extensions.pgp_sym_encrypt(v_pin, v_key)
  );
  new.raw_user_meta_data := coalesce(new.raw_user_meta_data, '{}'::jsonb) - 'ride_pin' - 'role';
  UPDATE auth.users SET raw_user_meta_data = new.raw_user_meta_data WHERE id = new.id;
  RETURN new;
END;
$function$;
