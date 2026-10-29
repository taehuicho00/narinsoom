-- ============================================================
-- 직원 화면: 로그인 계정 대신 4자리 비밀번호(PIN)
--  · PIN은 bcrypt 해시로만 저장 (원문은 코드·DB 어디에도 없음)
--  · 맞히면 30일짜리 기기 토큰 발급 → 그 기기에선 다시 안 물어봄
--  · 무작위 대입 방지: 같은 IP 15분 내 5회 실패 시 잠금, 전체 1시간 30회 실패 시 잠금
--  · 직원 화면은 표에 직접 접근하지 않고 아래 함수로만 조회·입금확인
-- ============================================================

create table public.staff_pin (
  id        int primary key default 1 check (id = 1),   -- 한 줄만 존재
  pin_hash  text not null,
  updated_at timestamptz not null default now()
);

create table public.staff_sessions (
  token_hash text primary key,                -- 토큰 원문이 아니라 sha256 해시만 저장
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days'
);

create table public.staff_login_attempts (
  id  bigint generated always as identity primary key,
  ip  text,
  ok  boolean not null,
  at  timestamptz not null default now()
);

alter table public.staff_pin            enable row level security;
alter table public.staff_sessions       enable row level security;
alter table public.staff_login_attempts enable row level security;
-- 정책 없음 = 함수 밖에서는 아무도 접근 불가

-- 요청한 기기의 IP (Supabase가 넘겨주는 헤더에서)
create or replace function public._client_ip() returns text
language sql stable as $$
  select coalesce(
    split_part(nullif(current_setting('request.headers', true),'')::json->>'x-forwarded-for', ',', 1),
    'unknown')
$$;

-- 토큰이 유효한지
create or replace function public._staff_token_ok(p_token text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.staff_sessions
    where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex')
      and expires_at > now())
$$;

-- PIN 확인 → 기기 토큰 발급
create or replace function public.staff_login(p_pin text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ip text := public._client_ip();
  v_hash text;
  v_token text;
begin
  -- 오래된 기록 정리
  delete from public.staff_login_attempts where at < now() - interval '1 day';
  delete from public.staff_sessions where expires_at < now();

  if (select count(*) from public.staff_login_attempts
       where ip = v_ip and not ok and at > now() - interval '15 minutes') >= 5 then
    raise exception '비밀번호를 여러 번 틀려 15분간 잠겼습니다';
  end if;
  if (select count(*) from public.staff_login_attempts
       where not ok and at > now() - interval '1 hour') >= 30 then
    raise exception '비정상 접근이 감지되어 잠시 잠겼습니다. 사장님께 문의하세요';
  end if;

  select pin_hash into v_hash from public.staff_pin where id = 1;
  if v_hash is null or p_pin is null or p_pin !~ '^[0-9]{4}$'
     or extensions.crypt(p_pin, v_hash) <> v_hash then
    insert into public.staff_login_attempts (ip, ok) values (v_ip, false);
    raise exception '비밀번호가 맞지 않습니다';
  end if;

  insert into public.staff_login_attempts (ip, ok) values (v_ip, true);
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.staff_sessions (token_hash)
    values (encode(extensions.digest(v_token, 'sha256'), 'hex'));
  return v_token;
end;
$$;

-- 한 주 예약 + 손님 응답 + 객실 설정 (직원 화면용)
create or replace function public.staff_week(p_token text, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return json_build_object(
    'rooms', (select coalesce(json_agg(r), '[]'::json) from public.rooms r),
    'reservations', (
      select coalesce(json_agg(x order by x.checkin), '[]'::json) from (
        select v.id, v.room, v.checkin, v.nights, v.guest_name, v.channel, v.pms_phone,
               v.need_phone, v.paid,
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.checkin between p_from and p_to) x));
end;
$$;

-- 입금 확인 저장
create or replace function public.staff_set_paid(p_token text, p_id uuid, p_paid boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  update public.reservations
     set paid = coalesce(p_paid,false), paid_at = case when p_paid then now() end
   where id = p_id;
  return found;
end;
$$;

-- 이 기기 로그아웃
create or replace function public.staff_logout(p_token text) returns void
language sql security definer set search_path = public, extensions as $$
  delete from public.staff_sessions
  where token_hash = encode(extensions.digest(coalesce(p_token,''), 'sha256'), 'hex');
$$;

revoke all on function public._client_ip() from public, anon, authenticated;
revoke all on function public._staff_token_ok(text) from public, anon, authenticated;
revoke all on function public.staff_login(text) from public;
revoke all on function public.staff_week(text,date,date) from public;
revoke all on function public.staff_set_paid(text,uuid,boolean) from public;
revoke all on function public.staff_logout(text) from public;
grant execute on function public.staff_login(text) to anon, authenticated;
grant execute on function public.staff_week(text,date,date) to anon, authenticated;
grant execute on function public.staff_set_paid(text,uuid,boolean) to anon, authenticated;
grant execute on function public.staff_logout(text) to anon, authenticated;

-- PIN 설정은 저장소에 넣지 않고 대시보드에서 해시값으로 따로 실행:
-- insert into public.staff_pin (id, pin_hash) values (1, '<bcrypt 해시>')
--   on conflict (id) do update set pin_hash = excluded.pin_hash, updated_at = now();
-- 비밀번호를 바꾸면 기존 기기 토큰도 지우기: delete from public.staff_sessions;
