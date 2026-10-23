CREATE OR REPLACE FUNCTION public.admin_set_authorized_driver(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_current_user_id uuid;
BEGIN
  IF p_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles WHERE id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Select an existing account.' USING errcode = '22023';
  END IF;

  SELECT user_id INTO v_current_user_id
  FROM public.authorized_riders
  WHERE slot = 1;

  IF v_current_user_id = p_user_id THEN
    RETURN;
  END IF;

  IF v_current_user_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.rides
    WHERE driver_id = v_current_user_id
      AND status IN ('accepted', 'arrived', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'Complete or cancel the current driver’s active ride first.' USING errcode = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rides
    WHERE customer_id = p_user_id
      AND status IN ('requested', 'accepted', 'arrived', 'in_progress')
  ) THEN
    RAISE EXCEPTION 'This account has an active customer ride.' USING errcode = 'P0001';
  END IF;

  UPDATE public.profiles
  SET role = 'customer'
  WHERE role = 'driver' AND id IS DISTINCT FROM p_user_id;

  DELETE FROM public.authorized_riders
  WHERE slot = 1;
  INSERT INTO public.authorized_riders (slot, user_id)
  VALUES (1, p_user_id);

  UPDATE public.profiles
  SET role = 'driver'
  WHERE id = p_user_id;
END;
$function$;
