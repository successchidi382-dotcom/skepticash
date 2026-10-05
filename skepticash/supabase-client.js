"use strict";

(() => {
  const config = window.SKEPTICASH_SUPABASE || {};
  const baseUrl = String(config.url || "").replace(/\/+$/, "");
  const anonKey = String(config.anonKey || "");
  const storageKey = baseUrl ? `skepticash-auth-${new URL(baseUrl).hostname}` : "skepticash-auth";
  let session = null;
  let refreshTimer = null;
  let refreshPromise = null;
  const authListeners = new Set();

  function isConfigured() {
    return Boolean(baseUrl && anonKey);
  }

  function requireConfig() {
    if (!isConfigured()) {
      throw new Error("Supabase is not configured. Add your project URL and publishable anon key to supabase-config.js.");
    }
  }

  function persistSession(value) {
    if (value && !value.expires_at) {
      value.expires_at = Math.floor(Date.now() / 1000) + Number(value.expires_in || 3600);
    }
    session = value;
    if (value) localStorage.setItem(storageKey, JSON.stringify(value));
    else localStorage.removeItem(storageKey);
    scheduleRefresh();
    authListeners.forEach((listener) => listener(value));
  }

  function loadSession() {
    if (session) return session;
    try {
      const stored = localStorage.getItem(storageKey);
      session = stored ? JSON.parse(stored) : null;
    } catch {
      localStorage.removeItem(storageKey);
      session = null;
    }
    return session;
  }

  async function fetchJson(path, { method = "GET", body, token, headers = {} } = {}) {
    requireConfig();
    let response;
    try {
      response = await fetch(`${baseUrl}${path}`, {
        method,
        headers: {
          apikey: anonKey,
          Authorization: `Bearer ${token || loadSession()?.access_token || anonKey}`,
          Accept: "application/json",
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
          ...headers
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {})
      });
    } catch (error) {
      if (error instanceof TypeError) throw new Error("Couldn't reach Supabase. Check your project URL and network connection.");
      throw error;
    }
    const text = await response.text();
    let result = null;
    if (text) {
      try {
        result = JSON.parse(text);
      } catch {
        throw new Error("Supabase returned an unreadable response.");
      }
    }
    if (!response.ok) {
      throw new Error(result?.msg || result?.message || result?.error_description || result?.error || `Supabase request failed (${response.status}).`);
    }
    return result;
  }

  async function memberAuthRequest(body, token) {
    const response = await fetch("/api/member-auth", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(token ? { Authorization: `Bearer ${token}` } : {})
      },
      body: JSON.stringify(body),
      cache: "no-store"
    });
    const text = await response.text();
    let result = null;
    if (text) {
      try { result = JSON.parse(text); }
      catch { throw new Error("Member authentication returned an unreadable response."); }
    }
    if (!response.ok) {
      if (response.status === 404 || response.status === 405) {
        throw new Error("Member sign-in service is not deployed. Deploy the SkeptiCash member site from the repository root on Vercel, including the api folder.");
      }
      throw new Error(result?.error || `Member authentication failed (${response.status}).`);
    }
    return result;
  }

  async function refreshSession() {
    if (refreshPromise) return refreshPromise;
    const current = loadSession();
    if (!current?.refresh_token) {
      persistSession(null);
      return null;
    }
    refreshPromise = memberAuthRequest({ action: "refresh", refresh_token: current.refresh_token }).then((result) => {
      persistSession(result);
      return result;
    }).catch((error) => {
      persistSession(null);
      throw error;
    }).finally(() => {
      refreshPromise = null;
    });
    return refreshPromise;
  }

  function scheduleRefresh() {
    window.clearTimeout(refreshTimer);
    const current = loadSession();
    if (!current?.expires_at) return;
    const delay = Math.max(10000, current.expires_at * 1000 - Date.now() - 60000);
    refreshTimer = window.setTimeout(() => {
      refreshSession().catch((error) => console.error("Supabase session refresh failed:", error.message));
    }, delay);
  }

  async function getSession() {
    const current = loadSession();
    if (!current) return null;
    if (!current.member_auth) {
      persistSession(null);
      return null;
    }
    if (!current.expires_at || current.expires_at * 1000 <= Date.now() + 30000) return refreshSession();
    return current;
  }

  function onAuthStateChange(listener) {
    authListeners.add(listener);
    return () => authListeners.delete(listener);
  }

  async function signUp({ phone, password, referralCode }) {
    const result = await memberAuthRequest({ action: "signup", phone, password, referralCode: referralCode || "" });
    persistSession(result);
    return result;
  }

  async function signIn({ phone, password }) {
    const result = await memberAuthRequest({ action: "signin", phone, password });
    persistSession(result);
    return result;
  }

  async function signOut() {
    const current = await getSession();
    try {
      if (current?.refresh_token) {
        await memberAuthRequest({ action: "signout", refresh_token: current.refresh_token });
      }
    } finally {
      persistSession(null);
    }
  }

  async function changePassword({ currentPassword, newPassword }) {
    const current = await getSession();
    if (!current?.access_token) throw new Error("Sign in again to change your password.");
    await memberAuthRequest({ action: "change-password", currentPassword, newPassword }, current.access_token);
    persistSession(null);
  }

  async function select(table, { columns = "*", filters = {}, order, limit, range, single = false } = {}) {
    const query = new URLSearchParams({ select: columns });
    Object.entries(filters).forEach(([key, value]) => {
      if (Array.isArray(value)) query.set(key, `in.(${value.join(",")})`);
      else if (value && typeof value === "object") {
        Object.entries(value).forEach(([operator, filterValue]) => query.set(key, `${operator}.${filterValue}`));
      } else query.set(key, `eq.${value}`);
    });
    if (order) query.set("order", order);
    if (limit) query.set("limit", String(limit));
    const rows = await fetchJson(`/rest/v1/${encodeURIComponent(table)}?${query}`, {
      headers: range ? { Range: `${range[0]}-${range[1]}`, "Range-Unit": "items" } : {}
    });
    if (!Array.isArray(rows)) throw new Error(`Supabase returned invalid ${table} data.`);
    if (single) return rows[0] || null;
    return rows;
  }

  async function insert(table, rows, { returning = true } = {}) {
    const result = await fetchJson(`/rest/v1/${encodeURIComponent(table)}`, {
      method: "POST",
      body: Array.isArray(rows) ? rows : [rows],
      headers: { Prefer: returning ? "return=representation" : "return=minimal" }
    });
    return result;
  }

  async function update(table, filters, values, { returning = true } = {}) {
    const query = new URLSearchParams();
    Object.entries(filters).forEach(([key, value]) => query.set(key, `eq.${value}`));
    return fetchJson(`/rest/v1/${encodeURIComponent(table)}?${query}`, {
      method: "PATCH",
      body: values,
      headers: { Prefer: returning ? "return=representation" : "return=minimal" }
    });
  }

  async function remove(table, filters) {
    const query = new URLSearchParams();
    Object.entries(filters).forEach(([key, value]) => query.set(key, `eq.${value}`));
    return fetchJson(`/rest/v1/${encodeURIComponent(table)}?${query}`, { method: "DELETE", headers: { Prefer: "return=minimal" } });
  }

  async function rpc(name, args = {}) {
    return fetchJson(`/rest/v1/rpc/${encodeURIComponent(name)}`, { method: "POST", body: args });
  }

  async function storageRequest(path, { method = "GET", body, contentType } = {}) {
    requireConfig();
    const current = await getSession();
    const response = await fetch(`${baseUrl}/storage/v1/${path}`, {
      method,
      headers: {
        apikey: anonKey,
        Authorization: `Bearer ${current?.access_token || anonKey}`,
        ...(body && !(body instanceof Blob) ? { "Content-Type": "application/json" } : {}),
        ...(body instanceof Blob && contentType ? { "Content-Type": contentType } : {})
      },
      ...(body !== undefined ? { body: body instanceof Blob ? body : JSON.stringify(body) } : {})
    });
    const text = await response.text();
    let result = null;
    if (text) {
      try { result = JSON.parse(text); }
      catch { throw new Error("Supabase Storage returned an unreadable response."); }
    }
    if (!response.ok) {
      throw new Error(result?.message || result?.error || `Supabase Storage request failed (${response.status}).`);
    }
    return result;
  }

  function storagePath(path) {
    return path.split("/").map(encodeURIComponent).join("/");
  }

  async function uploadFile(bucket, path, file) {
    return storageRequest(`object/${encodeURIComponent(bucket)}/${storagePath(path)}`, {
      method: "POST",
      body: file,
      contentType: file.type
    });
  }

  async function deleteFiles(bucket, paths) {
    return storageRequest(`object/${encodeURIComponent(bucket)}`, {
      method: "DELETE",
      body: { prefixes: paths }
    });
  }

  async function createSignedUrl(bucket, path, expiresIn = 120) {
    const result = await storageRequest(`object/sign/${encodeURIComponent(bucket)}/${storagePath(path)}`, {
      method: "POST",
      body: { expiresIn }
    });
    if (typeof result?.signedURL !== "string") throw new Error("Supabase Storage did not return a signed receipt link.");
    return result.signedURL.startsWith("http") ? result.signedURL : `${baseUrl}/storage/v1${result.signedURL}`;
  }

  window.SkeptiCashSupabase = Object.freeze({
    isConfigured, getSession, onAuthStateChange, signUp, signIn, changePassword,
    signOut, select, insert, update, remove, rpc,
    uploadFile, deleteFiles, createSignedUrl
  });
})();
