-- 구매요청에 상품명 추가 (필수 입력, 기존 요청은 비어 있음)
alter table public.purchase_requests
  add column if not exists item text check (item is null or length(item) <= 80);

drop function if exists public.staff_purchase_add(text,text,int,text);

create or replace function public.staff_purchase_add(p_token text, p_item text, p_url text, p_qty int, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_item text := btrim(coalesce(p_item,'')); v_url text := btrim(coalesce(p_url,'')); v_note text := nullif(btrim(coalesce(p_note,'')), '');
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if v_item = '' then raise exception '상품명을 적어 주세요'; end if;
  if v_url !~* '^https?://[^ ]+$' then raise exception '상품 링크를 https:// 로 시작하는 주소로 넣어 주세요'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 999 then raise exception '수량은 1~999 사이로 넣어 주세요'; end if;
  insert into public.purchase_requests (item, url, store, qty, note)
    values (left(v_item, 80), v_url, public._purchase_store(v_url), p_qty, left(v_note, 300))
    returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.staff_purchase_list(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return (
    select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
      select id, item, url, store, qty, note, status, created_at, status_at
      from public.purchase_requests
      where status = 'requested' or created_at > now() - interval '90 days'
      order by created_at desc
      limit 500) x);
end;
$$;

revoke all on function public.staff_purchase_add(text,text,text,int,text) from public;
grant execute on function public.staff_purchase_add(text,text,text,int,text) to anon, authenticated;
