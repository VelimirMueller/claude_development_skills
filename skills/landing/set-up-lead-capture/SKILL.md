---
name: set-up-lead-capture
description: Use when adding or hardening a lead, signup, contact, newsletter, or waitlist form on a public page — the form contract (labels, autocomplete, error and success states), a single destination seam (form service / serverless function / own API), layered spam defenses (honeypot, time-trap, escalation to Turnstile), consent at the point of capture, and double opt-in. Framework-agnostic.
---

# Set Up Lead Capture

A landing page exists to convert; this form is the conversion. The skill wires it with
one destination seam, invisible-first spam defenses, and consent that would survive an
audit.

## 1. Gate — is this a public page?

Run the gate from `../_shared/page-types.md`. Authenticated app forms (settings,
checkout, CRUD) are the other catalogue's job: `skills/frontend/set-up-forms`
(schema-first, mutation-wired). This skill owns the *public, anonymous* form.

## 2. Audit current state

```bash
curl -s "$URL" -o /tmp/page.html
grep -oiE "<form[^>]*" /tmp/page.html              # how many forms, where do they post?
grep -ciE "<label" /tmp/page.html                   # labels present?
grep -ciE "autocomplete=" /tmp/page.html
grep -ciE "type=\"checkbox\"[^>]*consent|consent[^>]*checkbox" /tmp/page.html
```

Findings to look for: forms posting directly to a vendor URL scattered per page (no
seam), missing labels, no spam defense, no consent checkbox, success state that dumps
PII into the URL.

## 3. The form contract

```html
<form method="post" action="/api/leads">
  <label for="lead-email">Work email</label>
  <input id="lead-email" name="email" type="email" autocomplete="email"
         required aria-describedby="lead-email-err">
  <p id="lead-email-err" class="field-error" hidden></p>

  <!-- honeypot: invisible to humans, irresistible to bots -->
  <div class="hp" aria-hidden="true">
    <label for="lead-company2">Company</label>
    <input id="lead-company2" name="company2" type="text" tabindex="-1" autocomplete="off">
  </div>
  <!-- time-trap: rendered at page build/serve time -->
  <input type="hidden" name="form_ts" value="{{render_timestamp}}">

  <label class="consent">
    <input type="checkbox" name="consent" required>
    I'd like to receive the newsletter — see the <a href="/privacy">privacy policy</a>.
  </label>

  <button type="submit">Get the guide</button>
  <p role="status" class="form-feedback"></p>
</form>
```

```css
.hp { position: absolute; left: -9999px; }   /* off-screen, not display:none */
```

- Minimal fields — each extra field costs conversions and widens PII. Often email alone.
- Real `<label>`s and `autocomplete` (WCAG 1.3.5 + mobile keyboards).
- Error state: inline, per field, announced (`aria-describedby`). Success state: visible
  confirmation **that says what happens next** ("Check your inbox to confirm").

## 4. The destination seam

All forms post to **one** endpoint/handler; the vendor (CRM, list provider, webhook)
lives behind it, named in one place. Shapes and trade-offs: `./capture-patterns.md`.
The handler's contract — whatever implements it:

1. Reject silently (normal success response, record dropped) if `company2` is non-empty
   or `now − form_ts < 3 s`.
2. Validate the email server-side; honest inline error for real mistakes.
3. Rate-limit by IP.
4. Store: `{ email, consent: true, consent_text_version, submitted_at, source_page }`.
5. Trigger the double-opt-in confirmation; the address is *used* only after the click.

## 5. Spam defenses — escalate, invisible first

Honeypot + time-trap (above) are free and invisible — they go in always. Escalate to
Cloudflare Turnstile (managed/invisible mode) only when measured spam pressure demands;
an interactive challenge is the last resort, because every challenge costs real
conversions. Rationale and rejection etiquette: `./capture-patterns.md`.

## 6. Consent + double opt-in

- Checkbox **unticked** by default; specific text; policy linked. Pre-ticked or bundled
  consent isn't consent.
- Record consent (timestamp + text version) with the lead.
- Double opt-in: store unconfirmed → confirmation email → only confirmed addresses enter
  the list. Established proof-of-consent practice in the EU. (Engineering guidance, not
  legal advice — a regulated project encodes its counsel's rules via
  `../audit-copy-compliance/SKILL.md`.)

## 7. Verify

- Valid submit → success state, record stored with consent fields, confirmation mail
  flow triggers.
- Fill the hidden `company2` field → normal success response, **no** record.
- Submit within 3 s of load → no record.
- Bad email → inline error names the field.
- View the page with JS disabled: the form is present and labeled (it's in the HTML).

## References
- ./capture-patterns.md — destination shapes, spam escalation, silent rejection, consent recording, PII minimization, when to deviate.
- ../_shared/page-types.md — the gate.
- ../../frontend/set-up-forms/SKILL.md — authenticated in-app forms (schema-first, mutation-wired); use that skill there.
