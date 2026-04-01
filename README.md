# Thallium — Web Proxy Backend

A production-grade Ruby web proxy backend inspired by CroxyProxy, built with
Sinatra + Puma. Thallium fetches any public web page through the server,
rewrites all URLs so assets and links continue to work, and exposes a clean
JSON API for frontend integration.

---

## Features

| Feature | Details |
|---|---|
| **Full HTML rewriting** | Rewrites `<a>`, `<script>`, `<img>`, `<link>`, `<form>`, `srcset`, CSS `url()`, meta-refresh |
| **JS shim** | Intercepts `fetch()` and `XMLHttpRequest` for dynamic content |
| **Cookie passthrough** | Per-session cookie jar so login flows work |
| **Redirect following** | Follows up to 5 HTTP redirects automatically |
| **Gzip / deflate** | Decodes compressed upstream responses |
| **SSRF protection** | Blocks private IPs, loopback, link-local, cloud metadata endpoints |
| **Rate limiting** | Token-bucket (30 req burst, 5 req/s refill) per IP, fully in-memory |
| **CORS** | Open CORS so any frontend can connect |
| **Concurrent** | Puma multi-threaded; no global lock on requests |

---

## Quick Start

```bash
# 1. Install dependencies
cd thallium
bundle install

# 2. Start the server (default port 4567)
bundle exec ruby server.rb

# OR via Rack (recommended for production)
bundle exec rackup config.ru -p 4567
```

---

## API Reference

### `GET /health`
Returns server status.

```json
{ "status": "ok", "version": "1.0.0", "name": "Thallium" }
```

---

### `POST /api/proxy`
Proxy a URL and receive the (rewritten) page body.

**Request body (JSON):**
```json
{
  "url": "https://example.com",
  "options": {
    "referer": "https://google.com"   // optional
  }
}
```

**Response:**
- `Content-Type` mirrors the upstream type
- Body is the (HTML-rewritten) page
- A `thallium_session` cookie is set for cookie persistence

**Error responses:**
```json
{ "error": "Invalid or blocked URL" }          // 400
{ "error": "Rate limit exceeded." }            // 429
{ "error": "Could not reach target: ..." }     // 502
{ "error": "Target server timed out" }         // 504
```

---

### `GET /proxy?url=<encoded-url>`
Direct asset passthrough — used by the rewritten `src` / `href` attributes.
Returns raw body with upstream Content-Type. No HTML rewriting.

---

### `GET /api/info?url=<encoded-url>`
Returns metadata about the target URL without fetching it.

```json
{
  "host":    "example.com",
  "scheme":  "https",
  "path":    "/",
  "port":    443,
  "proxied": "/proxy?url=https%3A%2F%2Fexample.com"
}
```

---

### `GET /api/stats`
Runtime statistics.

```json
{
  "requests_served": 1042,
  "active_sessions": 7,
  "uptime_seconds":  3600
}
```

---

## Architecture

```
client
  │
  ▼
server.rb         ← Sinatra routes, CORS, error handling
  │
  ├─ lib/url_validator.rb    ← SSRF protection (private IP blocking)
  ├─ lib/rate_limiter.rb     ← Token-bucket per-IP limiter
  ├─ lib/request_handler.rb  ← HTTP fetch, redirect following, decompression
  ├─ lib/html_rewriter.rb    ← Nokogiri URL rewriting + JS shim injection
  └─ lib/session_manager.rb  ← Cookie persistence per session
```

---

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `PORT` | `4567` | TCP port to listen on |

For Puma threading, create a `puma.rb`:

```ruby
threads 4, 16
workers ENV.fetch('WEB_CONCURRENCY', 2).to_i
preload_app!
```

---

## Security Notes

- **SSRF**: All RFC-1918, loopback, link-local, and cloud-metadata addresses
  are blocked before any DNS lookup. Hostnames are resolved and each returned IP
  is validated.
- **No credentials stored**: Session cookies live only in RAM and expire after
  1 hour of inactivity.
- **No logging of user URLs** in production mode (add your own audit log if needed).
- Consider adding authentication (API key / OAuth) before exposing publicly.

---

## Connecting a Frontend

Point your form's submit or fetch call at `POST /api/proxy`:

```js
const res = await fetch('/api/proxy', {
  method: 'POST',
  credentials: 'include',          // send the session cookie
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ url: 'https://example.com' })
});
const html = await res.text();
document.getElementById('frame').srcdoc = html;
```

Or render the proxied page in an `<iframe>` by pointing `src` at
`/proxy?url=https%3A%2F%2Fexample.com`.
