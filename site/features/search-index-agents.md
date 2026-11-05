# Use the index with an agent

The [search index](/features/search-index) answers over HTTP with JSON, which
makes a WordPress site's whole archive usable by an AI agent: it can search
the text of every published post and page, filter by author, category, tag and
date, and count instead of read. wordpress-idx ships a compact API reference
written for that purpose, <IdxLink file="API_PROMPT.md" />. Hand it to the
agent together with the address of the index.

## What the agent needs

1. **The address.** With `idx.enabled` and `ingress.enabled`, the chart's
   Ingress routes `idx.basePath` (default `/idx`) on the site's host name to
   the sidecar. The API of a site at `blog.example.com` is then at
   `https://blog.example.com/idx/api/`. Without the chart's Ingress, the
   sidecar answers on a port of its own on the release's Service,
   `idx.service.port` (default 3000), under the same base path.
2. **The reference.** <IdxLink file="API_PROMPT.md" /> describes the
   endpoints, their parameters and the entry format in about seventy lines. The
   link, like the plain-text one below, points at the wordpress-idx release
   this chart version deploys.

The search and statistics endpoints need no credentials. The index holds what
the site publishes anyway: published posts and pages, and approved comments.
Only `POST /api/reindex` asks for a key.

## A prompt to start from

Put the reference into the agent's instructions, or let the agent fetch it:

```text
You can search the archive of blog.example.com through its full-text index.

Base URL: https://blog.example.com/idx
API reference: read it before your first request, from the address below.

Use /api/stats to learn the shape of the archive before you search. Search
with context=true and a limit first, then fetch the entries worth reading in
full by id. Cite each entry you use by its title, date and slug.
```

The reference as plain text:
<IdxLink file="API_PROMPT.md" raw>API_PROMPT.md (raw)</IdxLink>.

## Requests an agent makes

Learn the shape of the archive: totals, the date range, and the most frequent
authors, categories and tags.

```bash
curl -s 'https://blog.example.com/idx/api/stats'
```

Search with snippets instead of full texts. `context=true` returns about 500
characters around the first match, which keeps the answer small enough to read
many hits:

```bash
curl -s 'https://blog.example.com/idx/api/search?q=kubernetes&context=true&limit=20'
```

Narrow by metadata. Filters combine with AND, and a partial date covers the
whole period, so this is every post tagged `docker` from 2023 and 2024 that
mentions backups:

```bash
curl -s 'https://blog.example.com/idx/api/search?q=backup&type=post&tag=docker&from=2023&to=2024&context=true'
```

Read one entry in full, by the id a search returned:

```bash
curl -s 'https://blog.example.com/idx/api/entry/1234'
```

Count instead of read. `/api/stats` takes the same filters as the search, so
"how much did this author write about the topic, and when" is one request:

```bash
curl -s 'https://blog.example.com/idx/api/stats?q=kubernetes&author=jane'
```

Include the discussion. Comments are part of every entry; with
`include_comments=true` the full-text search matches them as well:

```bash
curl -s 'https://blog.example.com/idx/api/search?q=migration&include_comments=true&context=true&limit=10'
```

## Questions this answers

- *What has the site published about a topic, and how did it change over the
  years?* Search with `context=true`, a year at a time with `from` and `to`.
- *Which posts should a new article link to?* Search for its key terms and
  read the best hits by id.
- *Is there already a post on this?* A search limited to `type=post`, before
  writing a new one.
- *Who writes about what?* `/api/stats` per author or per category.

## Good to know

- The search matches word beginnings: `kube` finds `kubernetes`.
- Without `q`, a request returns every entry the filters leave. Set a `limit`
  unless the agent is meant to read the whole archive.
- The index is built from the database when the sidecar first starts and
  loaded from the volume after that. A reindex brings it up to date;
  [Search index](/features/search-index) covers the sidecar's settings.
