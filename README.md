# orgsite

A minimal, dependency-free static site generator written in pure Emacs
Lisp. Turns a directory of `.org` files into a set of HTML pages,
suitable for personal blogs and portfolios.

- **Zero external deps** — only built-in `org`, `ox-html`, `seq`,
  `sgml-mode`, `dom`, and (optionally) `libxml`.
- **Razor-style templates** — plain HTML files with `@(elisp-expr)`
  interpolation. No DSL to learn.
- **File-based routing** — content tree mirrors URL tree. Hugo-style
  page bundles (`foo/index.org` + siblings) and section landings
  (`foo/_index.org`) both work.
- **Smart template resolver** — pick templates by layout, section,
  and kind.
- **Co-located assets, `public/`, `assets/`** — three asset
  conventions covered.
- **Dev server built-in** — `M-x orgsite-serve` → `http://127.0.0.1:8000/`.
- **Pretty-printed output** — via `sgml-pretty-print` or libxml.
- **Auto sitemap + RSS** — one toggle each, zero boilerplate.
- **Status workflow** — `#+STATUS:` filters drafts from feeds and
  listings.

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
├── templates/      -- HTML templates with @() tags (overrides)
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

```org
#+title: My Post
#+description: One-line summary used in <meta> and listings.
#+date: 2025-06-23
#+author: Jane Doe
#+filetags: :Tag1:Tag2:
#+layout: post
#+status: In Progress
#+kicker: Writing
```

`#+STATUS:` is free-form; `draft` is recognized as a filter marker by
the sitemap, RSS, and the `orgsite-posts` helper. Anything else is
passed through for templates to interpret.

## Routing

| File                          | URL            | Kind     |
|-------------------------------|----------------|----------|
| `content/index.org`           | `/`            | single   |
| `content/about.org`           | `/about/`      | single   |
| `content/blog/foo.org`        | `/blog/foo/`   | single   |
| `content/blog/foo/index.org`  | `/blog/foo/`   | single   |
| `content/blog/_index.org`     | `/blog/`       | list     |

`_index.org` = section landing (kind = list).
`index.org` inside a folder = page bundle; siblings (images, PDFs,
whatever) are copied into the output at the same relative path.

## Co-located assets

Any non-`.org` file in `content/` is mirrored into `dist/` at the
same relative path. So `content/blog/foo/diagram.svg` → `dist/blog/foo/diagram.svg`
and `[[./diagram.svg]]` in `foo/index.org` resolves correctly.

Use **`public/`** for files that must live at the site root (`cv.pdf`,
`favicon.ico`, `robots.txt`, `.well-known/`). Use **`assets/`** for
anything served under `/assets/` (stylesheets, fonts, bundled JS).

## Templates

### Resolution

For every page, the resolver tries, in order:

1. `<layout>.html`                (explicit `#+LAYOUT:`)
2. `<section>/<layout>.html`      (section-specific layout)
3. `<section>/<kind>.html`        (section-specific by kind)
4. `<kind>.html`                  (global `single.html` / `list.html`)
5. `layout.html`                  (universal fallback)

User `templates/` wins over the package-shipped defaults.

### Syntax

Razor-style interpolation:

```html
<h1>@(orgsite-escape (orgsite-page-title page))</h1>

<!-- @(sexp)  -- eval sexp, insert stringified result, nil -> "" -->
<!-- @@       -- emits a literal @ character                     -->
```

Any balanced elisp expression works inside `@(...)`. The built-in
Lisp reader parses it, so nested parens, backquotes and reader
syntax are fine.

### Env

Every template is rendered with two bindings:

- `page` — the current `orgsite-page` struct
- `pages` — the full list of pages in the build

Partials inherit the same env plus whatever extras are passed in.

### Package-shipped templates

| File                 | Purpose                                          |
|----------------------|--------------------------------------------------|
| `layout.html`        | Universal fallback: head + nav + body + footer   |
| `list.html`          | Section landing: body + posts of this section    |
| `home.html`          | Root: body + latest 5 posts                      |
| `nav.html`           | Top navigation bar                               |
| `footer.html`        | Site footer with © and author                    |
| `post-header.html`   | `<h1>` + optional `<time>` for posts             |
| `posts-list.html`    | `<section>` + `<ul>` of post entries             |
| `post-entry.html`    | Single `<li>` entry: date, link, description     |

Drop a same-named file into your project's `templates/` to override.

## Public API

### Pages

- `orgsite-page-title PAGE`, `orgsite-page-date PAGE`,
  `orgsite-page-description PAGE`, `orgsite-page-tags PAGE`,
  `orgsite-page-layout PAGE`, `orgsite-page-kicker PAGE`,
  `orgsite-page-status PAGE`, `orgsite-page-body PAGE`,
  `orgsite-page-slug PAGE`, `orgsite-page-source-path PAGE`
- `orgsite-page-url PAGE` — site-root-relative path
- `orgsite-page-permalink PAGE` — fully-qualified canonical URL
- `orgsite-page-section PAGE` — top-level section name or nil
- `orgsite-page-kind PAGE` — `list` or `single`
- `orgsite-page-is-post-p PAGE` — layout = post

### Listing helpers

- `orgsite-posts &key pages layout section tag include-drafts sort limit`
  — one-call listing. Defaults: pages = current build, layout = post,
  drafts excluded, newest first.
- `orgsite-sort-by-date PAGES &optional ASCENDING`
- `orgsite-filter-by-layout PAGES LAYOUT`
- `orgsite-filter-by-tag PAGES TAG`
- `orgsite-filter-by-status PAGES STATUS`
- `orgsite-reject-by-status PAGES STATUS`

### Template helpers

- `orgsite-escape STRING` — HTML-escape text.
- `orgsite-head PAGE` — render the default `<head>` block.
- `orgsite-partial NAME PAGE` — render a partial with PAGE bound.
- `orgsite-tmpl-render-file NAME ENV` — render partial with a
  custom env alist.
- `orgsite-tmpl-render TEMPLATE ENV` — render a raw template string.
- `orgsite-format-date ISO` — format an ISO date per
  `orgsite-date-format`.

### Build + serve

- `orgsite-build` — build the whole site (interactive).
- `orgsite-serve`, `orgsite-serve-stop`, `orgsite-serve-restart`,
  `orgsite-serve-status` — tiny dev HTTP server.

### Config variables

| Variable                            | Default                | Purpose                            |
|-------------------------------------|------------------------|------------------------------------|
| `orgsite-content-dir`               | `./content/`           | Source org files                   |
| `orgsite-output-dir`                | `./dist/`              | Build target                       |
| `orgsite-assets-dir`                | `./assets/`            | Copied to `/assets/`               |
| `orgsite-public-dir`                | `./public/`            | Copied to `/`                      |
| `orgsite-templates-dir`             | `./templates/`         | User template overrides            |
| `orgsite-site-title`                | `"My Site"`            |                                    |
| `orgsite-site-description`          | `"A personal site."`   |                                    |
| `orgsite-site-url`                  | `"https://example.com"`|                                    |
| `orgsite-site-author`               | `"Anonymous"`          |                                    |
| `orgsite-extra-stylesheets`         | `("/assets/style.css")`|                                    |
| `orgsite-date-format`               | `"%B %-d, %Y"`         | `format-time-string` pattern       |
| `orgsite-output-format`             | `pretty`               | `pretty`, `libxml`, `minify`, nil  |
| `orgsite-generate-sitemap`          | `t`                    | Auto-emit `/sitemap.xml`           |
| `orgsite-sitemap-output`            | `"sitemap.xml"`        |                                    |
| `orgsite-generate-rss`              | `t`                    | Auto-emit RSS feed                 |
| `orgsite-rss-output`                | `"rss.xml"`            |                                    |
| `orgsite-rss-limit`                 | `20`                   | Items per feed                     |
| `orgsite-rss-filter`                | layout = post          | Predicate for inclusion            |
| `orgsite-serve-host`                | `"127.0.0.1"`          | Dev server bind                    |
| `orgsite-serve-port`                | `8000`                 |                                    |
| `orgsite-synthetic-pages-functions` | `nil`                  | Hook producing extra pages         |

## Extending

### Custom listings / archives

Push a function onto `orgsite-synthetic-pages-functions`:

```elisp
(defun my-tag-pages (pages)
  (mapcar
   (lambda (tag)
     (make-orgsite-page
      :slug  (concat "tags/" (downcase tag))
      :title (format "Posts tagged %s" tag)
      :layout 'page
      :body  (orgsite-tmpl-render-file
              "posts-list.html"
              `((page . nil)
                (posts . ,(orgsite-posts :tag tag))))))
   (my-collect-all-tags pages)))

(add-hook 'orgsite-synthetic-pages-functions #'my-tag-pages)
```

### Raw XML / JSON output

Set `:raw t` on an `orgsite-page` and its `:body` is written to
disk verbatim --- no template wrap, no HTML formatter.

### Dev server

```elisp
M-x orgsite-serve          ;; 127.0.0.1:8000
M-x orgsite-serve-stop
M-x orgsite-serve-restart
M-x orgsite-serve-status
```

Request log goes to `*orgsite-serve*`.  Path-traversal guarded.

## License

GPL-3.0-or-later.  See `LICENSE`.
