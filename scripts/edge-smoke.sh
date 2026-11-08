#!/usr/bin/env bash
# Сквозная проверка Edge Functions против мока шлюза.
#   локально: нужен `supabase functions serve` в другом терминале; по умолчанию db reset + Vault, --no-reset пропускает
#   облако:   scripts/edge-smoke.sh --cloud <project-ref> после scripts/deploy.sh (данные остаются)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-local}
if [[ "$MODE" == "--cloud" ]]; then
  # scripts/edge-smoke.sh --cloud <project-ref>: без reset, данные в проекте остаются
  REF=${2:?usage: scripts/edge-smoke.sh --cloud <project-ref>}
  API="https://$REF.supabase.co"
  KEYS=$(supabase projects api-keys --remote="$REF" -o json)
  ANON=$(printf '%s' "$KEYS" | python3 -c 'import sys,json; ks=json.load(sys.stdin); print(next(k.get("api_key") or k.get("key") for k in ks if k.get("name")=="anon" or k.get("type")=="publishable"))')
  SERVICE=$(printf '%s' "$KEYS" | python3 -c 'import sys,json; ks=json.load(sys.stdin); print(next(k.get("api_key") or k.get("key") for k in ks if k.get("name")=="service_role" or k.get("type")=="secret"))')
  sql() { supabase db query --remote --yes -o json "$1" 2>/dev/null | python3 -c '
import sys, json
raw = sys.stdin.read(); raw = raw[raw.find("{"):]
rows = json.loads(raw).get("rows") or []
print("" if not rows else list(rows[0].values())[0])'; }
else
  if [[ "$MODE" != "--no-reset" ]]; then
    supabase db reset >/dev/null
    scripts/dev-vault.sh
  fi
  status=$(supabase status -o json 2>/dev/null)
  API=$(printf '%s' "$status" | python3 -c 'import sys,json; print(json.load(sys.stdin)["API_URL"])')
  ANON=$(printf '%s' "$status" | python3 -c 'import sys,json; print(json.load(sys.stdin)["ANON_KEY"])')
  SERVICE=$(printf '%s' "$status" | python3 -c 'import sys,json; print(json.load(sys.stdin)["SERVICE_ROLE_KEY"])')
  DB=$(docker ps --format '{{.Names}}' | grep '^supabase_db_' | head -1)
  sql() { docker exec -i "$DB" psql -U postgres -d postgres -Atq -c "$1"; }
fi
FN="$API/functions/v1"
jget() { python3 -c 'import sys,json; d=json.load(sys.stdin); print(d'"$1"')'; }
step() { printf '\n== %s\n' "$1"; }
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1: $2"; else echo "FAIL $1: got '$2', want '$3'"; exit 1; fi; }

step "login Ana (test OTP)"
curl -sf -X POST "$API/auth/v1/otp" -H "apikey: $ANON" -H 'content-type: application/json' -d '{"phone":"244900000005"}' >/dev/null
VERIFY=$(curl -sf -X POST "$API/auth/v1/verify" -H "apikey: $ANON" -H 'content-type: application/json' \
  -d '{"type":"sms","phone":"244900000005","token":"123456"}')
JWT=$(printf '%s' "$VERIFY" | jget '["access_token"]')
ANA=$(printf '%s' "$VERIFY" | jget '["user"]["id"]')
check "seed Ana logged in" "$ANA" "55555555-5555-5555-5555-555555555555"
AUTH=(-H "apikey: $ANON" -H "Authorization: Bearer $JWT" -H 'content-type: application/json')

# в облаке данные остаются между прогонами: снимаем активные брони Ana, чтобы не упереться в лимит 3
step "cleanup Ana: active bookings, restricted after mismatch runs"
sql "update public.profiles set status='active' where id='$ANA' and status='restricted'; delete from public.events where user_id='$ANA' and name='payment_phone_mismatch'" >/dev/null
for B in $(sql "select string_agg(id::text, ' ') from public.bookings where passenger_id='$ANA' and status in ('requested','accepted')"); do
  curl -s -X POST "$API/rest/v1/rpc/cancel_booking" "${AUTH[@]}" -d "{\"booking_id\":\"$B\"}" >/dev/null && echo "cancelled $B"
done

pick_trip() { sql "select id from public.trips t where t.status='published' and t.driver_id<>'$ANA' and not exists (select 1 from public.bookings b where b.trip_id=t.id and b.passenger_id='$ANA' and b.status in ('pending_payment','requested','accepted','awaiting_confirm')) and t.booking_mode='instant' order by departure_at limit 1"; }
book() {
  local r; r=$(curl -s -X POST "$API/rest/v1/rpc/request_booking" "${AUTH[@]}" -d "{\"trip_id\":\"$1\",\"seats\":1}")
  printf '%s' "$r" | jget '["booking_id"]' 2>/dev/null || { echo "request_booking failed: $r" >&2; exit 1; }
}

step "instant: init -> mock webhook (paid) -> accepted"
T1=$(pick_trip); B1=$(book "$T1")
R=$(curl -sf -X POST "$FN/payments-init" "${AUTH[@]}" -d "{\"booking_id\":\"$B1\",\"simulate\":\"paid\"}")
check "instructions.type" "$(printf '%s' "$R" | jget '["instructions"]["type"]')" "push"
P1=$(printf '%s' "$R" | jget '["payment_id"]')
check "payment pending" "$(sql "select status from public.payments where id='$P1'")" "pending"
sleep 7
check "booking accepted" "$(sql "select status from public.bookings where id='$B1'")" "accepted"
check "ledger cash_in" "$(sql "select -sum(amount_kz) from public.ledger_entries where booking_id='$B1' and account='cash_in'")" "$(sql "select amount_kz from public.payments where id='$P1'")"

step "payments-status by user"
R=$(curl -sf -X POST "$FN/payments-status" "${AUTH[@]}" -d "{\"payment_id\":\"$P1\"}")
check "status reply" "$(printf '%s' "$R" | jget '["booking_status"]')" "accepted"

step "mismatch: paid from another phone -> payment_failed -> refund via gateway"
T2=$(pick_trip); B2=$(book "$T2")
P2=$(curl -sf -X POST "$FN/payments-init" "${AUTH[@]}" -d "{\"booking_id\":\"$B2\",\"simulate\":\"mismatch\"}" | jget '["payment_id"]')
sleep 7
check "booking payment_failed" "$(sql "select status from public.bookings where id='$B2'")" "payment_failed"
check "refund queued" "$(sql "select count(*) from public.pending_refunds where payment_id='$P2'")" "1"
R=$(curl -sf -X POST "$FN/payments-refund" -H "Authorization: Bearer $SERVICE" -H 'content-type: application/json' -d '{}')
echo "payments-refund: $R (в облаке cron мог успеть раньше)"
check "payment refunded" "$(sql "select status from public.payments where id='$P2'")" "refunded"

step "silent: no webhook -> sweep payments-status asks the gateway"
T3=$(pick_trip); B3=$(book "$T3")
P3=$(curl -sf -X POST "$FN/payments-init" "${AUTH[@]}" -d "{\"booking_id\":\"$B3\",\"simulate\":\"silent\"}" | jget '["payment_id"]')
sleep 1
sql "update public.payments set expires_at = now() - interval '1 minute' where id='$P3'" >/dev/null
R=$(curl -sf "$FN/payments-status?sweep=1" -H "Authorization: Bearer $SERVICE")
echo "payments-status sweep: $R (в облаке cron мог успеть раньше)"
check "booking accepted via sweep" "$(sql "select status from public.bookings where id='$B3'")" "accepted"

step "webhook with bad signature is rejected"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$FN/payments-webhook" -H 'content-type: application/json' -H 'x-gateway-signature: sha256=00' -d '{"reference":"x"}')
check "401" "$CODE" "401"

step "notify sweep delivers queued push/sms with the log provider"
R=$(curl -sf "$FN/notify?sweep=1" -H "Authorization: Bearer $SERVICE")
echo "notify: $R"
check "nothing left queued" "$(sql "select count(*) from public.notifications where status='queued' and channel in ('push','sms') and (scheduled_for is null or scheduled_for <= now())")" "0"

step "admin role in JWT (custom_access_token_hook)"
curl -sf -X POST "$API/auth/v1/otp" -H "apikey: $ANON" -H 'content-type: application/json' -d '{"phone":"244900000001"}' >/dev/null
AJWT=$(curl -sf -X POST "$API/auth/v1/verify" -H "apikey: $ANON" -H 'content-type: application/json' \
  -d '{"type":"sms","phone":"244900000001","token":"123456"}' | jget '["access_token"]')
ROLE=$(printf '%s' "$AJWT" | cut -d. -f2 | python3 -c 'import sys,base64,json; s=sys.stdin.read().strip(); s+="="*(-len(s)%4); print(json.loads(base64.urlsafe_b64decode(s)).get("app_metadata",{}).get("role",""))')
check "app_metadata.role" "$ROLE" "admin"

printf '\nALL OK\n'
