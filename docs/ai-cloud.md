# Juno cloud AI

The assistant, receipt reading and the monthly read run through a small
Supabase edge function, `supabase/functions/ai`. The OpenAI key is stored
there as a project secret and is never put inside the app. Any device signed
in to Juno sync can use AI straight away, with no key to enter.

## How a request flows

1. The app sends an OpenAI-style chat request to `/functions/v1/ai`, along
   with the signed-in session. It never sends a key.
2. The function checks the session and refuses anyone who isn't signed in.
   Because sign-ups are disabled, that means only your account.
3. It checks this month's spend in `ai_usage`. At the cap it replies 429, and
   the app falls back to its on-device features.
4. It forwards the request to OpenAI with the key, using the model it chooses
   (default `gpt-5-mini`).
5. It records the cost from the token usage OpenAI reports, then returns the
   reply. The month's spend and the cap travel back in the response headers,
   which is where the app's Settings screen gets its meter.

A key set in Settings → AI assist on one device overrides the relay on that
device only.

## Setup (once)

```bash
npx supabase db push                                    # creates ai_usage + ai_charge
npx supabase functions deploy ai                        # deploys the relay
npx supabase secrets set OPENAI_API_KEY=sk-proj-…       # the key, stored server-side
```

These secrets are optional:

| Secret | Default | What it sets |
|---|---|---|
| `AI_MONTHLY_CAP_CENTS` | `200` | Monthly cap per user, in cents ($2) |
| `AI_MODEL` | `gpt-5-mini` | Model the relay sends requests to |
| `AI_PRICE_IN_PER_M` / `AI_PRICE_OUT_PER_M` | `0.25` / `2` | USD per million tokens, used by the cap |

If you change `AI_MODEL`, set its prices too.

## Check it

```bash
SUPABASE_URL=… SUPABASE_ANON_KEY=… JUNO_LIVE_EMAIL=… JUNO_LIVE_PASSWORD=… \
  flutter test test/ai_live_test.dart --run-skipped --plain-name relay
```

Use this month's usage to check spend:

```sql
select * from ai_usage;
```
