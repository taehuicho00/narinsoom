"""신비서 방막기 메모에서 손님 정보를 뽑습니다.

규칙 (사장님과 정한 것)
- 메모에 전화번호가 있으면 손님 예약으로 가져옴 (없으면 휴무·판매중지로 보고 무시)
- 전화번호와 인원수(4명·7인)만 뽑고, 결제 등 특이사항은 해석하지 않고 메모 원문 그대로 둠
- 같은 객실에 같은 메모가 연속된 날짜면 연박으로 묶음
- 방막기 손님은 추가요금 자동 문자 대상에서 제외
"""
import re
from datetime import date, timedelta


def phone(memo):
    """'+82 10-1234-5678', '010-1234-5678' → '010-1234-5678'"""
    m = re.search(r"(\+?82[\s-]?1\d|01\d)[\s-]?\d{3,4}[\s-]?\d{4}", memo)
    if not m:
        return None
    d = re.sub(r"\D", "", m.group(0))
    if d.startswith("82"):
        d = "0" + d[2:]
    return f"{d[:3]}-{d[3:-4]}-{d[-4:]}"


def people(memo):
    """'4명', '7인' → 4, 7 (없으면 None)"""
    # 전화번호 숫자를 먼저 지우고, '인원'의 '인'은 인원수로 보지 않음
    text = re.sub(r"(\+?82[\s-]?1\d|01\d)[\s-]?\d{3,4}[\s-]?\d{4}", " ", memo)
    m = re.search(r"(?<!\d)(\d{1,2})\s*(명|인(?!원))", text)
    return int(m.group(1)) if m else None


def name(memo):
    """메모 맨 앞의 한글 이름 (없으면 None)"""
    m = re.match(r"\s*([가-힣]{2,4})(?=\s|/|$)", memo)
    return m.group(1) if m else None


def group_stays(blocks):
    """blocks: [{date, room, reason}] → 연박을 묶은 손님 목록"""
    out = []
    guests = (b for b in blocks if b["reason"] and phone(b["reason"]))
    for b in sorted(guests, key=lambda b: (b["room"], b["date"])):
        prev = out[-1] if out else None
        d = date.fromisoformat(b["date"])
        if (prev and prev["room"] == b["room"] and prev["memo"] == b["reason"]
                and date.fromisoformat(prev["checkin"]) + timedelta(days=prev["nights"]) == d):
            prev["nights"] += 1
            continue
        out.append({"room": b["room"], "checkin": b["date"], "nights": 1, "memo": b["reason"],
                    "phone": phone(b["reason"]), "people": people(b["reason"]), "name": name(b["reason"])})
    return out


if __name__ == "__main__":  # 점검용 (가짜 데이터)
    for t in ["+82 10-0000-1111 / 4명 / 숯불 지급 완료", "홍길동 010-0000-2222 인원추가·숯불 미결제",
              "김철수 / +82 10-0000-3333 / 7인 예약 완료 / 숯불 미지급", "ㅇㅃㅇㅊ", ""]:
        print(repr(t), "→", name(t), phone(t), people(t))
    print(group_stays([
        {"date": "2026-01-10", "room": "별채", "reason": "홍길동 010-0000-2222 2박"},
        {"date": "2026-01-11", "room": "별채", "reason": "홍길동 010-0000-2222 2박"},
        {"date": "2026-01-10", "room": "2호실", "reason": ""},
    ]))
