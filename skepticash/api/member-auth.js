"use strict";

const {
  createHash,
  createHmac,
  randomBytes,
  scrypt: scryptCallback,
  timingSafeEqual
} = require("node:crypto");
const { promisify } = require("node:util");

const scrypt = promisify(scryptCallback);
const accessTokenSeconds = 15 * 60;
const refreshTokenSeconds = 30 * 24 * 60 * 60;

function config() {
  const url = String(process.env.SUPABASE_URL || "").replace(/\/+$/, "");
  const anonKey = process.env.SUPABASE_ANON_KEY || "";
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || "";
  const jwtSecret = process.env.SUPABASE_JWT_SECRET || "";
  const missing = [
    ["SUPABASE_URL", url],
    ["SUPABASE_ANON_KEY", anonKey],
    ["SUPABASE_SERVICE_ROLE_KEY", serviceKey],
    ["SUPABASE_JWT_SECRET", jwtSecret]
  ].filter(([, value]) => !value).map(([name]) => name);
  if (missing.length) {
    const error = new Error(`Member sign-in setup is incomplete. Add the missing server environment variable${missing.length === 1 ? "" : "s"}: ${missing.join(", ")}.`);
    error.code = "AUTH_CONFIGURATION";
    throw error;
  }
  if (!/^https:\/\/[^/]+$/i.test(url)) {
    const error = new Error("Member sign-in setup is invalid: SUPABASE_URL must be the HTTPS project URL without a path.");
    error.code = "AUTH_CONFIGURATION";
    throw error;
  }
  return { url, anonKey, serviceKey, jwtSecret };
}

function allowedOrigin(origin) {
  if (!origin) return true;
  const configured = [
    process.env.MEMBER_APP_ORIGIN || "https://skepticash.vercel.app",
    process.env.ADMIN_APP_ORIGIN || "https://skiptcashadmin.vercel.app",
    "http://localhost:3000",
    "http://127.0.0.1:3000"
  ];
  return configured.includes(origin);
}

function send(res, status, body) {
  res.status(status).json(body);
}

function serverReadiness() {
  const variables = [
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
    "SUPABASE_JWT_SECRET"
  ];
  return {
    configured: variables.every((name) => Boolean(process.env[name])),
    missing: variables.filter((name) => !process.env[name])
  };
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function signAccessToken(userId, jwtSecret, url, phone) {
  const now = Math.floor(Date.now() / 1000);
  const header = encode({ alg: "HS256", typ: "JWT" });
  const payload = encode({
    aud: "authenticated",
    exp: now + accessTokenSeconds,
    iat: now,
    iss: `${url}/auth/v1`,
    phone,
    role: "authenticated",
    sub: userId
  });
  const unsigned = `${header}.${payload}`;
  const signature = createHmac("sha256", jwtSecret).update(unsigned).digest("base64url");
  return `${unsigned}.${signature}`;
}

async function hashPassword(password) {
  const salt = randomBytes(16);
  const derived = await scrypt(password, salt, 64, {
    N: 16384,
    r: 8,
    p: 1,
    maxmem: 64 * 1024 * 1024
  });
  return `scrypt$16384$8$1$${salt.toString("hex")}$${Buffer.from(derived).toString("hex")}`;
}

async function verifyPassword(password, stored) {
  const parts = String(stored || "").split("$");
  if (parts.length !== 6 || parts[0] !== "scrypt") return false;
  const [, n, r, p, saltHex, expectedHex] = parts;
  if (n !== "16384" || r !== "8" || p !== "1" || !/^[a-f0-9]{32}$/i.test(saltHex) ||
      !/^[a-f0-9]{128}$/i.test(expectedHex)) return false;
  const actual = Buffer.from(await scrypt(password, Buffer.from(saltHex, "hex"), 64, {
    N: 16384,
    r: 8,
    p: 1,
    maxmem: 64 * 1024 * 1024
  }));
  return timingSafeEqual(actual, Buffer.from(expectedHex, "hex"));
}

async function supabaseRequest(path, { method = "GET", body, token, key, headers = {} } = {}) {
  const settings = config();
  const activeKey = key || settings.serviceKey;
  const response = await fetch(`${settings.url}${path}`, {
    method,
    headers: {
      apikey: activeKey,
      Authorization: `Bearer ${token || activeKey}`,
      Accept: "application/json",
      ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...(method === "POST" ? { Prefer: "return=representation" } : {}),
      ...headers
    },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {})
  });
  const text = await response.text();
  let value = null;
  if (text) {
    try { value = JSON.parse(text); }
    catch { throw new Error("Supabase returned an unreadable response."); }
  }
  if (!response.ok) {
    const message = value?.message || value?.msg || value?.error_description || value?.error;
    throw new Error(message || `Supabase request failed (${response.status}).`);
  }
  return value;
}

async function issueSession(profile, mustChangePassword = false) {
  const { jwtSecret, url } = config();
  const refreshToken = randomBytes(32).toString("base64url");
  const expiresAt = new Date(Date.now() + refreshTokenSeconds * 1000).toISOString();
  await supabaseRequest("/rest/v1/member_sessions", {
    method: "POST",
    body: { token_hash: sha256(refreshToken), user_id: profile.id, expires_at: expiresAt }
  });
  const now = Math.floor(Date.now() / 1000);
  return {
    access_token: signAccessToken(profile.id, jwtSecret, url, profile.phone),
    refresh_token: refreshToken,
    token_type: "bearer",
    expires_in: accessTokenSeconds,
    expires_at: now + accessTokenSeconds,
    user: {
      id: profile.id,
      phone: profile.phone,
      user_metadata: { full_name: profile.full_name || "" },
      app_metadata: { provider: "skepticash-phone", providers: ["skepticash-phone"] }
    },
    member_auth: true,
    must_change_password: mustChangePassword
  };
}

async function enforceRateLimit(phone, request) {
  const forwarded = String(request.headers["x-forwarded-for"] || "").split(",")[0].trim();
  const key = sha256(`${phone}|${forwarded || "unknown"}`);
  await supabaseRequest("/rest/v1/rpc/check_member_auth_rate_limit", {
    method: "POST",
    body: { p_attempt_key: key }
  });
}

async function clearRateLimit(phone, request) {
  const forwarded = String(request.headers["x-forwarded-for"] || "").split(",")[0].trim();
  const key = sha256(`${phone}|${forwarded || "unknown"}`);
  await supabaseRequest("/rest/v1/rpc/clear_member_auth_rate_limit", {
    method: "POST",
    body: { p_attempt_key: key }
  });
}

function validPhone(phone) {
  return typeof phone === "string" && /^\+[1-9]\d{7,14}$/.test(phone);
}

async function signUp(body, request) {
  const phone = String(body.phone || "").trim();
  const password = body.password;
  const referralCode = String(body.referralCode || "").trim().toUpperCase();
  if (!validPhone(phone)) throw new Error("Enter a valid phone number in international format.");
  if (typeof password !== "string" || password.length < 8 || password.length > 128) {
    throw new Error("Password must be between 8 and 128 characters.");
  }
  if (referralCode.length > 10) throw new Error("Referral code is invalid.");
  await enforceRateLimit(phone, request);
  const passwordHash = await hashPassword(password);
  const result = await supabaseRequest("/rest/v1/rpc/create_custom_member_account", {
    method: "POST",
    body: { p_phone: phone, p_referral_code: referralCode, p_password_hash: passwordHash }
  });
  await clearRateLimit(phone, request);
  return issueSession(result);
}

async function signIn(body, request) {
  const phone = String(body.phone || "").trim();
  const password = body.password;
  if (!validPhone(phone) || typeof password !== "string" || password.length > 128) {
    throw new Error("Phone number or password is incorrect.");
  }
  await enforceRateLimit(phone, request);
  const profileQuery = new URLSearchParams({
    select: "id,phone,full_name",
    phone: `eq.${phone}`,
    role: "eq.user",
    limit: "1"
  });
  const profiles = await supabaseRequest(`/rest/v1/profiles?${profileQuery}`);
  const profile = profiles[0];
  const credentialQuery = new URLSearchParams({
    select: "id,password_hash,must_change_password",
    id: `eq.${profile?.id || "00000000-0000-0000-0000-000000000000"}`,
    limit: "1"
  });
  const credentials = await supabaseRequest(`/rest/v1/member_credentials?${credentialQuery}`);
  const credential = credentials[0];
  if (!profile || !credential || !await verifyPassword(password, credential.password_hash)) {
    throw new Error("Phone number or password is incorrect.");
  }
  await clearRateLimit(phone, request);
  return issueSession(profile, credential.must_change_password);
}

async function refresh(body) {
  const token = String(body.refresh_token || "");
  if (!/^[A-Za-z0-9_-]{40,60}$/.test(token)) throw new Error("Session expired. Please sign in again.");
  const tokenHash = sha256(token);
  const query = new URLSearchParams({
    select: "token_hash,user_id,expires_at",
    token_hash: `eq.${tokenHash}`,
    expires_at: `gt.${new Date().toISOString()}`,
    limit: "1"
  });
  const rows = await supabaseRequest(`/rest/v1/member_sessions?${query}`);
  if (!rows[0]) throw new Error("Session expired. Please sign in again.");
  await supabaseRequest(`/rest/v1/member_sessions?token_hash=eq.${tokenHash}`, { method: "DELETE" });
  const profilesQuery = new URLSearchParams({
    select: "id,phone,full_name",
    id: `eq.${rows[0].user_id}`,
    role: "eq.user",
    limit: "1"
  });
  const profiles = await supabaseRequest(`/rest/v1/profiles?${profilesQuery}`);
  if (!profiles[0]) throw new Error("Session expired. Please sign in again.");
  const credentialQuery = new URLSearchParams({
    select: "must_change_password",
    id: `eq.${profiles[0].id}`,
    limit: "1"
  });
  const credentials = await supabaseRequest(`/rest/v1/member_credentials?${credentialQuery}`);
  if (!credentials[0]) throw new Error("Session expired. Please sign in again.");
  return issueSession(profiles[0], credentials[0].must_change_password);
}

async function signOut(body) {
  const token = String(body.refresh_token || "");
  if (!/^[A-Za-z0-9_-]{40,60}$/.test(token)) return { success: true };
  await supabaseRequest(`/rest/v1/member_sessions?token_hash=eq.${sha256(token)}`, { method: "DELETE" });
  return { success: true };
}

async function changePassword(body, authorization) {
  const currentPassword = body.currentPassword;
  const newPassword = body.newPassword;
  if (typeof currentPassword !== "string" || typeof newPassword !== "string" ||
      newPassword.length < 8 || newPassword.length > 128) {
    throw new Error("Enter your current password and a new password of at least 8 characters.");
  }
  const profile = await currentMember(authorization);
  const query = new URLSearchParams({
    select: "id,password_hash",
    id: `eq.${profile.id}`,
    limit: "1"
  });
  const credentials = await supabaseRequest(`/rest/v1/member_credentials?${query}`);
  if (!credentials[0] || !await verifyPassword(currentPassword, credentials[0].password_hash)) {
    throw new Error("Current password is incorrect.");
  }
  const passwordHash = await hashPassword(newPassword);
  await supabaseRequest(`/rest/v1/member_credentials?id=eq.${profile.id}`, {
    method: "PATCH",
    body: { password_hash: passwordHash, must_change_password: false, updated_at: new Date().toISOString() }
  });
  await supabaseRequest(`/rest/v1/member_sessions?user_id=eq.${profile.id}`, { method: "DELETE" });
  return { success: true };
}

async function currentMember(authorization) {
  if (!authorization || !authorization.startsWith("Bearer ")) throw new Error("Sign in again to continue.");
  const query = new URLSearchParams({ select: "id,phone,full_name", id: `eq.${authorizationClaims(authorization).sub}`, role: "eq.user", limit: "1" });
  const rows = await supabaseRequest(`/rest/v1/profiles?${query}`, { token: authorization.slice(7) });
  if (!rows[0]) throw new Error("Member account not found.");
  return rows[0];
}

function authorizationClaims(authorization) {
  const token = authorization.slice(7).split(".");
  if (token.length !== 3) throw new Error("Sign in again to continue.");
  try {
    const payload = JSON.parse(Buffer.from(token[1], "base64url").toString("utf8"));
    if (payload.exp <= Math.floor(Date.now() / 1000) || payload.role !== "authenticated" || !payload.sub) {
      throw new Error("Sign in again to continue.");
    }
    return payload;
  } catch {
    throw new Error("Sign in again to continue.");
  }
}

async function resetMemberPassword(body, authorization) {
  if (!authorization || !authorization.startsWith("Bearer ")) throw new Error("Administrator sign-in is required.");
  const adminToken = authorization.slice(7);
  const settings = config();
  const adminUser = await supabaseRequest("/auth/v1/user", {
    token: adminToken,
    key: settings.anonKey
  });
  const adminQuery = new URLSearchParams({
    select: "id",
    id: `eq.${adminUser.id}`,
    role: "eq.admin",
    limit: "1"
  });
  const admins = await supabaseRequest(`/rest/v1/profiles?${adminQuery}`);
  if (!admins[0]) throw new Error("Administrator access is required.");

  const memberId = String(body.userId || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(memberId)) {
    throw new Error("Select a valid member account.");
  }
  const memberQuery = new URLSearchParams({
    select: "id,phone",
    id: `eq.${memberId}`,
    role: "eq.user",
    limit: "1"
  });
  const members = await supabaseRequest(`/rest/v1/profiles?${memberQuery}`);
  if (!members[0]) throw new Error("Member account not found.");

  const temporaryPassword = randomBytes(12).toString("base64url");
  const passwordHash = await hashPassword(temporaryPassword);
  await supabaseRequest("/rest/v1/member_credentials?on_conflict=id", {
    method: "POST",
    body: { id: memberId, password_hash: passwordHash, must_change_password: true, updated_at: new Date().toISOString() },
    headers: { Prefer: "resolution=merge-duplicates,return=minimal" }
  });
  await supabaseRequest(`/rest/v1/member_sessions?user_id=eq.${memberId}`, { method: "DELETE" });
  return { phone: members[0].phone, temporaryPassword };
}

module.exports = async function handler(req, res) {
  const origin = req.headers.origin || "";
  if (!allowedOrigin(origin)) return send(res, 403, { error: "Request origin is not allowed." });
  res.setHeader("Access-Control-Allow-Origin", origin || "*");
  res.setHeader("Vary", "Origin");
  res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.setHeader("Cache-Control", "no-store");
  if (req.method === "OPTIONS") return res.status(204).end();
  if (req.method === "GET") {
    const readiness = serverReadiness();
    return send(res, readiness.configured ? 200 : 503, {
      status: readiness.configured ? "configured" : "configuration_required",
      ...readiness
    });
  }
  if (req.method !== "POST") return send(res, 405, { error: "Method not allowed." });

  try {
    config();
    const body = typeof req.body === "string" ? JSON.parse(req.body) : (req.body || {});
    let result;
    switch (body.action) {
      case "signup":
        result = await signUp(body, req);
        break;
      case "signin":
        result = await signIn(body, req);
        break;
      case "refresh":
        result = await refresh(body);
        break;
      case "signout":
        result = await signOut(body);
        break;
      case "change-password":
        result = await changePassword(body, req.headers.authorization);
        break;
      case "admin-reset-password":
        result = await resetMemberPassword(body, req.headers.authorization);
        break;
      default:
        return send(res, 400, { error: "Unknown member authentication action." });
    }
    return send(res, 200, result);
  } catch (error) {
    const message = error.message || "Member authentication failed.";
    const normalizedMessage = /profiles_phone_unique_idx|duplicate key value/i.test(message)
      ? "An account with this phone number already exists."
      : message;
    const status = error.code === "AUTH_CONFIGURATION" ? 503
      : /too many|rate limit/i.test(normalizedMessage) ? 429
      : /already exists/i.test(normalizedMessage) ? 409
      : /incorrect|expired|sign in again/i.test(normalizedMessage) ? 401
        : /not valid|invalid|must be|enter a valid|password/i.test(normalizedMessage) ? 400 : 500;
    if (status >= 500) console.error("Member authentication request failed:", message);
    const responseMessage = status === 500
      ? "Member authentication is temporarily unavailable. Check the member-auth function logs in Vercel for the cause."
      : normalizedMessage;
    return send(res, status, { error: responseMessage });
  }
};
