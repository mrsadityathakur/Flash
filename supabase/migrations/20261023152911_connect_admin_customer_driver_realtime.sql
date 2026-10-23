CREATE OR REPLACE FUNCTION public.admin_create_ride(
  p_id text,
  p_customer_id uuid,
  p_driver_id uuid,
  p_phone text,
  p_pickup text,
  p_destination text,
  p_instructions text DEFAULT '',
  p_ride_type text DEFAULT 'bike'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_customer public.profiles%rowtype;
  v_driver public.profiles%rowtype;
  v_status text := 'requested';
BEGIN
  IF p_id IS NULL OR char_length(p_id) NOT BETWEEN 1 AND 128
    OR p_customer_id IS NULL
    OR coalesce(char_length(p_phone), 0) > 30
    OR p_pickup IS NULL OR char_length(trim(p_pickup)) NOT BETWEEN 1 AND 160
    OR p_destination IS NULL OR char_length(trim(p_destination)) NOT BETWEEN 1 AND 160
    OR coalesce(char_length(p_instructions), 0) > 300
    OR p_ride_type IS DISTINCT FROM 'bike' THEN
    RAISE EXCEPTION 'Invalid ride details.' USING errcode = '22023';
  END IF;

  SELECT * INTO v_customer FROM public.profiles WHERE id = p_customer_id FOR SHARE;
  IF NOT FOUND OR v_customer.role <> 'customer' THEN
    RAISE EXCEPTION 'Choose an existing customer account.' USING errcode = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.customer_security WHERE user_id = p_customer_id) THEN
    RAISE EXCEPTION 'This customer account has no ride PIN.' USING errcode = 'P0001';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.rides
    WHERE customer_id = p_customer_id
      AND status IN ('requested', 'accepted', 'arrived', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'This customer already has an active ride.' USING errcode = 'P0001';
  END IF;

  IF p_driver_id IS NOT NULL THEN
    SELECT * INTO v_driver FROM public.profiles WHERE id = p_driver_id FOR SHARE;
    IF NOT FOUND OR v_driver.role <> 'driver' OR NOT EXISTS (
      SELECT 1
      FROM public.authorized_riders ar
      WHERE ar.slot = 1 AND ar.user_id = p_driver_id
    ) THEN
      RAISE EXCEPTION 'Choose the currently authorized driver.' USING errcode = '42501';
    END IF;
    IF EXISTS (
      SELECT 1 FROM public.rides
      WHERE driver_id = p_driver_id
        AND status IN ('accepted', 'arrived', 'in_progress')
    ) THEN
      RAISE EXCEPTION 'The driver already has an active ride.' USING errcode = 'P0001';
    END IF;
    v_status := 'accepted';
  END IF;

  INSERT INTO public.rides (
    id, customer_id, customer_name, phone, pickup, destination, ride_type, instructions,
    status, driver_id, driver_name, driver_phone, accepted_at
  )
  VALUES (
    p_id, p_customer_id, v_customer.name, coalesce(p_phone, v_customer.phone, ''),
    trim(p_pickup), trim(p_destination), p_ride_type, coalesce(p_instructions, ''),
    v_status, p_driver_id,
    CASE WHEN p_driver_id IS NULL THEN NULL ELSE v_driver.name END,
    CASE WHEN p_driver_id IS NULL THEN NULL ELSE v_driver.phone END,
    CASE WHEN p_driver_id IS NULL THEN NULL ELSE now() END
  );

  INSERT INTO public.ride_requests (
    id, customer_id, pickup, destination, ride_type, status, driver_id, accepted_at
  )
  VALUES (
    p_id, p_customer_id, trim(p_pickup), trim(p_destination), p_ride_type, v_status,
    p_driver_id, CASE WHEN p_driver_id IS NULL THEN NULL ELSE now() END
  );

  RETURN p_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_create_ride(text, uuid, uuid, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_ride(text, uuid, uuid, text, text, text, text, text)
  TO service_role;

DROP POLICY IF EXISTS "app admin reads profiles" ON public.profiles;
CREATE POLICY "app admin reads profiles"
  ON public.profiles FOR SELECT TO authenticated
  USING (auth.jwt() ->> 'email' = 'aadityathakur.ayu243@gmail.com');

DROP POLICY IF EXISTS "app admin reads rides" ON public.rides;
CREATE POLICY "app admin reads rides"
  ON public.rides FOR SELECT TO authenticated
  USING (auth.jwt() ->> 'email' = 'aadityathakur.ayu243@gmail.com');

DROP POLICY IF EXISTS "app admin reads ride messages" ON public.ride_messages;
CREATE POLICY "app admin reads ride messages"
  ON public.ride_messages FOR SELECT TO authenticated
  USING (auth.jwt() ->> 'email' = 'aadityathakur.ayu243@gmail.com');

DO $publication$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'profiles'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
  END IF;
END;
$publication$;
