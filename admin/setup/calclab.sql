-- 계산기연구소 (CalcLab) — 어드민 콘솔 연결 (rsscukpbsiiyfgbdfups 프로젝트, 멱등)
--
-- CalcLab 은 오늘하루·로또·한줄과 같은 Supabase 프로젝트를 쓴다. admin_users 화이트리스트는
-- oneulharu-lotto.sql 이 이미 만들었으므로 여기서는 RPC 만 추가한다.
--
-- 접근 모델 (CalcLab 세션과 합의, 2026-09-10):
--   cl_* 테이블에는 anon/authenticated 권한·정책을 일절 열지 않는다.
--   콘솔은 어드민 로그인 + 아래 SECURITY DEFINER 함수로만 읽고 쓴다.
--   함수마다 ① 첫 줄 admin_users 검사 ② REVOKE EXECUTE FROM PUBLIC, anon ③ search_path 고정.
--   DELETE 함수 없음 · read_at 은 앱 전용이라 건드리지 않음 · cl_ 외 테이블 접근 없음.
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_cl_inquiries(TEXT, TEXT, BOOLEAN, INT, INT);
--   DROP FUNCTION IF EXISTS public.admin_cl_reply(UUID, TEXT);
--   DROP FUNCTION IF EXISTS public.admin_cl_set_status(UUID, TEXT);
--   DROP FUNCTION IF EXISTS public.admin_cl_weekly_users(INT);
--   DROP FUNCTION IF EXISTS public.admin_cl_calc_stats(INT);
--   DROP FUNCTION IF EXISTS public.admin_cl_funnel(INT);
--   DROP FUNCTION IF EXISTS public.admin_cl_constants();
--   DROP FUNCTION IF EXISTS public.admin_cl_daily_events(INT);
--   DROP FUNCTION IF EXISTS public.admin_cl_recent_events(INT);

-- ── 1. 요청·문의 목록 (필터: kind · status · 미답변 · 기간) ─────────────
CREATE OR REPLACE FUNCTION public.admin_cl_inquiries(
  p_kind TEXT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_unreplied BOOLEAN DEFAULT FALSE,
  p_days INT DEFAULT NULL,
  p_limit INT DEFAULT 200
)
RETURNS SETOF public.cl_inquiries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT i.*
    FROM public.cl_inquiries i
   WHERE (p_kind IS NULL OR i.kind = p_kind)
     AND (p_status IS NULL OR i.status = p_status)
     AND (NOT p_unreplied OR i.reply IS NULL)
     AND (p_days IS NULL OR i.created_at > NOW() - (p_days || ' days')::interval)
   ORDER BY i.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_inquiries(TEXT, TEXT, BOOLEAN, INT, INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_inquiries(TEXT, TEXT, BOOLEAN, INT, INT) TO authenticated;

-- ── 2. 답변 저장 (빈 문자열/NULL 이면 답변 삭제) ─────────────────────
-- 답변은 앱 안에서만 사용자에게 보인다 (회신 이메일 없음).
CREATE OR REPLACE FUNCTION public.admin_cl_reply(p_id UUID, p_reply TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE public.cl_inquiries
     SET reply = NULLIF(TRIM(p_reply), ''),
         replied_at = CASE WHEN NULLIF(TRIM(p_reply), '') IS NULL THEN NULL ELSE NOW() END
   WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inquiry not found: %', p_id;
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_reply(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_reply(UUID, TEXT) TO authenticated;

-- ── 3. 상태 변경 — received | done | declined 만 허용 ────────────────
-- 앱 표시: 접수됐어요 / 반영했어요 / 만들지 않기로 했어요
CREATE OR REPLACE FUNCTION public.admin_cl_set_status(p_id UUID, p_status TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_status NOT IN ('received', 'done', 'declined') THEN
    RAISE EXCEPTION 'invalid status: % (received|done|declined)', p_status;
  END IF;

  UPDATE public.cl_inquiries SET status = p_status WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'inquiry not found: %', p_id;
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_set_status(UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_set_status(UUID, TEXT) TO authenticated;

-- ── 4. ★ 핵심 지표: 주간(월~일, KST) 달력 기록 순 사용자 ─────────────
-- 판정 게이트 지표. day = 그 주 월요일 날짜 (콘솔 barChart 가 day 열을 읽는다).
CREATE OR REPLACE FUNCTION public.admin_cl_weekly_users(p_weeks INT DEFAULT 12)
RETURNS TABLE(day DATE, users BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH weeks AS (
    SELECT generate_series(
      date_trunc('week', (NOW() AT TIME ZONE 'Asia/Seoul'))::date - ((p_weeks - 1) * 7),
      date_trunc('week', (NOW() AT TIME ZONE 'Asia/Seoul'))::date,
      '7 days'
    )::date AS w
  ),
  ev AS (
    SELECT date_trunc('week', (e.created_at AT TIME ZONE 'Asia/Seoul'))::date AS w, e.user_id
      FROM public.cl_events e
     WHERE e.event_type = 'calendar_entry'
       AND e.created_at > NOW() - ((p_weeks + 1) * 7 || ' days')::interval
  )
  SELECT weeks.w, COUNT(DISTINCT ev.user_id)
    FROM weeks LEFT JOIN ev ON ev.w = weeks.w
   GROUP BY weeks.w
   ORDER BY weeks.w;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_weekly_users(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_weekly_users(INT) TO authenticated;

-- ── 5. 사용 지표 (긴 형식: metric · k · cnt) ─────────────────────────
--   calc_run       k = calc_id       계산기별 실행
--   calc_share     k = calc_id       계산기별 공유
--   persona        k = variant       사용자 구성 (persona_pick)
--   request_daily  k = KST 날짜      계산기 요청 일별 (빈 날 0 채움)
CREATE OR REPLACE FUNCTION public.admin_cl_calc_stats(p_days INT DEFAULT 30)
RETURNS TABLE(metric TEXT, k TEXT, cnt BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH ev AS (
    SELECT e.event_type, e.calc_id, e.variant,
           (e.created_at AT TIME ZONE 'Asia/Seoul')::date AS d
      FROM public.cl_events e
     WHERE e.created_at > NOW() - (p_days || ' days')::interval
  )
  SELECT 'calc_run'::text, COALESCE(ev.calc_id, '(없음)'), COUNT(*)
    FROM ev WHERE ev.event_type = 'calc_run' GROUP BY ev.calc_id
  UNION ALL
  SELECT 'calc_share', COALESCE(ev.calc_id, '(없음)'), COUNT(*)
    FROM ev WHERE ev.event_type = 'calc_share' GROUP BY ev.calc_id
  UNION ALL
  SELECT 'persona', COALESCE(ev.variant, '(없음)'), COUNT(*)
    FROM ev WHERE ev.event_type = 'persona_pick' GROUP BY ev.variant
  UNION ALL
  SELECT 'request_daily', ds.d::text, COUNT(ev.d)
    FROM (SELECT generate_series(
            (NOW() AT TIME ZONE 'Asia/Seoul')::date - (p_days - 1),
            (NOW() AT TIME ZONE 'Asia/Seoul')::date, '1 day')::date AS d) ds
    LEFT JOIN ev ON ev.d = ds.d AND ev.event_type = 'request_submit'
   GROUP BY ds.d
   ORDER BY 1, 3 DESC;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_calc_stats(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_calc_stats(INT) TO authenticated;

-- ── 6. 전환 퍼널: 계산 → 달력 유도 클릭 → 달력 진입 → 기록 ───────────
CREATE OR REPLACE FUNCTION public.admin_cl_funnel(p_days INT DEFAULT 30)
RETURNS TABLE(calc_to_calendar BIGINT, calendar_open BIGINT, calendar_entry BIGINT, entry_users BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT COUNT(*) FILTER (WHERE e.event_type = 'calc_to_calendar'),
         COUNT(*) FILTER (WHERE e.event_type = 'calendar_open'),
         COUNT(*) FILTER (WHERE e.event_type = 'calendar_entry'),
         COUNT(DISTINCT e.user_id) FILTER (WHERE e.event_type = 'calendar_entry')
    FROM public.cl_events e
   WHERE e.created_at > NOW() - (p_days || ' days')::interval;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_funnel(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_funnel(INT) TO authenticated;

-- ── 7. 기준 데이터 (cl_constants) — 읽기 전용, payload 는 내려주지 않음 ──
CREATE OR REPLACE FUNCTION public.admin_cl_constants()
RETURNS TABLE(year INT, effective_from DATE, schema_version INT, published_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT c.year, c.effective_from, c.schema_version, c.published_at
    FROM public.cl_constants c
   ORDER BY c.year DESC;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_constants() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_constants() TO authenticated;

-- ── 8. 일별 이벤트 현황 (event_type 별 건수·순 사용자) ────────────────
CREATE OR REPLACE FUNCTION public.admin_cl_daily_events(p_days INT DEFAULT 14)
RETURNS TABLE(day DATE, event_type TEXT, cnt BIGINT, users BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT (e.created_at AT TIME ZONE 'Asia/Seoul')::date,
         e.event_type,
         COUNT(*),
         COUNT(DISTINCT e.user_id)
    FROM public.cl_events e
   WHERE e.created_at > NOW() - make_interval(days => p_days)
   GROUP BY 1, 2
   ORDER BY 1 DESC, 3 DESC;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_daily_events(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_daily_events(INT) TO authenticated;

-- ── 9. 최근 이벤트 목록 (user_id 는 앞 8자만 — 익명 계정 구분용) ──────
CREATE OR REPLACE FUNCTION public.admin_cl_recent_events(p_limit INT DEFAULT 100)
RETURNS TABLE(at_kst TEXT, event_type TEXT, calc_id TEXT, user8 TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT TO_CHAR(e.created_at AT TIME ZONE 'Asia/Seoul', 'MM-DD HH24:MI'),
         e.event_type,
         e.calc_id,
         LEFT(e.user_id::text, 8)
    FROM public.cl_events e
   ORDER BY e.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.admin_cl_recent_events(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cl_recent_events(INT) TO authenticated;
