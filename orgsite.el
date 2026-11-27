;;; orgsite.el --- Static site generator for Org files -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Moamen Hredeen

;; Author: Moamen Hredeen
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (seq "2.0"))
;; Keywords: hypermedia, outlines, org
;; URL: https://github.com/moamenhredeen/orgsite
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; orgsite is a minimal, dependency-free static site generator written
;; in pure Emacs Lisp.  It turns a directory of `.org' files into a
;; set of HTML pages, suitable for personal blogs and portfolios.
;;
;; Usage in a project's `site.el':
;;
;;   (setq orgsite-site-title "My Site"
;;         orgsite-site-url   "https://example.com")
;;   (orgsite-build)
;;
;; Project layout:
;;
;;   my-site/
;;   ├── site.el       -- user config, calls `orgsite-build'
;;   ├── content/      -- source .org files; nested dirs allowed
;;   └── assets/       -- static files, copied verbatim to dist/assets/
;;
;; Build pipeline (each stage is one function, no hidden state):
;;
;;   discover  -> list of .org source paths
;;   load      -> list of `orgsite-page' structs with metadata
;;   generate  -> add synthetic pages (blog index, later feeds)
;;   render    -> fill each page's BODY slot with HTML via ox-html
;;   format    -> optional pretty-print / minify pass
;;   write     -> wrap in layout, write to dist/
;;   assets    -> copy static files verbatim
;;
;; The file is organised in sections separated by `;;;;' banners so
;; `outline-minor-mode' can fold them.  Reading order mirrors the
;; pipeline above.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'ox-html)
(require 'sgml-mode)
(require 'dom)


;;;; ============================================================ Config

;; All user-facing configuration lives here.  Plain `defvar's so a
;; project's `site.el' can override with a simple `setq'.  Paths are
;; absolute strings without trailing slashes.  Defaults resolve
;; against `default-directory', so running `orgsite-build' from a
;; project root "just works" without any configuration, as long as
;; the project uses the standard `content/' + `assets/' layout.

(defvar orgsite-project-marker "site.el"
  "Filename that marks the root of an orgsite project.
`orgsite-project-root' walks up from `default-directory' looking
for a file with this name, the way LSP servers find a workspace
root.")

(defvar orgsite-project-root nil
  "Absolute path of the current project root, or nil.
When nil, orgsite looks it up on demand via
`orgsite-project-root'.  Set it explicitly from `site.el' only
when you want to override the auto-detection.")

(defvar orgsite-content-dir nil
  "Directory that holds the source `.org' files.
When nil, resolves to `<project-root>/content' at build time.")

(defvar orgsite-output-dir nil
  "Directory where the built HTML is written.
When nil, resolves to `<project-root>/dist' at build time.
Safe to delete between builds; the build will recreate it.")

(defvar orgsite-assets-dir nil
  "Directory of static files copied verbatim into the output as `assets/'.
When nil, resolves to `<project-root>/assets' at build time.
Skipped silently if the directory does not exist.")

(defvar orgsite-public-dir nil
  "Directory copied verbatim into the ROOT of the output dir.
When nil, resolves to `<project-root>/public' at build time.
Use for files that must live at the site root --- `favicon.ico',
`robots.txt', `cv.pdf', etc.  Skipped silently when missing.")

(defvar orgsite-date-format "%B %-d, %Y"
  "Pattern passed to `format-time-string' by `orgsite-format-date'.
Change to any `format-time-string' spec.  Examples:
  \"%B %-d, %Y\"  -> November 27, 2026   (default)
  \"%-d %B %Y\"   -> 27 November 2026
  \"%Y-%m-%d\"    -> 2026-11-27           (ISO, machine-readable)
  \"%a, %-d %b\"  -> Fri, 27 Nov")

(defvar orgsite-site-title "My Site"
  "Site title used in the <title> tag and templates.")

(defvar orgsite-site-description "A personal site."
  "Default meta description for pages that omit `#+DESCRIPTION:'.")

(defvar orgsite-site-url "https://example.com"
  "Canonical base URL of the deployed site, no trailing slash.")

(defvar orgsite-site-author "Anonymous"
  "Default author name for pages without an explicit `#+AUTHOR:'.")

(defvar orgsite-extra-stylesheets '("/assets/style.css")
  "List of stylesheet URLs linked from every page.
Read by the default `orgsite-head' helper; set to nil to disable
the automatic <link> tags and manage stylesheets yourself in the
`layout.html' template.")

(defvar orgsite-synthetic-pages-functions nil
  "Hook of functions that generate extra pages not backed by `.org' files.
Each function receives the list of loaded pages and must return a
list of additional `orgsite-page' structs (possibly empty).
Called after loading, before rendering.  Use this to build
listings, archives, category indexes, feeds, etc.")

(defvar orgsite-pre-build-hook nil
  "Normal hook run before every `orgsite-build'.
Useful for cleaning the output dir, compiling Tailwind, running
a formatter over content, etc.")

(defvar orgsite-post-build-hook nil
  "Normal hook run after every successful `orgsite-build'.
Useful for deploy steps (rsync, wrangler, vercel, s3 sync).")

;;; --------------------------------------- sitemap + RSS auto-generation

(defvar orgsite-generate-sitemap t
  "When non-nil, orgsite auto-emits `/sitemap.xml' for every build.
Set to nil to disable or to fully override via
`orgsite-synthetic-pages-functions'.")

(defvar orgsite-sitemap-output "sitemap.xml"
  "Relative output path (under dist/) for the auto-generated sitemap.")

(defvar orgsite-generate-rss t
  "When non-nil, orgsite auto-emits an RSS 2.0 feed of the latest posts.
Set to nil to disable.")

(defvar orgsite-rss-output "rss.xml"
  "Relative output path (under dist/) for the auto-generated RSS feed.
Default puts it at the site root; set to e.g. \"blog/rss.xml\" to
place it under a section.")

(defvar orgsite-rss-limit 20
  "Maximum number of items included in the auto-generated RSS feed.
Set to nil for no cap.")

(defvar orgsite-rss-filter
  (lambda (p) (eq (orgsite-page-layout p) 'post))
  "Predicate selecting which pages belong in the RSS feed.
Defaults to `#+LAYOUT: post'.  Change to broaden or narrow the
feed (e.g. include a specific section only).")

(defvar orgsite-templates-dir nil
  "User template directory.
When nil, resolves to `<project-root>/templates' at build time.
Looked up first by `orgsite--find-template'; falls back to the
package's built-in templates when a file is not found here.")

(defvar orgsite--package-templates-dir
  (expand-file-name "templates"
                    (file-name-directory
                     (or load-file-name buffer-file-name "")))
  "Directory of templates shipped with the orgsite package.
Serves as the fallback when a template is missing from
`orgsite-templates-dir'.")

(defun orgsite-project-root ()
  "Return the current project root, auto-detecting if needed.
Checks `orgsite-project-root'; if nil, walks up from
`default-directory' looking for a file named
`orgsite-project-marker' (default `site.el').  Falls back to
`default-directory' with a warning so running from a fresh
directory still builds something."
  (or orgsite-project-root
      (let ((root (locate-dominating-file default-directory
                                          orgsite-project-marker)))
        (if root
            (expand-file-name root)
          (prog1 (expand-file-name default-directory)
            (message "orgsite: no `%s' found above `%s'; using cwd"
                     orgsite-project-marker default-directory))))))

(defvar orgsite--auto-set-paths nil
  "List of path variable symbols that orgsite derived itself.
Used by `orgsite--resolve-paths' to re-derive paths when the
project root changes (e.g. the user runs `orgsite-serve' from a
second project in the same Emacs session) without clobbering
anything the user set explicitly.")

(defun orgsite--detect-root ()
  "Return the project root for the current `default-directory'.
Walks up looking for `orgsite-project-marker'.  Falls back to
`default-directory' with a warning."
  (let ((root (locate-dominating-file default-directory
                                      orgsite-project-marker)))
    (if root
        (expand-file-name root)
      (prog1 (expand-file-name default-directory)
        (message "orgsite: no `%s' found above `%s'; using cwd"
                 orgsite-project-marker default-directory)))))

;;;###autoload
(defun orgsite-project-try (dir)
  "Backend for `project-find-functions'.
Returns a project descriptor when DIR is inside an orgsite
project (i.e. has `orgsite-project-marker' in an ancestor dir).
Registered via `orgsite-project-enable'.

See `project-root' and friends from Emacs' built-in `project'
library for the full API."
  (when-let* ((root (locate-dominating-file dir orgsite-project-marker)))
    (cons 'orgsite (expand-file-name root))))

(cl-defmethod project-root ((project (head orgsite)))
  "Return the root directory of an orgsite PROJECT."
  (cdr project))

;;;###autoload
(defun orgsite-project-enable ()
  "Register orgsite as a `project.el' backend.
After calling this, any directory containing a `site.el' is
recognized by `project-current', `project-find-file' (C-x p f),
etc.  Call once from your init.el:

  (with-eval-after-load \\='project
    (orgsite-project-enable))"
  (interactive)
  (require 'project)
  (add-hook 'project-find-functions #'orgsite-project-try))

(defun orgsite--resolve-paths ()
  "Fill derived path variables for the current project root.
If the root has changed since the last resolve, reset the
auto-derived paths first so they re-fill against the new root.
Paths the user set explicitly (not via this function) are kept
untouched across calls."
  (let ((root (orgsite--detect-root)))
    ;; Root moved?  Drop everything we previously auto-set so those
    ;; vars re-fill from the new root on this call.
    (unless (equal root orgsite-project-root)
      (dolist (sym orgsite--auto-set-paths)
        (set sym nil))
      (setq orgsite--auto-set-paths nil
            orgsite-project-root root))
    (dolist (pair '((orgsite-content-dir   . "content")
                    (orgsite-output-dir    . "dist")
                    (orgsite-assets-dir    . "assets")
                    (orgsite-public-dir    . "public")
                    (orgsite-templates-dir . "templates")))
      (let ((sym (car pair)) (sub (cdr pair)))
        (unless (symbol-value sym)
          (set sym (expand-file-name sub root))
          (push sym orgsite--auto-set-paths))))))

(defvar orgsite-output-format 'pretty
  "How to format HTML before writing.
Possible values:
  nil      -- write the raw string from the template as-is.
  `pretty' -- run through `sgml-pretty-print' (built-in sgml-mode).
  `libxml' -- round-trip through libxml + `dom-print' pretty mode.
              Requires Emacs built with libxml2 support.
  `minify' -- collapse whitespace between tags (not yet implemented).")

(defvar orgsite-serve-host "127.0.0.1"
  "Host interface the dev server binds to.
Default is localhost-only.  Set to \"0.0.0.0\" to expose on LAN.")

(defvar orgsite-serve-port 8000
  "TCP port the dev server listens on.")


;;;; ============================================================== Page

;; A "page" is the central data structure of the build.  It carries
;; everything needed to render one HTML file: source path, output
;; path, metadata parsed from the Org keywords, the layout it wants,
;; and once rendered, the body HTML.  Body is filled later, not at
;; load time, so the loader does not depend on the exporter.

(cl-defstruct orgsite-page
  "A single page in the build graph.

Slots:
  SLUG         -- output path minus the extension (e.g. \"blog/foo\").
                  Drives both the URL and the on-disk HTML file name.
  SOURCE-PATH  -- absolute path to the source `.org' file, or nil for
                  pages generated in memory (such as the blog index).
  OUTPUT-PATH  -- absolute path of the HTML file to write.
  TITLE        -- page title (string).
  DESCRIPTION  -- meta description / summary (string).
  KICKER       -- small eyebrow label shown above the title.
  DATE         -- ISO date string for post sorting, or nil.
  AUTHOR       -- author name (string or nil).
  TAGS         -- list of tag strings, empty list if none.
  LAYOUT       -- symbol, one of `home', `page', `post'.  Templates
                  dispatch on this.
  STATUS       -- free-form status string from `#+STATUS:', or nil.
                  Typical values: \"draft\", \"published\", \"archived\".
                  Not interpreted by the package; use
                  `orgsite-filter-by-status' in your site code.
  RAW          -- when non-nil, the page's BODY is written to disk
                  verbatim: no template wrapping, no HTML formatter
                  pass.  Use this for XML artefacts like sitemaps and
                  RSS feeds.
  BODY         -- rendered inner HTML.  Filled later by the renderer."
  slug source-path output-path
  title description kicker date author tags
  (layout 'page)
  status
  raw
  body)

(defun orgsite--keyword (keywords name)
  "Return the first value for NAME in KEYWORDS, or nil.
KEYWORDS is the alist returned by `org-collect-keywords'."
  (let ((pair (assoc name keywords)))
    (when pair (car (cdr pair)))))

(defun orgsite--parse-tags (filetags)
  "Parse an Org FILETAGS string like \":a:b:c:\" into (\"a\" \"b\" \"c\").
Returns nil if FILETAGS is nil or empty."
  (when (and filetags (not (string-empty-p filetags)))
    (seq-filter (lambda (s) (not (string-empty-p s)))
                (split-string filetags ":" t))))

(defun orgsite--parse-layout (layout)
  "Convert a LAYOUT keyword string to a symbol.
Falls back to `page' when LAYOUT is nil or unrecognised, so the
build tolerates missing `#+LAYOUT' keywords."
  (pcase layout
    ("home" 'home)
    ("post" 'post)
    ("page" 'page)
    (_ 'page)))

(defun orgsite--slug-for (source-path)
  "Return the slug for SOURCE-PATH, relative to the content root.
A source file `content/blog/foo.org' becomes slug `blog/foo'.
Windows backslashes are normalised to forward slashes.

Two Hugo-style conventions collapse to their parent slug:
  `content/blog/_index.org'       ->  `blog'   (section landing)
  `content/blog/foo/index.org'    ->  `blog/foo' (page bundle)

The bare `content/index.org' at the root stays `index' so the
home page keeps its top-level URL."
  (let* ((rel (file-relative-name source-path orgsite-content-dir))
         (no-ext (file-name-sans-extension rel))
         (slashed (replace-regexp-in-string "\\\\" "/" no-ext)))
    (cond
     ((string= slashed "_index") "index")
     ((string= slashed "index") "index")
     ((string-suffix-p "/_index" slashed)
      (substring slashed 0 (- (length slashed) (length "/_index"))))
     ((string-suffix-p "/index" slashed)
      (substring slashed 0 (- (length slashed) (length "/index"))))
     (t slashed))))

(defun orgsite--output-for (slug)
  "Return the absolute output path for SLUG.
Everything becomes `<slug>/index.html' except the root `index',
which stays at the top of the output dir.  Clean URLs like
`/about/' without server rewrites."
  (expand-file-name
   (if (string= slug "index")
       "index.html"
     (concat slug "/index.html"))
   orgsite-output-dir))

(defun orgsite-page-load (source-path)
  "Read SOURCE-PATH and return a filled `orgsite-page' struct.
The struct's BODY slot is left nil; the renderer fills it later."
  (with-temp-buffer
    (insert-file-contents source-path)
    (org-mode)
    (let* ((keywords (org-collect-keywords
                      '("TITLE" "DESCRIPTION" "KICKER"
                        "DATE" "AUTHOR" "FILETAGS" "LAYOUT"
                        "STATUS")))
           (slug (orgsite--slug-for source-path)))
      (make-orgsite-page
       :slug slug
       :source-path source-path
       :output-path (orgsite--output-for slug)
       :title (or (orgsite--keyword keywords "TITLE") slug)
       :description (or (orgsite--keyword keywords "DESCRIPTION")
                        orgsite-site-description)
       :kicker (orgsite--keyword keywords "KICKER")
       :date (orgsite--keyword keywords "DATE")
       :author (or (orgsite--keyword keywords "AUTHOR")
                   orgsite-site-author)
       :tags (orgsite--parse-tags
              (orgsite--keyword keywords "FILETAGS"))
       :layout (orgsite--parse-layout
                (orgsite--keyword keywords "LAYOUT"))
       :status (orgsite--keyword keywords "STATUS")))))

(defun orgsite-page-url (page)
  "Return the site-root-relative URL for PAGE.
Mirrors `orgsite--output-for': every page is served as a
directory with a trailing slash, except the root."
  (let ((slug (orgsite-page-slug page)))
    (if (string= slug "index")
        "/"
      (concat "/" slug "/"))))

(defun orgsite-page-is-post-p (page)
  "Return t when PAGE is a blog post.
Posts are identified by LAYOUT, not by path, so the blog index
page (which lives under `blog/') is correctly excluded."
  (eq (orgsite-page-layout page) 'post))


;;;; ============================================================ Render

;; Thin wrapper around `ox-html' that turns a page's source Org file
;; into body HTML (no <html> or <head>).  Export knobs are set as
;; dynamic lets around `org-export-as' so we do not mutate the user's
;; global export settings.  If you want to change how headings, code
;; blocks, or links are rendered, do it here --- not in the templates.

(defun orgsite--export-body (source-path)
  "Export SOURCE-PATH to a body-only HTML string."
  (let ((org-export-with-toc nil)
        (org-export-with-section-numbers nil)
        (org-export-with-author nil)
        (org-export-with-date nil)
        (org-export-with-title nil)
        (org-export-with-broken-links 'mark)
        (org-html-htmlize-output-type 'css)
        (org-html-doctype "html5")
        (org-html-html5-fancy t)
        (org-html-postamble nil)
        (org-html-preamble nil))
    (with-temp-buffer
      (insert-file-contents source-path)
      (org-mode)
      ;; BODY-ONLY=t skips the <html>/<head>/<body> wrappers; the
      ;; template module supplies those.
      (org-export-as 'html nil nil t))))

(defun orgsite-render-page (page)
  "Return PAGE with its BODY slot filled.
If PAGE already has a BODY (e.g. the blog index was generated in
memory with pre-built HTML), it is returned unchanged."
  (if (orgsite-page-body page)
      page
    (setf (orgsite-page-body page)
          (orgsite--export-body (orgsite-page-source-path page)))
    page))


;;;; ======================================================= TemplateEngine

;; Tiny Razor-inspired template engine.  Templates are plain HTML
;; files with two kinds of tags:
;;
;;   @(SEXP)   -- evaluate SEXP, insert the stringified result.
;;                Nil becomes "".  SEXP may be any balanced elisp
;;                expression; nested parens are handled by the
;;                built-in reader via `read'.
;;   @@        -- a literal `@' in the output.
;;
;; Evaluation happens with an environment alist (symbol -> value),
;; which `eval' binds lexically.  Convention: pass PAGE as the sole
;; binding so templates read as `@(orgsite-page-title page)'.
;; Partial templates compose by calling `orgsite-tmpl-render-file'
;; from inside an `@(...)' expression.

(defun orgsite-tmpl--stringify (v)
  "Coerce V to a string for template insertion.
Nil becomes an empty string so missing data does not print as
\"nil\".  Strings pass through; everything else is formatted
with `%s'."
  (cond ((null v) "")
        ((stringp v) v)
        (t (format "%s" v))))

(defun orgsite-tmpl-render (template env)
  "Expand `@(SEXP)' and `@@' tags in TEMPLATE string.
ENV is an alist of \(SYMBOL . VALUE) bindings passed to `eval'
for lexical scope inside each sexp.  Returns the rendered
string."
  (with-temp-buffer
    (insert template)
    (goto-char (point-min))
    (while (re-search-forward "@" nil t)
      (cond
       ;; "@@" -> literal "@": drop the second '@' and leave the
       ;; first one in place.
       ((eq (char-after) ?@)
        (delete-char 1))
       ;; "@(" -> read + eval the sexp, replace with its value.
       ((eq (char-after) ?\()
        (let* ((at-pos (1- (point)))
               (sexp (read (current-buffer)))
               (value (eval sexp env)))
          (delete-region at-pos (point))
          (insert (orgsite-tmpl--stringify value))))
       ;; Any other character after '@' -- leave it untouched.
       (t nil)))
    (buffer-string)))

(defun orgsite--find-template (name)
  "Return the absolute path of template NAME.
Searches `orgsite-templates-dir' first so users can override any
file, then falls back to `orgsite--package-templates-dir'.
Signals an error when the template cannot be found in either."
  (let ((user (expand-file-name name orgsite-templates-dir))
        (default (expand-file-name name orgsite--package-templates-dir)))
    (cond
     ((file-readable-p user) user)
     ((file-readable-p default) default)
     (t (error "orgsite: template not found: %s" name)))))

(defun orgsite-tmpl-render-file (name env)
  "Render template file NAME with ENV.
Thin wrapper that reads the resolved template file and hands it
to `orgsite-tmpl-render'.  Prefer `orgsite-partial' from inside
a template --- the env plumbing is noisier."
  (orgsite-tmpl-render
   (with-temp-buffer
     (insert-file-contents (orgsite--find-template name))
     (buffer-string))
   env))

(defun orgsite-partial (name page)
  "Render partial template NAME with PAGE bound in its environment.
Convenience wrapper so templates can write
`@(orgsite-partial \"sidebar.html\" page)' instead of
reconstructing the full env alist."
  (orgsite-tmpl-render-file name `((page . ,page))))


;;;; ======================================================== TemplateAPI

;; Thin public helpers that templates and user code can call.  No
;; assumptions about site structure are baked in here --- these are
;; the primitives (escape, head, sort, filter) that every site needs
;; regardless of layout.

(defun orgsite-escape (s)
  "HTML-escape S for attribute values and text content.
Covers the five XSS-relevant characters: <, >, &, \", '.
Nil becomes an empty string."
  (if (null s)
      ""
    (replace-regexp-in-string
     "'" "&#39;"
     (replace-regexp-in-string
      "\"" "&quot;"
      (replace-regexp-in-string
       ">" "&gt;"
       (replace-regexp-in-string
        "<" "&lt;"
        (replace-regexp-in-string "&" "&amp;" s)))))))

;; Internal alias kept for templates that already use the dashed name.
(defalias 'orgsite--escape #'orgsite-escape)

(defun orgsite--stylesheet-links ()
  "Return <link> tags for every URL in `orgsite-extra-stylesheets'."
  (mapconcat (lambda (href)
               (format "    <link rel=\"stylesheet\" href=\"%s\">"
                       (orgsite-escape href)))
             orgsite-extra-stylesheets
             "\n"))

(defun orgsite-head (page)
  "Return a complete <head> element for PAGE.
Includes charset, viewport, title (`page-title — site-title'),
meta description, and every entry in `orgsite-extra-stylesheets'.
Call from a template with `@(orgsite-head page)'; override by
writing the <head> block directly in `layout.html'."
  (let ((title (orgsite-escape
                (format "%s — %s"
                        (orgsite-page-title page)
                        orgsite-site-title)))
        (desc (orgsite-escape (orgsite-page-description page))))
    (format "  <head>
    <meta charset=\"utf-8\">
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
    <title>%s</title>
    <meta name=\"description\" content=\"%s\">
%s
  </head>"
            title desc (orgsite--stylesheet-links))))

(defalias 'orgsite--head #'orgsite-head)

(defun orgsite-sort-by-date (pages &optional ascending)
  "Return PAGES sorted by DATE descending (newest first).
If ASCENDING is non-nil, sort oldest-first.  Pages without a
date sink to the bottom in both directions.  String comparison
works because dates are stored as ISO `YYYY-MM-DD'."
  (sort (copy-sequence pages)
        (lambda (a b)
          (let ((da (orgsite-page-date a))
                (db (orgsite-page-date b)))
            (cond ((and da db) (if ascending
                                   (string< da db)
                                 (string> da db)))
                  (da t)
                  (db nil)
                  (t nil))))))

(defun orgsite-filter-by-layout (pages layout)
  "Return the subset of PAGES whose LAYOUT slot equals LAYOUT symbol."
  (seq-filter (lambda (p) (eq (orgsite-page-layout p) layout)) pages))

(defun orgsite-filter-by-tag (pages tag)
  "Return the subset of PAGES whose TAGS list contains TAG string."
  (seq-filter (lambda (p) (member tag (orgsite-page-tags p))) pages))

(defun orgsite-page-permalink (page)
  "Return the fully-qualified canonical URL of PAGE.
Concatenates `orgsite-site-url' with the page's root-relative
URL.  Useful for RSS <link>, <guid>, OpenGraph `og:url', and
anywhere an absolute URL is required."
  (concat orgsite-site-url (orgsite-page-url page)))

(cl-defun orgsite-posts (&key (pages orgsite--all-pages)
                              (layout 'post)
                              section
                              tag
                              include-drafts
                              (sort t)
                              limit)
  "Return a list of post pages, filtered and sorted for listings.

Keyword arguments:
  :PAGES          source list, defaults to the dynamic `pages'.
  :LAYOUT         layout symbol to match; default `post', nil = any.
  :SECTION        restrict to a top-level section (e.g. \"blog\").
  :TAG            restrict to pages carrying this tag string.
  :INCLUDE-DRAFTS keep pages with `#+STATUS: draft'; default off.
  :SORT           t to sort newest-first, `ascending' for oldest-first,
                  nil to leave in load order.
  :LIMIT          integer to cap the list length, or nil for all.

The single call covers the common patterns (`latest N posts',
`every post in section', `posts tagged X')."
  (let* ((xs pages)
         (xs (if layout (orgsite-filter-by-layout xs layout) xs))
         (xs (if section
                 (seq-filter (lambda (p)
                               (equal (orgsite-page-section p) section))
                             xs)
               xs))
         (xs (if tag (orgsite-filter-by-tag xs tag) xs))
         (xs (if include-drafts xs (orgsite-reject-by-status xs "draft")))
         (xs (pcase sort
               ('ascending (orgsite-sort-by-date xs t))
               ('nil xs)
               (_ (orgsite-sort-by-date xs)))))
    (if limit (seq-take xs limit) xs)))

(defun orgsite-filter-by-status (pages status)
  "Return the subset of PAGES whose STATUS slot equals STATUS string."
  (seq-filter (lambda (p) (equal (orgsite-page-status p) status)) pages))

(defun orgsite-reject-by-status (pages status)
  "Return the subset of PAGES whose STATUS slot is NOT STATUS string.
Handy for excluding drafts from listings: pass \"draft\" and the
remaining pages are everything else."
  (seq-remove (lambda (p) (equal (orgsite-page-status p) status)) pages))

(defun orgsite--parse-iso-date (iso)
  "Return an Emacs time value for ISO `YYYY-MM-DD' string, or nil.
Uses `parse-time-string', so malformed input fails safely rather
than silently returning 1970-01-01.  Timezone is pinned to UTC
to keep dates stable across builders in different zones."
  (when (and iso (not (string-empty-p iso)))
    (let ((parsed (parse-time-string iso)))
      ;; parse-time-string fills missing fields with nil; require
      ;; at least year + month + day to accept the date.
      (when (and (nth 3 parsed) (nth 4 parsed) (nth 5 parsed))
        (encode-time 0 0 0
                     (nth 3 parsed) (nth 4 parsed) (nth 5 parsed)
                     nil 0)))))

(defun orgsite-format-date (iso)
  "Format an ISO date string with `orgsite-date-format'.
ISO is a string like `2025-06-23' as parsed from `#+DATE:'.
Returns an empty string when ISO is nil, empty, or unparseable."
  (if-let* ((time (orgsite--parse-iso-date iso)))
      (format-time-string orgsite-date-format time)
    ""))

(defvar orgsite--all-pages nil
  "Dynamic binding of every page in the current build.
Bound by `orgsite-build' around the synthetic + render + write
phases, so hook functions and templates all see the same `pages'
list.  Starts out with just the loaded pages during the
synthetic-page generation step, then widens to include synthetic
pages before rendering --- this way a synthetic generator that
renders a partial of its own still sees the loaded pages, while
regular templates see everything.")

(defun orgsite-page-section (page)
  "Return the top-level section of PAGE as a string, or nil.
The section is the first path segment of the slug.  A root page
like `about' has no section (returns nil).  `blog/foo' has
section `blog'."
  (let* ((slug (orgsite-page-slug page))
         (parts (split-string slug "/")))
    (when (> (length parts) 1)
      (car parts))))

(defun orgsite-page-kind (page)
  "Return the kind of PAGE: `list' or `single'.
Any page whose source file is named `_index.org' is treated as
a list page (section landing).  Everything else is a single
page.  Synthetic pages (no source) default to single --- the
code that builds them can set `#+LAYOUT:' explicitly."
  (let ((src (orgsite-page-source-path page)))
    (if (and src (string= (file-name-base src) "_index"))
        'list
      'single)))

(defun orgsite--template-candidates (page)
  "Return the ordered list of template names to try for PAGE.
Mirrors Hugo's lookup:
  1. `<layout>.html'                  (if `#+LAYOUT:' set)
  2. `<section>/<layout>.html'        (section-specific layout)
  3. `<section>/<kind>.html'          (section-specific by kind)
  4. `<kind>.html'                    (global by kind)
  5. `layout.html'                    (universal fallback)"
  (let* ((layout (orgsite-page-layout page))   ; symbol, always set
         (layout-name (and layout (symbol-name layout)))
         (section (orgsite-page-section page))
         (kind (symbol-name (orgsite-page-kind page)))
         (candidates '()))
    (when (and layout-name section)
      (push (format "%s/%s.html" section layout-name) candidates))
    (when layout-name
      (push (format "%s.html" layout-name) candidates))
    (when section
      (push (format "%s/%s.html" section kind) candidates))
    (push (format "%s.html" kind) candidates)
    (push "layout.html" candidates)
    (nreverse candidates)))

(defun orgsite--resolve-template (page)
  "Return the first template from the candidate list that exists."
  (let ((candidates (orgsite--template-candidates page)))
    (or (seq-find (lambda (name)
                    (let ((user (expand-file-name name orgsite-templates-dir))
                          (pkg  (expand-file-name name orgsite--package-templates-dir)))
                      (or (file-readable-p user) (file-readable-p pkg))))
                  candidates)
        ;; Guaranteed to exist because `layout.html' ships in the
        ;; package defaults, but signal if someone deleted it.
        (error "orgsite: no template found for page `%s'; tried %s"
               (orgsite-page-slug page) candidates))))

(defun orgsite-template-wrap (page)
  "Return the full HTML document for PAGE.
Resolves the template via `orgsite--resolve-template' (section +
kind + explicit layout).  Binds `page' and `pages' in the
template environment so listings can filter or sort the full
page list inline."
  (orgsite-tmpl-render-file
   (orgsite--resolve-template page)
   `((page . ,page)
     (pages . ,orgsite--all-pages))))


;;;; =================================================== Sitemap + RSS

;; Optional, auto-registered generators for `/sitemap.xml' and an RSS
;; 2.0 feed.  Both are controlled by `orgsite-generate-sitemap' and
;; `orgsite-generate-rss' and inserted into the pipeline by
;; `orgsite--auto-synthetic-pages' so users don't have to add a hook.
;; Users keep full control by (a) setting the vars to nil, (b)
;; overriding the related vars (output path, filter, limit), or
;; (c) adding their own hook function.

(defun orgsite--xml-escape (s)
  "Escape S for inclusion as XML text content."
  (if (null s)
      ""
    (replace-regexp-in-string
     "&" "&amp;"
     (replace-regexp-in-string
      "<" "&lt;"
      (replace-regexp-in-string ">" "&gt;" s)))))

(defun orgsite--rfc822-date (iso)
  "Convert an ISO `YYYY-MM-DD' string to an RFC 822 date for RSS.
Returns nil on malformed input so the caller can omit the
element rather than emit a broken timestamp."
  (when-let* ((time (orgsite--parse-iso-date iso)))
    (format-time-string "%a, %d %b %Y 00:00:00 +0000" time)))

(defun orgsite--sitemap-entry (page)
  "Return a single <url> element for PAGE."
  (format "  <url>\n    <loc>%s</loc>%s\n  </url>"
          (orgsite-page-permalink page)
          (if (orgsite-page-date page)
              (format "\n    <lastmod>%s</lastmod>" (orgsite-page-date page))
            "")))

(defun orgsite-sitemap-page (pages)
  "Return an `orgsite-page' representing /sitemap.xml for PAGES.
Includes every page except drafts.  Synthetic raw pages (feeds,
the sitemap itself) are excluded."
  (let* ((live (seq-remove (lambda (p)
                             (or (orgsite-page-raw p)
                                 (equal (orgsite-page-status p) "draft")))
                           pages))
         (entries (mapconcat #'orgsite--sitemap-entry live "\n"))
         (xml (concat "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                      "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
                      entries
                      "\n</urlset>\n")))
    (make-orgsite-page
     :slug "sitemap"
     :output-path (expand-file-name orgsite-sitemap-output orgsite-output-dir)
     :raw t
     :body xml)))

(defun orgsite--rss-item (post)
  "Return a single <item> element for POST.
Omits <pubDate> when the post has no date, which keeps the feed
valid for strict validators."
  (let ((url (orgsite-page-permalink post)))
    (format "    <item>
      <title>%s</title>
      <link>%s</link>
      <guid isPermaLink=\"true\">%s</guid>%s
      <description>%s</description>
    </item>"
            (orgsite--xml-escape (orgsite-page-title post))
            url
            url
            (if-let* ((rfc (orgsite--rfc822-date (orgsite-page-date post))))
                (format "\n      <pubDate>%s</pubDate>" rfc)
              "")
            (orgsite--xml-escape (orgsite-page-description post)))))

(defun orgsite-rss-page (pages)
  "Return an `orgsite-page' representing the RSS feed for PAGES.
Honours `orgsite-rss-filter', `orgsite-rss-limit', and
`orgsite-rss-output'."
  (let* ((candidates (seq-filter orgsite-rss-filter pages))
         (sorted (orgsite-sort-by-date
                  (seq-remove (lambda (p)
                                (equal (orgsite-page-status p) "draft"))
                              candidates)))
         (posts (if orgsite-rss-limit
                    (seq-take sorted orgsite-rss-limit)
                  sorted))
         (items (mapconcat #'orgsite--rss-item posts "\n"))
         (feed-link (concat orgsite-site-url
                            "/" (or (file-name-directory orgsite-rss-output)
                                    "")))
         (xml (concat "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                      "<rss version=\"2.0\">\n"
                      "  <channel>\n"
                      (format "    <title>%s</title>\n"
                              (orgsite--xml-escape orgsite-site-title))
                      (format "    <link>%s</link>\n" feed-link)
                      (format "    <description>%s</description>\n"
                              (orgsite--xml-escape orgsite-site-description))
                      "    <language>en</language>\n"
                      items (if (length> items 0) "\n" "")
                      "  </channel>\n"
                      "</rss>\n")))
    (make-orgsite-page
     :slug (file-name-sans-extension orgsite-rss-output)
     :output-path (expand-file-name orgsite-rss-output orgsite-output-dir)
     :raw t
     :body xml)))

(defun orgsite--auto-synthetic-pages (pages)
  "Return auto-registered synthetic pages controlled by vars.
Sitemap and RSS are each toggleable via
`orgsite-generate-sitemap' and `orgsite-generate-rss'."
  (let (result)
    (when orgsite-generate-sitemap
      (push (orgsite-sitemap-page pages) result))
    (when orgsite-generate-rss
      (push (orgsite-rss-page pages) result))
    (nreverse result)))


;;;; ============================================================ Format

;; Optional pass applied to each page's full HTML just before it is
;; written to disk.  Driven by `orgsite-output-format'.

(defun orgsite--format-pretty (html)
  "Return HTML re-indented by `sgml-pretty-print'.
Quirk: breaks inline tags (<a>, <title>) onto new lines."
  (with-temp-buffer
    (insert html)
    (sgml-mode)
    (sgml-pretty-print (point-min) (point-max))
    (buffer-string)))

(defun orgsite--format-libxml (html)
  "Return HTML round-tripped through libxml + `dom-print'.
Requires Emacs built with libxml2 support (true for mainstream
distros, macOS Homebrew, and Windows GNU builds).

We call `dom-print' with pretty-print DISABLED on purpose.  When
pretty-print is on, dom-print indents every child element,
including `<code>' inside `<pre>' --- and `<pre>' preserves
whitespace, so that indent renders as a visible leading gap in
every code block.  Shipping a single-line document is both
smaller and avoids a whole class of markup bugs; browsers and
view-source users don't care."
  (unless (fboundp 'libxml-parse-html-region)
    (error "orgsite: libxml2 support required for `libxml' format"))
  (with-temp-buffer
    (insert html)
    (let ((dom (libxml-parse-html-region (point-min) (point-max))))
      (erase-buffer)
      (insert "<!DOCTYPE html>\n")
      (dom-print dom nil)
      (buffer-string))))

(defun orgsite--format-html (html)
  "Dispatch HTML through the formatter chosen by `orgsite-output-format'.
Falls back to pass-through for unknown values so a typo in
configuration never drops output on the floor."
  (pcase orgsite-output-format
    ('pretty (orgsite--format-pretty html))
    ('libxml (orgsite--format-libxml html))
    (_ html)))


;;;; =========================================================== Pipeline

;; The build pipeline: discover -> load -> generate -> render ->
;; format -> write -> assets.  Each stage is one function that
;; returns data to the next.  No hidden globals, no mutation at a
;; distance.

(defun orgsite--discover-sources ()
  "Return absolute paths of every `.org' file under the content dir."
  (directory-files-recursively orgsite-content-dir "\\.org\\'"))

(defun orgsite--load-pages (sources)
  "Load each path in SOURCES into an `orgsite-page' struct."
  (mapcar #'orgsite-page-load sources))

(defun orgsite--generate-synthetic (pages)
  "Return PAGES with every synthetic page appended.
Three sources:

  1. User hook functions on `orgsite-synthetic-pages-functions'
     (listings, archives, category pages, custom feeds...).
  2. Auto-registered sitemap + RSS from `orgsite--auto-synthetic-pages'
     (toggled by `orgsite-generate-sitemap' / `-generate-rss').

Auto-registered pages see the full post list, so they happen AFTER
user hooks --- that way user-produced synthetic pages also get
indexed in the sitemap."
  (let* ((with-user-extras
          (append pages
                  (mapcan (lambda (fn) (funcall fn pages))
                          orgsite-synthetic-pages-functions)))
         (auto (orgsite--auto-synthetic-pages with-user-extras)))
    (append with-user-extras auto)))

(defun orgsite--render-pages (pages)
  "Fill the BODY slot of each page in PAGES."
  (mapc #'orgsite-render-page pages))

(defun orgsite--write-page (page)
  "Write PAGE to disk.
Regular pages are wrapped in their layout and run through the
formatter.  Pages with the RAW slot set are written verbatim ---
no layout, no HTML formatter --- which is what XML artefacts like
sitemaps and feeds need."
  (let* ((out (orgsite-page-output-path page))
         (body (if (orgsite-page-raw page)
                   (or (orgsite-page-body page) "")
                 (orgsite--format-html (orgsite-template-wrap page))))
         ;; Force UTF-8 so XML artefacts with chars outside the
         ;; default system coding don't trigger an interactive prompt
         ;; in batch mode.
         (coding-system-for-write 'utf-8-unix))
    (make-directory (file-name-directory out) t)
    (with-temp-file out
      (insert body))
    (message "  wrote %s" (file-relative-name out orgsite-output-dir))))

(defun orgsite--write-pages (pages)
  "Write every page in PAGES to disk.
`orgsite--all-pages' is bound by `orgsite-build' around the whole
pipeline, so templates see the full page list as `pages'."
  (mapc #'orgsite--write-page pages))

(defun orgsite--copy-assets ()
  "Copy the assets directory into the output as `dist/assets/'.
Skips silently when the assets directory does not exist."
  (when (file-directory-p orgsite-assets-dir)
    (let ((dest (expand-file-name "assets" orgsite-output-dir)))
      (copy-directory orgsite-assets-dir dest nil t t)
      (message "  copied assets -> %s"
               (file-relative-name dest orgsite-output-dir)))))

(defun orgsite--copy-public ()
  "Copy every entry in the public dir to the ROOT of the output.
Files like `cv.pdf' end up at `dist/cv.pdf', served from `/cv.pdf'."
  (when (file-directory-p orgsite-public-dir)
    (dolist (entry (directory-files orgsite-public-dir t "^[^.]"))
      (let ((dest (expand-file-name (file-name-nondirectory entry)
                                    orgsite-output-dir)))
        (if (file-directory-p entry)
            (copy-directory entry dest nil t t)
          (copy-file entry dest t))
        (message "  copied public/%s"
                 (file-name-nondirectory entry))))))

(defun orgsite--copy-content-assets ()
  "Copy co-located, non-`.org' files from content/ to dist/.
Implements Hugo-style page bundles: anything next to an `.org'
source (an image, PDF, dataset, etc.) is mirrored into the
output at the same relative path.  So a post written as
`content/blog/foo/index.org' + `content/blog/foo/diagram.svg'
ends up as `dist/blog/foo/index.html' + `dist/blog/foo/diagram.svg',
and the org link `[[diagram.svg]]' just works."
  (when (file-directory-p orgsite-content-dir)
    (dolist (file (directory-files-recursively orgsite-content-dir ".*"))
      (unless (string-suffix-p ".org" file)
        (let* ((rel (file-relative-name file orgsite-content-dir))
               (rel/ (replace-regexp-in-string "\\\\" "/" rel))
               (dest (expand-file-name rel/ orgsite-output-dir)))
          (make-directory (file-name-directory dest) t)
          (copy-file file dest t)
          (message "  copied content/%s" rel/))))))


;;;; ============================================================= Serve

;; Minimal HTTP/1.0 dev server for the output directory.  Not a
;; production server: no concurrency, no keep-alive, no streaming,
;; no HTTPS.  Enough to click around `dist/' locally so absolute
;; links like `/blog/' resolve correctly.
;;
;; Lifecycle:
;;   `orgsite-serve'          -- start (idempotent: reuses running server)
;;   `orgsite-serve-stop'     -- kill the process
;;   `orgsite-serve-restart'  -- stop + start
;;   `orgsite-serve-status'   -- message current state
;;
;; Request log goes to buffer `*orgsite-serve*'.  `M-x list-processes'
;; also shows the server.

(defvar orgsite--server-process nil
  "The currently running dev server, or nil.")

(defvar orgsite--server-log-buffer "*orgsite-serve*"
  "Name of the buffer that receives request logs.")

(defconst orgsite--mime-types
  '(("html" . "text/html; charset=utf-8")
    ("htm"  . "text/html; charset=utf-8")
    ("css"  . "text/css; charset=utf-8")
    ("js"   . "application/javascript; charset=utf-8")
    ("mjs"  . "application/javascript; charset=utf-8")
    ("json" . "application/json; charset=utf-8")
    ("svg"  . "image/svg+xml")
    ("png"  . "image/png")
    ("jpg"  . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("gif"  . "image/gif")
    ("webp" . "image/webp")
    ("ico"  . "image/x-icon")
    ("pdf"  . "application/pdf")
    ("woff" . "font/woff")
    ("woff2". "font/woff2")
    ("ttf"  . "font/ttf")
    ("txt"  . "text/plain; charset=utf-8")
    ("xml"  . "application/xml; charset=utf-8"))
  "Extension-to-Content-Type map used by the dev server.")

(defun orgsite--mime-for (path)
  "Return the Content-Type for PATH, or a safe default."
  (let* ((ext (downcase (or (file-name-extension path) "")))
         (hit (assoc ext orgsite--mime-types)))
    (if hit (cdr hit) "application/octet-stream")))

(defun orgsite--serve-log (format-string &rest args)
  "Append a formatted line to the server log buffer."
  (let ((buf (get-buffer-create orgsite--server-log-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format format-string args)
              "\n"))))

(defun orgsite--serve-resolve (url-path)
  "Resolve URL-PATH to an absolute file inside `orgsite-output-dir'.
Returns nil when the resolved path escapes the output dir
(path-traversal defence) or does not exist.  Appends `index.html'
when the target is a directory."
  (let* ((clean (car (split-string url-path "[?#]")))
         (decoded (url-unhex-string clean))
         (rel (string-remove-prefix "/" decoded))
         (full (expand-file-name rel orgsite-output-dir)))
    (cond
     ;; Reject anything that escapes the output dir (`../etc/passwd').
     ((not (string-prefix-p (file-name-as-directory
                             (expand-file-name orgsite-output-dir))
                            (file-name-as-directory full)))
      nil)
     ((file-directory-p full)
      (let ((idx (expand-file-name "index.html" full)))
        (when (file-regular-p idx) idx)))
     ((file-regular-p full) full)
     (t nil))))

(defun orgsite--serve-read-binary (path)
  "Return the raw bytes of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun orgsite--serve-send (proc status headers body)
  "Write an HTTP/1.0 response to PROC.
STATUS is a string like \"200 OK\".  HEADERS is an alist of
\(NAME . VALUE) pairs.  BODY is a unibyte string."
  (let ((head (concat
               (format "HTTP/1.0 %s\r\n" status)
               (mapconcat (lambda (h)
                            (format "%s: %s\r\n" (car h) (cdr h)))
                          headers
                          "")
               (format "Content-Length: %d\r\n" (length body))
               "Connection: close\r\n\r\n")))
    ;; Headers first (multibyte string ok), then raw body.  We send
    ;; the body with a unibyte write by concatenating a unibyte head.
    (process-send-string proc head)
    (process-send-string proc body)))

(defun orgsite--serve-404 (proc url-path)
  "Send a 404 response and log it."
  (orgsite--serve-log "404 %s" url-path)
  (orgsite--serve-send
   proc "404 Not Found"
   '(("Content-Type" . "text/html; charset=utf-8"))
   (format "<!doctype html><title>404</title><h1>404 Not Found</h1><p>%s</p>"
           url-path)))

(defun orgsite--serve-file (proc url-path file)
  "Send FILE in response to URL-PATH on PROC."
  (orgsite--serve-log "200 %s" url-path)
  (let ((body (orgsite--serve-read-binary file))
        (mime (orgsite--mime-for file)))
    (orgsite--serve-send proc "200 OK"
                         (list (cons "Content-Type" mime))
                         body)))

(defun orgsite--serve-parse-path (request)
  "Return the URL path from the first line of REQUEST, or nil."
  (when (string-match "^GET \\([^ \r\n]+\\) HTTP/" request)
    (match-string 1 request)))

(defun orgsite--serve-filter (proc chunk)
  "Accumulate CHUNK on PROC and respond once headers end."
  (let ((buf (or (process-get proc 'orgsite-buf) "")))
    (setq buf (concat buf chunk))
    (if (not (string-match "\r\n\r\n" buf))
        ;; Request still incoming --- stash and wait.
        (process-put proc 'orgsite-buf buf)
      (let ((url-path (orgsite--serve-parse-path buf)))
        (if (null url-path)
            (orgsite--serve-send proc "400 Bad Request" nil "")
          (let ((file (orgsite--serve-resolve url-path)))
            (if file
                (orgsite--serve-file proc url-path file)
              (orgsite--serve-404 proc url-path))))
        (ignore-errors (delete-process proc))))))

;;;###autoload
(defun orgsite-serve ()
  "Start the dev server on `orgsite-serve-host':`orgsite-serve-port'.
Idempotent: if a server is already running, this just prints its
address."
  (interactive)
  (orgsite--resolve-paths)
  (if (and orgsite--server-process
           (process-live-p orgsite--server-process))
      (message "orgsite: already serving at http://%s:%d/"
               orgsite-serve-host orgsite-serve-port)
    (get-buffer-create orgsite--server-log-buffer)
    (setq orgsite--server-process
          (make-network-process
           :name "orgsite-serve"
           :server t
           :host orgsite-serve-host
           :service orgsite-serve-port
           :family 'ipv4
           :coding '(binary . binary)
           :filter #'orgsite--serve-filter
           :log (lambda (_server _client _msg) nil)))
    (message "orgsite: serving %s at http://%s:%d/  (M-x orgsite-serve-stop)"
             orgsite-output-dir orgsite-serve-host orgsite-serve-port)))

;;;###autoload
(defun orgsite-serve-stop ()
  "Stop the dev server, if any."
  (interactive)
  (if (and orgsite--server-process
           (process-live-p orgsite--server-process))
      (progn
        (delete-process orgsite--server-process)
        (setq orgsite--server-process nil)
        (message "orgsite: server stopped"))
    (setq orgsite--server-process nil)
    (message "orgsite: no server running")))

;;;###autoload
(defun orgsite-serve-restart ()
  "Stop and start the dev server."
  (interactive)
  (orgsite-serve-stop)
  (orgsite-serve))

;;;###autoload
(defun orgsite-serve-status ()
  "Message whether the dev server is running and where."
  (interactive)
  (if (and orgsite--server-process
           (process-live-p orgsite--server-process))
      (message "orgsite: running at http://%s:%d/"
               orgsite-serve-host orgsite-serve-port)
    (message "orgsite: not running")))


;;;; ============================================================= Watch

;; Auto-rebuild on content / template / asset changes.  Uses the
;; built-in `filenotify' library so there's no extra dependency.
;; Rebuilds are debounced --- a burst of saves (e.g. an editor doing
;; a swap-file dance) triggers a single rebuild shortly after the
;; last event rather than N rebuilds in flight.

(require 'filenotify)

(defvar orgsite-watch-debounce-seconds 0.5
  "Seconds to wait after the last change before rebuilding.
Smooths over editors that fire many events per save.")

(defvar orgsite--watch-descriptors nil
  "List of active file-notify descriptors.")

(defvar orgsite--watch-timer nil
  "Pending rebuild timer, or nil.")

(defun orgsite--watch-rebuild ()
  "Run a build + notify.  Called from the debounce timer."
  (setq orgsite--watch-timer nil)
  (condition-case err
      (progn
        (orgsite-build)
        (message "orgsite-watch: rebuilt at %s"
                 (format-time-string "%H:%M:%S")))
    (error
     (message "orgsite-watch: build failed: %s"
              (error-message-string err)))))

(defun orgsite--watch-callback (_event)
  "File-notify handler: debounce, then rebuild."
  (when orgsite--watch-timer
    (cancel-timer orgsite--watch-timer))
  (setq orgsite--watch-timer
        (run-at-time orgsite-watch-debounce-seconds nil
                     #'orgsite--watch-rebuild)))

(defun orgsite--watch-add (dir)
  "Recursively watch DIR for content / write events."
  (when (file-directory-p dir)
    (push (file-notify-add-watch
           dir '(change) #'orgsite--watch-callback)
          orgsite--watch-descriptors)
    ;; file-notify-add-watch is NOT recursive on every backend, so
    ;; register every subdirectory explicitly.
    (dolist (sub (directory-files dir t "^[^.]"))
      (when (file-directory-p sub)
        (orgsite--watch-add sub)))))

;;;###autoload
(defun orgsite-watch ()
  "Start watching content / templates / assets and rebuild on change.
Idempotent: if already watching, prints the current status."
  (interactive)
  (orgsite--resolve-paths)
  (if orgsite--watch-descriptors
      (message "orgsite-watch: already watching (%d descriptors)"
               (length orgsite--watch-descriptors))
    (dolist (dir (list orgsite-content-dir
                       orgsite-templates-dir
                       orgsite-assets-dir
                       orgsite-public-dir))
      (orgsite--watch-add dir))
    (message "orgsite-watch: watching %d dirs; rebuild on save"
             (length orgsite--watch-descriptors))))

;;;###autoload
(defun orgsite-watch-stop ()
  "Stop watching and cancel any pending rebuild."
  (interactive)
  (dolist (desc orgsite--watch-descriptors)
    (ignore-errors (file-notify-rm-watch desc)))
  (setq orgsite--watch-descriptors nil)
  (when orgsite--watch-timer
    (cancel-timer orgsite--watch-timer)
    (setq orgsite--watch-timer nil))
  (message "orgsite-watch: stopped"))


;;;; ============================================================== Main

;;;###autoload
(defun orgsite-build ()
  "Build the entire site into `orgsite-output-dir'.
Runs `orgsite-pre-build-hook' before loading content, and
`orgsite-post-build-hook' after writing is complete.
Idempotent: existing files are overwritten.  Obsolete files are
left behind --- call `orgsite-clean' first if that matters."
  (interactive)
  (orgsite--resolve-paths)
  (run-hooks 'orgsite-pre-build-hook)
  (message "orgsite: building into %s" orgsite-output-dir)
  (make-directory orgsite-output-dir t)
  (let* ((sources (orgsite--discover-sources))
         (loaded (orgsite--load-pages sources))
         ;; Bind the dynamic `pages' list for the whole pipeline.
         ;; Starts with just the loaded pages so hook functions can
         ;; render partials that reference `pages' without surprise.
         (orgsite--all-pages loaded)
         (all (orgsite--generate-synthetic loaded)))
    ;; Widen the binding to include synthetic pages before render +
    ;; write, so regular templates see the complete list.
    (setq orgsite--all-pages all)
    (orgsite--render-pages all)
    (orgsite--write-pages all)
    (orgsite--copy-assets)
    (orgsite--copy-public)
    (orgsite--copy-content-assets)
    (message "orgsite: built %d page(s)" (length all)))
  (run-hooks 'orgsite-post-build-hook))

;;;###autoload
(defun orgsite-clean ()
  "Delete the output directory so the next build starts from scratch.
Removes obsolete files left behind by renames or deletions.
Prompts for confirmation when called interactively."
  (interactive)
  (orgsite--resolve-paths)
  (if (not (file-directory-p orgsite-output-dir))
      (message "orgsite: nothing to clean (%s does not exist)"
               orgsite-output-dir)
    (when (or (not (called-interactively-p 'any))
              (yes-or-no-p (format "orgsite: delete %s? "
                                   orgsite-output-dir)))
      (delete-directory orgsite-output-dir t)
      (message "orgsite: cleaned %s" orgsite-output-dir))))

(provide 'orgsite)
;;; orgsite.el ends here
