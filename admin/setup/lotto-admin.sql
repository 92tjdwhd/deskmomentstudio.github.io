-- 로또정석 어드민 기능을 스튜디오 콘솔로 (rsscukpbsiiyfgbdfups 프로젝트, 멱등)
--
-- 로또정석에는 자체 어드민(LottoJeongseok/admin/dashboard.html)이 있고, 인증을
-- 공유 비밀키로 한다 — 브라우저가 매 RPC 호출마다 p_admin_key 를 실어 보내고
-- 함수가 문자열을 비교한다.
--
-- 스튜디오 콘솔은 공개 repo(deskmomentstudio.github.io)라 그 키를 실을 수 없다.
-- 대신 여기서 admin_users(auth.uid()) 로 검사하는 래퍼를 만들고, 키는 DB 안
-- private 스키마에 한 번만 넣어 둔다 — 이 파일에도, 콘솔 HTML 에도 키는 없다.
-- 기존 함수와 기존 어드민 페이지는 건드리지 않는다. 두 경로가 같은 함수를
-- 각자의 방식으로 인증해서 부른다.
--
-- 선행 조건: oneulharu-lotto.sql 이 이미 admin_users 화이트리스트를 만들어 뒀다.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- 실행: 이 파일 전체를 SQL Editor 에서 Run. 그게 전부다.
--
-- 키는 사람이 옮기지 않는다 — 아래 6번에서 DB 가 기존 get_admin_dashboard
-- 함수 본문의 비교 문자열을 스스로 읽어 private.app_secrets 에 넣는다.
-- 덕분에 키가 이 파일에도, 콘솔 HTML 에도, 복사·붙여넣기 경로에도 남지 않는다.
--
-- 로또 어드민 키를 나중에 바꾸면 (기존 함수들을 새 키로 재배포한 뒤)
-- 이 파일을 다시 Run 하면 새 값으로 갱신된다.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_lt_notice_delete(INT);
--   DROP FUNCTION IF EXISTS public.admin_lt_notice_update(INT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INT);
--   DROP FUNCTION IF EXISTS public.admin_lt_notice_create(TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, INT);
--   DROP FUNCTION IF EXISTS public.admin_lt_notices();
--   DROP FUNCTION IF EXISTS public.admin_lt_gen_combo(INT);
--   DROP FUNCTION IF EXISTS public.admin_lt_user_numbers(INT, TEXT, INT, INT);
--   DROP FUNCTION IF EXISTS public.admin_lt_config_update(NUMERIC, BOOLEAN, BOOLEAN);
--   DROP FUNCTION IF EXISTS public.admin_lt_config();
--   DROP FUNCTION IF EXISTS public.admin_lt_dashboard(INT);
--   DROP FUNCTION IF EXISTS public.admin_lt_key();
--   DROP FUNCTION IF EXISTS public.admin_lt_guard();
--   DROP TABLE IF EXISTS private.app_secrets;   -- 다른 비밀값이 없을 때만

-- =============================================================================
-- 0. 비밀값 보관 — private 스키마 (PostgREST 는 public 만 노출한다)
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS private;

-- 어떤 클라이언트 역할에도 권한을 주지 않는다. SECURITY DEFINER 함수만 읽는다.
REVOKE ALL ON SCHEMA private FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS private.app_secrets (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  note       TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE private.app_secrets IS
  '공개 repo 에 둘 수 없는 값. 행 추가/수정은 SQL Editor 에서 운영자가 직접.';

ALTER TABLE private.app_secrets ENABLE ROW LEVEL SECURITY;  -- 정책 없음 = 아무도 못 읽음
REVOKE ALL ON TABLE private.app_secrets FROM anon, authenticated;

-- =============================================================================
-- 가드 + 키 조회 — 아래 래퍼들이 첫 줄에서 부른다
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_lt_guard()
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

-- 가드를 통과한 뒤에만 부른다. EXECUTE 를 회수해 두어 클라이언트가 직접
-- 호출해 키를 뽑아갈 수 없게 한다 (기본값이 PUBLIC 실행 허용이라 필수).
CREATE OR REPLACE FUNCTION public.admin_lt_key()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = private, pg_temp
AS $$
DECLARE
  k TEXT;
BEGIN
  SELECT value INTO k FROM private.app_secrets WHERE key = 'lotto_admin_key';
  IF k IS NULL THEN
    RAISE EXCEPTION 'lotto_admin_key 가 private.app_secrets 에 없습니다 — setup/lotto-admin.sql 상단의 INSERT 를 실행하세요';
  END IF;
  RETURN k;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_lt_key() FROM PUBLIC, anon, authenticated;

-- =============================================================================
-- 1. 애널리틱스 — 퍼널 / 화면별 / 버튼별 / 일별
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_lt_dashboard(p_days INT DEFAULT 7)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.get_admin_dashboard(p_days := p_days, p_admin_key := public.admin_lt_key());
END;
$$;

-- =============================================================================
-- 2. 앱 설정 — 표시 배수 / 실시간 기능 / 자랑 배너
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_lt_config()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.get_admin_config(p_admin_key := public.admin_lt_key());
END;
$$;

-- 세 값 모두 NULL 허용 — 원본 함수가 NULL 인 항목은 건드리지 않는 방식이라
-- 콘솔에서 토글 하나만 바꿔 보낼 수 있어야 한다.
CREATE OR REPLACE FUNCTION public.admin_lt_config_update(
  p_display_multiplier          NUMERIC DEFAULT NULL,
  p_feature_realtime_enabled    BOOLEAN DEFAULT NULL,
  p_feature_winner_brag_enabled BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.update_admin_config(
    p_admin_key                   := public.admin_lt_key(),
    p_display_multiplier          := p_display_multiplier,
    p_feature_realtime_enabled    := p_feature_realtime_enabled,
    p_feature_winner_brag_enabled := p_feature_winner_brag_enabled
  );
END;
$$;

-- =============================================================================
-- 3. 번호 저장소 — 사용자가 저장한 조합 (회차·생성방법 필터 + 페이지네이션)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_lt_user_numbers(
  p_round    INT  DEFAULT NULL,
  p_method   TEXT DEFAULT NULL,
  p_page     INT  DEFAULT 1,
  p_per_page INT  DEFAULT 30
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.get_admin_user_numbers(
    p_admin_key := public.admin_lt_key(),
    p_round     := p_round,
    p_method    := p_method,
    p_page      := p_page,
    p_per_page  := p_per_page
  );
END;
$$;

-- =============================================================================
-- 4. 조합 생성 — 아무도 저장하지 않은 유니크 조합
-- =============================================================================
-- 참고: 원본 generate_unique_combination 은 p_admin_key 를 받지 않는다.
-- anon 키만 있으면 누구나 부를 수 있다는 뜻이라 따로 점검해 볼 만하다.
-- 여기서는 콘솔 경로만 어드민으로 막는다.
CREATE OR REPLACE FUNCTION public.admin_lt_gen_combo(p_target_round INT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.generate_unique_combination(p_target_round := p_target_round);
END;
$$;

-- =============================================================================
-- 5. 공지사항 — 목록 / 생성 / 수정 / 삭제
-- =============================================================================
CREATE OR REPLACE FUNCTION public.admin_lt_notices()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.get_admin_notices(p_admin_key := public.admin_lt_key());
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_lt_notice_create(
  p_title       TEXT,
  p_body        TEXT    DEFAULT NULL,
  p_image_url   TEXT    DEFAULT NULL,
  p_button_text TEXT    DEFAULT '확인',
  p_button_link TEXT    DEFAULT NULL,
  p_is_active   BOOLEAN DEFAULT TRUE,
  p_priority    INT     DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.create_admin_notice(
    p_admin_key   := public.admin_lt_key(),
    p_title       := p_title,
    p_body        := p_body,
    p_image_url   := p_image_url,
    p_button_text := p_button_text,
    p_button_link := p_button_link,
    p_is_active   := p_is_active,
    p_priority    := p_priority
  );
END;
$$;

-- 토글 하나만 바꾸는 호출(p_id + p_is_active)이 있어 나머지는 NULL 허용.
CREATE OR REPLACE FUNCTION public.admin_lt_notice_update(
  p_id          INT,
  p_title       TEXT    DEFAULT NULL,
  p_body        TEXT    DEFAULT NULL,
  p_image_url   TEXT    DEFAULT NULL,
  p_button_text TEXT    DEFAULT NULL,
  p_button_link TEXT    DEFAULT NULL,
  p_is_active   BOOLEAN DEFAULT NULL,
  p_priority    INT     DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.update_admin_notice(
    p_admin_key   := public.admin_lt_key(),
    p_id          := p_id,
    p_title       := p_title,
    p_body        := p_body,
    p_image_url   := p_image_url,
    p_button_text := p_button_text,
    p_button_link := p_button_link,
    p_is_active   := p_is_active,
    p_priority    := p_priority
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_lt_notice_delete(p_id INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.admin_lt_guard();
  RETURN public.delete_admin_notice(p_admin_key := public.admin_lt_key(), p_id := p_id);
END;
$$;

-- =============================================================================
-- 6. 키 등록 — 기존 함수 본문에서 DB 가 직접 읽어 온다
-- =============================================================================
-- get_admin_dashboard 는 `IF p_admin_key != '<키>' THEN` 로 키를 비교한다.
-- 그 리터럴을 그대로 가져오므로 사람이 키를 타이핑하거나 복사할 일이 없다.
DO $$
DECLARE
  k TEXT;
BEGIN
  SELECT (regexp_match(p.prosrc, 'p_admin_key\s*(?:!=|<>)\s*''([^'']+)'''))[1]
    INTO k
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'get_admin_dashboard'
   LIMIT 1;

  IF k IS NULL OR k = '' THEN
    RAISE EXCEPTION
      'get_admin_dashboard 본문에서 어드민 키를 찾지 못했습니다 — 키 비교 방식이 바뀌었는지 확인하고, 필요하면 private.app_secrets 에 lotto_admin_key 를 직접 넣으세요';
  END IF;

  INSERT INTO private.app_secrets (key, value, note)
  VALUES ('lotto_admin_key', k, '로또정석 어드민 공유키 — get_admin_dashboard 본문에서 추출')
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
END $$;
