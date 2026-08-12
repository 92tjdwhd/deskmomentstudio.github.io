-- 오늘하루 + 로또정석 공용 프로젝트 (rsscukpbsiiyfgbdfups) — 스튜디오 어드민 콘솔 설정
--
-- 실행 방법: Supabase 대시보드 (해당 계정) → SQL Editor 에 이 파일 전체를
-- 붙여넣고 Run. 멱등이라 여러 번 실행해도 안전하다.
--
-- 순서:
--   1) Authentication → Users → Add user 로 seongjong@deskmomentstudio.com
--      생성 (Auto Confirm 체크, BabyDaily 쪽과 같은 비밀번호 사용)
--   2) 이 파일 전체 실행
--
-- 내용: admin_users 화이트리스트 + oneulharu_feedback 어드민 열람/답변(reply)
--       + Realtime + 애널리틱스 RPC (oneulharu_events / app_events)
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_top_events(TEXT, INT);
--   DROP FUNCTION IF EXISTS public.admin_daily_stats(TEXT, INT);
--   DROP POLICY IF EXISTS "feedback_admin_update" ON public.oneulharu_feedback;
--   DROP POLICY IF EXISTS "feedback_admin_select" ON public.oneulharu_feedback;
--   ALTER PUBLICATION supabase_realtime DROP TABLE public.oneulharu_feedback;
--   DROP TABLE IF EXISTS public.admin_users;

-- =============================================================================
-- 1. admin_users — 어드민 uid 화이트리스트
-- =============================================================================
-- 이메일 문자열 비교 정책은 같은 주소로 가입한 일반 계정에 뚫린다.
-- uid 화이트리스트는 운영자가 직접 넣은 계정만 통과한다.
CREATE TABLE IF NOT EXISTS public.admin_users (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.admin_users IS
  '스튜디오 어드민 콘솔 접근 화이트리스트. 행 추가는 운영자(SQL Editor)만.';

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

-- 다른 테이블 정책의 EXISTS(SELECT ... FROM admin_users) 가 호출자 권한으로
-- 평가되므로, 어드민 본인 행만큼은 SELECT 가 열려 있어야 한다.
DROP POLICY IF EXISTS "admin_users_select_self" ON public.admin_users;
CREATE POLICY "admin_users_select_self"
  ON public.admin_users
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- =============================================================================
-- 2. oneulharu_feedback — 어드민 열람 + 답변(reply) 쓰기
-- =============================================================================
-- 기존 X-Device-Id 헤더 기반 정책(anon)은 그대로 두고, authenticated 어드민
-- 정책만 얹는다. 앱은 reply 를 읽어 사용자에게 보여준다 (이미 구현돼 있음).
DROP POLICY IF EXISTS "feedback_admin_select" ON public.oneulharu_feedback;
CREATE POLICY "feedback_admin_select"
  ON public.oneulharu_feedback
  FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

DROP POLICY IF EXISTS "feedback_admin_update" ON public.oneulharu_feedback;
CREATE POLICY "feedback_admin_update"
  ON public.oneulharu_feedback
  FOR UPDATE
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

-- 새 건의가 어드민 페이지에 실시간으로 뜨도록 publication 에 추가.
-- Realtime 의 postgres_changes 는 위 SELECT 정책을 그대로 따른다.
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.oneulharu_feedback;
EXCEPTION WHEN duplicate_object THEN
  NULL;  -- 이미 추가돼 있으면 그대로 둔다
END $$;

-- =============================================================================
-- 3. 애널리틱스 RPC — 이벤트 테이블은 정책을 열지 않고 함수로만 읽는다
-- =============================================================================
-- SECURITY DEFINER 로 RLS 를 우회하는 대신 함수 첫 줄에서 어드민을 검사한다.
-- p_app: 'oneulharu' → oneulharu_events / 'lotto' → app_events

CREATE OR REPLACE FUNCTION public.admin_daily_stats(p_app TEXT, p_days INT DEFAULT 14)
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
    -- 두 테이블의 device_id 타입이 다르다 (oneulharu: uuid, lotto: text) — text 로 통일
    SELECT (e.created_at AT TIME ZONE 'Asia/Seoul')::date AS d, e.device_id::text AS device_id
      FROM public.oneulharu_events e
     WHERE p_app = 'oneulharu'
       AND e.created_at > NOW() - (p_days || ' days')::interval
    UNION ALL
    SELECT (a.created_at AT TIME ZONE 'Asia/Seoul')::date, a.device_id::text
      FROM public.app_events a
     WHERE p_app = 'lotto'
       AND a.created_at > NOW() - (p_days || ' days')::interval
  )
  SELECT
    days.d,
    (SELECT COUNT(*) FROM ev WHERE ev.d = days.d),
    (SELECT COUNT(DISTINCT ev.device_id) FROM ev WHERE ev.d = days.d)
  FROM days
  ORDER BY days.d;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_top_events(p_app TEXT, p_days INT DEFAULT 14)
RETURNS TABLE(event TEXT, cnt BIGINT, devices BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_app = 'oneulharu' THEN
    RETURN QUERY
    SELECT e.event, COUNT(*), COUNT(DISTINCT e.device_id)
      FROM public.oneulharu_events e
     WHERE e.created_at > NOW() - (p_days || ' days')::interval
     GROUP BY e.event
     ORDER BY COUNT(*) DESC
     LIMIT 20;
  ELSIF p_app = 'lotto' THEN
    RETURN QUERY
    SELECT a.event_name, COUNT(*), COUNT(DISTINCT a.device_id)
      FROM public.app_events a
     WHERE a.created_at > NOW() - (p_days || ' days')::interval
     GROUP BY a.event_name
     ORDER BY COUNT(*) DESC
     LIMIT 20;
  END IF;
END;
$$;

-- =============================================================================
-- 4. 어드민 화이트리스트 등록 (계정을 먼저 만든 뒤 실행 — 없으면 no-op)
-- =============================================================================
INSERT INTO public.admin_users (user_id, note)
SELECT id, '스튜디오 어드민 콘솔'
  FROM auth.users
 WHERE email = 'seongjong@deskmomentstudio.com'
ON CONFLICT (user_id) DO NOTHING;
