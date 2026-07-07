# 04. POST 시나리오 (작업 완료 후)

> **수행 시점**: 작업 완료 직후 ~ 익일 오전

---

## 1. 각 시스템별 데이터 점검

### 1-1. Oracle DB 데이터 점검

```bash
su - oracle

sqlplus / as sysdba <<EOF
-- DB 상태 최종 확인
SELECT STATUS FROM V\$INSTANCE;
SELECT NAME, OPEN_MODE FROM V\$DATABASE;

-- Tablespace 사용률 이상 없는지
SELECT ts.tablespace_name,
       ROUND((1 - NVL(fs.bytes,0)/ts.bytes)*100, 1) AS "사용률(%)"
FROM (SELECT tablespace_name, SUM(bytes) bytes FROM dba_data_files GROUP BY tablespace_name) ts,
     (SELECT tablespace_name, SUM(bytes) bytes FROM dba_free_space GROUP BY tablespace_name) fs
WHERE ts.tablespace_name = fs.tablespace_name(+)
ORDER BY 2 DESC;

-- 작업 후 새로운 ORA- 에러 없는지 (Alert Log 대신 SQL로 확인)
SELECT ORIGINATING_TIMESTAMP, MESSAGE_TEXT
FROM V\$DIAG_ALERT_EXT
WHERE MESSAGE_TEXT LIKE '%ORA-%'
  AND ORIGINATING_TIMESTAMP > SYSDATE - 1/24  -- 최근 1시간
ORDER BY ORIGINATING_TIMESTAMP DESC;

-- DB 동기화 상태 재확인
SELECT NAME, VALUE FROM V\$DATAGUARD_STATS
WHERE NAME IN ('transport lag', 'apply lag');
EXIT;
EOF
```

### 1-2. RVD 상태 점검

```bash
# RVD 프로세스 안정적으로 운영 중인지 (기동 후 10분 경과 후 재확인)
ps -ef | grep rvd | grep -v grep
ss -tlnp | grep "[RVD_PORT]"

# RVD 로그 에러 없는지
tail -50 /var/log/rvd.log | grep -i "error\|fail\|disconnect"
```

### 1-3. Cron 배치 정상 실행 확인

```bash
# Cron이 재활성화된 후 첫 배치가 정상 실행되었는지 확인
# (다음 배치 실행 예정 시간 이후에 확인)
journalctl -u crond --since "2025-07-13 17:00:00" | grep -E "CMD|error"

# 배치 실행 로그 확인 (경로는 환경마다 다름)
tail -50 /var/log/batch/*.log 2>/dev/null
```

### 1-4. 파일 인터페이스 정상 동작 확인

```bash
# 작업 완료 후 파일 인터페이스 정상 수신/발신 확인
# 최근 1시간 내 인터페이스 파일 처리 여부
find /[인터페이스경로] -mmin -60 -type f | wc -l
```

### 1-5. 전후 비교 리포트 최종 확인

```bash
# post_compare.sh 결과 재확인
cat /tmp/compare_report_*.txt

# 경고/불일치 항목 있으면 조치 후 재확인
```

---

## 2. Post-Mortem

> 작업 완료 후 **1~2일 이내** 팀 회의에서 수행.
> 목적: 이번 작업에서 배운 것을 정리하여 다음 PM을 더 잘하기 위함.

### 2-1. Post-Mortem 회의 아젠다

| # | 항목 | 내용 |
|---|------|------|
| 1 | 작업 결과 요약 | 계획 대비 실적, 소요 시간 비교 |
| 2 | 잘된 점 | 이번 작업에서 효과적이었던 부분 |
| 3 | 개선점 | 다음 작업 전까지 개선할 사항 |
| 4 | 이슈 분석 | 발생한 이슈의 근본 원인 및 재발 방지책 |
| 5 | 문서 업데이트 | 이번 경험을 반영하여 가이드 문서 업데이트 |
| 6 | 다음 PM 준비 사항 | 다음 작업 전에 미리 해야 할 것 |

### 2-2. Post-Mortem 기록 양식

```
=== Post-Mortem: 2025-07-13 서버 PM ===

작성일: 
작성자: 
참석자: 

[작업 결과]
- 계획 시간: 13:00~17:00 (4시간)
- 실제 소요: __:__~__:__ (__시간)
- Failover 소요 시간: __분
- 이슈 건수: __건

[잘된 점]
-
-

[개선점]
-
-

[이슈 및 근본 원인]
이슈 1:
  발생: 
  원인: 
  조치: 
  재발방지: 

[문서 업데이트 필요 항목]
-

[다음 PM 준비 사항]
-
```

---

## 3. 작업 후 보고서 작성

- **07_작업후_보고서_템플릿.md** 기반으로 작성
- 작업 당일 완료 후 또는 익일 오전까지 작성
- 승인자 결재 후 보관

---

## 4. 문서 업데이트

- 이번 작업에서 발견한 실제 경로, 포트, 계정명 등을 본 가이드에 반영
- Failover 스크립트 경로 등 파악된 정보 문서화
- 개선된 체크리스트 항목 반영
