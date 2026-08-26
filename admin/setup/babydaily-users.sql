-- BabyDaily (xnlypjfwqisastckqbwh) — 어드민 콘솔 회원 관리 RPC (멱등)
--
-- 광고 토글만 있던 목록(admin_list_ad_settings)을 대체한다.
-- 가입일·최근 로그인·가입 경로·아기 수·기록 수까지 한 번에 내려서
-- deskmomentstudio.com/admin 의 "회원 관리" 탭이 기간·상태 필터를 걸 수 있게 한다.
-- 테이블 정책은 열지 않고 SECURITY DEFINER 함수 + admin_users 검사로만 접근.
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_list_users(INT);
--   DROP FUNCTION IF EXISTS public.admin_delete_user(UUID);

-- 반환 열이 바뀌면 CREATE OR REPLACE 가 거부하므로(cannot change return type) 먼저 지운다
DROP FUNCTION IF EXISTS public.admin_list_users(INT);

CREATE FUNCTION public.admin_list_users(p_limit INT DEFAULT 2000)
RETURNS TABLE(
  user_id         UUID,
  email           TEXT,
  display_name    TEXT,
  joined_at       TIMESTAMPTZ,
  last_sign_in_at TIMESTAMPTZ,
  provider        TEXT,
  is_guest        BOOLEAN,
  ads_enabled     BOOLEAN,
  has_settings    BOOLEAN,
  baby_count      INT,
  owned_baby_count INT,
  babies          JSONB,
  record_count    BIGINT,
  last_record_at  TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  WITH recs AS (
    -- 기록 수는 admin_daily_stats 와 같은 기준(수유·수면·기저귀)으로 센다.
    SELECT f.author_id AS uid, f.created_at AS at_ts FROM public.feedings f WHERE f.deleted = FALSE AND f.author_id IS NOT NULL
    UNION ALL
    SELECT s.author_id,        s.created_at        FROM public.sleeps   s WHERE s.deleted = FALSE AND s.author_id IS NOT NULL
    UNION ALL
    SELECT d.author_id,        d.created_at        FROM public.diapers  d WHERE d.deleted = FALSE AND d.author_id IS NOT NULL
  ),
  ragg AS (
    SELECT r.uid, COUNT(*) AS n, MAX(r.at_ts) AS last_at FROM recs r GROUP BY r.uid
  ),
  bagg AS (
    -- 접근 가능한 아기(소유 + 공동양육) 와 그중 소유분. 삭제되지 않은 아기만.
    -- 계정을 지우면 '소유한 아기'만 함께 사라지고, 남의 아기에는 접근만 끊긴다.
    SELECT c.user_id AS uid,
           COUNT(*)::INT AS n,
           COUNT(*) FILTER (WHERE b.owner_id = c.user_id)::INT AS owned,
           -- 이름과 생일 (개월수는 화면에서 계산 — 매일 달라지므로 저장하지 않는다)
           jsonb_agg(
             jsonb_build_object('name', b.name, 'birth', b.birth_date,
                                'owned', b.owner_id = c.user_id)
             ORDER BY b.birth_date DESC
           ) AS js
      FROM public.baby_coparents c
      JOIN public.babies b ON b.id = c.baby_id AND b.deleted = FALSE
     GROUP BY c.user_id
  )
  SELECT
    p.id,
    p.email,
    p.display_name,
    p.created_at,
    u.last_sign_in_at,
    COALESCE(u.raw_app_meta_data->>'provider', '-'),
    (p.email IS NULL),                 -- 익명(게스트) 로그인은 이메일이 없다
    COALESCE(s.ads_enabled, TRUE),     -- app_settings 행이 없으면 기본값(켜짐)
    (s.user_id IS NOT NULL),
    COALESCE(bagg.n, 0),
    COALESCE(bagg.owned, 0),
    COALESCE(bagg.js, '[]'::jsonb),
    COALESCE(ragg.n, 0),
    ragg.last_at
  FROM public.profiles p
  LEFT JOIN auth.users u          ON u.id = p.id
  LEFT JOIN public.app_settings s ON s.user_id = p.id
  LEFT JOIN bagg ON bagg.uid = p.id
  LEFT JOIN ragg ON ragg.uid = p.id
  ORDER BY p.created_at DESC NULLS LAST
  LIMIT GREATEST(1, COALESCE(p_limit, 2000));
END;
$$;

COMMENT ON FUNCTION public.admin_list_users(INT) IS
  '스튜디오 어드민 콘솔 회원 관리 목록 — 가입일·최근 로그인·아기/기록 수·광고 상태. 광고 토글은 admin_set_ads().';

-- ── 계정 삭제 ────────────────────────────────────────────────────────────────
-- 사전 조건: 기록 테이블의 author_id FK 가 ON DELETE SET NULL 이어야 한다.
--
-- 2026-08-04 마이그레이션(author_fk_set_null)이 카탈로그를 훑어 전부 바꿨지만,
-- 그 뒤 2026-08-10 에 생긴 custom_record_types·custom_records 가 삭제 정책 없이
-- (NO ACTION) 다시 들어왔다. 그 계정이 커스텀 기록을 한 건이라도 남겼으면
-- 계정 삭제가 FK 위반으로 실패한다 — 앱 안의 '회원 탈퇴'도 같이 막힌다.
-- 같은 사슬을 여기서 한 번 더 훑는다 (이미 SET NULL 인 것은 건드리지 않으므로
-- 재실행해도 안전하고, auth.users 를 가리키는 author_id 는 대상이 아니다).
--
-- ※ 이건 원래 BabyDaily repo 의 마이그레이션으로 남아야 할 스키마 수정이다.
--    여기 있는 건 어드민 삭제 버튼이 그것 없이는 동작하지 않기 때문.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT tc.table_name, tc.constraint_name
      FROM information_schema.table_constraints tc
      JOIN information_schema.key_column_usage kcu
        ON kcu.constraint_name = tc.constraint_name
       AND kcu.table_schema = tc.table_schema
      JOIN information_schema.referential_constraints rc
        ON rc.constraint_name = tc.constraint_name
       AND rc.constraint_schema = tc.table_schema
     WHERE tc.constraint_type = 'FOREIGN KEY'
       AND tc.table_schema = 'public'
       AND kcu.column_name = 'author_id'
       AND rc.delete_rule <> 'SET NULL'
  LOOP
    -- 한 테이블에서 막혀도 나머지(와 아래 함수 생성)까지 같이 죽지 않게 한다 —
    -- SQL 편집기는 이 파일 전체를 한 트랜잭션으로 돌린다.
    BEGIN
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', r.table_name, r.constraint_name);
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I '
        'FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL',
        r.table_name, r.constraint_name);
      RAISE NOTICE 'author_id FK → ON DELETE SET NULL: %', r.table_name;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'author_id FK 교정 실패 — % (%): %', r.table_name, r.constraint_name, SQLERRM;
    END;
  END LOOP;
END $$;

-- 계정 삭제. auth.users 한 행을 지우면 CASCADE 사슬로
-- profiles → babies(소유분) → 그 아기의 기록 전부가 정리된다.
-- 어드민 계정과 본인 계정은 막는다 (실수로 콘솔 접근을 잃지 않게).
CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION '삭제할 계정을 지정해야 한다';
  END IF;
  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION '본인(어드민) 계정은 이 화면에서 삭제할 수 없다';
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin_users au WHERE au.user_id = p_user_id) THEN
    RAISE EXCEPTION '어드민 계정은 삭제할 수 없다';
  END IF;

  DELETE FROM auth.users u WHERE u.id = p_user_id;
  RETURN FOUND;
END;
$$;

COMMENT ON FUNCTION public.admin_delete_user(UUID) IS
  '스튜디오 어드민 콘솔 회원 삭제 — auth.users 삭제(CASCADE). 어드민·본인 계정은 거부.';

-- PostgREST 스키마 캐시 갱신 — 이게 없으면 방금 만든 함수를 한동안
-- "Could not find the function ... in the schema cache" 로 거절한다.
NOTIFY pgrst, 'reload schema';
