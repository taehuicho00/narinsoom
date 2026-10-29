-- 직원 대리 입력·추가요금 문자 보류
--  · fee_hold: 직원 화면에서 '보류'를 누르면 20시 추가요금 자동 문자에서 제외
--  · staff_week 에 code(대리 입력 링크용), fee_hold 추가
alter table public.reservations add column if not exists fee_hold boolean not null default false;

create or replace function public.staff_week(p_token text, p_from date, p_to date) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  return json_build_object(
    'rooms', (select coalesce(json_agg(r), '[]'::json) from public.rooms r),
    'reservations', (
      select coalesce(json_agg(x order by x.checkin), '[]'::json) from (
        select v.id, v.code, v.room, v.checkin, v.nights, v.guest_name, v.pms_phone,
               v.need_phone, v.paid, v.fee_hold, v.pms_memo,
               (select row_to_json(s) from (
                  select people, pets, checkin_time, bbq_time, memo, phone
                  from public.responses where reservation_id = v.id) s) as response
        from public.reservations v
        where v.checkin between p_from and p_to) x));
end;
$$;

create or replace function public.staff_set_hold(p_token text, p_id uuid, p_hold boolean) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public._staff_token_ok(p_token) then raise exception 'invalid_token'; end if;
  update public.reservations set fee_hold = coalesce(p_hold,false) where id = p_id;
  return found;
end;
$$;
revoke all on function public.staff_set_hold(text,uuid,boolean) from public;
grant execute on function public.staff_set_hold(text,uuid,boolean) to anon, authenticated;
