# 어드민 콘솔 설정

`deskmomentstudio.com/admin/` 페이지가 동작하려면 Supabase 프로젝트 2곳에 아래 1회성 설정이 필요하다.
(페이지는 정적 호스팅 + 공개 repo라 anon 키만 실려 있고, 접근 제어는 전적으로 각 프로젝트의 어드민 계정 + RLS가 담당한다.)

## 1. 아기의 하루 프로젝트 (xnlypjfwqisastckqbwh)

1. 대시보드 → Authentication → Users → **Add user**
   - email: `seongjong@deskmomentstudio.com` · 비밀번호 지정 · **Auto Confirm 체크**
2. SQL Editor에서 `babydaily.sql` 전체 실행 (멱등 — 재실행 안전)

## 2. 오늘하루·로또정석 공용 프로젝트 (rsscukpbsiiyfgbdfups, 별도 계정)

1. 대시보드 → Authentication → Users → **Add user**
   - 같은 이메일 · **같은 비밀번호** (어드민 페이지가 한 번의 로그인으로 두 프로젝트에 접속)
   - Email provider가 꺼져 있으면 Authentication → Providers에서 Email 활성화
2. SQL Editor에서 `oneulharu-lotto.sql` 전체 실행

## 확인

`https://deskmomentstudio.com/admin/` 접속 → 로그인 → 헤더에 두 프로젝트 모두 "연결됨" 뱃지가 떠야 한다.

- "admin_users 화이트리스트에 없음" → 계정 생성 **후에** SQL을 실행했는지 확인 (SQL 마지막 항목이 화이트리스트 등록)
- 문의 실시간 반영 안 됨 → Database → Replication에서 `supabase_realtime` publication에 해당 테이블이 있는지 확인

## 구성 요약

| | 아기의 하루 | 오늘하루 | 로또정석 |
|---|---|---|---|
| 문의 테이블 | `inquiries` (실시간·답변 기록·메일 답장) | `oneulharu_feedback` (실시간·답변 → 앱에 표시) | 서버 문의함 없음 |
| 애널리틱스 | `admin_daily_stats()` — 가입·기록·활성 아기 (행동분석은 Firebase) | `admin_daily_stats('oneulharu')` + `admin_top_events` | `admin_daily_stats('lotto')` + `admin_top_events` |
