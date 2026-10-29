-- 한국 날짜 기준으로 링크 유효기간·보관기간 계산
-- (DB 기본 시간대가 UTC라 current_date를 쓰면 한국 새벽 0~9시에 하루 어긋남)
create or replace function public.kst_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Seoul')::date $$;

create or replace function public.get_reservation(p_code text)
returns table (room text, checkin date, nights int, need_phone boolean,
               max_people int, max_pets int, self_checkin boolean, answered boolean)
language sql stable security definer set search_path = public as $$
  select r.room, r.checkin, r.nights, r.need_phone,
         rm.max_people, rm.max_pets, rm.self_checkin,
         exists (select 1 from public.responses s where s.reservation_id = r.id)
  from public.reservations r
  join public.rooms rm on rm.name = r.room
  where r.code = p_code
    and r.checkin + r.nights >= public.kst_today();   -- 퇴실 지난 링크는 무효
$$;

create or replace function public.submit_response(
  p_code text, p_people int, p_pets int, p_checkin_time time,
  p_bbq_time time, p_memo text, p_phone text, p_agree boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_res  public.reservations;
  v_room public.rooms;
begin
  select * into v_res from public.reservations
   where code = p_code and checkin + nights >= public.kst_today();
  if not found then raise exception '예약을 찾을 수 없습니다'; end if;
  select * into v_room from public.rooms where name = v_res.room;

  -- 인원·반려견·시간 범위 검증 (화면과 같은 규칙)
  if p_people is null or p_people < 2 or p_people > v_room.max_people then
    raise exception '인원이 범위를 벗어났습니다'; end if;
  if coalesce(p_pets,0) < 0 or coalesce(p_pets,0) > v_room.max_pets then
    raise exception '반려견 수가 범위를 벗어났습니다'; end if;
  if p_checkin_time is null or p_checkin_time < '15:00' or p_checkin_time > '21:00' then
    raise exception '입실 시간은 15:00~21:00입니다'; end if;
  if p_bbq_time is not null and (p_bbq_time < '17:00' or p_bbq_time > '20:00') then
    raise exception '숯불 시간은 17:00~20:00입니다'; end if;
  -- 안심번호 손님은 번호·동의 필수
  if v_res.need_phone then
    if p_phone is null or p_phone !~ '^01[016789]-[0-9]{3,4}-[0-9]{4}$' then
      raise exception '휴대폰 번호 형식이 올바르지 않습니다'; end if;
    if not coalesce(p_agree,false) then
      raise exception '개인정보 수집·이용 동의가 필요합니다'; end if;
  end if;

  insert into public.responses as s
    (reservation_id, people, pets, checkin_time, bbq_time, memo, phone, privacy_agreed_at)
  values
    (v_res.id, p_people, coalesce(p_pets,0), p_checkin_time, p_bbq_time, left(p_memo,500),
     case when v_res.need_phone then p_phone end,
     case when v_res.need_phone then now() end)
  on conflict (reservation_id) do update set
    people = excluded.people, pets = excluded.pets,
    checkin_time = excluded.checkin_time, bbq_time = excluded.bbq_time,
    memo = excluded.memo,
    phone = coalesce(excluded.phone, s.phone),
    privacy_agreed_at = coalesce(excluded.privacy_agreed_at, s.privacy_agreed_at),
    updated_at = now();
  return true;
end;
$$;

create or replace function public.purge_old_personal_data() returns int
language sql security definer set search_path = public as $$
  with done as (
    update public.responses s set phone = null, memo = null
    from public.reservations r
    where r.id = s.reservation_id
      and r.checkin + r.nights < public.kst_today() - 30
      and (s.phone is not null or s.memo is not null)
    returning 1)
  select count(*)::int from done;
$$;

-- 권한 다시 지정 (함수를 다시 만들어도 기존 권한은 유지되지만 명시적으로)
revoke all on function public.get_reservation(text) from public;
revoke all on function public.submit_response(text,int,int,time,time,text,text,boolean) from public;
grant execute on function public.get_reservation(text) to anon, authenticated;
grant execute on function public.submit_response(text,int,int,time,time,text,text,boolean) to anon, authenticated;
revoke all on function public.purge_old_personal_data() from public, anon, authenticated;
