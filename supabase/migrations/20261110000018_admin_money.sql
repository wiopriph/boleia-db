-- Boleia - админка, деньги (ТЗ раздел 11: баланс по счетам ledger, очередь возвратов)
--
-- Чтение для экрана денег: суммы по счетам ledger и очередь возвратов с колонками payments, закрытыми
-- от клиента column grants (refund_attempts, refund_failed_at, provider_ref). План: docs/plans/0018_admin_money.md

-- Баланс по каждому счёту ledger, включая счета без проводок. Сумма по всем счетам = 0 (двойная запись).
create or replace function public.admin_ledger_balances()
returns table (account public.ledger_account, balance_kz bigint, entries bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin();
  return query
    select a.account, coalesce(sum(l.amount_kz), 0)::bigint, count(l.id)
    from unnest(enum_range(null::public.ledger_account)) as a(account)
    left join public.ledger_entries l on l.account = a.account
    group by a.account
    order by a.account;
end $$;

-- Возвраты, которые ещё не дошли до пассажира: автоочередь Edge (refund_attempts < 3) и ручные
-- (>= 3 неудачных попыток; закрываются admin_mark_refund_manual). Ручные идут первыми.
create or replace function public.admin_refund_queue()
returns table (
  payment_id uuid, booking_id uuid, payer_id uuid, payer_name text, payer_phone text, provider_ref text,
  amount_kz integer, refund_kz integer, refund_attempts smallint, refund_failed_at timestamptz,
  is_manual boolean, updated_at timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin();
  return query
    select p.id, p.booking_id, p.payer_id, pr.display_name, pr.phone, p.provider_ref,
           p.amount_kz, p.refund_kz, p.refund_attempts, p.refund_failed_at,
           p.refund_attempts >= 3, p.updated_at
    from public.payments p
    join public.profiles pr on pr.id = p.payer_id
    where p.refund_kz > 0 and p.refund_ref is null
    order by (p.refund_attempts >= 3) desc, p.updated_at, p.id;
end $$;

revoke execute on function
  public.admin_ledger_balances(),
  public.admin_refund_queue()
from public, anon, authenticated;
grant execute on function
  public.admin_ledger_balances(),
  public.admin_refund_queue()
to authenticated;
