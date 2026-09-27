// Minimal web-API polyfills for a bare JavaScriptCore context.
// Only the surface apps/api/src actually touches.
const g = globalThis;

if (typeof g.TextEncoder === "undefined") {
  g.TextEncoder = class TextEncoder {
    encode(s = "") {
      const bin = unescape(encodeURIComponent(s));
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    }
  };
  g.TextDecoder = class TextDecoder {
    decode(b) {
      if (!b) return "";
      const u = b instanceof Uint8Array ? b : new Uint8Array(b.buffer ?? b);
      let s = ""; for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
      return decodeURIComponent(escape(s));
    }
  };
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
if (typeof g.btoa === "undefined") {
  g.btoa = (s) => {
    let out = "";
    for (let i = 0; i < s.length; i += 3) {
      const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
      const n = (a << 16) | ((b || 0) << 8) | (c || 0);
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (isNaN(b) ? "=" : B64[(n >> 6) & 63]) + (isNaN(c) ? "=" : B64[n & 63]);
    }
    return out;
  };
  g.atob = (s) => {
    s = String(s).replace(/[\s=]/g, "");
    let out = "", buf = 0, bits = 0;
    for (const ch of s) {
      const v = B64.indexOf(ch); if (v < 0) throw new Error("invalid base64");
      buf = (buf << 6) | v; bits += 6;
      if (bits >= 8) { bits -= 8; out += String.fromCharCode((buf >> bits) & 255); }
    }
    return out;
  };
}

if (typeof g.setTimeout === "undefined") {
  // No event loop in the host: timers are never fired (only reward-tools streaming uses one).
  let id = 0;
  g.setTimeout = () => ++id;
  g.clearTimeout = () => {};
}

if (typeof g.crypto === "undefined") {
  g.crypto = {
    getRandomValues(arr) { const b = g.__random(arr.byteLength); new Uint8Array(arr.buffer, arr.byteOffset, arr.byteLength).set(b); return arr; },
    randomUUID() {
      const b = g.__random(16); b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
      const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
      return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
    },
  };
}

if (typeof g.URLSearchParams === "undefined") {
  const dec = (s) => decodeURIComponent(s.replace(/\+/g, " "));
  const enc = (s) => encodeURIComponent(s).replace(/%20/g, "+");
  g.URLSearchParams = class URLSearchParams {
    constructor(init = "") {
      this._p = [];
      if (typeof init === "string") {
        for (const part of init.replace(/^\?/, "").split("&")) {
          if (!part) continue;
          const i = part.indexOf("=");
          this._p.push(i < 0 ? [dec(part), ""] : [dec(part.slice(0, i)), dec(part.slice(i + 1))]);
        }
      } else if (init && typeof init === "object") {
        for (const [k, v] of Array.isArray(init) ? init : Object.entries(init)) this._p.push([String(k), String(v)]);
      }
    }
    get(k) { const e = this._p.find(([n]) => n === k); return e ? e[1] : null; }
    getAll(k) { return this._p.filter(([n]) => n === k).map(([, v]) => v); }
    has(k) { return this._p.some(([n]) => n === k); }
    set(k, v) { this.delete(k); this._p.push([k, String(v)]); }
    append(k, v) { this._p.push([k, String(v)]); }
    delete(k) { this._p = this._p.filter(([n]) => n !== k); }
    entries() { return this._p[Symbol.iterator](); }
    keys() { return this._p.map(([k]) => k)[Symbol.iterator](); }
    forEach(fn) { this._p.forEach(([k, v]) => fn(v, k, this)); }
    [Symbol.iterator]() { return this.entries(); }
    toString() { return this._p.map(([k, v]) => `${enc(k)}=${enc(v)}`).join("&"); }
  };
}

if (typeof g.URL === "undefined") {
  // Absolute http(s) URLs only; enough for request routing.
  const RE = /^([a-z][a-z0-9+.-]*:)\/\/(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?#]+)(?::(\d+))?([^?#]*)(\?[^#]*)?(#.*)?$/i;
  g.URL = class URL {
    constructor(input, base) {
      let s = String(input);
      if (!RE.test(s) && base) { const b = new URL(base); s = s.startsWith("/") ? b.origin + s : b.origin + b.pathname.replace(/[^/]*$/, "") + s; }
      const m = RE.exec(s);
      if (!m) throw new TypeError(`Invalid URL: ${s}`);
      this.protocol = m[1].toLowerCase(); this.username = m[2] ?? ""; this.password = m[3] ?? "";
      this.hostname = m[4].toLowerCase(); this.port = m[5] ?? "";
      this.pathname = m[6] || "/"; this.search = m[7] && m[7] !== "?" ? m[7] : ""; this.hash = m[8] ?? "";
      this.searchParams = new g.URLSearchParams(this.search);
    }
    get host() { return this.port ? `${this.hostname}:${this.port}` : this.hostname; }
    get origin() { return `${this.protocol}//${this.host}`; }
    get href() { return `${this.origin}${this.pathname}${this.search}${this.hash}`; }
    toString() { return this.href; }
  };
}

if (typeof g.Headers === "undefined") {
  g.Headers = class Headers {
    constructor(init) {
      this._h = new Map();
      if (init instanceof Headers) init.forEach((v, k) => this.set(k, v));
      else if (Array.isArray(init)) init.forEach(([k, v]) => this.append(k, v));
      else if (init) Object.entries(init).forEach(([k, v]) => this.set(k, v));
    }
    get(k) { const v = this._h.get(String(k).toLowerCase()); return v === undefined ? null : v; }
    has(k) { return this._h.has(String(k).toLowerCase()); }
    set(k, v) { this._h.set(String(k).toLowerCase(), String(v)); }
    append(k, v) { const key = String(k).toLowerCase(); this._h.set(key, this._h.has(key) ? `${this._h.get(key)}, ${v}` : String(v)); }
    delete(k) { this._h.delete(String(k).toLowerCase()); }
    forEach(fn) { this._h.forEach((v, k) => fn(v, k, this)); }
    entries() { return this._h.entries(); }
    [Symbol.iterator]() { return this._h.entries(); }
  };
}

const bodyText = (b) => b == null ? "" : typeof b === "string" ? b : new TextDecoder().decode(b);

if (typeof g.Request === "undefined") {
  g.Request = class Request {
    constructor(url, init = {}) {
      this.url = String(url); this.method = (init.method ?? "GET").toUpperCase();
      this.headers = new g.Headers(init.headers); this._body = init.body ?? null; this.signal = init.signal ?? null;
    }
    async text() { return bodyText(this._body); }
    async json() { return JSON.parse(bodyText(this._body)); }
  };
}

if (typeof g.Response === "undefined") {
  g.Response = class Response {
    constructor(body = null, init = {}) {
      this._body = body; this.status = init.status ?? 200; this.statusText = init.statusText ?? "";
      this.headers = new g.Headers(init.headers);
    }
    get ok() { return this.status >= 200 && this.status < 300; }
    async text() { return bodyText(this._body); }
    async json() { return JSON.parse(bodyText(this._body)); }
    static json(data, init = {}) {
      const r = new Response(JSON.stringify(data), init);
      if (!r.headers.has("content-type")) r.headers.set("content-type", "application/json");
      return r;
    }
    static redirect(url, status = 302) { return new Response(null, { status, headers: { location: url } }); }
  };
}
