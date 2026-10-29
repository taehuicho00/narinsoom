-- ============================================================
-- 나린숨 예약관리 마스터 사이트 - 초기 데이터베이스 설계
--  · reservations : 예약 (봇이 PMS에서 읽어 저장)
--  · responses    : 손님 응답 (손님 링크에서 제출)
--  · staff_members: 직원 화면 접근 권한
-- 손님(로그인 없음)은 표에 직접 접근하지 못하고,
-- 아래 두 함수(get_reservation, submit_response)로만 자기 예약을 읽고 쓴다.
-- ============================================================

-- 1) 객실 설정: 사이트·봇이 같은 기준을 쓰도록 DB에도 둔다
create table public.rooms (
  name          text primary key,          -- '1호실' ~ '별채'
  base_people   int  not null,             -- 기준 인원 (추가요금 기준)
  max_people    int  not null,             -- 최대 인원
  max_pets      int  not null default 0,   -- 0이면 반려견 불가
  self_checkin  boolean not null default false
);

insert into public.rooms (name, base_people, max_people, max_pets, self_checkin) values
  ('1호실', 4, 8, 0, false),
  ('2호실', 2, 4, 4, false),
  ('3호실', 2, 3, 4, false),
  ('4호실', 2, 3, 4, false),
  ('별채',  4, 8, 0, true);

-- 2) 예약
create table public.reservations (
  id          uuid primary key default gen_random_uuid(),
  pms_id      text unique,                          -- 신비서 예약번호 (중복 저장 방지)
  code        text not null unique,                 -- 손님 링크용 무작위 코드
  room        text not null references public.rooms(name),
  checkin     date not null,
  nights      int  not null default 1 check (nights between 1 and 30),
  guest_name  text,                                 -- 직원 화면 표시용 (예: 김*수)
  channel     text,                                 -- 네이버/야놀자/전화 등
  pms_phone   text,                                 -- 실번호면 저장, 050 안심번호면 null
  need_phone  boolean not null default false,       -- 050 안심번호 손님이면 true
  paid        boolean not null default false,       -- 추가요금 입금 확인
  paid_at     timestamptz,
  link_sent_at timestamptz,                         -- 링크 문자 발송 시각
  created_at  timestamptz not null default now()
);
create index reservations_checkin_idx on public.reservations (checkin);

-- 3) 손님 응답 (예약 1건당 1개, 다시 제출하면 덮어씀)
create table public.responses (
  reservation_id    uuid primary key references public.reservations(id) on delete cascade,
  people            int  not null,
  pets              int  not null default 0,
  checkin_time      time not null,
  bbq_time          time,                           -- null = 숯불 안 함
  memo              text check (char_length(memo) <= 500),
  phone             text,                           -- 안심번호 손님만
  privacy_agreed_at timestamptz,
  submitted_at      timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

-- 4) 직원 목록: Supabase 로그인 계정 중 여기에 있는 사람만 직원 화면 접근
create table public.staff_members (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  name     text,
  role     text not null default 'staff' check (role in ('owner','staff'))
);

-- ============================================================
-- 보안: 모든 표에 RLS(행 단위 보안) 켜기 → 정책이 없으면 아무도 못 봄
-- (봇은 service_role 키를 써서 RLS를 우회)
-- ============================================================
alter table public.rooms         enable row level security;
alter table public.reservations  enable row level security;
alter table public.responses     enable row level security;
alter table public.staff_members enable row level security;

-- 현재 로그인한 사람이 직원인지
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_members where user_id = auth.uid());
$$;

-- 직원: 객실·예약·응답 조회 가능
create policy "직원 객실 조회" on public.rooms        for select to authenticated using (public.is_staff());
create policy "직원 예약 조회" on public.reservations for select to authenticated using (public.is_staff());
create policy "직원 응답 조회" on public.responses    for select to authenticated using (public.is_staff());
create policy "본인 직원정보 조회" on public.staff_members for select to authenticated using (user_id = auth.uid());

-- 직원: 입금 확인(paid)만 바꿀 수 있음 (다른 칸은 함수로 막음)
create policy "직원 입금확인 수정" on public.reservations for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
revoke update on public.reservations from authenticated;
grant  update (paid, paid_at) on public.reservations to authenticated;
grant  select on public.rooms, public.reservations, public.responses, public.staff_members to authenticated;

-- ============================================================
-- 손님용 함수 (로그인 없이 코드로만 호출)
-- ============================================================

-- 코드로 예약 기본 정보만 돌려줌 (이름·번호 등 개인정보는 안 줌)
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
    and r.checkin + r.nights >= current_date;   -- 퇴실 지난 링크는 무효
$$;

-- 손님 응답 저장: 값 검증 후 저장 (다시 제출하면 덮어씀)
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
   where code = p_code and checkin + nights >= current_date;
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

-- 손님(anon)은 이 두 함수만 호출 가능
revoke all on function public.get_reservation(text) from public;
revoke all on function public.submit_response(text,int,int,time,time,text,text,boolean) from public;
grant execute on function public.get_reservation(text) to anon, authenticated;
grant execute on function public.submit_response(text,int,int,time,time,text,text,boolean) to anon, authenticated;
grant execute on function public.is_staff() to authenticated;

-- ============================================================
-- 개인정보 보관: 퇴실 30일 지난 손님 번호·요청사항 삭제
-- (매일 봇이 호출하거나, 나중에 pg_cron으로 자동화)
-- ============================================================
create or replace function public.purge_old_personal_data() returns int
language sql security definer set search_path = public as $$
  with done as (
    update public.responses s set phone = null, memo = null
    from public.reservations r
    where r.id = s.reservation_id
      and r.checkin + r.nights < current_date - 30
      and (s.phone is not null or s.memo is not null)
    returning 1)
  select count(*)::int from done;
$$;
revoke all on function public.purge_old_personal_data() from public, anon, authenticated;
