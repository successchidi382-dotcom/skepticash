"use strict";

(() => {
  const config = window.SKEPTICASH_SUPABASE || {};
  const baseUrl = String(config.url || "").replace(/\/+$/, "");
  const anonKey = String(config.anonKey || "");
  const storageKey = baseUrl ? `skepticash-admin-auth-${new URL(baseUrl).hostname}` : "skepticash-admin-auth";
  let session = null;
  let refreshPromise = null;

  function isConfigured() {
    return Boolean(baseUrl && anonKey);
  }

  async function request(path, { method = "GET", body, token, headers = {} } = {}) {
    if (!isConfigured()) throw new Error("Supabase is not configured for this admin deployment.");
    const activeToken = token || (await getSession())?.access_token || anonKey;
    let response;
    try {
      response = await fetch(`${baseUrl}${path}`, {
        method,
        headers: {
          apikey: anonKey,
          Authorization: `Bearer ${activeToken}`,
          Accept: "application/json",
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
          ...headers
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {})
      });
    } catch (error) {
      if (error instanceof TypeError) throw new Error("Could not reach Supabase. Check the project URL and network.");
      throw error;
    }
    const text = await response.text();
    let result = null;
    if (text) {
      try { result = JSON.parse(text); }
      catch { throw new Error("Supabase returned an unreadable response."); }
    }
    if (!response.ok) {
      throw new Error(result?.msg || result?.message || result?.error_description || result?.error || `Supabase request failed (${response.status}).`);
    }
    return result;
  }

  function saveSession(value) {
    if (value && !value.expires_at) {
      value.expires_at = Math.floor(Date.now() / 1000) + Number(value.expires_in || 3600);
    }
    session = value;
    if (value) localStorage.setItem(storageKey, JSON.stringify(value));
    else localStorage.removeItem(storageKey);
  }

  async function getSession() {
    if (!session) {
      try { session = JSON.parse(localStorage.getItem(storageKey) || "null"); }
      catch { localStorage.removeItem(storageKey); }
    }
    if (!session) return null;
    if (!session.expires_at || session.expires_at * 1000 <= Date.now() + 30000) {
      if (refreshPromise) return refreshPromise;
      if (!session.refresh_token) { saveSession(null); return null; }
      refreshPromise = request("/auth/v1/token?grant_type=refresh_token", {
        method: "POST",
        body: { refresh_token: session.refresh_token },
        token: anonKey
      }).then((value) => { saveSession(value); return value; })
        .catch((error) => { saveSession(null); throw error; })
        .finally(() => { refreshPromise = null; });
      return refreshPromise;
    }
    return session;
  }

  async function signIn({ email, password }) {
    const value = await request("/auth/v1/token?grant_type=password", {
      method: "POST", body: { email, password }, token: anonKey
    });
    saveSession(value);
    return value;
  }

  async function signOut() {
    const current = await getSession();
    try {
      if (current?.access_token) await request("/auth/v1/logout", { method: "POST", token: current.access_token });
    } finally { saveSession(null); }
  }

  async function select(table, { columns = "*", filters = {}, order, limit } = {}) {
    const query = new URLSearchParams({ select: columns });
    Object.entries(filters).forEach(([key, value]) => {
      if (value && typeof value === "object") {
        Object.entries(value).forEach(([operator, filterValue]) => query.set(key, `${operator}.${filterValue}`));
      } else {
        query.set(key, `eq.${value}`);
      }
    });
    if (order) query.set("order", order);
    if (limit) query.set("limit", String(limit));
    const rows = await request(`/rest/v1/${encodeURIComponent(table)}?${query}`);
    if (!Array.isArray(rows)) throw new Error(`Supabase returned invalid ${table} data.`);
    return rows;
  }

  async function insert(table, rows) {
    return request(`/rest/v1/${encodeURIComponent(table)}`, {
      method: "POST",
      body: Array.isArray(rows) ? rows : [rows],
      headers: { Prefer: "return=representation" }
    });
  }

  async function update(table, filters, values) {
    const query = new URLSearchParams();
    Object.entries(filters).forEach(([key, value]) => query.set(key, `eq.${value}`));
    return request(`/rest/v1/${encodeURIComponent(table)}?${query}`, {
      method: "PATCH", body: values, headers: { Prefer: "return=representation" }
    });
  }

  async function remove(table, filters) {
    const query = new URLSearchParams();
    Object.entries(filters).forEach(([key, value]) => query.set(key, `eq.${value}`));
    return request(`/rest/v1/${encodeURIComponent(table)}?${query}`, { method: "DELETE" });
  }

  async function rpc(name, args = {}) {
    return request(`/rest/v1/rpc/${encodeURIComponent(name)}`, { method: "POST", body: args });
  }

  async function uploadFile(bucket, path, file) {
    const encodedPath = path.split("/").map(encodeURIComponent).join("/");
    const current = await getSession();
    if (!current?.access_token) throw new Error("Sign in to upload task media.");
    let response;
    try {
      response = await fetch(`${baseUrl}/storage/v1/object/${encodeURIComponent(bucket)}/${encodedPath}`, {
        method: "POST",
        headers: {
          apikey: anonKey,
          Authorization: `Bearer ${current.access_token}`,
          "Content-Type": file.type,
          "x-upsert": "false"
        },
        body: file
      });
    } catch (error) {
      if (error instanceof TypeError) throw new Error("Could not reach Supabase Storage.");
      throw error;
    }
    if (!response.ok) {
      const result = await response.json().catch(() => null);
      throw new Error(result?.message || result?.error || `Task media upload failed (${response.status}).`);
    }
  }

  async function deleteFiles(bucket, paths) {
    return request(`/storage/v1/object/${encodeURIComponent(bucket)}`, {
      method: "DELETE",
      body: { prefixes: paths }
    });
  }

  async function createSignedUrl(bucket, path, expiresIn = 120) {
    const encodedPath = path.split("/").map(encodeURIComponent).join("/");
    const result = await request(`/storage/v1/object/sign/${encodeURIComponent(bucket)}/${encodedPath}`, {
      method: "POST", body: { expiresIn }
    });
    if (typeof result?.signedURL !== "string") throw new Error("Supabase Storage did not return a signed receipt link.");
    return result.signedURL.startsWith("http") ? result.signedURL : `${baseUrl}/storage/v1${result.signedURL}`;
  }

  window.SkeptiCashSupabase = Object.freeze({
    isConfigured, getSession, signIn, signOut, select, insert, update, remove, rpc,
    uploadFile, deleteFiles, createSignedUrl
  });
})();
