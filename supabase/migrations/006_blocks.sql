-- 신비서 방막기(전화·계좌이체 예약) 손님
--  · source: 'pms'(신비서 예약) / 'block'(방막기 메모에서 가져옴)
--  · memo_people: 사장님이 메모에 적어 둔 인원 (손님 응답 전 참고용)
--  · 방막기 손님은 추가요금 자동 문자에서 제외 (봇이 source로 판단)
alter table public.reservations add column if not exists source text not null default 'pms'
  check (source in ('pms','block'));
alter table public.reservations add column if not exists memo_people int;

create or replace function public.staff_week(p_token text, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return json_build_object(
    'rooms', (select coalesce(json_agg(r), '[]'::json) from public.rooms r),
    'reservations', (
      select coalesce(json_agg(x order by x.checkin), '[]'::json) from (
        select v.id, v.code, v.room, v.checkin, v.nights, v.guest_name, v.pms_phone,
               v.need_phone, v.paid, v.fee_hold, v.pms_memo, v.source, v.memo_people,
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.checkin between p_from and p_to) x));
end;
$$;
