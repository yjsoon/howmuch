import { describe, expect, test } from "bun:test";
import { DOCUMENT_SECURITY_HEADERS, withDocumentSecurityHeaders } from "./security-headers";

describe("withDocumentSecurityHeaders", () => {
  test("pins a restrictive CSP and clickjacking protections", () => {
    const response = withDocumentSecurityHeaders(new Response("<html></html>", {
      headers: { "content-type": "text/html; charset=utf-8" },
    }));
    expect(response.headers.get("content-security-policy")).toBe(DOCUMENT_SECURITY_HEADERS["content-security-policy"]);
    expect(response.headers.get("x-frame-options")).toBe("DENY");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(response.headers.get("cache-control")).toBe("no-cache");
    expect(response.headers.get("content-security-policy")).toContain("frame-ancestors 'none'");
    expect(response.headers.get("content-security-policy")).not.toContain("unsafe-eval");
  });

  test("does not disable caching for hashed static assets", () => {
    const response = withDocumentSecurityHeaders(new Response("ok", {
      headers: { "content-type": "text/javascript", "cache-control": "public, max-age=31536000, immutable" },
    }));
    expect(response.headers.get("cache-control")).toBe("public, max-age=31536000, immutable");
  });
});
