-- ============================================================
-- 간이영수증 발행 내역
--  · 직원 화면에서 영수증 이미지를 만들 때마다 한 줄 기록
--  · 직원 화면과 같은 4자리 비밀번호 토큰으로만 접근 (표 직접 접근 불가)
--  · 품목·합계는 서버에서 다시 검증·계산
-- ============================================================

create table if not exists public.receipts (
  id         uuid primary key default gen_random_uuid(),
  no         bigint generated always as identity,
  to_name    text check (to_name is null or length(to_name) <= 30),
  issue_date date not null,
  items      jsonb not null,           -- [{name, price, memo}]
  total      int  not null check (total > 0),
  created_at timestamptz not null default now()
);
alter table public.receipts enable row level security;
-- 정책 없음 = 아래 함수 밖에서는 아무도 접근 불가

-- 목록: 최근 1년, 최대 300건
create or replace function public.staff_receipt_list(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return (
    select coalesce(json_agg(x order by x.no desc), '[]'::json) from (
      select id, no, to_name, issue_date, items, total, created_at
      from public.receipts
      where created_at > now() - interval '365 days'
      order by no desc
      limit 300) x);
end;
$$;

-- 발행 기록 추가 → {id, no}
create or replace function public.staff_receipt_add(p_token text, p_to text, p_date date, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare
  v_items jsonb := '[]'::jsonb; v_total int := 0; e jsonb; v_price int; v_id uuid; v_no bigint;
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if p_date is null then raise exception '작성일을 넣어 주세요'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 10 then
    raise exception '품목 금액을 하나 이상 입력해 주세요';
  end if;
  for e in select * from jsonb_array_elements(p_items) loop
    if coalesce(e->>'name','') not in ('숙박','추가인원','애견동반','숯/그릴') then raise exception '알 수 없는 품목입니다'; end if;
    v_price := (e->>'price')::int;
    if v_price is null or v_price < 1 or v_price > 100000000 then raise exception '금액을 확인해 주세요'; end if;
    v_items := v_items || jsonb_build_object('name', e->>'name', 'price', v_price,
                                             'memo', left(btrim(coalesce(e->>'memo','')), 20));
    v_total := v_total + v_price;
  end loop;
  insert into public.receipts (to_name, issue_date, items, total)
    values (left(nullif(btrim(coalesce(p_to,'')), ''), 30), p_date, v_items, v_total)
    returning id, no into v_id, v_no;
  return json_build_object('id', v_id, 'no', v_no);
end;
$$;

-- 삭제
create or replace function public.staff_receipt_delete(p_token text, p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  delete from public.receipts where id = p_id;
  return found;
end;
$$;

revoke all on function public.staff_receipt_list(text) from public;
revoke all on function public.staff_receipt_add(text,text,date,jsonb) from public;
revoke all on function public.staff_receipt_delete(text,uuid) from public;
grant execute on function public.staff_receipt_list(text) to anon, authenticated;
grant execute on function public.staff_receipt_add(text,text,date,jsonb) to anon, authenticated;
grant execute on function public.staff_receipt_delete(text,uuid) to anon, authenticated;
