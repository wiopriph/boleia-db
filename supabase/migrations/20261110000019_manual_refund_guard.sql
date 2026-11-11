-- Boleia - ручной возврат только для ручной очереди (ТЗ разделы 6, 11)
--
-- admin_mark_refund_manual закрывал любой платёж с refund_kz > 0. Пока возврат в автоочереди Edge
-- (refund_attempts < 3), ручная отметка опасна: либо деньги уходят дважды (шлюз уже в пути), либо
-- строка выпадает из pending_refunds и пассажир не получает ничего.

create or replace function public.admin_mark_refund_manual(payment_id uuid, ref text, note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_admin  public.profiles := public.require_admin();
  v_ref    text := nullif(btrim(ref), '');
  pay      public.payments;
  v_result jsonb;
begin
  if v_ref is null then perform public.raise_boleia('PAYMENT_REF_MISMATCH'); end if;
  -- блокировка: третья неудача Edge и отметка админа не должны разминуться
  select * into pay from public.payments where id = admin_mark_refund_manual.payment_id for update;
  if pay.id is null then perform public.raise_boleia('PAYMENT_NOT_FOUND'); end if;
  if pay.refund_ref is null and pay.refund_attempts < 3 then
    perform public.raise_boleia('PAYMENT_STATUS_INVALID');
  end if;

  v_result := public.payment_refund_result(pay.id, true, 'manual:' || v_ref,
    jsonb_build_object('manual', true, 'note', note, 'admin', v_admin.id));
  perform public.mod_log(v_admin.id, pay.payer_id, 'manual_refund', coalesce(nullif(btrim(note), ''), v_ref), null,
    jsonb_build_object('payment_id', pay.id, 'booking_id', pay.booking_id, 'refund_kz', pay.refund_kz, 'ref', v_ref));
  return v_result;
end $$;
