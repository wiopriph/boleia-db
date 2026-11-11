-- Boleia - чат: телефоны с разделителями и повторная бронь (ТЗ разделы 6, 8)
--
-- 1. mask_text ловил только 9 цифр подряд: "923 456 789", "923-456-789", "+244 923 456 789" проходили
--    как есть. Теперь между цифрами допускается один пробел, точка или дефис.
-- 2. Разговор один на пару (поездка, пассажир) и навсегда оставался привязан к первой брони. После
--    её отмены cron закрывал чат, а новая оплаченная бронь его не открывала: пассажир с местом не мог
--    написать водителю, а маскирование и conversation_paid считались по мёртвой брони.

-- ---------------------------------------------------------------------------
-- 1. mask_text
-- ---------------------------------------------------------------------------
create or replace function public.mask_text(p_body text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(p_body, '(https?://\S+|wa\.me/?\S*)', '[oculto]', 'gi'),
           -- с кодом страны любые 9 цифр, без кода - мобильный на 9; (?<!\d) и (?!\d) не дают резать длинные числа
           '(?<!\d)(?:(?:\+|00)?244[\s.-]?\d(?:[\s.-]?\d){8}|9(?:[\s.-]?\d){8})(?!\d)', '[oculto]', 'g')
$$;

-- ---------------------------------------------------------------------------
-- 2. ensure_conversation: оплаченная живая бронь забирает разговор и открывает его
-- ---------------------------------------------------------------------------
create or replace function public.ensure_conversation(p_trip_id uuid, p_passenger_id uuid, p_booking_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id        uuid;
  v_takes_over boolean := false;
begin
  -- confirm_payment зовёт функцию до смены статуса, поэтому признак - оплаченный платёж, а не статус;
  -- системные сообщения по старым броням (отмена, истечение) разговор не перехватывают
  if p_booking_id is not null then
    v_takes_over := exists (
      select 1 from public.bookings b
      where b.id = p_booking_id
        and b.status in ('pending_payment', 'requested', 'accepted', 'awaiting_confirm', 'disputed')
        and exists (select 1 from public.payments pay where pay.booking_id = b.id and pay.status = 'paid')
    );
  end if;

  insert into public.conversations (trip_id, passenger_id, driver_id, booking_id)
  select t.id, p_passenger_id, t.driver_id, p_booking_id from public.trips t where t.id = p_trip_id
  on conflict (trip_id, passenger_id) do update
    set booking_id = case when v_takes_over then excluded.booking_id
                          else coalesce(public.conversations.booking_id, excluded.booking_id) end,
        closed_at  = case when v_takes_over and public.conversations.booking_id is distinct from excluded.booking_id then null
                          else public.conversations.closed_at end
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Данные: разговоры, застрявшие на отменённой брони при живой новой
-- ---------------------------------------------------------------------------
update public.conversations c
set booking_id = live.id, closed_at = null
from (
  select distinct on (b.trip_id, b.passenger_id) b.id, b.trip_id, b.passenger_id
  from public.bookings b
  where b.status in ('requested', 'accepted', 'awaiting_confirm', 'disputed')
  order by b.trip_id, b.passenger_id, b.created_at desc
) live
where live.trip_id = c.trip_id and live.passenger_id = c.passenger_id
  and c.booking_id is distinct from live.id;
