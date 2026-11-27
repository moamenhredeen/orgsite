# orgsite

A minimal, dependency-free static site generator written in pure Emacs
Lisp. Turns a directory of `.org` files into a set of HTML pages,
suitable for personal blogs and portfolios.

- **Zero external dependencies** — only built-in `org`, `ox-html`,
  `sgml-mode`, and (optionally) `libxml` are used.
- **Razor-style templates** — plain HTML with `@(elisp-expr)`
  interpolation. No DSL to learn.
- **File-based routing** — content tree mirrors URL tree. Includes
  Hugo-style page bundles (`foo/index.org` + siblings) and section
  landings (`foo/_index.org`).
- **Dev server built-in** — `M-x orgsite-serve` starts an HTTP
  server at `http://127.0.0.1:8000/` using `make-network-process`.
- **Pretty-printed output** — via `sgml-pretty-print` or
  `libxml-parse-html-region` + `dom-print`.

## Install

Via `use-package` + `:vc` (Emacs 30+):

```elisp
(use-package orgsite
  :vc (:url "https://github.com/moamenhredeen/orgsite" :branch "main"))
```

Via `straight.el`:

```elisp
(straight-use-package
 '(orgsite :type git :host github :repo "moamenhredeen/orgsite"))
```

Or clone and add to `load-path`:

```elisp
(add-to-list 'load-path "/path/to/orgsite")
(require 'orgsite)
```

## Project layout

```
my-site/
├── site.el         -- user config, calls (orgsite-build)
├── content/        -- source .org files; nested dirs allowed
├── templates/      -- HTML templates with @() tags
├── assets/         -- static files copied to /assets/
└── public/         -- static files copied to /
```

## Minimal `site.el`

```elisp
(setq orgsite-site-title       "My Site"
      orgsite-site-description "A personal site."
      orgsite-site-url         "https://example.com"
      orgsite-site-author      "Jane Doe")

(orgsite-build)
```

Build:

```
emacs --batch -l site.el
```

## Front matter

Standard org keywords at the top of each `.org` file:

```org
#+title: My Post
#+description: One-line summary used in <meta> and listings.
#+date: 2025-06-23
#+author: Jane Doe
#+filetags: :Tag1:Tag2:
#+layout: post
#+status: In Progress
```

## Routing conventions

| File                          | URL           |
|-------------------------------|---------------|
| `content/index.org`           | `/`           |
| `content/about.org`           | `/about/`     |
| `content/blog/foo.org`        | `/blog/foo/`  |
| `content/blog/foo/index.org`  | `/blog/foo/`  |
| `content/blog/_index.org`     | `/blog/`      |

`_index.org` = section landing (kind=list).
`index.org` inside a folder = page bundle; sibling non-org files are
copied into the output at the same relative path.

## Template resolution

For every page, the following candidates are tried in order:

1. `<layout>.html`                       (explicit `#+LAYOUT:`)
2. `<section>/<kind>.html`               (section-specific)
3. `<kind>.html`                         (`single.html` or `list.html`)
4. `layout.html`                         (universal fallback)

Kind is `list` for `_index.org`, `single` otherwise.

## Template syntax

```html
<h1>@(orgsite-escape (orgsite-page-title page))</h1>
<ul>
  @(mapconcat (lambda (post)
                (orgsite-tmpl-render-file "entry.html" `((post . ,post))))
              (orgsite-sort-by-date
                (orgsite-filter-by-layout pages 'post))
              "\n")
</ul>
<!-- @@ emits a literal @ character -->
```

## Public API

Helpers templates and user code can call:

- `orgsite-escape STRING` — HTML-escape text.
- `orgsite-head PAGE` — render the default `<head>` block.
- `orgsite-partial NAME PAGE` — render a partial with PAGE bound.
- `orgsite-sort-by-date PAGES &optional ASCENDING` — sort pages by date.
- `orgsite-filter-by-layout PAGES LAYOUT` — filter by `#+LAYOUT:`.
- `orgsite-filter-by-tag PAGES TAG` — filter by tag.
- `orgsite-filter-by-status PAGES STATUS` / `orgsite-reject-by-status` — filter by `#+STATUS:`.
- `orgsite-format-date ISO` — format an ISO date per `orgsite-date-format`.

## Dev server

```
M-x orgsite-serve         -- start on 127.0.0.1:8000
M-x orgsite-serve-stop    -- kill the server
M-x orgsite-serve-restart
M-x orgsite-serve-status
```

Request log in buffer `*orgsite-serve*`.

## License

GPL-3.0-or-later.  See `LICENSE`.
