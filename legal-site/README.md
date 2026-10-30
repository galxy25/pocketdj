# legal.pocket-dj.com (legal site)

Static pages served at https://legal.pocket-dj.com from the `PDJ_LEGAL_BUCKET` S3 bucket behind
the `PDJ_CF_LEGAL` CloudFront distribution in the **green** account (profile `llc`). A viewer-request
function (`pocketdj-subpath-rewrite`) maps `/privacy` and `/privacy/` to `privacy/index.html`.
Deploy to GREEN only. Brought into the repo 2026-10-29 from the bucket (it was deployed by hand
on 2026-10-12 with no source in git).

| Path | Source |
|---|---|
| `privacy/index.html` | **Generated** from `docs/legal/PRIVACY.md` |
| `delete-account/index.html` | **Generated** from `docs/legal/DELETE-ACCOUNT.md` (Google Play's web account-deletion URL) |
| `terms/`, `dmca/`, `notices/`, `index.html`, `404.html` | Hand-maintained HTML. These are the published versions; `docs/legal/{TERMS,DMCA,NOTICE}.md` are the earlier drafts with `{{PLACEHOLDER}}` tokens and `#TOUPDATE` markers, kept for their review notes. |
| `_template.html` | Page shell for the generated pages (not deployed) |

Build and deploy (all pages are HTML with `Cache-Control: public, max-age=300`):

```bash
node scripts/legal-site-build.mjs        # regenerate privacy + delete-account
scripts/legal-site-deploy.sh --dry-run    # preview
scripts/legal-site-deploy.sh              # build, refuse on placeholders, sync, invalidate
```

Preview locally: `python3 -m http.server 8766 --directory legal-site` (the root-relative links resolve
at http://localhost:8766/privacy/index.html).

Values filled 2026-10-29 that need Levi's legal sign-off: Terms §2.1 minimum age 13, §13.2 liability
cap US$100, §15 Oregon law and Multnomah County courts, §16.2 courts or small claims (no arbitration),
§11.4 one-month deletion; DMCA designated agent "Copyright Agent" with no telephone number (a
§512(c)(2) designation needs a phone number and a Copyright Office registration).
