-- ============================================================
-- 문자 봇(Mac의 narinsum_bot) 전용 함수
--  · 봇은 비밀 키 대신 '봇 토큰'으로만 접근 (해시만 DB에 저장, 원문은 Mac .env)
--  · 봇이 할 수 있는 일: 예약 동기화, 날짜별 예약 조회, 발송 기록 남기기
--  · 신비서에서 사라진(취소된) 예약은 status='cancelled' → 문자·직원 화면에서 제외
-- ============================================================

alter table public.reservations add column if not exists status text not null default 'active'
  check (status in ('active','cancelled'));
alter table public.reservations add column if not exists checkin_sent_at timestamptz;
alter table public.reservations add column if not exists fee_amount int;
alter table public.reservations add column if not exists fee_sent_at timestamptz;
alter table public.reservations add column if not exists remind_sent_at timestamptz;
alter table public.reservations add column if not exists synced_at timestamptz;

create table if not exists public.bot_tokens (
  token_hash text primary key,
  created_at timestamptz not null default now()
);
alter table public.bot_tokens enable row level security;   -- 정책 없음 = 함수 밖 접근 불가

create or replace function public._bot_ok(p_token text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.bot_tokens
                 where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex'))
$$;

-- 손님 링크 코드 (헷갈리는 0/O, 1/I 제외, 8자리)
create or replace function public._new_code() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  c text;
begin
  loop
    select string_agg(substr(a, 1 + (get_byte(b, i) % 32), 1), '')
      into c from (select extensions.gen_random_bytes(8) b) x, generate_series(0,7) i;
    exit when not exists (select 1 from public.reservations where code = c);
  end loop;
  return c;
end;
$$;

-- 예약 동기화: p_rows = [{pms_id, source, room, checkin, nights, guest_name, pms_phone, need_phone,
--                          pms_memo, memo_people, memo_pets, bbq_prepaid}]
-- p_from~p_to 범위에서 이번 목록에 없는 같은 출처(source) 예약은 취소로 표시
create or replace function public.bot_sync(p_token text, p_rows json, p_from date, p_to date, p_sources text[])
returns json
language plpgsql security definer set search_path = public as $$
declare
  r json; n_new int := 0; n_upd int := 0; n_cancel int := 0; v_id uuid;
begin
  if not public._bot_ok(p_token) then raise exception 'invalid_bot_token'; end if;
  for r in select * from json_array_elements(p_rows) loop
    update public.reservations set
      room = r->>'room', checkin = (r->>'checkin')::date, nights = (r->>'nights')::int,
      guest_name = coalesce(r->>'guest_name', guest_name),
      pms_phone = coalesce(r->>'pms_phone', pms_phone),
      need_phone = (r->>'need_phone')::boolean,
      pms_memo = r->>'pms_memo',
      memo_people = (r->>'memo_people')::int, memo_pets = (r->>'memo_pets')::int,
      bbq_prepaid = coalesce((r->>'bbq_prepaid')::boolean, false),
      status = 'active', synced_at = now()
    where pms_id = r->>'pms_id'
    returning id into v_id;
    if v_id is null then
      insert into public.reservations (pms_id, code, source, room, checkin, nights, guest_name, pms_phone,
        need_phone, pms_memo, memo_people, memo_pets, bbq_prepaid, synced_at)
      values (r->>'pms_id', public._new_code(), coalesce(r->>'source','pms'), r->>'room', (r->>'checkin')::date,
        (r->>'nights')::int, r->>'guest_name', r->>'pms_phone', (r->>'need_phone')::boolean, r->>'pms_memo',
        (r->>'memo_people')::int, (r->>'memo_pets')::int, coalesce((r->>'bbq_prepaid')::boolean, false), now());
      n_new := n_new + 1;
    else
      n_upd := n_upd + 1;
    end if;
    v_id := null;
  end loop;

  update public.reservations set status = 'cancelled', synced_at = now()
  where status = 'active' and source = any(p_sources) and checkin between p_from and p_to
    and pms_id is not null
    and pms_id not in (select x->>'pms_id' from json_array_elements(p_rows) x);
  get diagnostics n_cancel = row_count;

  return json_build_object('new', n_new, 'updated', n_upd, 'cancelled', n_cancel);
end;
$$;

-- 날짜별 예약 + 손님 응답 + 객실 설정 (입실일 기준 또는 퇴실일 기준)
create or replace function public.bot_day(p_token text, p_date date, p_by text default 'checkin')
returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._bot_ok(p_token) then raise exception 'invalid_bot_token'; end if;
  return json_build_object(
    'rooms', (select coalesce(json_agg(r), '[]'::json) from public.rooms r),
    'reservations', (
      select coalesce(json_agg(x order by x.room), '[]'::json) from (
        select v.*,
          (select row_to_json(s) from (
             select people, pets, checkin_time, bbq_time, memo, phone
             from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.status = 'active'
          and case when p_by = 'checkout' then v.checkin + v.nights = p_date else v.checkin = p_date end) x));
end;
$$;

-- 발송 기록: p_kind = link | checkin | fee | remind
create or replace function public.bot_mark(p_token text, p_id uuid, p_kind text, p_amount int default null)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._bot_ok(p_token) then raise exception 'invalid_bot_token'; end if;
  update public.reservations set
    link_sent_at    = case when p_kind = 'link'    then now() else link_sent_at end,
    checkin_sent_at = case when p_kind = 'checkin' then now() else checkin_sent_at end,
    fee_sent_at     = case when p_kind = 'fee'     then now() else fee_sent_at end,
    fee_amount      = case when p_kind = 'fee'     then p_amount else fee_amount end,
    remind_sent_at  = case when p_kind = 'remind'  then now() else remind_sent_at end
  where id = p_id;
  return found;
end;
$$;

-- 개인정보 30일 정리도 봇이 하루 한 번 실행
create or replace function public.bot_purge(p_token text) returns int
language plpgsql security definer set search_path = public as $$
begin
  if not public._bot_ok(p_token) then raise exception 'invalid_bot_token'; end if;
  return public.purge_old_personal_data();
end;
$$;

revoke all on function public._bot_ok(text) from public, anon, authenticated;
revoke all on function public._new_code() from public, anon, authenticated;
revoke all on function public.bot_sync(text,json,date,date,text[]) from public;
revoke all on function public.bot_day(text,date,text) from public;
revoke all on function public.bot_mark(text,uuid,text,int) from public;
revoke all on function public.bot_purge(text) from public;
grant execute on function public.bot_sync(text,json,date,date,text[]) to anon;
grant execute on function public.bot_day(text,date,text) to anon;
grant execute on function public.bot_mark(text,uuid,text,int) to anon;
grant execute on function public.bot_purge(text) to anon;

-- 취소된 예약은 손님 링크·직원 화면에서도 제외
create or replace function public.get_reservation(p_code text)
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
  where r.code = p_code and r.status = 'active'
    and r.checkin + r.nights >= public.kst_today();
$$;

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
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.status = 'active' and v.checkin between p_from and p_to) x));
end;
$$;

-- 봇 토큰 등록은 저장소에 넣지 않고 대시보드에서 해시값으로 따로 실행:
-- insert into public.bot_tokens (token_hash) values ('<sha256 해시>');

-- 취소된 예약에는 손님 응답도 받지 않음
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
   where code = p_code and status = 'active' and checkin + nights >= public.kst_today();
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
