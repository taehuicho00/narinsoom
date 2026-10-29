"""신비서 방막기 메모에서 손님 정보를 뽑습니다.

규칙 (사장님과 정한 것)
- 메모에 전화번호가 있으면 손님 예약으로 가져옴 (없으면 휴무·판매중지로 보고 무시)
- 확실히 적힌 정보만 데이터로 넣음: 전화번호, 인원(4명·7인), 반려견(N마리), 숯불 결제 완료 여부
  숫자가 없는 표현(인원추가, +애견)은 추측하지 않고 비워 둠. 메모 원문도 그대로 보관
- 같은 객실에 같은 메모가 연속된 날짜면 연박으로 묶음
- 방막기 손님은 추가요금 자동 문자 대상에서 제외
"""
import re
from datetime import date, timedelta

NO_PET_ROOMS = {"1호실", "별채"}  # 반려견 불가 객실은 메모와 상관없이 0마리


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


def pets(memo):
    """'애견 2마리', '반려견 1마리' → 2, 1. 숫자가 없으면(예: '+애견') 추측하지 않고 None"""
    m = re.search(r"(애견|반려견|강아지)\s*(\d)\s*마리", memo)
    return int(m.group(2)) if m else None


def bbq_prepaid(memo):
    """'숯불 지급 완료', '숯불 결제완료' → True. '미지급·미결제'면 False"""
    if re.search(r"숯불[^/]*미(지급|결제|지불|입금)", memo):
        return False
    return bool(re.search(r"숯불\s*(지급|결제|입금)?\s*완료", memo))


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
                    "phone": phone(b["reason"]), "people": people(b["reason"]), "name": name(b["reason"]),
                    "pets": 0 if b["room"] in NO_PET_ROOMS else pets(b["reason"]),
                    "bbq_prepaid": bbq_prepaid(b["reason"])})
    return out


if __name__ == "__main__":  # 점검용 (가짜 데이터)
    for t in ["+82 10-0000-1111 / 4명 / 숯불 지급 완료", "홍길동 010-0000-2222 인원추가·숯불 미결제",
              "김철수 / +82 10-0000-3333 / 7인 예약 완료 / 숯불 미지급", "010-0000-4444 / 5인 +애견 / 숯불,애견 미지불",
              "010-0000-5555 2인 애견 2마리 숯불결제완료", "ㅇㅃㅇㅊ", ""]:
        print(repr(t), "→", name(t), phone(t), people(t), pets(t), bbq_prepaid(t))
    print(group_stays([
        {"date": "2026-01-10", "room": "별채", "reason": "홍길동 010-0000-2222 2박"},
        {"date": "2026-01-11", "room": "별채", "reason": "홍길동 010-0000-2222 2박"},
        {"date": "2026-01-10", "room": "2호실", "reason": ""},
    ]))
