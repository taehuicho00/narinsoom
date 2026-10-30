-- 고객요청 메모의 연락처를 1순위로 (대신 예약해 주는 경우)
--  · contact_source: 'memo' = 신비서 고객요청 메모에서 자동 / 'manual' = 사장님이 직접 지정 (동기화가 덮어쓰지 않음)
--  · 받는 순서: 지정 연락처(메모·사장님) > 손님이 링크에서 준 번호 > 신비서 예약자 번호
alter table public.reservations add column if not exists contact_source text
  check (contact_source in ('memo','manual'));

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
      contact_phone  = case when contact_source = 'manual' then contact_phone else r->>'contact_phone' end,
      contact_name   = case when contact_source = 'manual' then contact_name  else r->>'contact_name'  end,
      contact_source = case when contact_source = 'manual' then 'manual'
                            when r->>'contact_phone' is not null then 'memo' end,
      status = 'active', synced_at = now()
    where pms_id = r->>'pms_id'
    returning id into v_id;
    if v_id is null then
      insert into public.reservations (pms_id, code, source, room, checkin, nights, guest_name, pms_phone,
        need_phone, pms_memo, memo_people, memo_pets, bbq_prepaid, synced_at,
        contact_phone, contact_name, contact_source)
      values (r->>'pms_id', public._new_code(), coalesce(r->>'source','pms'), r->>'room', (r->>'checkin')::date,
        (r->>'nights')::int, r->>'guest_name', r->>'pms_phone', (r->>'need_phone')::boolean, r->>'pms_memo',
        (r->>'memo_people')::int, (r->>'memo_pets')::int, coalesce((r->>'bbq_prepaid')::boolean, false), now(),
        r->>'contact_phone', r->>'contact_name', case when r->>'contact_phone' is not null then 'memo' end);
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
