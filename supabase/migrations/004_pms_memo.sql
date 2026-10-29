-- 신비서 예약의 고객요청 메모를 직원 화면에 보여주기
alter table public.reservations add column if not exists pms_memo text;

create or replace function public.staff_week(p_token text, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return json_build_object(
    'rooms', (select coalesce(json_agg(r), '[]'::json) from public.rooms r),
    'reservations', (
      select coalesce(json_agg(x order by x.checkin), '[]'::json) from (
        select v.id, v.room, v.checkin, v.nights, v.guest_name, v.channel, v.pms_phone,
               v.need_phone, v.paid, v.pms_memo,
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.checkin between p_from and p_to) x));
end;
$$;
