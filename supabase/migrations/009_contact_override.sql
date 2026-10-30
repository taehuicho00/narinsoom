-- 사장님이 지정한 받는 분 (예: 예약자와 실제 투숙객이 다를 때)
--  · 신비서 동기화가 덮어쓰지 않는 별도 칸
--  · 봇 문자는 contact_phone 으로, 인사말은 contact_name 으로
alter table public.reservations add column if not exists contact_phone text;
alter table public.reservations add column if not exists contact_name text;

create or replace function public.staff_week(p_token text, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return json_build_object(
    'rooms', (select coalesce(json_agg(r), '[]'::json) from public.rooms r),
    'reservations', (
      select coalesce(json_agg(x order by x.checkin), '[]'::json) from (
        select v.id, v.code, v.room, v.checkin, v.nights, v.guest_name, v.pms_phone,
               v.need_phone, v.paid, v.fee_hold, v.pms_memo, v.source,
               v.memo_people, v.memo_pets, v.bbq_prepaid,
               v.link_sent_at, v.checkin_sent_at, v.fee_sent_at, v.fee_amount,
               v.contact_phone, v.contact_name,
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.status = 'active' and v.checkin between p_from and p_to) x));
end;
$$;
