-- 구매요청 반려 사유 (선택 입력)
--  · 반려할 때만 저장, 진행중으로 되돌리면 지움
--  · p_reason 은 기본값 null → 사유 없이 부르는 예전 화면도 그대로 동작
alter table public.purchase_requests
  add column if not exists reject_reason text check (reject_reason is null or length(reject_reason) <= 200);

drop function if exists public.staff_purchase_set_status(text,uuid,text);

create or replace function public.staff_purchase_set_status(p_token text, p_id uuid, p_status text, p_reason text default null) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  if p_status not in ('requested','bought','rejected') then raise exception '알 수 없는 상태입니다'; end if;
  update public.purchase_requests
     set status = p_status,
         status_at = case when p_status = 'requested' then null else now() end,
         reject_reason = case when p_status = 'rejected' then left(nullif(btrim(coalesce(p_reason,'')), ''), 200) end
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
      select id, item, url, store, qty, note, status, reject_reason, created_at, status_at
      from public.purchase_requests
      where status = 'requested' or created_at > now() - interval '90 days'
      order by created_at desc
      limit 500) x);
end;
$$;

revoke all on function public.staff_purchase_set_status(text,uuid,text,text) from public;
grant execute on function public.staff_purchase_set_status(text,uuid,text,text) to anon, authenticated;
