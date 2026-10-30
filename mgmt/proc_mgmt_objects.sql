-- =====================================================================
-- 프로시저 백업 / Git 반영 / 버전관리 / 배포 - 관리 객체 (최종)
--   위치 : TBI.ML
--   Git  : TBI.ML.SF_PROC  (https://github.com/jjj-j/SF_PROC.git)
--   검증 : 2026-10-30 실행 검증
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Git 연결 (최초 1회)
-- ---------------------------------------------------------------------
-- CREATE API INTEGRATION IF NOT EXISTS GIT_INT
--   API_PROVIDER = git_https_api
--   API_ALLOWED_PREFIXES = ('https://github.com/jjj-j/')
--   ALLOWED_AUTHENTICATION_SECRETS = (TBI.ML.GIT_PAT)
--   ENABLED = TRUE;
-- CREATE OR REPLACE SECRET TBI.ML.GIT_PAT TYPE = PASSWORD USERNAME = 'jjj-j' PASSWORD = '<github_pat>';
CREATE GIT REPOSITORY IF NOT EXISTS TBI.ML.SF_PROC
  API_INTEGRATION = GIT_INT
  GIT_CREDENTIALS = TBI.ML.GIT_PAT
  ORIGIN = 'https://github.com/jjj-j/SF_PROC.git';

CREATE STAGE IF NOT EXISTS TBI.ML.STG_TBI_PROC DIRECTORY = (ENABLE = TRUE);

CREATE FILE FORMAT IF NOT EXISTS TBI.ML.FF_RAW_TEXT
    TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
    ESCAPE_UNENCLOSED_FIELD = NONE FIELD_OPTIONALLY_ENCLOSED_BY = NONE;

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS TBI.ML.PROC_DDL_BACKUP (
    BACKUP_ID      NUMBER AUTOINCREMENT START 1 INCREMENT 1 ORDER,
    BACKUP_TS      TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    RUN_ID         VARCHAR,          -- PROC_RUN_HIST.RUN_ID
    DB_NAME        VARCHAR,
    SCHEMA_NAME    VARCHAR,
    PROC_NAME      VARCHAR,
    PROC_SIGNATURE VARCHAR,          -- DB.SCHEMA.NAME(TYPE, ...)
    DDL            VARCHAR,          -- GET_DDL 결과 (DB/스키마 미포함)
    DDL_HASH       VARCHAR,          -- MD5(DDL), 직전 백업과 같으면 SKIP
    BK_COMMENT     VARCHAR,          -- 백업 시점 COMMENT
    BK_VERSION     VARCHAR,          -- COMMENT 의 버전
    BK_GIT_COMMIT  VARCHAR,          -- COMMENT 의 git 커밋
    BACKUP_TYPE    VARCHAR,          -- PRE_DEPLOY / PRE_ROLLBACK / SCHEDULED / MANUAL
    BACKUP_BY      VARCHAR DEFAULT CURRENT_USER(),
    BACKUP_ROLE    VARCHAR DEFAULT CURRENT_ROLE()
) COMMENT = '프로시저 DDL 백업 이력';

CREATE TABLE IF NOT EXISTS TBI.ML.PROC_RUN_HIST (
    RUN_ID         VARCHAR,
    RUN_TYPE       VARCHAR,          -- EXPORT / BACKUP / DEPLOY / ROLLBACK
    DB_NAME        VARCHAR,
    SCHEMA_NAME    VARCHAR,
    PROC_NAME      VARCHAR,
    PROC_SIGNATURE VARCHAR,
    SOURCE_PATH    VARCHAR,          -- Git 파일 / Stage 경로
    GIT_REF        VARCHAR,
    GIT_COMMIT     VARCHAR,
    VERSION        VARCHAR,
    FILE_HASH      VARCHAR,          -- 배포한 Git 파일 sha1
    BACKUP_ID      NUMBER,           -- 배포 전 / 원복 대상 백업
    STATUS         VARCHAR,          -- RUNNING / SUCCESS / FAILED
    OBJ_CNT        NUMBER,
    MESSAGE        VARCHAR,
    ERROR_MSG      VARCHAR,
    START_TS       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    END_TS         TIMESTAMP_LTZ,
    RUN_BY         VARCHAR DEFAULT CURRENT_USER(),
    RUN_ROLE       VARCHAR DEFAULT CURRENT_ROLE()
) COMMENT = '프로시저 추출/백업/배포/원복 수행이력';

CREATE TABLE IF NOT EXISTS TBI.ML.PROC_GIT_FILES (
    GIT_REF     VARCHAR,
    FILE_PATH   VARCHAR,             -- procedures/<SCHEMA>/<PROC>.sql
    SCHEMA_NAME VARCHAR,
    PROC_NAME   VARCHAR,
    GIT_SHA1    VARCHAR,
    GIT_COMMIT  VARCHAR,
    SYNC_TS     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
) COMMENT = 'Git(TBI.ML.SF_PROC) procedures/ 파일 인덱스 (SP_SYNC_GIT 로 갱신)';

-- ---------------------------------------------------------------------
-- 2. SP_BACKUP_PROC : 단건 백업
--    CALL TBI.ML.SP_BACKUP_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)');
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TBI.ML.SP_BACKUP_PROC(
    P_SIG VARCHAR, P_TYPE VARCHAR DEFAULT 'MANUAL', P_RUN_ID VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '프로시저 단건 DDL 백업 (직전 백업과 DDL 동일하면 SKIP)'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_ddl       VARCHAR;
    v_hash      VARCHAR;
    v_cmt       VARCHAR;
    v_last_id   NUMBER;
    v_last_hash VARCHAR;
BEGIN
    v_ddl  := (SELECT GET_DDL('PROCEDURE', :P_SIG));
    v_hash := MD5(v_ddl);
    v_cmt  := REGEXP_SUBSTR(v_ddl, 'COMMENT=''([^'']*)''', 1, 1, 'e', 1);

    v_last_id   := (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = :P_SIG);
    v_last_hash := (SELECT DDL_HASH FROM TBI.ML.PROC_DDL_BACKUP WHERE BACKUP_ID = :v_last_id);
    IF (v_last_hash = v_hash) THEN
        RETURN 'SKIP:' || v_last_id;
    END IF;

    -- COMMENT 형식: '버전 | git:커밋 | 일시'
    INSERT INTO TBI.ML.PROC_DDL_BACKUP
        (RUN_ID, DB_NAME, SCHEMA_NAME, PROC_NAME, PROC_SIGNATURE, DDL, DDL_HASH,
         BK_COMMENT, BK_VERSION, BK_GIT_COMMIT, BACKUP_TYPE)
    SELECT :P_RUN_ID, SPLIT_PART(:P_SIG, '.', 1), SPLIT_PART(:P_SIG, '.', 2),
           SPLIT_PART(SPLIT_PART(:P_SIG, '.', 3), '(', 1), :P_SIG, :v_ddl, :v_hash,
           :v_cmt,
           IFF(CONTAINS(:v_cmt, '| git:'), TRIM(SPLIT_PART(:v_cmt, '|', 1)), NULL),
           IFF(CONTAINS(:v_cmt, '| git:'), REPLACE(TRIM(SPLIT_PART(:v_cmt, '|', 2)), 'git:', ''), NULL),
           :P_TYPE;

    RETURN 'OK:' || (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = :P_SIG);
END;
$$;

-- ---------------------------------------------------------------------
-- 3. SP_BACKUP_SCHEMA_PROCS : 스키마 전체 백업 (정기)
--    CALL TBI.ML.SP_BACKUP_SCHEMA_PROCS('TBI', 'MGMT');
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TBI.ML.SP_BACKUP_SCHEMA_PROCS(
    P_DB VARCHAR, P_SCHEMA VARCHAR, P_TYPE VARCHAR DEFAULT 'SCHEDULED')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '스키마 전체 프로시저 DDL 백업 (변경분만 저장)'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_total  NUMBER DEFAULT 0;
    v_saved  NUMBER;
    v_err    VARCHAR;
    res      RESULTSET;
BEGIN
    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, STATUS)
    VALUES (:v_run_id, 'BACKUP', :P_DB, :P_SCHEMA, 'RUNNING');

    -- 동적 SQL 안의 정규식은 2회 해석되므로 \\\\1
    res := (EXECUTE IMMEDIATE
        'SELECT ''' || P_DB || '.'' || PROCEDURE_SCHEMA || ''.'' || PROCEDURE_NAME
                || REGEXP_REPLACE(ARGUMENT_SIGNATURE, ''([(]|, )[^ ]+ '', ''\\\\1'') AS SIG
         FROM ' || P_DB || '.INFORMATION_SCHEMA.PROCEDURES
         WHERE PROCEDURE_SCHEMA = ?' USING (P_SCHEMA));
    LET c1 CURSOR FOR res;
    FOR r IN c1 DO
        LET s VARCHAR := r.SIG;
        CALL TBI.ML.SP_BACKUP_PROC(:s, :P_TYPE, :v_run_id);
        v_total := v_total + 1;
    END FOR;

    v_saved := (SELECT COUNT(*) FROM TBI.ML.PROC_DDL_BACKUP WHERE RUN_ID = :v_run_id);
    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = 'SUCCESS', OBJ_CNT = :v_total,
           MESSAGE = :v_saved || ' saved / ' || (:v_total - :v_saved) || ' skipped(no change)',
           END_TS = CURRENT_TIMESTAMP()
     WHERE RUN_ID = :v_run_id;
    RETURN 'SUCCESS: ' || v_total || ' procs, ' || v_saved || ' saved, ' || (v_total - v_saved) || ' skipped';
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = 'FAILED', ERROR_MSG = :v_err, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN 'FAILED: ' || v_err;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. SP_EXPORT_PROCS : 현행 DDL -> Stage (Git 반영용)
--    CALL TBI.ML.SP_EXPORT_PROCS('TBI');            -- 전체 (관리용 SP 제외)
--    CALL TBI.ML.SP_EXPORT_PROCS('TBI', 'MGMT');
--    COPY FILES INTO 'snow://workspace/USER$.PUBLIC.SF_PROC/versions/live/procedures/'
--      FROM @TBI.ML.STG_TBI_PROC/procedures/;
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TBI.ML.SP_EXPORT_PROCS(
    P_DB VARCHAR, P_SCHEMA VARCHAR DEFAULT NULL,
    P_EXCLUDE VARCHAR DEFAULT 'SP_(BACKUP|EXPORT|DEPLOY|ROLLBACK|SYNC)_.*')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '프로시저 DDL -> @TBI.ML.STG_TBI_PROC/procedures/<SCHEMA>/<PROC>.sql'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_cnt    NUMBER DEFAULT 0;
    v_sql    VARCHAR;
    v_err    VARCHAR;
    res      RESULTSET;
BEGIN
    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, SOURCE_PATH, STATUS)
    VALUES (:v_run_id, 'EXPORT', :P_DB, :P_SCHEMA, '@TBI.ML.STG_TBI_PROC/procedures/', 'RUNNING');

    res := (EXECUTE IMMEDIATE
        'SELECT PROCEDURE_SCHEMA AS S, PROCEDURE_NAME AS N,
                REGEXP_REPLACE(ARGUMENT_SIGNATURE, ''([(]|, )[^ ]+ '', ''\\\\1'') AS SIG,
                PROCEDURE_NAME || IFF(ROW_NUMBER() OVER (PARTITION BY PROCEDURE_SCHEMA, PROCEDURE_NAME ORDER BY ARGUMENT_SIGNATURE) > 1,
                    ''__'' || ROW_NUMBER() OVER (PARTITION BY PROCEDURE_SCHEMA, PROCEDURE_NAME ORDER BY ARGUMENT_SIGNATURE), '''') AS FNAME
         FROM ' || P_DB || '.INFORMATION_SCHEMA.PROCEDURES
         WHERE (? IS NULL OR PROCEDURE_SCHEMA = ?)
           AND (? IS NULL OR NOT REGEXP_LIKE(PROCEDURE_NAME, ?))'
        USING (P_SCHEMA, P_SCHEMA, P_EXCLUDE, P_EXCLUDE));
    LET c CURSOR FOR res;
    FOR r IN c DO
        LET full_sig VARCHAR := P_DB || '.' || r.S || '.' || r.N || r.SIG;
        LET path VARCHAR := '@TBI.ML.STG_TBI_PROC/procedures/' || r.S || '/' || r.FNAME || '.sql';
        v_sql := 'COPY INTO ' || path ||
                 ' FROM (SELECT GET_DDL(''PROCEDURE'', ''' || full_sig || '''))' ||
                 ' FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE' ||
                 ' FIELD_OPTIONALLY_ENCLOSED_BY = NONE ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE)' ||
                 ' SINGLE = TRUE HEADER = FALSE OVERWRITE = TRUE';
        EXECUTE IMMEDIATE :v_sql;
        v_cnt := v_cnt + 1;
    END FOR;

    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = 'SUCCESS', OBJ_CNT = :v_cnt, END_TS = CURRENT_TIMESTAMP(),
           MESSAGE = :v_cnt || ' procedures exported'
     WHERE RUN_ID = :v_run_id;
    RETURN 'SUCCESS: ' || v_cnt || ' procedures exported to @TBI.ML.STG_TBI_PROC/procedures/';
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = 'FAILED', ERROR_MSG = :v_err, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN 'FAILED: ' || v_err;
END;
$$;

-- ---------------------------------------------------------------------
-- 5. SP_SYNC_GIT : FETCH + Git 파일 인덱스 갱신 (커밋 해시 반환)
--    CALL TBI.ML.SP_SYNC_GIT();
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TBI.ML.SP_SYNC_GIT(P_GIT_REF VARCHAR DEFAULT 'main')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Git FETCH 후 procedures/ 파일 목록(sha1)을 PROC_GIT_FILES 에 반영, 커밋 해시 반환'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_commit VARCHAR;
    v_qid    VARCHAR;
BEGIN
    ALTER GIT REPOSITORY TBI.ML.SF_PROC FETCH;
    SHOW GIT BRANCHES IN GIT REPOSITORY TBI.ML.SF_PROC;
    v_commit := (SELECT LEFT("commit_hash", 7) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "name" = :P_GIT_REF);
    IF (v_commit IS NULL) THEN
        RETURN 'NO_BRANCH';
    END IF;

    EXECUTE IMMEDIATE 'LIST @TBI.ML.SF_PROC/branches/' || P_GIT_REF || '/';
    v_qid := LAST_QUERY_ID();

    DELETE FROM TBI.ML.PROC_GIT_FILES WHERE GIT_REF = :P_GIT_REF;
    INSERT INTO TBI.ML.PROC_GIT_FILES (GIT_REF, FILE_PATH, SCHEMA_NAME, PROC_NAME, GIT_SHA1, GIT_COMMIT)
    SELECT :P_GIT_REF,
           REGEXP_SUBSTR("name", 'procedures/.*'),
           SPLIT_PART(REGEXP_SUBSTR("name", 'procedures/.*'), '/', 2),
           UPPER(SPLIT_PART(REPLACE(SPLIT_PART("name", '/', -1), '.sql', ''), '__', 1)),
           "sha1",
           :v_commit
      FROM TABLE(RESULT_SCAN(:v_qid))
     WHERE "name" ILIKE '%/procedures/%.sql';
    RETURN v_commit;
END;
$$;

-- ---------------------------------------------------------------------
-- 6. SP_DEPLOY_PROC : Git 파일 배포
--    CALL TBI.ML.SP_DEPLOY_PROC('TBI', 'MGMT', 'procedures/MGMT/SP_CW001.sql', 'v0.0.1');
--    (오버로드) ..., 'main', '(VARCHAR, NUMBER)'
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TBI.ML.SP_DEPLOY_PROC(
    P_DB VARCHAR, P_SCHEMA VARCHAR, P_FILE VARCHAR, P_VERSION VARCHAR,
    P_GIT_REF VARCHAR DEFAULT 'main', P_ARG_TYPES VARCHAR DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Git(TBI.ML.SF_PROC) 파일 배포: FETCH -> 백업 -> 배포 -> COMMENT -> 이력 (실패 시 자동 원복)'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id   VARCHAR DEFAULT UUID_STRING();
    v_src      VARCHAR;
    v_name     VARCHAR;
    v_commit   VARCHAR;
    v_content  VARCHAR;
    v_hash     VARCHAR;
    v_sig      VARCHAR;
    v_cnt      NUMBER;
    v_bk_id    NUMBER;
    v_deployed BOOLEAN DEFAULT FALSE;
    v_ddl      VARCHAR;
    v_msg      VARCHAR;
    v_err      VARCHAR;
    res        RESULTSET;
    e_nofile   EXCEPTION (-20001, 'Git 파일을 찾을 수 없음');
    e_commit   EXCEPTION (-20002, 'Git 브랜치를 찾을 수 없음');
    e_sig      EXCEPTION (-20003, '대상 프로시저가 여러 개(오버로드) - P_ARG_TYPES 지정 필요');
BEGIN
    v_name := UPPER(SPLIT_PART(REPLACE(SPLIT_PART(P_FILE, '/', -1), '.sql', ''), '__', 1));
    v_src  := '@TBI.ML.SF_PROC/branches/' || P_GIT_REF || '/' || P_FILE;

    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, PROC_NAME, SOURCE_PATH, GIT_REF, VERSION, STATUS)
    VALUES (:v_run_id, 'DEPLOY', :P_DB, :P_SCHEMA, :v_name, :v_src, :P_GIT_REF, :P_VERSION, 'RUNNING');

    -- 1) FETCH + Git 인덱스 갱신 + 커밋
    CALL TBI.ML.SP_SYNC_GIT(:P_GIT_REF);
    v_commit := (SELECT MAX(GIT_COMMIT) FROM TBI.ML.PROC_GIT_FILES WHERE GIT_REF = :P_GIT_REF);
    IF (v_commit IS NULL) THEN RAISE e_commit; END IF;
    v_hash := (SELECT GIT_SHA1 FROM TBI.ML.PROC_GIT_FILES WHERE GIT_REF = :P_GIT_REF AND FILE_PATH = :P_FILE);
    IF (v_hash IS NULL) THEN RAISE e_nofile; END IF;

    -- 2) Git 파일 읽기
    res := (EXECUTE IMMEDIATE 'SELECT $1 AS TXT FROM ' || v_src || ' (FILE_FORMAT => ''TBI.ML.FF_RAW_TEXT'')');
    LET c1 CURSOR FOR res;
    OPEN c1;
    FETCH c1 INTO v_content;
    CLOSE c1;
    IF (v_content IS NULL) THEN RAISE e_nofile; END IF;

    -- 3) 기존 프로시저 확인 -> 백업
    EXECUTE IMMEDIATE 'SHOW PROCEDURES LIKE ''' || v_name || ''' IN SCHEMA ' || P_DB || '.' || P_SCHEMA;
    SELECT COUNT(*), MAX(:P_DB || '.' || :P_SCHEMA || '.' || SPLIT_PART("arguments", ' RETURN ', 1))
      INTO :v_cnt, :v_sig
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE :P_ARG_TYPES IS NULL OR SPLIT_PART("arguments", ' RETURN ', 1) = :v_name || :P_ARG_TYPES;
    IF (v_cnt > 1) THEN RAISE e_sig; END IF;
    IF (v_sig IS NOT NULL) THEN
        CALL TBI.ML.SP_BACKUP_PROC(:v_sig, 'PRE_DEPLOY', :v_run_id);
        v_bk_id := (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = :v_sig);
    END IF;

    -- 4) 배포 (프로시저명을 대상 DB.SCHEMA 로 한정)
    v_content := REGEXP_REPLACE(v_content, 'PROCEDURE\\s+"?([A-Za-z0-9_$]+)"?\\s*\\(',
                                'PROCEDURE ' || P_DB || '.' || P_SCHEMA || '.\\1(', 1, 1, 'i');
    v_deployed := TRUE;
    EXECUTE IMMEDIATE :v_content;

    -- 5) 배포 후 시그니처 확정 + COMMENT
    EXECUTE IMMEDIATE 'SHOW PROCEDURES LIKE ''' || v_name || ''' IN SCHEMA ' || P_DB || '.' || P_SCHEMA;
    SELECT COUNT(*), MAX(:P_DB || '.' || :P_SCHEMA || '.' || SPLIT_PART("arguments", ' RETURN ', 1))
      INTO :v_cnt, :v_sig
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE :P_ARG_TYPES IS NULL OR SPLIT_PART("arguments", ' RETURN ', 1) = :v_name || :P_ARG_TYPES;
    IF (v_cnt > 1) THEN RAISE e_sig; END IF;

    EXECUTE IMMEDIATE 'ALTER PROCEDURE ' || v_sig || ' SET COMMENT = '''
        || P_VERSION || ' | git:' || v_commit || ' | ' || TO_CHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD HH24:MI') || '''';

    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = 'SUCCESS', PROC_SIGNATURE = :v_sig, GIT_COMMIT = :v_commit, FILE_HASH = :v_hash,
           BACKUP_ID = :v_bk_id, OBJ_CNT = 1, END_TS = CURRENT_TIMESTAMP(),
           MESSAGE = 'deployed ' || :P_VERSION || ' (git:' || :v_commit || ')'
     WHERE RUN_ID = :v_run_id;
    RETURN 'SUCCESS: ' || v_sig || ' ' || P_VERSION || ' git:' || v_commit || ' (backup_id=' || COALESCE(v_bk_id::VARCHAR, 'new') || ')';

EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        v_msg := 'no rollback';
        IF (v_deployed AND v_bk_id IS NOT NULL) THEN
            BEGIN
                v_ddl := (SELECT DDL FROM TBI.ML.PROC_DDL_BACKUP WHERE BACKUP_ID = :v_bk_id);
                v_ddl := REGEXP_REPLACE(v_ddl, 'PROCEDURE\\s+"?([A-Za-z0-9_$]+)"?\\s*\\(',
                                        'PROCEDURE ' || P_DB || '.' || P_SCHEMA || '.\\1(', 1, 1, 'i');
                EXECUTE IMMEDIATE :v_ddl;
                v_msg := 'auto-rollback to backup_id=' || v_bk_id;
            EXCEPTION
                WHEN OTHER THEN
                    v_msg := 'auto-rollback FAILED: ' || SQLERRM;
            END;
        END IF;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = 'FAILED', GIT_COMMIT = :v_commit, FILE_HASH = :v_hash, BACKUP_ID = :v_bk_id,
               ERROR_MSG = :v_err, MESSAGE = :v_msg, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN 'FAILED: ' || v_err || ' / ' || v_msg;
END;
$$;

-- ---------------------------------------------------------------------
-- 7. SP_ROLLBACK_PROC : 백업으로 원복
--    CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)');      -- 직전 버전
--    CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)', 12);  -- 지정 백업
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE TBI.ML.SP_ROLLBACK_PROC(P_SIG VARCHAR, P_BACKUP_ID NUMBER DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = '백업 DDL 로 원복 (미지정 시 현재 DDL 과 다른 최신 백업)'
EXECUTE AS CALLER
AS
$$
DECLARE
    v_run_id  VARCHAR DEFAULT UUID_STRING();
    v_db      VARCHAR;
    v_schema  VARCHAR;
    v_cur     VARCHAR;
    v_bk_id   NUMBER;
    v_ddl     VARCHAR;
    v_ver     VARCHAR;
    v_commit  VARCHAR;
    v_err     VARCHAR;
    e_nobk    EXCEPTION (-20011, '원복할 백업이 없음');
BEGIN
    v_db     := SPLIT_PART(P_SIG, '.', 1);
    v_schema := SPLIT_PART(P_SIG, '.', 2);
    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, PROC_NAME, PROC_SIGNATURE, STATUS)
    VALUES (:v_run_id, 'ROLLBACK', :v_db, :v_schema, SPLIT_PART(SPLIT_PART(:P_SIG, '.', 3), '(', 1), :P_SIG, 'RUNNING');

    v_cur   := (SELECT MD5(GET_DDL('PROCEDURE', :P_SIG)));
    v_bk_id := COALESCE(P_BACKUP_ID,
                 (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP
                   WHERE PROC_SIGNATURE = :P_SIG AND DDL_HASH <> :v_cur));
    IF (v_bk_id IS NULL) THEN RAISE e_nobk; END IF;

    SELECT DDL, BK_VERSION, BK_GIT_COMMIT INTO :v_ddl, :v_ver, :v_commit
      FROM TBI.ML.PROC_DDL_BACKUP WHERE BACKUP_ID = :v_bk_id;

    CALL TBI.ML.SP_BACKUP_PROC(:P_SIG, 'PRE_ROLLBACK', :v_run_id);

    v_ddl := REGEXP_REPLACE(v_ddl, 'PROCEDURE\\s+"?([A-Za-z0-9_$]+)"?\\s*\\(',
                            'PROCEDURE ' || v_db || '.' || v_schema || '.\\1(', 1, 1, 'i');
    EXECUTE IMMEDIATE :v_ddl;

    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = 'SUCCESS', VERSION = :v_ver, GIT_COMMIT = :v_commit, BACKUP_ID = :v_bk_id,
           OBJ_CNT = 1, END_TS = CURRENT_TIMESTAMP(),
           MESSAGE = 'rolled back to backup_id=' || :v_bk_id || ' (' || COALESCE(:v_ver, 'no version') || ')'
     WHERE RUN_ID = :v_run_id;
    RETURN 'SUCCESS: ' || P_SIG || ' -> backup_id=' || v_bk_id || ' ' || COALESCE(v_ver, '');
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = 'FAILED', ERROR_MSG = :v_err, BACKUP_ID = :v_bk_id, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN 'FAILED: ' || v_err;
END;
$$;

-- ---------------------------------------------------------------------
-- 8. V_PROC_STATUS : 프로시저 현황
--    SELECT * FROM TBI.ML.V_PROC_STATUS;   (Git 상태는 마지막 SP_SYNC_GIT 기준)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW TBI.ML.V_PROC_STATUS
COMMENT = '프로시저 현황: 현재 적용 버전 / 최근 배포 / 최근 백업 / Git 동기화 상태 (Git 은 마지막 SP_SYNC_GIT 기준)'
AS
WITH procs AS (
    SELECT PROCEDURE_CATALOG AS DB_NAME, PROCEDURE_SCHEMA AS SCHEMA_NAME, PROCEDURE_NAME AS PROC_NAME,
           PROCEDURE_CATALOG || '.' || PROCEDURE_SCHEMA || '.' || PROCEDURE_NAME
             || REGEXP_REPLACE(ARGUMENT_SIGNATURE, '([(]|, )[^ ]+ ', '\\1') AS PROC_SIGNATURE,
           COMMENT, LAST_ALTERED
    FROM TBI.INFORMATION_SCHEMA.PROCEDURES
    WHERE PROCEDURE_SCHEMA <> 'INFORMATION_SCHEMA'
), deploy AS (
    SELECT PROC_SIGNATURE, RUN_TYPE, GIT_COMMIT, VERSION, FILE_HASH, END_TS, RUN_BY
    FROM TBI.ML.PROC_RUN_HIST
    WHERE RUN_TYPE IN ('DEPLOY', 'ROLLBACK') AND STATUS = 'SUCCESS'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PROC_SIGNATURE ORDER BY END_TS DESC) = 1
), bk AS (
    SELECT PROC_SIGNATURE, BACKUP_ID, BK_VERSION, BK_GIT_COMMIT, BACKUP_TS, BACKUP_TYPE, BACKUP_BY
    FROM TBI.ML.PROC_DDL_BACKUP
    QUALIFY ROW_NUMBER() OVER (PARTITION BY PROC_SIGNATURE ORDER BY BACKUP_ID DESC) = 1
), git AS (
    SELECT SCHEMA_NAME, PROC_NAME, FILE_PATH, GIT_SHA1, GIT_COMMIT
    FROM TBI.ML.PROC_GIT_FILES
    WHERE GIT_REF = 'main'
)
SELECT
    ROW_NUMBER() OVER (ORDER BY p.DB_NAME, p.SCHEMA_NAME, p.PROC_NAME, p.PROC_SIGNATURE) AS NO,
    p.DB_NAME,
    p.SCHEMA_NAME,
    p.PROC_NAME,
    p.PROC_SIGNATURE,
    IFF(CONTAINS(p.COMMENT, '| git:'), TRIM(SPLIT_PART(p.COMMENT, '|', 1)), NULL)                      AS CUR_VERSION,
    IFF(CONTAINS(p.COMMENT, '| git:'), REPLACE(TRIM(SPLIT_PART(p.COMMENT, '|', 2)), 'git:', ''), NULL) AS CUR_GIT_COMMIT,
    d.END_TS        AS DEPLOY_TS,
    d.RUN_BY        AS DEPLOY_BY,
    d.RUN_TYPE      AS LAST_ACTION,
    b.BK_VERSION,
    b.BK_GIT_COMMIT,
    b.BACKUP_TS,
    b.BACKUP_TYPE,
    b.BACKUP_ID,
    g.FILE_PATH     AS GIT_FILE,
    g.GIT_COMMIT    AS GIT_HEAD_COMMIT,
    CASE
        WHEN g.FILE_PATH IS NULL       THEN 'Git 없음'
        WHEN d.PROC_SIGNATURE IS NULL  THEN '미관리(배포이력 없음)'
        WHEN d.RUN_TYPE = 'ROLLBACK'   THEN '원복됨(Git과 다름)'
        WHEN g.GIT_SHA1 = d.FILE_HASH  THEN '동기화'
        ELSE 'Git 변경(미배포)'
    END             AS GIT_STATUS,
    p.LAST_ALTERED,
    p.COMMENT
FROM procs p
LEFT JOIN deploy d ON d.PROC_SIGNATURE = p.PROC_SIGNATURE
LEFT JOIN bk b     ON b.PROC_SIGNATURE = p.PROC_SIGNATURE
LEFT JOIN git g    ON g.SCHEMA_NAME = p.SCHEMA_NAME AND g.PROC_NAME = p.PROC_NAME;
