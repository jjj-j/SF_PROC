# 프로시저 백업 · Git 반영 · 버전관리 · 배포 설계

> 상태: TBI DB 대상 **실행 검증 완료** (2026-10-30)
> 관리 객체 위치: `TBI.ML` / Git: `TBI.ML.SF_PROC` → https://github.com/jjj-j/SF_PROC.git
> 최종 DDL: [`mgmt/proc_mgmt_objects.sql`](../mgmt/proc_mgmt_objects.sql)

---

## 1. 목표

| 문제 | 해결 |
|---|---|
| 프로시저는 버전관리 기능이 없고 `CREATE OR REPLACE` 하면 이전 정의가 사라짐 (Time Travel/UNDROP 대상 아님) | **Git 을 원본**으로 관리, 배포 전 **자동 DDL 백업** |
| 지금 어떤 버전이 적용됐는지, 누가 배포했는지 모름 | COMMENT 에 `버전 \| git:커밋 \| 일시` 기록 + **수행이력** + **현황 뷰** |
| 운영에서 잘못 배포하면 원복이 어려움 | **배포 실패 시 자동 원복**, `SP_ROLLBACK_PROC` 로 수동 원복 |

---

## 2. Snowflake 에서 가능한 Git 작업

| 작업 | SQL 가능 여부 | 방법 |
|---|---|---|
| GitHub → Snowflake 가져오기 (pull) | **가능** | `ALTER GIT REPOSITORY TBI.ML.SF_PROC FETCH` (`SP_SYNC_GIT` 이 수행) |
| 브랜치 / 커밋 조회 | **가능** | `SHOW GIT BRANCHES IN GIT REPOSITORY TBI.ML.SF_PROC` |
| Git 파일 실행 / 조회 | **가능** | `EXECUTE IMMEDIATE FROM @TBI.ML.SF_PROC/branches/main/...`, `LIST`, `SELECT $1 FROM @...` |
| Stage → Workspace 파일 복사 | **가능** | `COPY FILES INTO 'snow://workspace/USER$.PUBLIC.SF_PROC/versions/live/...'` |
| Workspace → GitHub (commit / push) | **불가** | Workspace **Changes 탭 → Push** (UI 전용) |
| GitHub → Workspace 반영 (pull) | **불가** | Workspace **Changes 탭 → Pull** (UI 전용) |

> Git Repository 객체(`TBI.ML.SF_PROC`)는 **읽기 전용 복제본**입니다. 쓰기(push)는 Git 연동 Workspace(`USER$.PUBLIC.SF_PROC`)에서만 됩니다.
> 퍼블릭 저장소라도 push 하려면 인증이 필요합니다 (현재 PAT: `TBI.ML.GIT_PAT`).

---

## 3. 전체 흐름

```
 ┌─────────────────────────── [최초 / 필요 시] 현행 프로시저 Git 반영 ───────────────────────────┐
 │  TBI 프로시저 ── SP_EXPORT_PROCS ──▶ @TBI.ML.STG_TBI_PROC/procedures/<SCHEMA>/<PROC>.sql    │
 │                                          │ COPY FILES INTO 'snow://workspace/.../procedures/'│
 │                                          ▼                                                   │
 │                              Git Workspace USER$.PUBLIC.SF_PROC ── (UI) Push ──▶ GitHub main │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────── [상시] 개발 → 배포 ──────────────────────────────────────┐
 │  Git Workspace 에서 procedures/*.sql 수정 → (UI) Commit & Push                               │
 │                                                                                              │
 │  SELECT * FROM V_PROC_STATUS  → GIT_STATUS = 'Git 변경(미배포)' 확인                         │
 │                                                                                              │
 │  CALL SP_DEPLOY_PROC('TBI','MGMT','procedures/MGMT/SP_CW001.sql','v0.0.2')                   │
 │    ① SP_SYNC_GIT : FETCH + PROC_GIT_FILES 갱신 + 커밋 해시                                    │
 │    ② Git 파일 읽기 (없으면 FAILED)                                                           │
 │    ③ 기존 프로시저 SP_BACKUP_PROC (PRE_DEPLOY, 동일 DDL 이면 SKIP)                           │
 │    ④ 프로시저명을 TBI.MGMT. 로 한정해 실행                                                   │
 │    ⑤ COMMENT = 'v0.0.2 | git:a97ff59 | 2026-10-30 22:03'                                     │
 │    ⑥ PROC_RUN_HIST SUCCESS                                                                    │
 │    ✖ 실패 시 : ③ 백업으로 자동 원복 → PROC_RUN_HIST FAILED (+ 원복 결과)                      │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────── [장애 시] 원복 ──────────────────────────────────────────┐
 │  CALL SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)')        -- 직전(현재와 다른) 백업 │
 │  CALL SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)', 6)     -- 지정 백업             │
 │    현재 DDL 백업(PRE_ROLLBACK) → 백업 DDL 실행 → PROC_RUN_HIST ROLLBACK                       │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘

 ┌──────────────────────────────────── [정기] 백업 ─────────────────────────────────────────────┐
 │  CALL SP_BACKUP_SCHEMA_PROCS('TBI','MGMT')   -- 변경분만 저장 (직접 수정 흔적도 남음)        │
 └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 객체 구성 (TBI.ML)

| 구분 | 객체 | 역할 |
|---|---|---|
| Integration | `GIT_INT` (계정 단위) | GitHub `https://github.com/jjj-j/` 허용 |
| Secret | `TBI.ML.GIT_PAT` | GitHub PAT |
| Git Repository | `TBI.ML.SF_PROC` | GitHub 읽기 전용 복제본 |
| Stage | `TBI.ML.STG_TBI_PROC` | DDL 추출 파일 |
| File Format | `TBI.ML.FF_RAW_TEXT` | 파일을 통째로 한 컬럼으로 읽기 |
| Table | `PROC_DDL_BACKUP` | 백업 이력 |
| Table | `PROC_RUN_HIST` | 수행이력 |
| Table | `PROC_GIT_FILES` | Git 파일 인덱스 (경로, sha1, 커밋) |
| View | `V_PROC_STATUS` | 프로시저 현황 |
| Procedure | `SP_BACKUP_PROC` | 단건 백업 |
| Procedure | `SP_BACKUP_SCHEMA_PROCS` | 스키마 전체 백업 |
| Procedure | `SP_EXPORT_PROCS` | 현행 DDL → Stage |
| Procedure | `SP_SYNC_GIT` | FETCH + Git 인덱스 갱신 |
| Procedure | `SP_DEPLOY_PROC` | Git 파일 배포 |
| Procedure | `SP_ROLLBACK_PROC` | 백업으로 원복 |

관리용 프로시저(`SP_BACKUP_*`, `SP_EXPORT_*`, `SP_DEPLOY_*`, `SP_ROLLBACK_*`, `SP_SYNC_*`)는 `SP_EXPORT_PROCS` 추출 대상에서 기본 제외되며, 소스는 `mgmt/proc_mgmt_objects.sql` 로 관리합니다.

---

## 5. 테이블 / 뷰 설계

### 5.1 관계

```
PROC_RUN_HIST (RUN_ID) ─────1:N───── PROC_DDL_BACKUP (RUN_ID)        이 실행에서 만든 백업
PROC_RUN_HIST (BACKUP_ID) ──N:1───── PROC_DDL_BACKUP (BACKUP_ID)     배포 전 / 원복 대상 백업
PROC_RUN_HIST (FILE_HASH) ─────────── PROC_GIT_FILES (GIT_SHA1)      배포한 Git 파일
              ╲                 │                  ╱
               ╲                │                 ╱
                └──── V_PROC_STATUS (+ INFORMATION_SCHEMA.PROCEDURES) ┘
```

### 5.2 PROC_DDL_BACKUP — 백업 이력

| 컬럼 | 설명 |
|---|---|
| BACKUP_ID | 순번 (AUTOINCREMENT ORDER) |
| BACKUP_TS | 백업 일시 |
| RUN_ID | 수행이력 키 |
| DB_NAME / SCHEMA_NAME / PROC_NAME | 대상 |
| PROC_SIGNATURE | `TBI.MGMT.SP_CW001(VARCHAR, NUMBER)` |
| DDL | `GET_DDL` 결과 (DB/스키마 미포함) |
| DDL_HASH | MD5(DDL). **직전 백업과 같으면 저장 안 함** |
| BK_COMMENT / BK_VERSION / BK_GIT_COMMIT | 백업 시점 COMMENT 와 분리값 (형식이 맞을 때만) |
| BACKUP_TYPE | `PRE_DEPLOY` / `PRE_ROLLBACK` / `SCHEDULED` / `MANUAL` |
| BACKUP_BY / BACKUP_ROLE | 실행자 |

### 5.3 PROC_RUN_HIST — 수행이력

| 컬럼 | 설명 |
|---|---|
| RUN_ID | UUID |
| RUN_TYPE | `EXPORT` / `BACKUP` / `DEPLOY` / `ROLLBACK` |
| DB_NAME / SCHEMA_NAME / PROC_NAME / PROC_SIGNATURE | 대상 |
| SOURCE_PATH | Git 파일 경로 / Stage 경로 |
| GIT_REF / GIT_COMMIT / VERSION | 배포 정보 (원복은 복원된 버전) |
| FILE_HASH | 배포한 Git 파일 sha1 (현황 뷰의 동기화 판단 기준) |
| BACKUP_ID | 배포 전 백업 / 원복에 사용한 백업 |
| STATUS | `RUNNING` / `SUCCESS` / `FAILED` |
| OBJ_CNT / MESSAGE / ERROR_MSG | 결과 (자동 원복 결과는 MESSAGE) |
| START_TS / END_TS / RUN_BY / RUN_ROLE | 실행 정보 |

### 5.4 PROC_GIT_FILES — Git 파일 인덱스

`SP_SYNC_GIT` 이 `LIST @TBI.ML.SF_PROC/branches/main/` 결과 중 `procedures/**/*.sql` 을 저장합니다.
(뷰에서 Git 저장소를 직접 조회하면 내부 오류가 나고, 파일 경로가 `blobs/<sha>/...` 로만 보여 스키마 폴더를 알 수 없어 별도 테이블로 분리)

| 컬럼 | 설명 |
|---|---|
| GIT_REF | 브랜치 (main) |
| FILE_PATH | `procedures/MGMT/SP_CW001.sql` |
| SCHEMA_NAME / PROC_NAME | 경로에서 추출 (`__2` 오버로드 접미사 제거) |
| GIT_SHA1 | Git 파일 sha1 |
| GIT_COMMIT | 동기화 시점 브랜치 커밋 |
| SYNC_TS | 동기화 일시 |

### 5.5 V_PROC_STATUS — 프로시저 현황

| 컬럼 | 출처 |
|---|---|
| NO, DB_NAME, SCHEMA_NAME, PROC_NAME, PROC_SIGNATURE | `TBI.INFORMATION_SCHEMA.PROCEDURES` (실제 객체 — 백업 안 된 것도 표시) |
| **CUR_VERSION / CUR_GIT_COMMIT** (현재 적용) | 실제 프로시저 COMMENT 파싱 |
| **DEPLOY_TS / DEPLOY_BY / LAST_ACTION** | 최근 성공 `DEPLOY`/`ROLLBACK` 이력 |
| **BK_VERSION / BK_GIT_COMMIT / BACKUP_TS / BACKUP_TYPE / BACKUP_ID** (백업) | 최신 백업 |
| GIT_FILE / GIT_HEAD_COMMIT | `PROC_GIT_FILES` |
| **GIT_STATUS** | 아래 표 |

| GIT_STATUS | 의미 |
|---|---|
| `동기화` | 최근 배포한 파일 sha1 = 현재 Git 파일 sha1 |
| `Git 변경(미배포)` | Git 이 바뀌었는데 아직 배포 안 함 |
| `원복됨(Git과 다름)` | 마지막 작업이 원복 → 운영이 Git 과 다름 |
| `미관리(배포이력 없음)` | Git 에 파일은 있지만 이 체계로 배포한 적 없음 |
| `Git 없음` | Git 에 파일이 없음 |

> Git 상태는 **마지막 `SP_SYNC_GIT` 시점** 기준입니다. 최신으로 보려면 `CALL TBI.ML.SP_SYNC_GIT();` 후 조회하세요. (`SP_DEPLOY_PROC` 은 매번 자동 실행)

---

## 6. 운영 절차

### 6.1 현황 조회
```sql
CALL TBI.ML.SP_SYNC_GIT();
SELECT NO, DB_NAME, SCHEMA_NAME, PROC_NAME,
       CUR_VERSION, CUR_GIT_COMMIT, DEPLOY_TS, DEPLOY_BY,
       BK_VERSION, BK_GIT_COMMIT, BACKUP_TS,
       GIT_STATUS
FROM TBI.ML.V_PROC_STATUS;

-- 배포 필요 대상
SELECT * FROM TBI.ML.V_PROC_STATUS WHERE GIT_STATUS = 'Git 변경(미배포)';
```

### 6.2 변경 배포
1. Git Workspace `SF_PROC` 에서 `procedures/<SCHEMA>/<PROC>.sql` 수정
   - `CREATE OR REPLACE PROCEDURE <이름>(...)` — **DB/스키마는 쓰지 않음** (배포 시 자동 한정)
   - `$$ ... $$` 형식 사용 가능, COMMENT 는 쓰지 않아도 됨 (배포 시 덮어씀)
2. Changes 탭 → Commit & **Push**
3. 배포
   ```sql
   CALL TBI.ML.SP_DEPLOY_PROC('TBI', 'MGMT', 'procedures/MGMT/SP_CW001.sql', 'v0.0.2');
   -- 오버로드(동일명 여러 개)인 경우
   CALL TBI.ML.SP_DEPLOY_PROC('TBI', 'MGMT', 'procedures/MGMT/SP_X__2.sql', 'v1.0.0', 'main', '(VARCHAR, NUMBER)');
   ```
4. 결과 확인: 반환값 / `V_PROC_STATUS` / `PROC_RUN_HIST`

### 6.3 원복
```sql
-- 백업 목록
SELECT BACKUP_ID, BK_VERSION, BK_GIT_COMMIT, BACKUP_TYPE, BACKUP_TS
FROM TBI.ML.PROC_DDL_BACKUP
WHERE PROC_SIGNATURE = 'TBI.MGMT.SP_CW001(VARCHAR, NUMBER)'
ORDER BY BACKUP_ID DESC;

CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)');      -- 직전 버전
CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)', 6);   -- 지정 백업
```
원복 후 `GIT_STATUS = '원복됨(Git과 다름)'` → Git 소스도 되돌리거나 수정본을 다시 배포하세요.

### 6.4 현행 DDL → Git 반영 (최초 / 운영 직접 수정 반영 시)
```sql
REMOVE @TBI.ML.STG_TBI_PROC/procedures/;
CALL TBI.ML.SP_EXPORT_PROCS('TBI');              -- 또는 ('TBI', 'MGMT')
COPY FILES INTO 'snow://workspace/USER$.PUBLIC.SF_PROC/versions/live/procedures/'
  FROM @TBI.ML.STG_TBI_PROC/procedures/;
-- 이후 Workspace Changes 탭에서 diff 확인 → Push
```

### 6.5 정기 백업 (권장)
```sql
CREATE OR REPLACE TASK TBI.ML.TSK_DAILY_PROC_BACKUP
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = 'USING CRON 0 2 * * * Asia/Seoul'
AS
BEGIN
  CALL TBI.ML.SP_BACKUP_SCHEMA_PROCS('TBI', 'MGMT');
  CALL TBI.ML.SP_BACKUP_SCHEMA_PROCS('TBI', 'ML');
END;
-- ALTER TASK TBI.ML.TSK_DAILY_PROC_BACKUP RESUME;
```
(Task 는 미생성 상태 — 필요 시 실행)

---

## 7. 테스트 결과 (2026-10-30)

| # | 시나리오 | 결과 |
|---|---|---|
| 1 | 스키마 백업 1회차 / 2회차 | `3 saved` → `0 saved, 3 skipped` (동일 DDL 중복 저장 안 함) |
| 2 | 추출 (관리용 SP 제외) | 6개 → Stage → Workspace `COPY FILES` |
| 3 | Push #1 후 `SP_SYNC_GIT` | 커밋 `7d83543`, 파일 6개 인덱싱 |
| 4 | SP_CW001 / SP_ML010 / SP_GW002 v0.0.1 배포 | SUCCESS, COMMENT `v0.0.1 \| git:7d83543`, 현황 `동기화` |
| 5 | 없는 파일 배포 | `FAILED: Git 파일을 찾을 수 없음 / no rollback` |
| 6 | Push #2 (SP_CW001 수정, SP_GW002 오류) 후 현황 | 두 건만 `Git 변경(미배포)`, SP_ML010 은 `동기화` 유지 |
| 7 | SP_GW002 오류 파일 배포 | `FAILED: Unsupported data type 'VARCHR' / auto-rollback to backup_id=5`, 호출 정상, v0.0.1 유지 |
| 8 | SP_CW001 v0.0.2 배포 | SUCCESS (git `a97ff59`), 호출 결과 `SP_CW001 v2 [...] cnt=2` |
| 9 | SP_CW001 수동 원복 | backup_id=6 (v0.0.1) 복원, 호출 결과 원래 형식, 현황 `원복됨(Git과 다름)` |

현재 현황 (테스트 종료 시점):

| NO | 스키마 | 프로시저 | 현재 버전 | 커밋 | 배포일시 | 배포자 | 최근 작업 | 백업 버전 | 백업 커밋 | 백업 유형 | Git 상태 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | MGMT | SP_CW001 | v0.0.1 | 7d83543 | 10-29 22:04 | JJJHWANG | ROLLBACK | v0.0.2 | a97ff59 | PRE_ROLLBACK | 원복됨(Git과 다름) |
| 2 | MGMT | SP_GW001 | | | | | | | | SCHEDULED | 미관리 |
| 3 | MGMT | SP_GW002 | v0.0.1 | 7d83543 | 10-29 21:57 | JJJHWANG | DEPLOY | v0.0.1 | 7d83543 | PRE_DEPLOY | Git 변경(미배포) |
| 8 | ML | SP_ML001 | | | | | | | | | 미관리 |
| 9 | ML | SP_ML010 | v0.0.1 | 7d83543 | 10-29 21:56 | JJJHWANG | DEPLOY | | | PRE_DEPLOY | 동기화 |
| 10 | ML | SP_ML011 | | | | | | | | | 미관리 |

(시각은 세션 TZ America/Los_Angeles 기준)

---

## 8. 규칙 / 주의사항

| 항목 | 내용 |
|---|---|
| 운영 직접 수정 금지 | Git → `SP_DEPLOY_PROC` 경유만. 배포용 Role 로 권한 한정 권장 |
| 파일명 = 프로시저명 | 버전 접미사 금지. 오버로드는 `__2`, `__3` |
| 소스에 DB/스키마 미기재 | 배포 시 `PROCEDURE <이름>(` → `PROCEDURE TBI.<SCHEMA>.<이름>(` 로 자동 한정 (환경별 DB 배포에 유리) |
| 대소문자 | 따옴표 혼합대소문자 이름(`"MyProc"`)은 미지원 (대문자로 생성됨) |
| COMMENT | 배포 시 `버전 \| git:커밋 \| 일시` 로 덮어씀. 원복 시 백업 당시 COMMENT 로 복원 |
| 시그니처 변경 | 인자가 바뀌면 새 오버로드가 생김 → 구 시그니처 `DROP` 필요 |
| 자동 원복 | 컴파일 오류는 기존 객체가 유지되므로 원복은 안전장치 성격. 배포 후 COMMENT 단계 실패 등에 유효 |
| Git 브랜치 | `SP_DEPLOY_PROC` / `SP_SYNC_GIT` 는 브랜치만 지원 (태그 미지원) |
| 현황 뷰 범위 | TBI DB. 다른 DB 는 뷰의 `procs` CTE 에 UNION 추가 |
| 권한 | 관리 프로시저는 `EXECUTE AS CALLER` — 호출 Role 이 Git Repository·대상 스키마 권한 필요 |
| Push | SQL 불가 — Workspace UI 에서만 |

---

## 9. 향후 확장

- 다건 배포: `PROC_GIT_FILES` 에서 `Git 변경(미배포)` 대상을 일괄 `SP_DEPLOY_PROC`
- dev / prod 브랜치 분리 → `P_GIT_REF` + 대상 DB 만 바꿔 동일 파일 배포
- 정기 백업 Task 활성화, 실패 알림 (Alert / 이메일)
- DCM Project / GitHub Actions + Snowflake CLI 로 merge 시 자동 배포
