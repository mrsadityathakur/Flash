import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const adminEmail = "aadityathakur.ayu243@gmail.com";
const activeRideStatuses = ["accepted", "arrived", "in_progress"];

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("Flash admin function is missing required environment configuration.");
    return json({ error: "Admin service is not configured." }, 500);
  }

  const token = request.headers.get("Authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return json({ error: "Sign in to the admin account." }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const user = authData.user;
  if (
    authError || !user?.email ||
    user.email.toLowerCase() !== adminEmail ||
    !user.email_confirmed_at
  ) {
    return json({ error: "This verified account is not an app administrator." }, 403);
  }

  let payload: {
    action?: string;
    userId?: string;
    rideId?: string;
    customerId?: string;
    driverId?: string | null;
    phone?: string;
    pickup?: string;
    destination?: string;
    instructions?: string;
    text?: string;
  };
  try {
    payload = await request.json();
  } catch {
    return json({ error: "Invalid request body." }, 400);
  }

  if (payload.action === "overview") {
    const [profiles, rides, authorized] = await Promise.all([
      admin.from("profiles")
        .select("id,name,email,phone,role,created_at")
        .order("created_at", { ascending: false })
        .limit(500),
      admin.from("rides")
        .select("id,customer_id,customer_name,phone,pickup,destination,status,driver_id,driver_name,created_at")
        .order("created_at", { ascending: false })
        .limit(500),
      admin.from("authorized_riders").select("user_id").maybeSingle(),
    ]);
    const error = profiles.error || rides.error || authorized.error;
    if (error) {
      console.error("Admin overview query failed:", error.message);
      return json({ error: "Could not load the admin overview." }, 500);
    }
    return json({
      profiles: profiles.data,
      rides: rides.data,
      authorizedDriverId: authorized.data?.user_id ?? null,
    });
  }

  if (payload.action === "ride-chat") {
    if (!payload.rideId || payload.rideId.length > 128) return json({ error: "Select a valid ride." }, 400);
    const { data, error } = await admin.from("ride_messages")
      .select("id,ride_id,sender_id,sender_name,text,created_at")
      .eq("ride_id", payload.rideId)
      .order("created_at", { ascending: true })
      .limit(200);
    if (error) {
      console.error("Admin ride chat query failed:", error.message);
      return json({ error: "Could not load this ride chat." }, 500);
    }
    return json({ messages: data });
  }

  if (payload.action === "create-ride") {
    if (
      !payload.customerId ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.customerId) ||
      (payload.driverId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.driverId)) ||
      !payload.pickup?.trim() || payload.pickup.length > 160 ||
      !payload.destination?.trim() || payload.destination.length > 160 ||
      (payload.phone?.length ?? 0) > 30 ||
      (payload.instructions?.length ?? 0) > 300
    ) {
      return json({ error: "Enter valid customer, route, phone, and instructions." }, 400);
    }
    const { data, error } = await admin.rpc("admin_create_ride", {
      p_id: crypto.randomUUID(),
      p_customer_id: payload.customerId,
      p_driver_id: payload.driverId || null,
      p_phone: payload.phone?.trim() || null,
      p_pickup: payload.pickup.trim(),
      p_destination: payload.destination.trim(),
      p_instructions: payload.instructions?.trim() || "",
      p_ride_type: "bike",
    });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true, rideId: data });
  }

  if (payload.action === "send-message") {
    if (
      !payload.rideId || payload.rideId.length > 128 ||
      !payload.text?.trim() || payload.text.trim().length > 1000
    ) {
      return json({ error: "Enter a message with 1–1000 characters." }, 400);
    }
    const { data: ride, error: rideError } = await admin
      .from("rides")
      .select("id,status")
      .eq("id", payload.rideId)
      .single();
    if (rideError || !activeRideStatuses.includes(ride.status)) {
      return json({ error: "Chat is available only while a ride is assigned and active." }, 400);
    }
    const { data: adminProfile, error: profileError } = await admin
      .from("profiles")
      .select("name")
      .eq("id", user.id)
      .single();
    if (profileError) return json({ error: "Could not load admin profile." }, 500);
    const { error } = await admin.from("ride_messages").insert({
      ride_id: payload.rideId,
      sender_id: user.id,
      sender_name: adminProfile.name,
      text: payload.text.trim(),
    });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (payload.action === "authorize-driver") {
    if (!payload.userId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.userId)) {
      return json({ error: "Select a valid account." }, 400);
    }
    const { data: target, error: targetError } = await admin.auth.admin.getUserById(payload.userId);
    if (targetError || !target.user?.email_confirmed_at) {
      return json({ error: "The selected account must exist and have a verified email." }, 400);
    }
    const { error } = await admin.rpc("admin_set_authorized_driver", { p_user_id: payload.userId });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (payload.action === "revoke-driver") {
    if (!payload.userId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.userId)) {
      return json({ error: "Select a valid account." }, 400);
    }
    const { error } = await admin.rpc("admin_remove_authorized_driver", { p_user_id: payload.userId });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  if (payload.action === "cancel-ride") {
    if (!payload.rideId || payload.rideId.length > 128) {
      return json({ error: "Select a valid ride." }, 400);
    }
    const { error } = await admin.rpc("admin_cancel_ride", { p_ride_id: payload.rideId });
    if (error) return json({ error: error.message }, 400);
    return json({ ok: true });
  }

  return json({ error: "Unsupported admin action." }, 400);
});
