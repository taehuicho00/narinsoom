-- ============================================================
-- 직원 구매요청
--  · 직원이 네이버·쿠팡 상품 링크 + 수량(+메모)을 남기면 사장이 구매완료/반려 처리
--  · 직원 화면과 같은 4자리 비밀번호 토큰으로만 접근 (표 직접 접근 불가)
--  · 상태: requested(진행중) → bought(구매완료) / rejected(반려)
-- ============================================================

create table if not exists public.purchase_requests (
  id         uuid primary key default gen_random_uuid(),
  url        text not null check (url ~* '^https?://' and length(url) <= 2000),
  store      text not null default 'etc' check (store in ('naver','coupang','etc')),
  qty        int  not null default 1 check (qty between 1 and 999),
  note       text check (note is null or length(note) <= 300),
  status     text not null default 'requested' check (status in ('requested','bought','rejected')),
  created_at timestamptz not null default now(),
  status_at  timestamptz
);
alter table public.purchase_requests enable row level security;
-- 정책 없음 = 아래 함수 밖에서는 아무도 접근 불가

-- 링크 주소로 쇼핑몰 구분
create or replace function public._purchase_store(p_url text) returns text
language sql immutable as $$
  select case
    when p_url ~* '^https?://([^/?#]*\.)?(coupang\.com|coupa\.ng)([/?#:]|$)' then 'coupang'
    when p_url ~* '^https?://([^/?#]*\.)?(naver\.com|naver\.me)([/?#:]|$)'   then 'naver'
    else 'etc' end
$$;

-- 목록: 진행중 전부 + 최근 90일 완료·반려
create or replace function public.staff_purchase_list(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return (
    select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
      select id, url, store, qty, note, status, created_at, status_at
      from public.purchase_requests
      where status = 'requested' or created_at > now() - interval '90 days'
      order by created_at desc
      limit 500) x);
end;
$$;

-- 요청 추가
create or replace function public.staff_purchase_add(p_token text, p_url text, p_qty int, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_url text := btrim(coalesce(p_url,'')); v_note text := nullif(btrim(coalesce(p_note,'')), '');
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if v_url !~* '^https?://[^ ]+$' then raise exception '상품 링크를 https:// 로 시작하는 주소로 넣어 주세요'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 999 then raise exception '수량은 1~999 사이로 넣어 주세요'; end if;
  insert into public.purchase_requests (url, store, qty, note)
    values (v_url, public._purchase_store(v_url), p_qty, left(v_note, 300))
    returning id into v_id;
  return v_id;
end;
$$;

-- 상태 변경 (진행중 / 구매완료 / 반려)
create or replace function public.staff_purchase_set_status(p_token text, p_id uuid, p_status text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if p_status not in ('requested','bought','rejected') then raise exception '알 수 없는 상태입니다'; end if;
  update public.purchase_requests
     set status = p_status, status_at = case when p_status = 'requested' then null else now() end
   where id = p_id;
  return found;
end;
$$;

-- 삭제
create or replace function public.staff_purchase_delete(p_token text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  delete from public.purchase_requests where id = p_id;
  return found;
end;
$$;

revoke all on function public._purchase_store(text) from public, anon, authenticated;
revoke all on function public.staff_purchase_list(text) from public;
revoke all on function public.staff_purchase_add(text,text,int,text) from public;
revoke all on function public.staff_purchase_set_status(text,uuid,text) from public;
revoke all on function public.staff_purchase_delete(text,uuid) from public;
grant execute on function public.staff_purchase_list(text) to anon, authenticated;
grant execute on function public.staff_purchase_add(text,text,int,text) to anon, authenticated;
grant execute on function public.staff_purchase_set_status(text,uuid,text) to anon, authenticated;
grant execute on function public.staff_purchase_delete(text,uuid) to anon, authenticated;
