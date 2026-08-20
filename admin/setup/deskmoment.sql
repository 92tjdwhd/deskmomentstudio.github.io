-- DeskMoment (jfbrqvljvbckrhiivmyy) — 스튜디오 어드민 콘솔 연결 (멱등)
--
-- DeskMoment 는 자체 어드민(deskmoment.com/admin)이 이미 있고, 그쪽은
-- Google 로그인 + ADMIN_EMAILS(deskmoment@gmail.com) 로 막혀 있다.
-- 스튜디오 콘솔은 다른 두 프로젝트와 같은 방식(이메일/비밀번호 + admin_users
-- 화이트리스트 + SECURITY DEFINER RPC)으로 별도로 붙는다. 기존 어드민의
-- 인증·RLS 는 건드리지 않는다.
--
-- 실행 방법:
--   1) Authentication → Users → Add user
--      email: seongjong@deskmomentstudio.com · 다른 두 프로젝트와 **같은 비밀번호**
--      · Auto Confirm 체크 (Email provider 가 꺼져 있으면 Providers 에서 켤 것)
--   2) SQL Editor 에 이 파일 전체를 붙여넣고 Run
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_dm_reply_inquiry(BIGINT, TEXT);
--   DROP FUNCTION IF EXISTS public.admin_dm_matches();
--   DROP FUNCTION IF EXISTS public.admin_dm_crawl_logs(INT);
--   DROP FUNCTION IF EXISTS public.admin_dm_inquiries(INT);
--   DROP FUNCTION IF EXISTS public.admin_dm_daily(INT);
--   DROP FUNCTION IF EXISTS public.admin_dm_overview();
--   DROP TABLE IF EXISTS public.admin_users;

-- =============================================================================
-- 1. admin_users — 어드민 uid 화이트리스트
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.admin_users (
  user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.admin_users IS
  '스튜디오 어드민 콘솔 접근 화이트리스트. 행 추가는 운영자(SQL Editor)만.';

ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_users_select_self" ON public.admin_users;
CREATE POLICY "admin_users_select_self"
  ON public.admin_users
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

-- 어드민 검사 헬퍼 — 아래 함수들이 첫 줄에서 부른다.
CREATE OR REPLACE FUNCTION public.admin_dm_guard()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;
END;
$$;

-- =============================================================================
-- 2. admin_dm_overview() — 한 번의 왕복으로 요약 카드 전부
-- =============================================================================
-- 개별 count 쿼리를 7번 날리면 Supabase 왕복만 3초가 넘는다(웹앱에서 실측된
-- 문제와 같은 원인). 한 함수에서 모아 jsonb 하나로 돌려준다.
CREATE OR REPLACE FUNCTION public.admin_dm_overview()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  result JSONB;
BEGIN
  PERFORM public.admin_dm_guard();

  SELECT jsonb_build_object(
    'setups_total',      (SELECT COUNT(*) FROM public.desk_setups),
    'setups_public',     (SELECT COUNT(*) FROM public.desk_setups WHERE is_approved IS NOT FALSE),
    'setups_pending',    (SELECT COUNT(*) FROM public.desk_setups WHERE is_approved IS FALSE),
    'products_total',    (SELECT COUNT(*) FROM public.products),
    'users_total',       (SELECT COUNT(*) FROM auth.users),
    'inquiries_total',   (SELECT COUNT(*) FROM public.inquiries),
    'inquiries_pending', (SELECT COUNT(*) FROM public.inquiries WHERE status = 'pending'),
    'comments_total',    (SELECT COUNT(*) FROM public.comments),
    'reports_pending',   (SELECT COUNT(*) FROM public.comment_reports WHERE status = 'pending'),
    'aff_products',      (SELECT COUNT(*) FROM public.affiliate_products WHERE is_active),
    'aff_platforms',     (SELECT COUNT(*) FROM public.affiliate_platforms WHERE is_active),
    'aff_clicks',        (SELECT COALESCE(SUM(click_count), 0) FROM public.affiliate_products)
  ) INTO result;

  RETURN result;
END;
$$;

-- 문의 실시간(postgres_changes)은 RPC 가 아니라 SELECT 정책을 따른다.
-- 기존 어드민이 쓰던 정책은 그대로 두고 authenticated 어드민 정책만 얹는다.
DROP POLICY IF EXISTS "inquiries_studio_admin_select" ON public.inquiries;
CREATE POLICY "inquiries_studio_admin_select"
  ON public.inquiries
  FOR SELECT
  TO authenticated
  USING (EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()));

-- =============================================================================
-- 3. admin_dm_daily(p_days) — 일별 추이 (KST 기준, 빈 날도 0으로 채움)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_dm_daily(p_days INT DEFAULT 14)
RETURNS TABLE(day DATE, setups BIGINT, products BIGINT, comments BIGINT, signups BIGINT, inquiries BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_dm_guard();

  RETURN QUERY
  WITH days AS (
    SELECT generate_series(
      (NOW() AT TIME ZONE 'Asia/Seoul')::date - (p_days - 1),
      (NOW() AT TIME ZONE 'Asia/Seoul')::date,
      '1 day'
    )::date AS d
  ),
  since AS (SELECT NOW() - (p_days || ' days')::interval AS t),
  s AS (SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS d FROM public.desk_setups, since WHERE created_at > since.t),
  p AS (SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS d FROM public.products,    since WHERE created_at > since.t),
  c AS (SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS d FROM public.comments,    since WHERE created_at > since.t),
  u AS (SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS d FROM auth.users,         since WHERE created_at > since.t),
  i AS (SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS d FROM public.inquiries,   since WHERE created_at > since.t)
  SELECT
    days.d,
    (SELECT COUNT(*) FROM s WHERE s.d = days.d),
    (SELECT COUNT(*) FROM p WHERE p.d = days.d),
    (SELECT COUNT(*) FROM c WHERE c.d = days.d),
    (SELECT COUNT(*) FROM u WHERE u.d = days.d),
    (SELECT COUNT(*) FROM i WHERE i.d = days.d)
  FROM days
  ORDER BY days.d;
END;
$$;

-- =============================================================================
-- 4. admin_dm_inquiries(p_limit) — 문의함 (콘솔에서 읽고 답변까지)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_dm_inquiries(p_limit INT DEFAULT 100)
RETURNS TABLE(
  id BIGINT, user_email TEXT, user_name TEXT, type TEXT, title TEXT,
  content TEXT, status TEXT, admin_reply TEXT, admin_replied_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_dm_guard();

  RETURN QUERY
  SELECT q.id::BIGINT, q.user_email, q.user_name, q.type, q.title,
         q.content, q.status, q.admin_reply, q.admin_replied_at, q.created_at
    FROM public.inquiries q
   ORDER BY q.created_at DESC
   LIMIT p_limit;
END;
$$;

-- 답변 저장 — 기존 어드민(/admin/inquiries)과 같은 동작:
-- 답변이 있으면 status='answered', 지우면 'pending' 으로 되돌린다.
CREATE OR REPLACE FUNCTION public.admin_dm_reply_inquiry(p_id BIGINT, p_reply TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_dm_guard();

  UPDATE public.inquiries
     SET admin_reply      = NULLIF(TRIM(COALESCE(p_reply, '')), ''),
         admin_replied_at = CASE WHEN TRIM(COALESCE(p_reply, '')) = '' THEN NULL ELSE NOW() END,
         status           = CASE WHEN TRIM(COALESCE(p_reply, '')) = '' THEN 'pending' ELSE 'answered' END
   WHERE id = p_id;
END;
$$;

-- =============================================================================
-- 5. admin_dm_crawl_logs(p_limit) — 크롤 로그 (유입 콘텐츠의 생명줄)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_dm_crawl_logs(p_limit INT DEFAULT 12)
RETURNS TABLE(
  source TEXT, status TEXT, items_found INT, items_new INT, items_updated INT,
  error_message TEXT, started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_dm_guard();

  RETURN QUERY
  SELECT l.source, l.status, l.items_found, l.items_new, l.items_updated,
         l.error_message, l.started_at, l.finished_at
    FROM public.crawl_logs l
   ORDER BY l.started_at DESC
   LIMIT p_limit;
END;
$$;

-- =============================================================================
-- 6. admin_dm_matches() — 가격 카드 매칭 상태
-- =============================================================================
-- 2026-05~06 에 21건 생성된 뒤 멈춰 있다(네이버 쇼핑 검색 API 2026-07-31 종료,
-- 쿠팡은 15만원 승인 게이트 미달). 다시 돌기 시작했는지 한눈에 보려는 용도.
CREATE OR REPLACE FUNCTION public.admin_dm_matches()
RETURNS TABLE(store TEXT, confidence TEXT, cnt BIGINT, demoted BIGINT, last_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_dm_guard();

  RETURN QUERY
  SELECT m.store, m.confidence, COUNT(*),
         COUNT(*) FILTER (WHERE m.demoted),
         MAX(m.created_at)
    FROM public.gear_matches m
   GROUP BY m.store, m.confidence
   ORDER BY COUNT(*) DESC;
END;
$$;

-- =============================================================================
-- 7. 어드민 화이트리스트 등록 (계정을 먼저 만든 뒤 실행 — 없으면 no-op)
-- =============================================================================
INSERT INTO public.admin_users (user_id, note)
SELECT id, '스튜디오 어드민 콘솔'
  FROM auth.users
 WHERE email = 'seongjong@deskmomentstudio.com'
ON CONFLICT (user_id) DO NOTHING;

-- 문의가 실시간으로 뜨도록 publication 에 추가 (이미 있으면 무시)
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.inquiries;
EXCEPTION WHEN duplicate_object THEN
  NULL;
END $$;
