-- BabyDaily (xnlypjfwqisastckqbwh) — 어드민 콘솔 광고 관리 RPC (멱등)
--
-- 계정별 광고 on/off (app_settings.ads_enabled, 2026-08-14 추가 컬럼)를
-- deskmomentstudio.com/admin 에서 SQL 없이 토글할 수 있게 한다.
-- 테이블 정책은 열지 않고 SECURITY DEFINER 함수 + admin_users 검사로만 접근.
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_set_ads(UUID, BOOLEAN);
--   DROP FUNCTION IF EXISTS public.admin_list_ad_settings();

-- 계정 목록 + 광고 상태. app_settings 행이 아직 없는 계정은 기본값(켜짐)으로 표시.
CREATE OR REPLACE FUNCTION public.admin_list_ad_settings()
RETURNS TABLE(user_id UUID, email TEXT, display_name TEXT, ads_enabled BOOLEAN, has_row BOOLEAN)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT p.id,
         p.email,
         p.display_name,
         COALESCE(s.ads_enabled, TRUE),
         (s.user_id IS NOT NULL)
    FROM public.profiles p
    LEFT JOIN public.app_settings s ON s.user_id = p.id
   ORDER BY (p.email IS NULL), p.created_at;
END;
$$;

-- 광고 토글. app_settings 행이 없으면 만들어서라도 저장한다 (나머지 컬럼은 기본값 —
-- 앱이 첫 실행 때 만들었을 행과 같다).
CREATE OR REPLACE FUNCTION public.admin_set_ads(p_user_id UUID, p_enabled BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  INSERT INTO public.app_settings (user_id, ads_enabled)
  VALUES (p_user_id, p_enabled)
  ON CONFLICT (user_id) DO UPDATE
    SET ads_enabled = EXCLUDED.ads_enabled,
        updated_at  = NOW();

  RETURN p_enabled;
END;
$$;
