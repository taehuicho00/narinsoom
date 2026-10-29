-- 방막기 메모에서 확실히 알 수 있는 정보를 데이터 칸으로
--  · memo_people / memo_pets: 메모에 숫자로 적힌 인원·반려견 (반려견 불가 객실은 0)
--  · bbq_prepaid: 메모에 '숯불 지급/결제 완료' → 추가요금에서 숯불 제외
alter table public.reservations add column if not exists memo_pets int;
alter table public.reservations add column if not exists bbq_prepaid boolean not null default false;

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
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.checkin between p_from and p_to) x));
end;
$$;

-- 손님 화면: 이미 알고 있는 인원·숯불 결제 여부를 미리 선택해 보여주기 위해 반환 칸 추가
drop function if exists public.get_reservation(text);
create function public.get_reservation(p_code text)
returns table (room text, checkin date, nights int, need_phone boolean,
               max_people int, max_pets int, self_checkin boolean, answered boolean,
               memo_people int, memo_pets int, bbq_prepaid boolean)
language sql stable security definer set search_path = public as $$
  select r.room, r.checkin, r.nights, r.need_phone,
         rm.max_people, rm.max_pets, rm.self_checkin,
         exists (select 1 from public.responses s where s.reservation_id = r.id),
         r.memo_people, r.memo_pets, r.bbq_prepaid
  from public.reservations r
  join public.rooms rm on rm.name = r.room
  where r.code = p_code
    and r.checkin + r.nights >= public.kst_today();
$$;
revoke all on function public.get_reservation(text) from public;
grant execute on function public.get_reservation(text) to anon, authenticated;
