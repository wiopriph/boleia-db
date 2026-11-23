-- Boleia - заявка на выплату не чаще раза в сутки вместо раза в 7 дней (ТЗ разделы 6, 10)
--
-- Меняется только интервал между заявками одного водителя. Минимум 5 000 Kz, одна заявка в работе и
-- ручная обработка админом остаются. План: docs/plans/0023_payout_daily.md

create or replace function public.request_payout(amount_kz integer)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p        public.profiles := public.current_profile();
  v_amount integer := amount_kz;
  v_id     uuid;
begin
  select * into p from public.profiles where id = p.id for update;
  if p.payout_method is null then perform public.raise_boleia('PAYOUT_METHOD_INVALID'); end if;
  if v_amount is null or v_amount < 5000 then perform public.raise_boleia('AMOUNT_INVALID'); end if;
  if exists (select 1 from public.payouts where user_id = p.id and status in ('requested', 'processing')) then
    perform public.raise_boleia('PAYOUT_PENDING');
  end if;
  if exists (select 1 from public.payouts where user_id = p.id and created_at > now() - interval '24 hours') then
    perform public.raise_boleia('RATE_LIMITED');
  end if;
  if p.balance_kz < v_amount then perform public.raise_boleia('INSUFFICIENT_BALANCE'); end if;

  insert into public.payouts (user_id, amount_kz, method) values (p.id, v_amount, p.payout_method) returning id into v_id;
  perform public.ledger_post(gen_random_uuid(), 'payout:' || v_id, null, jsonb_build_array(
    jsonb_build_object('account', 'driver_balance', 'user_id', p.id, 'payout_id', v_id, 'amount_kz', -v_amount),
    jsonb_build_object('account', 'cash_out', 'payout_id', v_id, 'amount_kz', v_amount)
  ));
  perform public.notify_admins('payout_requested', jsonb_build_object('payout_id', v_id, 'user_id', p.id, 'amount_kz', v_amount));
  perform public.log_event('payout_requested', jsonb_build_object('payout_id', v_id, 'amount_kz', v_amount));
  return v_id;
end $$;
