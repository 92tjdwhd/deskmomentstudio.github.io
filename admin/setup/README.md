# 어드민 콘솔 설정

`deskmomentstudio.com/admin/` 페이지가 동작하려면 Supabase 프로젝트 2곳에 아래 1회성 설정이 필요하다.
(페이지는 정적 호스팅 + 공개 repo라 anon 키만 실려 있고, 접근 제어는 전적으로 각 프로젝트의 어드민 계정 + RLS가 담당한다.)

## 1. 아가하루 프로젝트 (xnlypjfwqisastckqbwh, 구 "아기의 하루")

1. 대시보드 → Authentication → Users → **Add user**
   - email: `seongjong@deskmomentstudio.com` · 비밀번호 지정 · **Auto Confirm 체크**
2. SQL Editor에서 `babydaily.sql` 전체 실행 (멱등 — 재실행 안전)
3. 같은 자리에서 `babydaily-ads.sql`, `babydaily-users.sql` 도 실행
   (광고 토글 · 회원 관리 탭. 셋 다 멱등이라 언제 다시 실행해도 안전)

## 2. 오늘하루·로또정석 공용 프로젝트 (rsscukpbsiiyfgbdfups, 별도 계정)

1. 대시보드 → Authentication → Users → **Add user**
   - 같은 이메일 · **같은 비밀번호** (어드민 페이지가 한 번의 로그인으로 두 프로젝트에 접속)
   - Email provider가 꺼져 있으면 Authentication → Providers에서 Email 활성화
2. SQL Editor에서 `oneulharu-lotto.sql` 전체 실행

## 3. DeskMoment 프로젝트 (jfbrqvljvbckrhiivmyy, 별도 계정)

1. 대시보드 → Authentication → Users → **Add user**
   - 같은 이메일 · **같은 비밀번호** · Auto Confirm 체크
2. SQL Editor에서 `deskmoment.sql` 전체 실행
3. `admin/index.html`의 `PROJECTS.dm.anon` 에 **publishable 키**를 넣는다
   (`web/.env.local` 의 `NEXT_PUBLIC_SUPABASE_ANON_KEY` = `sb_publishable_…` — deskmoment.com
   브라우저 번들에 이미 실려 있는 공개 키라 공개 repo에 둬도 된다)

### GA4 (트래픽·제휴 클릭)

세션과 아웃바운드 클릭은 Supabase가 아니라 GA4에 있고, GA4 Data API는 서비스 계정 서명을
요구해 정적 페이지에서 직접 못 읽는다. DeskMoment의 Vercel 서버에 둔
`web/src/app/api/admin/ga4/route.ts` 가 대신 조회해 준다.

1. Google Cloud → 서비스 계정 생성 → JSON 키 발급 → **Google Analytics Data API** 사용 설정
2. GA4 속성(`G-YK1VCZ7Q3X`) → 관리 → 속성 액세스 관리 → 그 서비스 계정 이메일을 **뷰어**로 추가
3. Vercel 환경변수 3개 (Production)
   - `GA4_PROPERTY_ID` — 숫자 속성 ID (관리 → 속성 설정 상단. `G-…` 측정 ID가 아니다)
   - `GA4_SA_EMAIL` · `GA4_SA_PRIVATE_KEY` — JSON 키의 `client_email` / `private_key`
4. 재배포

쇼핑몰별·링크 유형별 클릭 분해는 GA4 → 관리 → **맞춤 정의**에서 이벤트 매개변수
`store` / `link_type` 을 맞춤 측정기준(이벤트 범위)으로 등록해야 집계된다.
등록 전에는 그 두 카드만 안내 문구로 바뀌고 세션·클릭·클릭률은 정상으로 나온다.

## 확인

`https://deskmomentstudio.com/admin/` 접속 → 로그인 → 헤더에 두 프로젝트 모두 "연결됨" 뱃지가 떠야 한다.

- "admin_users 화이트리스트에 없음" → 계정 생성 **후에** SQL을 실행했는지 확인 (SQL 마지막 항목이 화이트리스트 등록)
- 문의 실시간 반영 안 됨 → Database → Replication에서 `supabase_realtime` publication에 해당 테이블이 있는지 확인

## 구성 요약

| | 아가하루 | 오늘하루 | 로또정석 | 한줄 | DeskMoment |
|---|---|---|---|---|---|
| 문의 테이블 | `inquiries` (실시간·답변 기록·메일 답장) | `oneulharu_feedback` (실시간·답변 → 앱에 표시) | 서버 문의함 없음 | 서버 문의함 없음 (메일) | `inquiries` (실시간·답변 저장 시 status 변경·메일 답장) |
| 회원 관리 | `admin_list_users()` — 가입일·최근 로그인·아기/기록 수 + 계정별 광고 on/off(`admin_set_ads`) | – | – | – | – |
| 애널리틱스 | `admin_daily_stats()` — 가입·기록·활성 아기 (행동분석은 Firebase) | `admin_daily_stats('oneulharu')` + `admin_top_events` | `admin_daily_stats('lotto')` + `admin_top_events` | `admin_hj_daily` + `admin_hj_top_events` + `admin_hj_quote_rank` | **GA4** 세션·제휴 클릭(`/api/admin/ga4` 경유) + `admin_dm_daily`/`admin_dm_overview` 콘텐츠·운영 |
