-- 반려된 구매요청을 수정해서 다시 신청
--  · 같은 요청을 고쳐서 '진행중'으로 되돌림 (새 줄을 만들지 않아 목록이 중복되지 않음)
--  · 이전 반려 사유는 남겨 두고 재신청 시각 기록 → 사장이 무엇이 바뀌었는지 알 수 있음
alter table public.purchase_requests add column if not exists resubmitted_at timestamptz;

create or replace function public.staff_purchase_resubmit(p_token text, p_id uuid, p_item text, p_url text, p_qty int, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
declare v_item text := btrim(coalesce(p_item,'')); v_url text := btrim(coalesce(p_url,'')); v_note text := nullif(btrim(coalesce(p_note,'')), '');
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if v_item = '' then raise exception '상품명을 적어 주세요'; end if;
  if v_url !~* '^https?://[^ ]+$' then raise exception '상품 링크를 https:// 로 시작하는 주소로 넣어 주세요'; end if;
  if p_qty is null or p_qty < 1 or p_qty > 999 then raise exception '수량은 1~999 사이로 넣어 주세요'; end if;
  update public.purchase_requests
     set item = left(v_item, 80), url = v_url, store = public._purchase_store(v_url), qty = p_qty,
         note = left(v_note, 300), status = 'requested', status_at = null, resubmitted_at = now()
   where id = p_id and status = 'rejected';
  if not found then raise exception '반려된 요청만 다시 신청할 수 있습니다'; end if;
  return true;
end;
$$;

-- 반려 사유는 반려·재신청(진행중) 때만 유지, 구매완료나 '되돌리기'로 진행중이 되면 지움
create or replace function public.staff_purchase_set_status(p_token text, p_id uuid, p_status text, p_reason text default null) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if p_status not in ('requested','bought','rejected') then raise exception '알 수 없는 상태입니다'; end if;
  update public.purchase_requests
     set status = p_status,
         status_at = case when p_status = 'requested' then null else now() end,
         reject_reason = case when p_status = 'rejected' then left(nullif(btrim(coalesce(p_reason,'')), ''), 200) end,
         resubmitted_at = case when p_status = 'requested' then null else resubmitted_at end
   where id = p_id;
  return found;
end;
$$;

create or replace function public.staff_purchase_list(p_token text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return (
    select coalesce(json_agg(x order by x.created_at desc), '[]'::json) from (
      select id, item, url, store, qty, note, status, reject_reason, created_at, status_at, resubmitted_at
      from public.purchase_requests
      where status = 'requested' or coalesce(resubmitted_at, created_at) > now() - interval '90 days'
      order by created_at desc
      limit 500) x);
end;
$$;

revoke all on function public.staff_purchase_resubmit(text,uuid,text,text,int,text) from public;
grant execute on function public.staff_purchase_resubmit(text,uuid,text,text,int,text) to anon, authenticated;
