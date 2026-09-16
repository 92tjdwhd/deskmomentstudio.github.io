-- 하루타로 (com.deskmoment.harutarot) — 스튜디오 어드민 콘솔 설정
-- 프로젝트: 오늘하루·로또·한줄·계산기연구소 공용 (rsscukpbsiiyfgbdfups)
--
-- 전제: admin_users 화이트리스트와 어드민 계정은 oneulharu-lotto.sql 로 이미 있음.
--       harutarot_events / harutarot_feedback 테이블은 앱 쪽에서 이미 생성됨
--       (events: anon INSERT only / feedback: anon INSERT + own SELECT).
-- 실행: supabase db query --linked -f admin/setup/harutarot.sql  (또는 SQL Editor)
-- 멱등 — 여러 번 실행해도 안전.
--
-- 되돌리는 법:
--   DROP FUNCTION IF EXISTS public.admin_ht_breakdown(INT);
--   DROP FUNCTION IF EXISTS public.admin_ht_top_events(INT);
--   DROP FUNCTION IF EXISTS public.admin_ht_daily(INT);
--   DROP POLICY IF EXISTS "harutarot_feedback_admin_update" ON public.harutarot_feedback;
--   DROP POLICY IF EXISTS "harutarot_feedback_admin_select" ON public.harutarot_feedback;
--   ALTER PUBLICATION supabase_realtime DROP TABLE public.harutarot_feedback;

-- =============================================================================
-- 1. harutarot_feedback — 어드민 열람 + 답변(reply, replied_at) 쓰기
-- =============================================================================
-- 앱의 X-Device-Id 기반 anon 정책은 그대로 두고 authenticated 어드민 정책만 얹는다.
-- 앱은 reply 가 채워지면 "답변: …" 으로 표시한다.
DROP POLICY IF EXISTS "harutarot_feedback_admin_select" ON public.harutarot_feedback;
CREATE POLICY "harutarot_feedback_admin_select"
  ON public.harutarot_feedback
  FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

DROP POLICY IF EXISTS "harutarot_feedback_admin_update" ON public.harutarot_feedback;
CREATE POLICY "harutarot_feedback_admin_update"
  ON public.harutarot_feedback
  FOR UPDATE
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

-- 새 건의가 어드민 페이지에 실시간으로 뜨도록 (postgres_changes 는 위 SELECT 정책을 따른다)
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.harutarot_feedback;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

-- =============================================================================
-- 2. 애널리틱스 RPC — harutarot_events 는 정책을 열지 않고 함수로만 읽는다
-- =============================================================================
-- 공용 admin_daily_stats / admin_top_events 는 건드리지 않고 앱 전용 함수를 둔다
-- (한줄 admin_hj_*, 계산기연구소 admin_cl_* 와 같은 방식).
-- SECURITY DEFINER 로 RLS 를 우회하는 대신 첫 줄에서 어드민을 검사한다.

-- 일별 이벤트 수 + DAU (고유 device_id), KST 기준
CREATE OR REPLACE FUNCTION public.admin_ht_daily(p_days INT DEFAULT 14)
RETURNS TABLE(day DATE, events BIGINT, dau BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH days AS (
    SELECT generate_series(
      (NOW() AT TIME ZONE 'Asia/Seoul')::date - (p_days - 1),
      (NOW() AT TIME ZONE 'Asia/Seoul')::date,
      '1 day'
    )::date AS d
  ),
  ev AS (
    SELECT (e.created_at AT TIME ZONE 'Asia/Seoul')::date AS d, e.device_id
      FROM public.harutarot_events e
     WHERE e.created_at > NOW() - (p_days || ' days')::interval
  )
  SELECT
    days.d,
    (SELECT COUNT(*) FROM ev WHERE ev.d = days.d),
    (SELECT COUNT(DISTINCT ev.device_id) FROM ev WHERE ev.d = days.d)
  FROM days
  ORDER BY days.d;
END;
$$;

-- 이벤트별 카운트 + 기기 수
CREATE OR REPLACE FUNCTION public.admin_ht_top_events(p_days INT DEFAULT 14)
RETURNS TABLE(event TEXT, cnt BIGINT, devices BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT e.event, COUNT(*), COUNT(DISTINCT e.device_id)
    FROM public.harutarot_events e
   WHERE e.created_at > NOW() - (p_days || ' days')::interval
   GROUP BY e.event
   ORDER BY COUNT(*) DESC
   LIMIT 20;
END;
$$;

-- params 안의 분포 — kind 별로 key/cnt
--   spread        : draw_complete.params.spread   (one | three)
--   prompt_spread : prompt_open.params.spread     (one | three | today)
--   ai_app        : ai_open.params.app            (chatgpt | claude | gemini)
--   today_flip    : today_flip.params.reversed    (true | false)  → 역방향 비율
--   notify        : notify_toggle.params.on       (true | false)
CREATE OR REPLACE FUNCTION public.admin_ht_breakdown(p_days INT DEFAULT 14)
RETURNS TABLE(kind TEXT, key TEXT, cnt BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH ev AS (
    SELECT e.event, e.params
      FROM public.harutarot_events e
     WHERE e.created_at > NOW() - (p_days || ' days')::interval
  )
  SELECT 'spread'::text,        COALESCE(params->>'spread', '(없음)'),   COUNT(*) FROM ev WHERE event = 'draw_complete' GROUP BY 2
  UNION ALL
  SELECT 'prompt_spread'::text, COALESCE(params->>'spread', '(없음)'),   COUNT(*) FROM ev WHERE event = 'prompt_open'   GROUP BY 2
  UNION ALL
  SELECT 'ai_app'::text,        COALESCE(params->>'app', '(없음)'),      COUNT(*) FROM ev WHERE event = 'ai_open'       GROUP BY 2
  UNION ALL
  SELECT 'today_flip'::text,    COALESCE(params->>'reversed', '(없음)'), COUNT(*) FROM ev WHERE event = 'today_flip'    GROUP BY 2
  UNION ALL
  SELECT 'notify'::text,        COALESCE(params->>'on', '(없음)'),       COUNT(*) FROM ev WHERE event = 'notify_toggle' GROUP BY 2
  ORDER BY 1, 3 DESC;
END;
$$;

-- harutarot_events 의 테이블 권한·정책(anon INSERT only)은 앱 쪽 설정 그대로 둔다.
-- SELECT 정책이 없어도 위 함수들은 SECURITY DEFINER 라 읽을 수 있다.

-- RPC 는 로그인한 어드민만 (함수 내부 검사와 이중)
REVOKE EXECUTE ON FUNCTION public.admin_ht_daily(INT)      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_ht_top_events(INT) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.admin_ht_breakdown(INT)  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_ht_daily(INT)      TO authenticated;
GRANT  EXECUTE ON FUNCTION public.admin_ht_top_events(INT) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.admin_ht_breakdown(INT)  TO authenticated;
