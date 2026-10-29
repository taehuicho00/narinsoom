"""신비서 예약 목록(표 행)을 Supabase reservations 표에 넣는 SQL로 바꿉니다.

입력: 예약 목록 표의 각 행 [예약번호, 예약자정보, 객실명, 체크인, 체크아웃, 채널, 메모, 상태, 금액]
- 예약완료만 넣고, 같은 예약번호(pms_id)가 이미 있으면 정보만 갱신 (링크 코드는 유지)
- 050 안심번호이거나 번호가 없으면 need_phone = true (손님 화면에서 번호를 받음)
- 이름은 직원 화면용으로 가운데를 가림 (강병창 → 강*창)
"""
import json, re, secrets, sys
from datetime import date

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # 헷갈리는 0/O, 1/I 제외

def new_code(n=8):
    return "".join(secrets.choice(ALPHABET) for _ in range(n))

def room_name(full):
    m = re.match(r"\s*(\d호실|별채)", full)
    return m.group(1) if m else None

def mask(name):
    name = re.sub(r"\(.*?\)", "", name).strip()
    if len(name) <= 1: return name
    if len(name) == 2: return name[0] + "*"
    return name[0] + "*" * (len(name) - 2) + name[-1]

def phone(raw):
    """실번호면 010-xxxx-xxxx 형식으로, 안심번호·없음이면 None"""
    d = re.sub(r"\D", "", raw or "")
    if d.startswith("82"): d = "0" + d[2:]          # 해외채널: 8210... → 010...
    if d.startswith("050") or len(d) < 10: return None
    if d.startswith("01") and len(d) in (10, 11):
        return f"{d[:3]}-{d[3:-4]}-{d[-4:]}"
    return None

def q(v):
    return "null" if v is None else "'" + str(v).replace("'", "''") + "'"

def to_sql(rows):
    vals = []
    for r in rows:
        if "예약완료" not in r[7]: continue
        room = room_name(r[2])
        if not room: continue
        name, _, ph = r[1].partition(" · ")
        nights = max(1, (date.fromisoformat(r[4]) - date.fromisoformat(r[3])).days)
        memo = None if r[6].strip() in ("", "-") else r[6].strip()
        p = phone(ph)
        vals.append(f"({q(r[0])}, {q(new_code())}, {q(room)}, {q(r[3])}, {nights}, {q(mask(name))}, "
                    f"{q(r[5].split(' · ')[0])}, {q(p)}, {str(p is None).lower()}, {q(memo)})")
    return ("insert into public.reservations (pms_id, code, room, checkin, nights, guest_name, channel, pms_phone, need_phone, pms_memo) values\n  "
            + ",\n  ".join(vals) +
            "\non conflict (pms_id) do update set room = excluded.room, checkin = excluded.checkin, nights = excluded.nights,\n"
            "  guest_name = excluded.guest_name, channel = excluded.channel, pms_phone = excluded.pms_phone,\n"
            "  need_phone = excluded.need_phone, pms_memo = excluded.pms_memo;"), len(vals)

if __name__ == "__main__":
    sql, n = to_sql(json.load(open(sys.argv[1])))
    print(sql); print(f"-- {n}건", file=sys.stderr)
