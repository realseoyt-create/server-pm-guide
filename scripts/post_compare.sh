#!/bin/bash
# ============================================================
# post_compare.sh - 작업 전후 상태 비교 리포트
# 실행 시점: 서비스 기동 완료 후
# 의존: pre_snapshot.sh 가 먼저 실행되어 /tmp/snapshot_before/ 가 있어야 함
# ============================================================

BEFORE_DIR=/tmp/snapshot_before
AFTER_DIR=/tmp/snapshot_after
REPORT=/tmp/compare_report_$(date +%Y%m%d_%H%M%S).txt

mkdir -p "$AFTER_DIR"

echo "================================================" | tee "$REPORT"
echo " 전후 비교 리포트: $(date)" | tee -a "$REPORT"
echo " 서버: $(hostname)" | tee -a "$REPORT"
echo "================================================" | tee -a "$REPORT"

# 전 스냅샷 존재 확인
if [ ! -d "$BEFORE_DIR" ]; then
    echo "❌ 사전 스냅샷 없음: $BEFORE_DIR" | tee -a "$REPORT"
    echo "   pre_snapshot.sh 를 먼저 실행해야 합니다." | tee -a "$REPORT"
    exit 1
fi

OK()     { echo "✅ $*" | tee -a "$REPORT"; }
WARN()   { echo "⚠️  $*" | tee -a "$REPORT"; }
ERR()    { echo "❌ $*" | tee -a "$REPORT"; }
SECTION(){ echo "" | tee -a "$REPORT"; echo "===== $* =====" | tee -a "$REPORT"; }

# ─── 1. 프로세스 비교 ────────────────────────────────────────
SECTION "1. 프로세스 비교"
ps -ef --forest > "$AFTER_DIR/process_after.txt"

# 주요 프로세스 기동 여부 확인
for PROC in pmon rvd crond; do
    BEFORE=$(grep -c "$PROC" "$BEFORE_DIR/process_before.txt" 2>/dev/null || echo 0)
    AFTER=$(ps -ef | grep "$PROC" | grep -v grep | wc -l)
    echo "  [$PROC] 작업 전: ${BEFORE}개 → 작업 후: ${AFTER}개" | tee -a "$REPORT"
    if [ "$AFTER" -gt 0 ]; then
        OK "[$PROC] 기동 확인"
    else
        ERR "[$PROC] 미기동 - 확인 필요"
    fi
done

# 예상치 못한 새 프로세스 확인 (시스템 프로세스 제외)
echo "" | tee -a "$REPORT"
echo "  [작업 후 새로 생긴 주요 프로세스 (참고)]" | tee -a "$REPORT"
diff <(awk '{print $8}' "$BEFORE_DIR/process_before.txt" | sort -u) \
     <(awk '{print $8}' "$AFTER_DIR/process_after.txt" | sort -u) \
     | grep "^>" | grep -v -E "^> $|kworker|migration|rcu|watchdog" \
     | head -10 | tee -a "$REPORT"

# ─── 2. 포트 비교 ────────────────────────────────────────────
SECTION "2. 리스닝 포트 비교"
ss -tlnp > "$AFTER_DIR/ports_after.txt"

# 주요 포트 확인
for PORT in 1621; do
    BEFORE_HAS=$(grep ":$PORT" "$BEFORE_DIR/ports_before.txt" 2>/dev/null | wc -l)
    AFTER_HAS=$(ss -tlnp | grep ":$PORT" | wc -l)
    if [ "$AFTER_HAS" -gt 0 ]; then
        OK "포트 $PORT 오픈 확인"
    else
        ERR "포트 $PORT 닫힘 - Oracle Listener 확인 필요"
    fi
done

# 작업 전 있었는데 지금 없는 포트
echo "" | tee -a "$REPORT"
echo "  [작업 전 있었으나 현재 없는 포트]" | tee -a "$REPORT"
diff <(awk '{print $4}' "$BEFORE_DIR/ports_before.txt" | sort) \
     <(awk '{print $4}' "$AFTER_DIR/ports_after.txt" | sort) \
     | grep "^<" | head -10 | tee -a "$REPORT"

# ─── 3. 디스크 비교 ──────────────────────────────────────────
SECTION "3. 디스크 사용률 비교"
df -h > "$AFTER_DIR/disk_after.txt"

echo "  파티션           | 작업 전 | 작업 후 | 변화" | tee -a "$REPORT"
echo "  ─────────────────────────────────────────────" | tee -a "$REPORT"

while read -r line; do
    MOUNT=$(echo "$line" | awk '{print $6}')
    AFTER_PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
    BEFORE_LINE=$(grep " $MOUNT$" "$BEFORE_DIR/disk_before.txt" 2>/dev/null)
    BEFORE_PCT=$(echo "$BEFORE_LINE" | awk '{print $5}' | tr -d '%')

    if [ -n "$BEFORE_PCT" ] && [ -n "$AFTER_PCT" ]; then
        DIFF=$((AFTER_PCT - BEFORE_PCT))
        DIFF_STR=""
        [ "$DIFF" -gt 0 ] && DIFF_STR="+$DIFF%" || DIFF_STR="${DIFF}%"
        printf "  %-20s | %6s%% | %6s%% | %s\n" "$MOUNT" "$BEFORE_PCT" "$AFTER_PCT" "$DIFF_STR" | tee -a "$REPORT"
        [ "$AFTER_PCT" -ge 80 ] && WARN "$MOUNT 사용률 ${AFTER_PCT}% - 정리 필요"
    fi
done < <(df -h | awk 'NR>1')

# ─── 4. Cron 비교 ────────────────────────────────────────────
SECTION "4. Cron 등록 내용 비교"

CURRENT_CRON="$AFTER_DIR/crontab_after.txt"
for user in $(getent passwd | cut -d: -f1); do
    CRON=$(crontab -l -u "$user" 2>/dev/null)
    [ -n "$CRON" ] && echo "### $user ###" >> "$CURRENT_CRON" && echo "$CRON" >> "$CURRENT_CRON"
done

CRON_BEFORE="$BEFORE_DIR/crontab_before.txt"
if [ -f "$CRON_BEFORE" ]; then
    CRON_DIFF=$(diff "$CRON_BEFORE" "$CURRENT_CRON" 2>/dev/null)
    if [ -z "$CRON_DIFF" ]; then
        OK "Cron 내용 작업 전과 동일 (변경 없음)"
    else
        ERR "Cron 내용 차이 발견!"
        echo "  (< 작업 전, > 작업 후)" | tee -a "$REPORT"
        echo "$CRON_DIFF" | head -30 | tee -a "$REPORT"
        echo "  → 누락된 항목이 있으면 수동으로 복구 필요" | tee -a "$REPORT"
    fi
else
    WARN "작업 전 Cron 백업 파일 없음: $CRON_BEFORE"
fi

# ─── 5. VIP 위치 확인 ────────────────────────────────────────
SECTION "5. VIP 현황"

ip addr show > "$AFTER_DIR/ip_after.txt"

for VIP_ADDR in "12.230.210.207" "12.230.210.203"; do
    VIP_NAME=""
    [ "$VIP_ADDR" = "12.230.210.207" ] && VIP_NAME="PJTSAP"
    [ "$VIP_ADDR" = "12.230.210.203" ] && VIP_NAME="PJTSEC"

    BEFORE_HAS=$(grep -c "$VIP_ADDR" "$BEFORE_DIR/ip_before.txt" 2>/dev/null || echo 0)
    AFTER_HAS=$(ip addr show | grep -c "$VIP_ADDR" || echo 0)

    echo "  [$VIP_NAME VIP: $VIP_ADDR]" | tee -a "$REPORT"
    echo "    작업 전 보유: $([ $BEFORE_HAS -gt 0 ] && echo '이 서버' || echo '다른 서버')" | tee -a "$REPORT"
    echo "    작업 후 보유: $([ $AFTER_HAS -gt 0 ] && echo '이 서버' || echo '다른 서버')" | tee -a "$REPORT"
done

# ─── 6. Oracle 최종 상태 ─────────────────────────────────────
SECTION "6. Oracle DB 최종 상태"

if ps -ef | grep pmon | grep -v grep > /dev/null 2>&1; then
    su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'INSTANCE STATUS: '||STATUS FROM V\\\$INSTANCE;
SELECT 'DB OPEN_MODE: '||OPEN_MODE FROM V\\\$DATABASE;
SELECT 'LISTENER PORT: 1621' FROM DUAL;
EXIT;
EOF
" 2>/dev/null | tee -a "$REPORT"

    # PJOSCD 서비스 등록 확인
    su - oracle -c "lsnrctl status" 2>/dev/null | grep -q "PJOSCD" \
        && OK "PJOSCD 서비스 Listener 등록 확인" \
        || ERR "PJOSCD 서비스 미등록 - ALTER SYSTEM REGISTER 실행 필요"

    # Data Guard 동기화 lag 확인
    echo "" | tee -a "$REPORT"
    echo "  [Data Guard 동기화 상태]" | tee -a "$REPORT"
    su - oracle -c "
sqlplus -S / as sysdba <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT NAME||': '||VALUE FROM V\\\$DATAGUARD_STATS
WHERE NAME IN ('transport lag','apply lag');
EXIT;
EOF
" 2>/dev/null | tee -a "$REPORT"
else
    ERR "Oracle pmon 없음 - DB 미기동 상태"
fi

# ─── 최종 요약 ───────────────────────────────────────────────
echo "" | tee -a "$REPORT"
echo "================================================" | tee -a "$REPORT"
echo " 전후 비교 완료: $(date)" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

WARN_COUNT=$(grep -c "^⚠️" "$REPORT" 2>/dev/null || echo 0)
ERR_COUNT=$(grep -c "^❌" "$REPORT" 2>/dev/null || echo 0)
OK_COUNT=$(grep -c "^✅" "$REPORT" 2>/dev/null || echo 0)

echo " 결과 요약:" | tee -a "$REPORT"
echo "   ✅ 정상: ${OK_COUNT}건" | tee -a "$REPORT"
echo "   ⚠️  경고: ${WARN_COUNT}건" | tee -a "$REPORT"
echo "   ❌ 오류: ${ERR_COUNT}건" | tee -a "$REPORT"
echo "================================================" | tee -a "$REPORT"

echo ""
echo "✅ post_compare.sh 완료"
echo "   리포트: $REPORT"
[ "$ERR_COUNT" -gt 0 ] && echo "   ❌ 오류 ${ERR_COUNT}건 발견 - 리포트 확인 필요" && exit 1
[ "$WARN_COUNT" -gt 0 ] && echo "   ⚠️  경고 ${WARN_COUNT}건 - 리포트 확인 권장"
exit 0
