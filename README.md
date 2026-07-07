# 서버 PM 및 Failover 테스트 가이드

> **PM 일정**: 2025년 7월 13일 (일) 오후 13:00 ~ 17:00
>
> 본 문서는 이 작업을 처음 수행하는 담당자도 이 문서만 보고 안전하게 진행할 수 있도록 작성되었습니다.

---

## 대상 서버

| 서버 | VIP | Real IP | OS | DB | Service | Port |
|------|-----|---------|----|----|---------|------|
| **PJTSAP** | 12.230.210.207 | 12.230.210.205 / .206 | RHEL 8.10 (64bit) | Oracle 19C | PJOSCD | 1621 |
| **PJTSEC** | 12.230.210.203 | 12.230.210.201 / .202 | RHEL 8.10 (64bit) | Oracle 19C | PJOSCD | 1621 |

- 제조사: Dell
- 미들웨어: RVD (TIBCO Rendezvous Daemon)
- HA 구성: VIP 기반 Failover

---

## 전체 작업 구조

```
[PRE 시나리오]  D-14 ~ D-1
  계획정전 공지 → 시나리오 초안 → 각종 리스트 점검 → 외부 공지 → CAB 확정

[MAIN 시나리오]  D-Day (7/13 13:00~17:00)
  작업 전 준비 → 서버 작업 (Failover 테스트) → 복구 확인

[POST 시나리오]  작업 완료 후
  데이터 점검 → Post-Mortem → 보고서
```

---

## 문서 목록

| 파일 | 내용 | 시점 |
|------|------|------|
| [01_PRE_시나리오.md](01_PRE_시나리오.md) | 사전 준비 전체 절차 + 각종 리스트 점검 방법 | D-14 ~ D-1 |
| [02_CAB_회의_초안.md](02_CAB_회의_초안.md) | CAB 제출용 작업계획서 | D-3 |
| [03_MAIN_시나리오.md](03_MAIN_시나리오.md) | 작업 당일 단계별 절차 | D-Day |
| [04_POST_시나리오.md](04_POST_시나리오.md) | 데이터 점검 및 Post-Mortem | 완료 후 |
| [05_체크리스트.md](05_체크리스트.md) | Pre/Main/Post 전체 체크리스트 | 전체 |
| [06_이메일_템플릿.md](06_이메일_템플릿.md) | 공지/협조요청/완료 메일 | 각 시점 |
| [07_작업후_보고서_템플릿.md](07_작업후_보고서_템플릿.md) | 결과 보고서 양식 | 완료 후 |
| [scripts/](scripts/) | 자동화 스크립트 모음 | 작업 당일 |

---

## 자동화 스크립트 목록

| 스크립트 | 용도 | 실행 시점 |
|----------|------|-----------|
| [scripts/pre_snapshot.sh](scripts/pre_snapshot.sh) | 작업 전 전체 상태 스냅샷 수집 | 작업 시작 직전 |
| [scripts/stop_services.sh](scripts/stop_services.sh) | RVD → Oracle 순차 중지 | 작업 중 |
| [scripts/start_services.sh](scripts/start_services.sh) | Oracle → RVD → Cron 순차 기동 | 복구 시 |
| [scripts/post_compare.sh](scripts/post_compare.sh) | 작업 전후 상태 비교 리포트 | 작업 완료 후 |
| [scripts/check_oracle.sh](scripts/check_oracle.sh) | Oracle 상태 종합 점검 | 기동 확인 시 |
| [scripts/check_rvd.sh](scripts/check_rvd.sh) | RVD 상태 점검 | 기동 확인 시 |

---

## ⚠️ 절대 놓치면 안 되는 핵심

> 🔴 **1. Oracle Listener 포트 1621 확인** — 표준 1521이 아님. 기동 후 반드시 1621 포트 확인
>
> 🔴 **2. Cron 재활성화 확인** — 작업 후 복구 시 가장 많이 빠뜨리는 항목
>
> 🔴 **3. DB 동기화 재개 확인** — 양 서버(PJTSAP/PJTSEC) 모두 동기화 상태 확인
>
> 🔴 **4. RVD 기동 순서** — Oracle 완전 기동 후 RVD 기동. 역순 금지
