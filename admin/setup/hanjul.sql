-- 한줄 (hanjul) — 어드민 콘솔 연결 (rsscukpbsiiyfgbdfups 프로젝트, 멱등)
--
-- 한줄은 로또·오늘하루와 같은 Supabase 프로젝트를 쓴다. admin_users 화이트리스트는
-- oneulharu-lotto.sql 이 이미 만들었으므로 여기서는 RPC만 추가한다.
-- hj_events 에는 device_id 가 없어(익명 카운트 전용) DAU 는 없다.
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_hj_quote_rank(TEXT, INT, INT);
--   DROP FUNCTION IF EXISTS public.admin_hj_top_events(INT);
--   DROP FUNCTION IF EXISTS public.admin_hj_daily(INT);

-- 일별 이벤트 (전체 + 핵심 3종)
CREATE OR REPLACE FUNCTION public.admin_hj_daily(p_days INT DEFAULT 14)
RETURNS TABLE(day DATE, events BIGINT, hearts BIGINT, shares BIGINT, skips BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
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
    SELECT (e.created_at AT TIME ZONE 'Asia/Seoul')::date AS d, e.event_type
      FROM public.hj_events e
     WHERE e.created_at > NOW() - (p_days || ' days')::interval
  )
  SELECT
    days.d,
    (SELECT COUNT(*) FROM ev WHERE ev.d = days.d),
    (SELECT COUNT(*) FROM ev WHERE ev.d = days.d AND ev.event_type = 'heart'),
    (SELECT COUNT(*) FROM ev WHERE ev.d = days.d AND ev.event_type = 'share'),
    (SELECT COUNT(*) FROM ev WHERE ev.d = days.d AND ev.event_type = 'skip')
  FROM days
  ORDER BY days.d;
END;
$$;

-- 이벤트 종류별 카운트
CREATE OR REPLACE FUNCTION public.admin_hj_top_events(p_days INT DEFAULT 14)
RETURNS TABLE(event TEXT, cnt BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT e.event_type, COUNT(*)
    FROM public.hj_events e
   WHERE e.created_at > NOW() - (p_days || ' days')::interval
   GROUP BY e.event_type
   ORDER BY COUNT(*) DESC
   LIMIT 25;
END;
$$;

-- 문장별 랭킹 — 콘텐츠 검증용 (p_kind: 'heart' = 사랑받는 문장 / 'skip' = 걸러낼 문장)
CREATE OR REPLACE FUNCTION public.admin_hj_quote_rank(p_kind TEXT, p_days INT DEFAULT 14, p_limit INT DEFAULT 10)
RETURNS TABLE(quote_id BIGINT, quote TEXT, cnt BIGINT, views BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_kind NOT IN ('heart', 'skip', 'share') THEN
    RAISE EXCEPTION 'p_kind must be heart/skip/share';
  END IF;

  RETURN QUERY
  SELECT q.id, q.text,
         COUNT(*) FILTER (WHERE e.event_type = p_kind),
         COUNT(*) FILTER (WHERE e.event_type = 'view')
    FROM public.hj_events e
    JOIN public.hj_quotes q ON q.id = e.quote_id
   WHERE e.created_at > NOW() - (p_days || ' days')::interval
     AND e.quote_id IS NOT NULL
   GROUP BY q.id, q.text
  HAVING COUNT(*) FILTER (WHERE e.event_type = p_kind) > 0
   ORDER BY 3 DESC, 4 DESC
   LIMIT p_limit;
END;
$$;
