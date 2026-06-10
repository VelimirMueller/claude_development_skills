# Structured Data

Reference for `set-up-seo`. JSON-LD: which types, where, and the one hard rule.

## Rule: JSON-LD, one script per entity (or one @graph)
**Why:** JSON-LD is the format Google recommends and the only one that keeps markup
separable from the DOM — no microdata attributes threaded through templates.
**How to apply:** `<script type="application/ld+json">` in the page. Site-wide entities
(`Organization`, `WebSite`) once per page via the shared layout; page entities per page.
Several scripts are fine; an `@graph` array in one script is equally valid — pick one
convention per site.

## Rule: schema mirrors visible content — never invents it
**Why:** Markup describing content that isn't on the page is the textbook structured-data
spam pattern and risks a manual action; it also breaks the answer-engine use (the quoted
"answer" wouldn't exist on the page).
**How to apply:** every value in the JSON-LD (headline, dates, prices, questions) must be
findable as visible text on the page. Write the page first, mirror it second.

## Type selection

| Page | Type(s) |
|---|---|
| every public page (via layout) | `Organization` + `WebSite` |
| product / offer landing | `Product` with nested `Offer` (real price, currency, availability) |
| guide / article / ratgeber | `Article` (headline, author as `Person`, `datePublished`, `dateModified`) |
| page with a real FAQ section | `FAQPage` (see the caveat below) |
| pages ≥2 levels deep | `BreadcrumbList` |
| physical / local business | `LocalBusiness` (address, hours) |

## The FAQ caveat (2026 reality)
Google restricted FAQ *rich results* in 2023 to well-known authoritative government and
health sites — for everyone else `FAQPage` markup no longer earns the expanded SERP
listing. It remains valid schema.org, and answer engines still read it. So: mark up real,
visible FAQs for machine readability; do not add FAQ schema chasing a rich result that
won't come. (`HowTo` rich results were deprecated entirely — don't ship `HowTo` markup.)

## Validation
- `https://validator.schema.org` — syntax + vocabulary.
- Google Rich Results Test — eligibility for the types that still have rich results.

## When to deviate
A page with nothing to mark up takes `Organization`/`WebSite` only. Don't force `Product`
onto a lead-gen page with no purchasable offer — wrong type beats no type for spam
signals, in the bad direction.
