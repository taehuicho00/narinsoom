-- 2026-11-27 주인님 결정: 1호실도 반려견 동반 가능 (최대 4마리, 1마리당 20,000원)
update public.rooms set max_pets = 4 where name = '1호실';
