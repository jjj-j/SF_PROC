# 프로시저 백업 · Git 반영 · 버전관리 · 배포 설계

> 상태: TBI DB 대상 **실행 검증 완료** (2026-10-30) — CodeCommit 경로는 코드만 포함, **미검증**
> 관리 객체: `TBI.ML` / Git: `TBI.ML.SF_PROC` → https://github.com/jjj-j/SF_PROC.git
> 최종 DDL: `mgmt/proc_mgmt_objects.sql` (실제 객체에서 `GET_DDL` 로 생성)

---

## 1. 목표

| 문제 | 해결 |
|---|---|
| 프로시저는 버전관리 기능이 없고 `CREATE OR REPLACE` 하면 이전 정의가 사라짐 (Time Travel/UNDROP 대상 아님) | **Git 을 원본**으로 관리, 배포 전 **자동 DDL 백업** |
| 지금 어떤 버전이 적용됐는지, 누가 배포했는지 모름 | COMMENT 에 `버전 \| git:커밋 \| 일시` 기록 + **수행이력** + **현황 뷰** |
| 운영 DDL 을 Git 에 올리려면 수작업 (다운로드 → 업로드 → Push) | **`SP_GIT_PUSH`** 로 Snowflake 에서 Git 원격에 직접 커밋 |
| 잘못 배포하면 원복이 어려움 | **배포 실패 시 자동 원복**, `SP_ROLLBACK_PROC` 로 수동 원복 |

---

## 2. Snowflake 에서 가능한 Git 작업

| 작업 | SQL/프로시저 | 방법 |
|---|---|---|
| GitHub/CodeCommit → Snowflake 가져오기 | **가능** | `ALTER GIT REPOSITORY TBI.ML.SF_PROC FETCH` (`SP_SYNC_GIT`) |
| 브랜치 / 커밋 / 파일 조회, 파일 실행 | **가능** | `SHOW GIT BRANCHES`, `LIST @repo/...`, `EXECUTE IMMEDIATE FROM @repo/...` |
| Snowflake → Git 원격 커밋 | **가능** | **`SP_GIT_PUSH`** (Python + External Access, GitHub REST / CodeCommit API) |
| Stage → Workspace 파일 복사 | **가능** | `COPY FILES INTO 'snow://workspace/USER$.PUBLIC.SF_PROC/versions/live/...'` |
| Workspace → Git (commit / push) | **불가** | Workspace **Changes 탭 → Push** (UI 전용) |
| Git → Workspace (pull) | **불가** | Workspace **Changes 탭 → Pull** (UI 전용, 자동화 불가) |

- Git Repository 객체(`TBI.ML.SF_PROC`)는 **읽기 전용 복제본** — 배포 흐름(`FETCH` → `EXECUTE`)은 완전 자동.
- `SP_GIT_PUSH` 는 Git **원격 저장소**에 직접 커밋합니다. **Workspace 는 자동 갱신되지 않으므로** Workspace 에서 작업하기 전에 **Pull** 을 먼저 하세요.

---

## 3. 전체 흐름

```
 ┌─────────────────── [A] 운영 DDL → Git (자동, 정기 Task 가능) ───────────────────┐
 │  CALL SP_EXPORT_AND_PUSH('TBI' [, 'MGMT'])                                       │
 │    ① SP_EXPORT_PROCS : GET_DDL → @STG_TBI_PROC/procedures/<SCHEMA>/<PROC>.sql   │
 │                        (배포 COMMENT 줄 제거, 관리용 SP 제외)                     │
 │    ② SP_GIT_PUSH     : 원격과 비교 → 변경/삭제분만 1개 커밋 (없으면 NO_CHANGE)   │
 │    ③ SP_SYNC_GIT     : FETCH + PROC_GIT_FILES 갱신                               │
 └──────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────── [B] 개발 → 배포 ──────────────────────────────────────────────┐
 │  Git Workspace SF_PROC : (Pull) → procedures/*.sql 수정 → Commit & Push (UI)     │
 │  SELECT * FROM V_PROC_STATUS → 'Git 변경(미배포)'                                │
 │  CALL SP_DEPLOY_PROC('TBI','MGMT','procedures/MGMT/SP_CW001.sql','v0.0.2')       │
 │    ① SP_SYNC_GIT (FETCH, 커밋, 파일 sha1)                                        │
 │    ② Git 파일 읽기 (없으면 FAILED)                                               │
 │    ③ SP_BACKUP_PROC (PRE_DEPLOY, 동일 DDL 이면 SKIP)                             │
 │    ④ 프로시저명을 TBI.MGMT. 로 한정해 실행                                       │
 │    ⑤ COMMENT = 'v0.0.2 | git:a97ff59 | 2026-10-30 22:03'                         │
 │    ⑥ PROC_RUN_HIST SUCCESS   /  ✖ 실패 시 ③ 백업으로 자동 원복 → FAILED          │
 └──────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────── [C] 원복 ─────────────────────────────────────────────────────┐
 │  CALL SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)' [, BACKUP_ID])        │
 │    PRE_ROLLBACK 백업 → 백업 DDL 실행 → PROC_RUN_HIST ROLLBACK                     │
 └──────────────────────────────────────────────────────────────────────────────────┘

 ┌─────────────────── [D] 정기 백업 ────────────────────────────────────────────────┐
 │  CALL SP_BACKUP_SCHEMA_PROCS('TBI','MGMT')   -- 변경분만 저장                    │
 └──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 객체 구성

| 구분 | 객체 | 역할 |
|---|---|---|
| API Integration | `GIT_INT` (계정) | Git Repository 객체용 (`https://github.com/jjj-j/`) |
| Secret | `TBI.ML.GIT_PAT` | GitHub PAT (Git Repository + SP_GIT_PUSH 공용) |
| Git Repository | `TBI.ML.SF_PROC` | 원격 읽기 전용 복제본 |
| Network Rule | `TBI.ML.NR_GITHUB_API` | `api.github.com:443` |
| External Access Integration | `GIT_PUSH_EAI` (계정) | SP_GIT_PUSH 외부 통신 |
| Stage | `TBI.ML.STG_TBI_PROC` | DDL 추출 파일 (`procedures/`), 저장소 파일 (`repo/`) |
| File Format | `TBI.ML.FF_RAW_TEXT` | 파일을 통째로 한 컬럼으로 읽기 |
| Table | `PROC_DDL_BACKUP` | 백업 이력 |
| Table | `PROC_RUN_HIST` | 수행이력 (EXPORT / BACKUP / PUSH / DEPLOY / ROLLBACK) |
| Table | `PROC_GIT_FILES` | Git 파일 인덱스 |
| View | `V_PROC_STATUS` | 프로시저 현황 |
| Procedure (SQL) | `SP_BACKUP_PROC`, `SP_BACKUP_SCHEMA_PROCS` | 백업 |
| Procedure (SQL) | `SP_EXPORT_PROCS` | 현행 DDL → Stage |
| Procedure (SQL) | `SP_SYNC_GIT` | FETCH + Git 인덱스 |
| Procedure (Python) | **`SP_GIT_PUSH`** | Stage → Git 원격 커밋 |
| Procedure (SQL) | **`SP_EXPORT_AND_PUSH`** | 추출 + Push + 동기화 |
| Procedure (SQL) | `SP_DEPLOY_PROC` | Git 파일 배포 |
| Procedure (SQL) | `SP_ROLLBACK_PROC` | 원복 |

관리용 프로시저(`SP_(BACKUP|EXPORT|DEPLOY|ROLLBACK|SYNC|GIT)_*`)는 추출 대상에서 제외되며 소스는 `mgmt/proc_mgmt_objects.sql` 로 관리합니다.

---

## 5. 테이블 / 뷰 설계

### 5.1 관계
```
PROC_RUN_HIST (RUN_ID)    ──1:N── PROC_DDL_BACKUP (RUN_ID)       실행 중 생성한 백업
PROC_RUN_HIST (BACKUP_ID) ──N:1── PROC_DDL_BACKUP (BACKUP_ID)    배포 전 / 원복 대상 백업
PROC_RUN_HIST (FILE_HASH) ─────── PROC_GIT_FILES  (GIT_SHA1)     배포한 Git 파일
              └──────── V_PROC_STATUS (+ INFORMATION_SCHEMA.PROCEDURES) ────────┘
```

### 5.2 PROC_DDL_BACKUP
| 컬럼 | 설명 |
|---|---|
| BACKUP_ID | 순번 (AUTOINCREMENT ORDER) |
| BACKUP_TS / RUN_ID | 백업 일시 / 수행이력 키 |
| DB_NAME / SCHEMA_NAME / PROC_NAME / PROC_SIGNATURE | 대상 (`TBI.MGMT.SP_CW001(VARCHAR, NUMBER)`) |
| DDL / DDL_HASH | `GET_DDL` 결과 / MD5 — **직전 백업과 같으면 저장 안 함** |
| BK_COMMENT / BK_VERSION / BK_GIT_COMMIT | 백업 시점 COMMENT 와 분리값 |
| BACKUP_TYPE | `PRE_DEPLOY` / `PRE_ROLLBACK` / `SCHEDULED` / `MANUAL` |
| BACKUP_BY / BACKUP_ROLE | 실행자 |

### 5.3 PROC_RUN_HIST
| 컬럼 | 설명 |
|---|---|
| RUN_ID / RUN_TYPE | UUID / `EXPORT` `BACKUP` `PUSH` `DEPLOY` `ROLLBACK` |
| DB_NAME / SCHEMA_NAME / PROC_NAME / PROC_SIGNATURE | 대상 |
| SOURCE_PATH | Git 파일 / Stage 경로 |
| GIT_REF / GIT_COMMIT / VERSION | 브랜치 / 커밋 / 버전 (PUSH 는 생성한 커밋) |
| FILE_HASH | 배포한 Git 파일 sha1 (동기화 판단 기준) |
| BACKUP_ID | 배포 전 / 원복 대상 백업 |
| STATUS / OBJ_CNT / MESSAGE / ERROR_MSG | 결과 (PUSH: 변경/삭제 파일 목록, 자동 원복 결과) |
| START_TS / END_TS / RUN_BY / RUN_ROLE | 실행 정보 |

### 5.4 PROC_GIT_FILES
`SP_SYNC_GIT` 이 `LIST @TBI.ML.SF_PROC/branches/main/` 중 `procedures/**/*.sql` 을 저장.
(뷰에서 Git 저장소를 직접 조회하면 내부 오류 + 경로가 `blobs/<sha>/...` 로만 보여 별도 테이블로 분리)

| 컬럼 | 설명 |
|---|---|
| GIT_REF / FILE_PATH | 브랜치 / `procedures/MGMT/SP_CW001.sql` |
| SCHEMA_NAME / PROC_NAME | 경로에서 추출 (`__2` 오버로드 접미사 제거) |
| GIT_SHA1 / GIT_COMMIT / SYNC_TS | 파일 sha1 / 브랜치 커밋 / 동기화 일시 |

### 5.5 V_PROC_STATUS
| 컬럼 | 출처 |
|---|---|
| NO, DB_NAME, SCHEMA_NAME, PROC_NAME, PROC_SIGNATURE | `TBI.INFORMATION_SCHEMA.PROCEDURES` (실제 객체) |
| **CUR_VERSION / CUR_GIT_COMMIT** (현재 적용) | 실제 COMMENT 파싱 |
| **DEPLOY_TS / DEPLOY_BY / LAST_ACTION** | 최근 성공 DEPLOY/ROLLBACK |
| **BK_VERSION / BK_GIT_COMMIT / BACKUP_TS / BACKUP_TYPE / BACKUP_ID** (백업) | 최신 백업 |
| GIT_FILE / GIT_HEAD_COMMIT / **GIT_STATUS** | `PROC_GIT_FILES` |

| GIT_STATUS | 의미 |
|---|---|
| `동기화` | 최근 배포 파일 sha1 = 현재 Git 파일 sha1 |
| `Git 변경(미배포)` | Git 이 바뀌었는데 아직 배포 안 함 |
| `원복됨(Git과 다름)` | 마지막 작업이 원복 |
| `미관리(배포이력 없음)` | Git 에 있지만 이 체계로 배포한 적 없음 |
| `Git 없음` | Git 에 파일 없음 |

> Git 상태는 마지막 `SP_SYNC_GIT` 기준 (`SP_DEPLOY_PROC`, `SP_EXPORT_AND_PUSH` 는 자동 실행).

---

## 6. SP_GIT_PUSH 상세

```sql
CALL TBI.ML.SP_GIT_PUSH(
    P_PROVIDER       => 'GITHUB',                            -- 'GITHUB' | 'CODECOMMIT'
    P_REPO           => 'jjj-j/SF_PROC',                     -- CodeCommit: 저장소명
    P_SRC_PATH       => '@TBI.ML.STG_TBI_PROC/procedures/',  -- 원본 Stage 경로
    P_DEST_DIR       => 'procedures/',                       -- 저장소 내 경로
    P_MESSAGE        => 'export procedures from Snowflake',
    P_BRANCH         => 'main',
    P_REGION         => NULL,                                -- CodeCommit 리전
    P_DELETE_MISSING => FALSE);                              -- P_DEST_DIR 아래 Stage 에 없는 파일 삭제
```
(이름 지정 인자와 위치 인자는 섞어 쓸 수 없음 — 생략 인자가 있으면 모두 `=>` 사용)

| 단계 | GitHub | CodeCommit |
|---|---|---|
| 인증 | Secret PASSWORD = PAT (Bearer) | Secret USERNAME = Access Key ID, PASSWORD = Secret Key |
| 브랜치 HEAD | `GET /git/ref/heads/{branch}` | `get_branch` |
| 변경 판단 | 원격 tree blob sha1 vs 로컬 `sha1("blob <len>\0" + data)` | `get_file` 내용 비교 |
| 삭제 대상 | tree 에서 `P_DEST_DIR` 하위 | `get_folder` 재귀 |
| 커밋 | `POST /git/trees` → `POST /git/commits` → `PATCH /git/refs` | `create_commit(putFiles, deleteFiles)` |
| 결과 | `SUCCESS: commit abc1234 (updated: ... / deleted: ...)` / `NO_CHANGE` / `FAILED: ...` | 동일 |

- 커밋 작성자: GitHub 는 PAT 소유자, CodeCommit 은 `Snowflake`. 메시지에 실행 사용자와 RUN_ID 를 덧붙임.
- 추출 시 배포 COMMENT 줄(`COMMENT='v.. | git:.. | ..'`)을 제거하므로 **코드가 같으면 NO_CHANGE** (배포만 했다고 Git 이 바뀌지 않음).

---

## 7. 운영 절차

### 7.1 현황 조회
```sql
CALL TBI.ML.SP_SYNC_GIT();
SELECT NO, DB_NAME, SCHEMA_NAME, PROC_NAME,
       CUR_VERSION, CUR_GIT_COMMIT, DEPLOY_TS, DEPLOY_BY,
       BK_VERSION, BK_GIT_COMMIT, BACKUP_TS, GIT_STATUS
FROM TBI.ML.V_PROC_STATUS;
```

### 7.2 운영 DDL → Git
```sql
CALL TBI.ML.SP_EXPORT_AND_PUSH('TBI');                  -- 전체
CALL TBI.ML.SP_EXPORT_AND_PUSH('TBI', 'MGMT', 'snapshot MGMT');   -- 스키마 단위
```
이후 Workspace 사용 전 **Pull**.

### 7.3 변경 배포
1. Workspace `SF_PROC` → **Pull** → `procedures/<SCHEMA>/<PROC>.sql` 수정
   - `CREATE OR REPLACE PROCEDURE <이름>(...)` — DB/스키마 미기재, COMMENT 불필요
2. Commit & Push
3. `CALL TBI.ML.SP_DEPLOY_PROC('TBI', 'MGMT', 'procedures/MGMT/SP_CW001.sql', 'v0.0.2');`
   - 오버로드: `..., 'main', '(VARCHAR, NUMBER)'`

### 7.4 원복
```sql
SELECT BACKUP_ID, BK_VERSION, BK_GIT_COMMIT, BACKUP_TYPE, BACKUP_TS
FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = 'TBI.MGMT.SP_CW001(VARCHAR, NUMBER)' ORDER BY 1 DESC;

CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)');       -- 직전
CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)', 6);    -- 지정
```

### 7.5 정기 실행 (Task — 미생성)
```sql
CREATE OR REPLACE TASK TBI.ML.TSK_DAILY_PROC_SNAPSHOT
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = 'USING CRON 0 2 * * * Asia/Seoul'
AS
BEGIN
  CALL TBI.ML.SP_BACKUP_SCHEMA_PROCS('TBI', 'MGMT');
  CALL TBI.ML.SP_BACKUP_SCHEMA_PROCS('TBI', 'ML');
  CALL TBI.ML.SP_EXPORT_AND_PUSH('TBI', NULL, 'daily snapshot');
END;
-- ALTER TASK TBI.ML.TSK_DAILY_PROC_SNAPSHOT RESUME;
```

---

## 8. 테스트 결과 (2026-10-30, GitHub)

| # | 시나리오 | 결과 |
|---|---|---|
| 1 | 스키마 백업 1회 / 2회 | `3 saved` → `0 saved, 3 skipped` |
| 2 | 추출 → Workspace `COPY FILES` → Push #1 | 커밋 `7d83543`, 6 파일 |
| 3 | v0.0.1 배포 (SP_CW001 / SP_ML010 / SP_GW002) | SUCCESS, 현황 `동기화` |
| 4 | 없는 파일 배포 | `FAILED: Git 파일을 찾을 수 없음 / no rollback` |
| 5 | Push #2 후 현황 | 수정 2건만 `Git 변경(미배포)` |
| 6 | 오류 파일 배포 (SP_GW002) | `FAILED ... / auto-rollback to backup_id=5`, v0.0.1 유지 |
| 7 | SP_CW001 v0.0.2 배포 → 수동 원복 | 배포 SUCCESS → backup_id=6 (v0.0.1) 복원, `원복됨(Git과 다름)` |
| 8 | `SP_GIT_PUSH` 최초 | 커밋 `8c5ef05` — 관리용 SP 포함·배포 COMMENT 차이 발견 → 추출 로직 수정 |
| 9 | `SP_GIT_PUSH` (`P_DELETE_MISSING`) | 커밋 `2094e00`: 3 updated, 1 deleted |
| 10 | 동일 내용 재실행 | `NO_CHANGE: 6 files compared` |
| 11 | 없는 브랜치 | `FAILED: GitHub GET ... -> 404`, 이력 FAILED |
| 12 | `SP_EXPORT_AND_PUSH('TBI','MGMT')` / `('TBI')` | `NO_CHANGE` (스키마 범위 비교·삭제) |
| 13 | SP_CW001 재배포 (Git → 운영 일치) | 현황 `동기화` |
| — | CodeCommit 경로 | **미검증** (이 계정에 CodeCommit 없음) |

테스트 종료 시점 현황:

| NO | 스키마 | 프로시저 | 현재 버전 | 커밋 | 최근 작업 | 백업 버전 | 백업 커밋 | 백업 유형 | Git 상태 |
|---|---|---|---|---|---|---|---|---|---|
| 1 | MGMT | SP_CW001 | v0.0.1 | 2094e00 | DEPLOY | v0.0.1 | 7d83543 | PRE_DEPLOY | 동기화 |
| 2 | MGMT | SP_GW001 | | | | | | SCHEDULED | 미관리 |
| 3 | MGMT | SP_GW002 | v0.0.1 | 7d83543 | DEPLOY | v0.0.1 | 7d83543 | PRE_DEPLOY | 동기화 |
| 10 | ML | SP_ML001 | | | | | | | 미관리 |
| 11 | ML | SP_ML010 | v0.0.1 | 7d83543 | DEPLOY | | | PRE_DEPLOY | 동기화 |
| 12 | ML | SP_ML011 | | | | | | | 미관리 |

---

## 9. 사내 적용 (AWS CodeCommit)

Snowflake Git 연동은 CodeCommit 을 지원하므로 Git Repository / FETCH / 배포 / 현황은 **그대로** 사용합니다. 차이는 `SP_GIT_PUSH` 의 외부 통신과 인증입니다.

| 항목 | 내용 |
|---|---|
| Git Repository | `ORIGIN = 'https://git-codecommit.<region>.amazonaws.com/v1/repos/<repo>'`, Secret 은 **CodeCommit HTTPS Git 자격 증명** |
| EAI | 사내 `GIT_EXT_INT` (EAI 는 계정 객체 — 스키마 없음). Network Rule 에 **`codecommit.<region>.amazonaws.com:443`** (API 엔드포인트) 포함 여부 확인 — git 엔드포인트(`git-codecommit...`)만으로는 boto3 호출 불가 |
| Push Secret | `TYPE = PASSWORD`, `USERNAME` = IAM Access Key ID, `PASSWORD` = Secret Access Key (Git 자격 증명과 **별도**) — EAI 의 `ALLOWED_AUTHENTICATION_SECRETS` 에 포함 |
| IAM 권한 | `codecommit:GetBranch`, `GetFile`, `GetFolder`, `CreateCommit` |
| 프로시저 변경 | `EXTERNAL_ACCESS_INTEGRATIONS = (GIT_EXT_INT)`, `SECRETS = ('git_cred' = <DB>.<SCHEMA>.<AWS_KEY_SECRET>)` 로 교체, `SP_EXPORT_AND_PUSH` 기본값 `P_PROVIDER => 'CODECOMMIT'`, `P_REPO`, `P_REGION` |

```sql
-- 사내 예시
CREATE OR REPLACE NETWORK RULE TBI.ML.NR_CODECOMMIT
  MODE = EGRESS TYPE = HOST_PORT
  VALUE_LIST = ('codecommit.ap-northeast-2.amazonaws.com:443');
-- 기존 GIT_EXT_INT 에 Network Rule / Secret 추가 (기존 값 유지하며 나열)
-- ALTER EXTERNAL ACCESS INTEGRATION GIT_EXT_INT SET
--   ALLOWED_NETWORK_RULES = (<기존 규칙>, TBI.ML.NR_CODECOMMIT)
--   ALLOWED_AUTHENTICATION_SECRETS = (<기존 시크릿>, TBI.ML.AWS_CC_KEY);
CREATE OR REPLACE SECRET TBI.ML.AWS_CC_KEY TYPE = PASSWORD
  USERNAME = '<AWS_ACCESS_KEY_ID>' PASSWORD = '<AWS_SECRET_ACCESS_KEY>';

CALL TBI.ML.SP_GIT_PUSH(P_PROVIDER => 'CODECOMMIT', P_REPO => 'SF_PROC', P_REGION => 'ap-northeast-2');
```
> 사내 보안 정책상 장기 Access Key 사용이 어렵다면 별도 검토 필요 (이 설계는 Access Key 방식만 구현).

---

## 10. 규칙 / 주의사항

| 항목 | 내용 |
|---|---|
| 운영 직접 수정 금지 | Git → `SP_DEPLOY_PROC` 경유. 직접 수정했다면 `SP_EXPORT_AND_PUSH` 로 Git 에 반영 |
| Workspace 와 SP_GIT_PUSH 병행 | SP_GIT_PUSH 후 Workspace 는 **Pull 먼저** (자동 Pull 불가) |
| 파일명 = 프로시저명 | 버전 접미사 금지, 오버로드는 `__2` |
| 소스에 DB/스키마 미기재 | 배포 시 `PROCEDURE <이름>(` → `PROCEDURE TBI.<SCHEMA>.<이름>(` 로 한정 |
| 대소문자 | 따옴표 혼합대소문자 이름 미지원 |
| COMMENT | 배포 시 덮어씀, 추출 시 제거, 원복 시 백업 당시 값 복원 |
| 시그니처 변경 | 새 오버로드 생성 → 구 시그니처 `DROP` |
| 자동 원복 | 컴파일 오류는 기존 객체가 유지되므로 안전장치 성격 |
| `P_DELETE_MISSING` | `P_DEST_DIR` 하위만 대상. 스키마 지정 실행 시 해당 스키마 폴더만 |
| 관리 DDL 형식 | `mgmt/proc_mgmt_objects.sql` 은 `GET_DDL` 출력이라 본문이 `AS '...'` (작은따옴표 이스케이프) 형식 |
| Git 브랜치 | 브랜치만 지원 (태그 미지원) |
| 현황 뷰 범위 | TBI DB (다른 DB 는 `procs` CTE 에 UNION) |
| 권한 | 모든 관리 SP 는 `EXECUTE AS CALLER` |

---

## 11. 향후 확장

- 다건 배포: `V_PROC_STATUS` 의 `Git 변경(미배포)` 대상 일괄 배포
- dev / prod 브랜치 분리 (`P_GIT_REF` + 대상 DB)
- 정기 Task 활성화 + 실패 알림
- CodeCommit 사내 검증 후 `SP_EXPORT_AND_PUSH` 기본값 전환
