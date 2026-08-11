-- BabyDaily (xnlypjfwqisastckqbwh) — 스튜디오 어드민 콘솔 설정 (멱등)
-- admin_users 화이트리스트 + inquiries 어드민 열람/답변 + Realtime + 지표 RPC

CREATE TABLE IF NOT EXISTS public.admin_users (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.admin_users IS
  '스튜디오 어드민 콘솔 접근 화이트리스트. 행 추가는 service_role(운영자)만.';

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_users_select_self" ON public.admin_users;
CREATE POLICY "admin_users_select_self"
  ON public.admin_users
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

ALTER TABLE public.inquiries
  ADD COLUMN IF NOT EXISTS reply      TEXT,
  ADD COLUMN IF NOT EXISTS replied_at TIMESTAMPTZ;

DROP POLICY IF EXISTS "inquiries_admin_select" ON public.inquiries;
CREATE POLICY "inquiries_admin_select"
  ON public.inquiries
  FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

DROP POLICY IF EXISTS "inquiries_admin_update" ON public.inquiries;
CREATE POLICY "inquiries_admin_update"
  ON public.inquiries
  FOR UPDATE
  TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.inquiries;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;

CREATE OR REPLACE FUNCTION public.admin_daily_stats(p_days INT DEFAULT 14)
RETURNS TABLE(day DATE, new_users BIGINT, records BIGINT, active_babies BIGINT)
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
  recs AS (
    SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS d, baby_id
      FROM public.feedings WHERE created_at > NOW() - (p_days || ' days')::interval
    UNION ALL
    SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date, baby_id
      FROM public.sleeps   WHERE created_at > NOW() - (p_days || ' days')::interval
    UNION ALL
    SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date, baby_id
      FROM public.diapers  WHERE created_at > NOW() - (p_days || ' days')::interval
  )
  SELECT
    days.d,
    (SELECT COUNT(*) FROM public.profiles p
      WHERE (p.created_at AT TIME ZONE 'Asia/Seoul')::date = days.d),
    (SELECT COUNT(*) FROM recs WHERE recs.d = days.d),
    (SELECT COUNT(DISTINCT recs.baby_id) FROM recs WHERE recs.d = days.d)
  FROM days
  ORDER BY days.d;
END;
$$;

-- =============================================================================
-- 어드민 화이트리스트 등록
-- =============================================================================
-- 먼저 대시보드 Authentication → Users → Add user 로
-- seongjong@deskmomentstudio.com 계정을 만든 뒤 (Auto Confirm 체크),
-- 아래를 실행한다. 계정이 없으면 아무 일도 일어나지 않으니 파일 전체를
-- 다시 실행해도 안전하다.
INSERT INTO public.admin_users (user_id, note)
SELECT id, '스튜디오 어드민 콘솔'
  FROM auth.users
 WHERE email = 'seongjong@deskmomentstudio.com'
ON CONFLICT (user_id) DO NOTHING;
