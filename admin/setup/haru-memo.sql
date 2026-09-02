-- 오늘하루 — 일진 기록(메모) 지표 RPC
--
-- 실행 방법: Supabase 대시보드(rsscukpbsiiyfgbdfups 계정) → SQL Editor 에
-- 이 파일 전체를 붙여넣고 Run. 멱등이라 여러 번 실행해도 안전하다.
--
-- 선행 조건: oneulharu-lotto.sql 이 이미 admin_users 화이트리스트를 만들어 뒀다.
--
-- 배경: 앱 1.2.0(feat(memo): measure the memo feature)이 여덟 종의 이벤트를
-- oneulharu_events 에 싣기 시작했다. 이름별 총량은 admin_top_events 로도
-- 보이지만, 정작 답을 가진 건 params 안이다 — days_ago 가 '오늘을 적는 습관'과
-- '과거를 채우는 습관'을 가르고, has_memo 가 달력 마커의 기여를 말한다.
-- 이름만 세면 그 구분이 통째로 사라진다.
--
-- 되돌리는 법 (rollback):
--   DROP FUNCTION IF EXISTS public.admin_haru_memo(INT);

-- 앱이 싣는 것 (본문·태그 이름은 싣지 않는다 — 동기화가 기본 꺼짐이므로 의도된 것):
--   memo_save       {has_note bool, is_edit bool, days_ago int}
--   memo_delete     {}
--   memo_entry      {via 'bar'|'appbar'}
--   tag_create      {color_id int, total int}
--   tag_delete      {memo_count int}
--   tag_manage_open {via 'record'|'settings'}
--   record_mode_set {on bool}
--   day_detail_open {grade, via, has_memo bool}  ← has_memo 는 셀 탭에서만 실린다

CREATE OR REPLACE FUNCTION public.admin_haru_memo(p_days INT DEFAULT 14)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.admin_users WHERE user_id = auth.uid()) THEN
    RAISE EXCEPTION 'admin only' USING ERRCODE = 'insufficient_privilege';
  END IF;

  WITH ev AS (
    SELECT e.event,
           e.params,
           e.device_id::text AS device_id,
           (e.created_at AT TIME ZONE 'Asia/Seoul')::date AS d
      FROM public.oneulharu_events e
     WHERE e.created_at > NOW() - (p_days || ' days')::interval
  ),
  -- days_ago 는 앱이 int 로 싣지만, 못 믿을 행 하나가 함수 전체를 죽이면 안 된다.
  sv AS (
    SELECT device_id,
           d,
           COALESCE((params->>'is_edit')::bool, false)  AS is_edit,
           COALESCE((params->>'has_note')::bool, false) AS has_note,
           CASE WHEN params->>'days_ago' ~ '^-?[0-9]+$'
                THEN (params->>'days_ago')::int END     AS days_ago
      FROM ev
     WHERE event = 'memo_save'
  ),
  days AS (
    SELECT generate_series(
      (NOW() AT TIME ZONE 'Asia/Seoul')::date - (p_days - 1),
      (NOW() AT TIME ZONE 'Asia/Seoul')::date,
      '1 day'
    )::date AS d
  )
  SELECT jsonb_build_object(
    'days', p_days,

    -- 채택: 기간 안에 앱을 쓴 기기 중 몇이 실제로 기록을 남겼나
    'devices_total', (SELECT COUNT(DISTINCT device_id) FROM ev),
    'devices_memo',  (SELECT COUNT(DISTINCT device_id) FROM sv),

    'saves',        (SELECT COUNT(*) FROM sv),
    'saves_new',    (SELECT COUNT(*) FROM sv WHERE NOT is_edit),
    'saves_edit',   (SELECT COUNT(*) FROM sv WHERE is_edit),
    -- 리텐션에 기여하는 건 '오늘을 적는' 쪽이다
    'saves_today',  (SELECT COUNT(*) FROM sv WHERE days_ago = 0),
    'saves_past',   (SELECT COUNT(*) FROM sv WHERE days_ago > 0),
    'saves_future', (SELECT COUNT(*) FROM sv WHERE days_ago < 0),
    'with_note',    (SELECT COUNT(*) FROM sv WHERE has_note),
    'deletes',      (SELECT COUNT(*) FROM ev WHERE event = 'memo_delete'),

    -- 두 개 낸 문 중 어디로 오는가
    'entry', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('k', k, 'cnt', cnt, 'devices', devices) ORDER BY cnt DESC), '[]'::jsonb)
        FROM (SELECT COALESCE(params->>'via', '(없음)') AS k, COUNT(*) AS cnt, COUNT(DISTINCT device_id) AS devices
                FROM ev WHERE event = 'memo_entry' GROUP BY 1) t),

    -- 기본 3종으로 충분한가
    'tag_create',  (SELECT COUNT(*) FROM ev WHERE event = 'tag_create'),
    'tag_delete',  (SELECT COUNT(*) FROM ev WHERE event = 'tag_delete'),
    -- "태그를 지워도 기록은 남는다" 는 약속이 실제로 일한 횟수
    'tag_delete_with_memo', (
      SELECT COUNT(*) FROM ev
       WHERE event = 'tag_delete'
         AND params->>'memo_count' ~ '^[0-9]+$'
         AND (params->>'memo_count')::int > 0),
    'tag_manage', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('k', k, 'cnt', cnt, 'devices', devices) ORDER BY cnt DESC), '[]'::jsonb)
        FROM (SELECT COALESCE(params->>'via', '(없음)') AS k, COUNT(*) AS cnt, COUNT(DISTINCT device_id) AS devices
                FROM ev WHERE event = 'tag_manage_open' GROUP BY 1) t),

    -- 기록 토글이 제 값을 하는가
    'mode_on',      (SELECT COUNT(*) FROM ev WHERE event = 'record_mode_set' AND COALESCE((params->>'on')::bool, false)),
    'mode_off',     (SELECT COUNT(*) FROM ev WHERE event = 'record_mode_set' AND NOT COALESCE((params->>'on')::bool, true)),
    'mode_devices', (SELECT COUNT(DISTINCT device_id) FROM ev WHERE event = 'record_mode_set'),

    -- 달력 마커의 기여. has_memo 는 셀 탭에서만 실리므로 분모도 그 행으로 잡는다
    'cell_open',    (SELECT COUNT(*) FROM ev WHERE event = 'day_detail_open' AND params ? 'has_memo'),
    'cell_has_memo',(SELECT COUNT(*) FROM ev WHERE event = 'day_detail_open' AND COALESCE((params->>'has_memo')::bool, false)),

    'daily', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object('day', d, 'saves', saves, 'devices', devices) ORDER BY d), '[]'::jsonb)
        FROM (SELECT days.d,
                     (SELECT COUNT(*) FROM sv WHERE sv.d = days.d)                  AS saves,
                     (SELECT COUNT(DISTINCT sv.device_id) FROM sv WHERE sv.d = days.d) AS devices
                FROM days) t)
  )
  INTO v_out;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_haru_memo(INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_haru_memo(INT) TO authenticated;

COMMENT ON FUNCTION public.admin_haru_memo(INT) IS
  '오늘하루 일진 기록(메모) 지표. 어드민 콘솔 전용 — admin_users 화이트리스트 검사.';
