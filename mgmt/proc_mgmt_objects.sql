-- =====================================================================
-- 프로시저 백업 / Git 반영 / 버전관리 / 배포 - 관리 객체 (최종)
--   위치 : TBI.ML   /  Git : TBI.ML.SF_PROC (https://github.com/jjj-j/SF_PROC.git)
--   생성 : GET_DDL 로 실제 객체에서 추출 (2026-10-30 실행 검증)
--   상세 : docs/DESIGN.md
-- =====================================================================

USE SCHEMA TBI.ML;

-- ---------------------------------------------------------------------
-- 0. 연결 객체 (계정/환경별 1회)
-- ---------------------------------------------------------------------
-- CREATE API INTEGRATION GIT_INT API_PROVIDER = git_https_api
--   API_ALLOWED_PREFIXES = ('https://github.com/jjj-j/') ALLOWED_AUTHENTICATION_SECRETS = (TBI.ML.GIT_PAT) ENABLED = TRUE;
-- CREATE SECRET TBI.ML.GIT_PAT TYPE = PASSWORD USERNAME = 'jjj-j' PASSWORD = '<github_pat>';
-- CREATE GIT REPOSITORY TBI.ML.SF_PROC API_INTEGRATION = GIT_INT GIT_CREDENTIALS = TBI.ML.GIT_PAT
--   ORIGIN = 'https://github.com/jjj-j/SF_PROC.git';
-- CREATE NETWORK RULE TBI.ML.NR_GITHUB_API MODE = EGRESS TYPE = HOST_PORT VALUE_LIST = ('api.github.com:443');
-- CREATE EXTERNAL ACCESS INTEGRATION GIT_PUSH_EAI ALLOWED_NETWORK_RULES = (TBI.ML.NR_GITHUB_API)
--   ALLOWED_AUTHENTICATION_SECRETS = (TBI.ML.GIT_PAT) ENABLED = TRUE;
-- CREATE STAGE TBI.ML.STG_TBI_PROC DIRECTORY = (ENABLE = TRUE);
-- CREATE FILE FORMAT TBI.ML.FF_RAW_TEXT TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
--   ESCAPE_UNENCLOSED_FIELD = NONE FIELD_OPTIONALLY_ENCLOSED_BY = NONE;
--
-- [사내 CodeCommit] SP_GIT_PUSH 의 EXTERNAL_ACCESS_INTEGRATIONS / SECRETS 교체 -> docs/DESIGN.md 9장

-- ---------------------------------------------------------------------
-- 1. 테이블
-- ---------------------------------------------------------------------
create or replace TABLE PROC_DDL_BACKUP (
	BACKUP_ID NUMBER(38,0) autoincrement start 1 increment 1 order,
	BACKUP_TS TIMESTAMP_LTZ(9) DEFAULT CURRENT_TIMESTAMP(),
	RUN_ID VARCHAR(16777216),
	DB_NAME VARCHAR(16777216),
	SCHEMA_NAME VARCHAR(16777216),
	PROC_NAME VARCHAR(16777216),
	PROC_SIGNATURE VARCHAR(16777216),
	DDL VARCHAR(16777216),
	DDL_HASH VARCHAR(16777216),
	BK_COMMENT VARCHAR(16777216),
	BK_VERSION VARCHAR(16777216),
	BK_GIT_COMMIT VARCHAR(16777216),
	BACKUP_TYPE VARCHAR(16777216),
	BACKUP_BY VARCHAR(16777216) DEFAULT CURRENT_USER(),
	BACKUP_ROLE VARCHAR(16777216) DEFAULT CURRENT_ROLE()
)COMMENT='프로시저 DDL 백업 이력'
;
create or replace TABLE PROC_RUN_HIST (
	RUN_ID VARCHAR(16777216),
	RUN_TYPE VARCHAR(16777216),
	DB_NAME VARCHAR(16777216),
	SCHEMA_NAME VARCHAR(16777216),
	PROC_NAME VARCHAR(16777216),
	PROC_SIGNATURE VARCHAR(16777216),
	SOURCE_PATH VARCHAR(16777216),
	GIT_REF VARCHAR(16777216),
	GIT_COMMIT VARCHAR(16777216),
	VERSION VARCHAR(16777216),
	FILE_HASH VARCHAR(16777216),
	BACKUP_ID NUMBER(38,0),
	STATUS VARCHAR(16777216),
	OBJ_CNT NUMBER(38,0),
	MESSAGE VARCHAR(16777216),
	ERROR_MSG VARCHAR(16777216),
	START_TS TIMESTAMP_LTZ(9) DEFAULT CURRENT_TIMESTAMP(),
	END_TS TIMESTAMP_LTZ(9),
	RUN_BY VARCHAR(16777216) DEFAULT CURRENT_USER(),
	RUN_ROLE VARCHAR(16777216) DEFAULT CURRENT_ROLE()
)COMMENT='프로시저 추출/백업/배포/원복 수행이력'
;
create or replace TABLE PROC_GIT_FILES (
	GIT_REF VARCHAR(16777216),
	FILE_PATH VARCHAR(16777216),
	SCHEMA_NAME VARCHAR(16777216),
	PROC_NAME VARCHAR(16777216),
	GIT_SHA1 VARCHAR(16777216),
	GIT_COMMIT VARCHAR(16777216),
	SYNC_TS TIMESTAMP_LTZ(9) DEFAULT CURRENT_TIMESTAMP()
)COMMENT='Git(TBI.ML.SF_PROC) procedures/ 파일 인덱스 (SP_SYNC_GIT 로 갱신)'
;

-- ---------------------------------------------------------------------
-- 2. 백업
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "SP_BACKUP_PROC"("P_SIG" VARCHAR, "P_TYPE" VARCHAR DEFAULT 'MANUAL', "P_RUN_ID" VARCHAR DEFAULT null)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='프로시저 단건 DDL 백업 (직전 백업과 DDL 동일하면 SKIP)'
EXECUTE AS CALLER
AS '
DECLARE
    v_ddl       VARCHAR;
    v_hash      VARCHAR;
    v_cmt       VARCHAR;
    v_last_id   NUMBER;
    v_last_hash VARCHAR;
BEGIN
    v_ddl  := (SELECT GET_DDL(''PROCEDURE'', :P_SIG));
    v_hash := MD5(v_ddl);
    v_cmt  := REGEXP_SUBSTR(v_ddl, ''COMMENT=''''([^'''']*)'''''', 1, 1, ''e'', 1);

    v_last_id   := (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = :P_SIG);
    v_last_hash := (SELECT DDL_HASH FROM TBI.ML.PROC_DDL_BACKUP WHERE BACKUP_ID = :v_last_id);
    IF (v_last_hash = v_hash) THEN
        RETURN ''SKIP:'' || v_last_id;
    END IF;

    -- COMMENT 형식: ''버전 | git:커밋 | 일시''
    INSERT INTO TBI.ML.PROC_DDL_BACKUP
        (RUN_ID, DB_NAME, SCHEMA_NAME, PROC_NAME, PROC_SIGNATURE, DDL, DDL_HASH,
         BK_COMMENT, BK_VERSION, BK_GIT_COMMIT, BACKUP_TYPE)
    SELECT :P_RUN_ID, SPLIT_PART(:P_SIG, ''.'', 1), SPLIT_PART(:P_SIG, ''.'', 2),
           SPLIT_PART(SPLIT_PART(:P_SIG, ''.'', 3), ''('', 1), :P_SIG, :v_ddl, :v_hash,
           :v_cmt,
           IFF(CONTAINS(:v_cmt, ''| git:''), TRIM(SPLIT_PART(:v_cmt, ''|'', 1)), NULL),
           IFF(CONTAINS(:v_cmt, ''| git:''), REPLACE(TRIM(SPLIT_PART(:v_cmt, ''|'', 2)), ''git:'', ''''), NULL),
           :P_TYPE;

    RETURN ''OK:'' || (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = :P_SIG);
END;
';

CREATE OR REPLACE PROCEDURE "SP_BACKUP_SCHEMA_PROCS"("P_DB" VARCHAR, "P_SCHEMA" VARCHAR, "P_TYPE" VARCHAR DEFAULT 'SCHEDULED')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='스키마 전체 프로시저 DDL 백업 (변경분만 저장)'
EXECUTE AS CALLER
AS '
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_total  NUMBER DEFAULT 0;
    v_saved  NUMBER;
    v_err    VARCHAR;
    res      RESULTSET;
BEGIN
    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, STATUS)
    VALUES (:v_run_id, ''BACKUP'', :P_DB, :P_SCHEMA, ''RUNNING'');

    res := (EXECUTE IMMEDIATE
        ''SELECT '''''' || P_DB || ''.'''' || PROCEDURE_SCHEMA || ''''.'''' || PROCEDURE_NAME
                || REGEXP_REPLACE(ARGUMENT_SIGNATURE, ''''([(]|, )[^ ]+ '''', ''''\\\\\\\\1'''') AS SIG
         FROM '' || P_DB || ''.INFORMATION_SCHEMA.PROCEDURES
         WHERE PROCEDURE_SCHEMA = ?'' USING (P_SCHEMA));
    LET c1 CURSOR FOR res;
    FOR r IN c1 DO
        LET s VARCHAR := r.SIG;
        CALL TBI.ML.SP_BACKUP_PROC(:s, :P_TYPE, :v_run_id);
        v_total := v_total + 1;
    END FOR;

    v_saved := (SELECT COUNT(*) FROM TBI.ML.PROC_DDL_BACKUP WHERE RUN_ID = :v_run_id);
    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = ''SUCCESS'', OBJ_CNT = :v_total,
           MESSAGE = :v_saved || '' saved / '' || (:v_total - :v_saved) || '' skipped(no change)'',
           END_TS = CURRENT_TIMESTAMP()
     WHERE RUN_ID = :v_run_id;
    RETURN ''SUCCESS: '' || v_total || '' procs, '' || v_saved || '' saved, '' || (v_total - v_saved) || '' skipped'';
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = ''FAILED'', ERROR_MSG = :v_err, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN ''FAILED: '' || v_err;
END;
';

-- ---------------------------------------------------------------------
-- 3. 추출 / Git 동기화 / Git Push
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "SP_EXPORT_PROCS"("P_DB" VARCHAR, "P_SCHEMA" VARCHAR DEFAULT null, "P_EXCLUDE" VARCHAR DEFAULT 'SP_(BACKUP|EXPORT|DEPLOY|ROLLBACK|SYNC|GIT)_.*')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='프로시저 DDL -> @TBI.ML.STG_TBI_PROC/procedures/<SCHEMA>/<PROC>.sql (배포 COMMENT 제외)'
EXECUTE AS CALLER
AS '
DECLARE
    v_run_id VARCHAR DEFAULT UUID_STRING();
    v_cnt    NUMBER DEFAULT 0;
    v_sql    VARCHAR;
    v_err    VARCHAR;
    v_pat    VARCHAR;
    res      RESULTSET;
BEGIN
    -- 배포 시 기록한 COMMENT 줄 (''버전 | git:커밋 | 일시'') 은 Git 소스에서 제외
    v_pat := CHR(10) || ''COMMENT=''''[^'''']*[|] git:[^'''']*'''''';

    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, SOURCE_PATH, STATUS)
    VALUES (:v_run_id, ''EXPORT'', :P_DB, :P_SCHEMA, ''@TBI.ML.STG_TBI_PROC/procedures/'', ''RUNNING'');

    res := (EXECUTE IMMEDIATE
        ''SELECT PROCEDURE_SCHEMA AS S, PROCEDURE_NAME AS N,
                REGEXP_REPLACE(ARGUMENT_SIGNATURE, ''''([(]|, )[^ ]+ '''', ''''\\\\\\\\1'''') AS SIG,
                PROCEDURE_NAME || IFF(ROW_NUMBER() OVER (PARTITION BY PROCEDURE_SCHEMA, PROCEDURE_NAME ORDER BY ARGUMENT_SIGNATURE) > 1,
                    ''''__'''' || ROW_NUMBER() OVER (PARTITION BY PROCEDURE_SCHEMA, PROCEDURE_NAME ORDER BY ARGUMENT_SIGNATURE), '''''''') AS FNAME
         FROM '' || P_DB || ''.INFORMATION_SCHEMA.PROCEDURES
         WHERE (? IS NULL OR PROCEDURE_SCHEMA = ?)
           AND (? IS NULL OR NOT REGEXP_LIKE(PROCEDURE_NAME, ?))''
        USING (P_SCHEMA, P_SCHEMA, P_EXCLUDE, P_EXCLUDE));
    LET c CURSOR FOR res;
    FOR r IN c DO
        LET full_sig VARCHAR := P_DB || ''.'' || r.S || ''.'' || r.N || r.SIG;
        LET path VARCHAR := ''@TBI.ML.STG_TBI_PROC/procedures/'' || r.S || ''/'' || r.FNAME || ''.sql'';
        v_sql := ''COPY INTO '' || path ||
                 '' FROM (SELECT REGEXP_REPLACE(GET_DDL(''''PROCEDURE'''', '''''' || full_sig || ''''''), '''''' ||
                 REPLACE(v_pat, '''''''', '''''''''''') || '''''', ''''''''))'' ||
                 '' FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE'' ||
                 '' FIELD_OPTIONALLY_ENCLOSED_BY = NONE ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE)'' ||
                 '' SINGLE = TRUE HEADER = FALSE OVERWRITE = TRUE'';
        EXECUTE IMMEDIATE :v_sql;
        v_cnt := v_cnt + 1;
    END FOR;

    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = ''SUCCESS'', OBJ_CNT = :v_cnt, END_TS = CURRENT_TIMESTAMP(),
           MESSAGE = :v_cnt || '' procedures exported''
     WHERE RUN_ID = :v_run_id;
    RETURN ''SUCCESS: '' || v_cnt || '' procedures exported to @TBI.ML.STG_TBI_PROC/procedures/'';
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = ''FAILED'', ERROR_MSG = :v_err, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN ''FAILED: '' || v_err;
END;
';

CREATE OR REPLACE PROCEDURE "SP_SYNC_GIT"("P_GIT_REF" VARCHAR DEFAULT 'main')
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Git FETCH 후 procedures/ 파일 목록(sha1)을 PROC_GIT_FILES 에 반영, 커밋 해시 반환'
EXECUTE AS CALLER
AS '
DECLARE
    v_commit VARCHAR;
    v_qid    VARCHAR;
    v_cnt    NUMBER;
BEGIN
    ALTER GIT REPOSITORY TBI.ML.SF_PROC FETCH;
    SHOW GIT BRANCHES IN GIT REPOSITORY TBI.ML.SF_PROC;
    v_commit := (SELECT LEFT("commit_hash", 7) FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE "name" = :P_GIT_REF);
    IF (v_commit IS NULL) THEN
        RETURN ''NO_BRANCH'';
    END IF;

    EXECUTE IMMEDIATE ''LIST @TBI.ML.SF_PROC/branches/'' || P_GIT_REF || ''/'';
    v_qid := LAST_QUERY_ID();

    DELETE FROM TBI.ML.PROC_GIT_FILES WHERE GIT_REF = :P_GIT_REF;
    INSERT INTO TBI.ML.PROC_GIT_FILES (GIT_REF, FILE_PATH, SCHEMA_NAME, PROC_NAME, GIT_SHA1, GIT_COMMIT)
    SELECT :P_GIT_REF,
           REGEXP_SUBSTR("name", ''procedures/.*''),
           SPLIT_PART(REGEXP_SUBSTR("name", ''procedures/.*''), ''/'', 2),
           UPPER(SPLIT_PART(REPLACE(SPLIT_PART("name", ''/'', -1), ''.sql'', ''''), ''__'', 1)),
           "sha1",
           :v_commit
      FROM TABLE(RESULT_SCAN(:v_qid))
     WHERE "name" ILIKE ''%/procedures/%.sql'';
    v_cnt := SQLROWCOUNT;
    RETURN v_commit;
END;
';

CREATE OR REPLACE PROCEDURE "SP_GIT_PUSH"("P_PROVIDER" VARCHAR, "P_REPO" VARCHAR, "P_SRC_PATH" VARCHAR DEFAULT '@TBI.ML.STG_TBI_PROC/procedures/', "P_DEST_DIR" VARCHAR DEFAULT 'procedures/', "P_MESSAGE" VARCHAR DEFAULT 'export procedures from Snowflake', "P_BRANCH" VARCHAR DEFAULT 'main', "P_REGION" VARCHAR DEFAULT null, "P_DELETE_MISSING" BOOLEAN DEFAULT FALSE)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','requests','boto3')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (GIT_PUSH_EAI)
SECRETS = ('git_cred'=TBI.ML.GIT_PAT)
COMMENT='Stage 파일을 Git 원격(GitHub/CodeCommit)에 1개 커밋으로 반영 (변경분만)'
EXECUTE AS CALLER
AS '
import hashlib
import uuid

import _snowflake

HIST = "TBI.ML.PROC_RUN_HIST"


def _s(v):
    # None 은 '''' 로 바인딩하고 SQL 에서 NULLIF 로 NULL 처리
    return "" if v is None else str(v)


def _hist_start(session, run_id, src, repo, branch):
    session.sql(
        f"INSERT INTO {HIST} (RUN_ID, RUN_TYPE, SOURCE_PATH, GIT_REF, MESSAGE, STATUS) "
        "VALUES (?, ''PUSH'', ?, ?, ?, ''RUNNING'')",
        params=[run_id, src, branch, repo],
    ).collect()


def _hist_end(session, run_id, status, commit=None, cnt=None, msg=None, err=None):
    session.sql(
        f"UPDATE {HIST} SET STATUS = ?, GIT_COMMIT = NULLIF(?, ''''), OBJ_CNT = NULLIF(?, '''')::NUMBER, "
        "MESSAGE = NULLIF(?, ''''), ERROR_MSG = NULLIF(?, ''''), END_TS = CURRENT_TIMESTAMP() WHERE RUN_ID = ?",
        params=[status, _s(commit), _s(cnt), _s(msg), _s(err), run_id],
    ).collect()


def _read_stage_files(session, src_path, dest_dir):
    """src_path 아래 파일 -> {repo 경로: bytes}"""
    src = src_path.rstrip("/") + "/"
    stage_part = src.lstrip("@")
    stage_name = stage_part.split("/")[0].split(".")[-1].lower()
    sub = "/".join(stage_part.split("/")[1:])
    prefix = f"{stage_name}/{sub}"
    files = {}
    for row in session.sql(f"LIST {src}").collect():
        name = row["name"]
        if not name.lower().startswith(prefix.lower()):
            continue
        rest = name[len(prefix):]
        with session.file.get_stream(src + rest) as f:
            files[dest_dir + rest] = f.read()
    return files


def _push_github(repo, branch, files, message, dest_dir, delete_missing):
    import requests

    token = _snowflake.get_username_password("git_cred").password
    api = f"https://api.github.com/repos/{repo}"
    s = requests.Session()
    s.headers.update({"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"})

    def call(method, url, **kw):
        r = s.request(method, url, timeout=60, **kw)
        if r.status_code >= 300:
            raise Exception(f"GitHub {method} {url.replace(api, '''')} -> {r.status_code}: {r.text[:300]}")
        return r.json()

    head = call("GET", f"{api}/git/ref/heads/{branch}")["object"]["sha"]
    base_tree = call("GET", f"{api}/git/commits/{head}")["tree"]["sha"]
    remote = {t["path"]: t["sha"] for t in call("GET", f"{api}/git/trees/{base_tree}?recursive=1")["tree"]
              if t["type"] == "blob"}

    changed = [p for p, d in files.items()
               if remote.get(p) != hashlib.sha1(b"blob %d\\0" % len(d) + d).hexdigest()]
    deleted = [p for p in remote if delete_missing and p.startswith(dest_dir) and p not in files]
    if not changed and not deleted:
        return None, [], []

    entries = [{"path": p, "mode": "100644", "type": "blob", "content": files[p].decode("utf-8")} for p in changed]
    entries += [{"path": p, "mode": "100644", "type": "blob", "sha": None} for p in deleted]
    tree = call("POST", f"{api}/git/trees", json={"base_tree": base_tree, "tree": entries})["sha"]
    commit = call("POST", f"{api}/git/commits", json={"message": message, "tree": tree, "parents": [head]})["sha"]
    call("PATCH", f"{api}/git/refs/heads/{branch}", json={"sha": commit})
    return commit, changed, deleted


def _push_codecommit(repo, branch, region, files, message, dest_dir, delete_missing):
    import boto3

    cred = _snowflake.get_username_password("git_cred")   # USERNAME=Access Key ID, PASSWORD=Secret Key
    cc = boto3.client("codecommit", region_name=region,
                      aws_access_key_id=cred.username, aws_secret_access_key=cred.password)
    head = cc.get_branch(repositoryName=repo, branchName=branch)["branch"]["commitId"]

    def list_remote(folder):
        try:
            res = cc.get_folder(repositoryName=repo, commitSpecifier=head, folderPath=folder)
        except cc.exceptions.FolderDoesNotExistException:
            return []
        paths = [f["absolutePath"] for f in res.get("files", [])]
        for sub in res.get("subFolders", []):
            paths += list_remote(sub["absolutePath"])
        return paths

    changed = []
    for path, data in files.items():
        try:
            cur = cc.get_file(repositoryName=repo, commitSpecifier=head, filePath=path)["fileContent"]
        except cc.exceptions.FileDoesNotExistException:
            cur = None
        if cur != data:
            changed.append(path)
    deleted = [p for p in list_remote(dest_dir.rstrip("/")) if p not in files] if delete_missing else []
    if not changed and not deleted:
        return None, [], []

    res = cc.create_commit(
        repositoryName=repo, branchName=branch, parentCommitId=head,
        authorName="Snowflake", commitMessage=message,
        putFiles=[{"filePath": p, "fileMode": "NORMAL", "fileContent": files[p]} for p in changed],
        deleteFiles=[{"filePath": p} for p in deleted],
    )
    return res["commitId"], changed, deleted


def run(session, p_provider, p_repo, p_src_path, p_dest_dir, p_message, p_branch, p_region, p_delete_missing):
    run_id = str(uuid.uuid4())
    provider = (p_provider or "").upper()
    dest_dir = p_dest_dir.rstrip("/") + "/"
    _hist_start(session, run_id, p_src_path, f"{provider}:{p_repo}", p_branch)
    try:
        user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
        message = f"{p_message}\\n\\n(pushed from Snowflake by {user}, run_id={run_id})"

        files = _read_stage_files(session, p_src_path, dest_dir)
        if not files:
            raise Exception(f"Stage 에 파일이 없음: {p_src_path}")

        if provider == "GITHUB":
            commit, changed, deleted = _push_github(p_repo, p_branch, files, message, dest_dir, p_delete_missing)
        elif provider == "CODECOMMIT":
            if not p_region:
                raise Exception("CODECOMMIT 은 P_REGION 필요")
            commit, changed, deleted = _push_codecommit(p_repo, p_branch, p_region, files, message,
                                                        dest_dir, p_delete_missing)
        else:
            raise Exception(f"지원하지 않는 P_PROVIDER: {p_provider}")

        if commit is None:
            _hist_end(session, run_id, "SUCCESS", None, 0, f"NO_CHANGE ({len(files)} files compared)")
            return f"NO_CHANGE: {len(files)} files compared"

        short = commit[:7]
        detail = "updated: " + ", ".join(changed) if changed else ""
        if deleted:
            detail += (" / " if detail else "") + "deleted: " + ", ".join(deleted)
        _hist_end(session, run_id, "SUCCESS", short, len(changed) + len(deleted), detail)
        return f"SUCCESS: commit {short} ({detail})"
    except Exception as e:
        _hist_end(session, run_id, "FAILED", err=str(e)[:4000])
        return f"FAILED: {e}"
';

CREATE OR REPLACE PROCEDURE "SP_EXPORT_AND_PUSH"("P_DB" VARCHAR, "P_SCHEMA" VARCHAR DEFAULT null, "P_MESSAGE" VARCHAR DEFAULT 'export procedures from Snowflake', "P_PROVIDER" VARCHAR DEFAULT 'GITHUB', "P_REPO" VARCHAR DEFAULT 'jjj-j/SF_PROC', "P_BRANCH" VARCHAR DEFAULT 'main', "P_REGION" VARCHAR DEFAULT null)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='현행 DDL 추출 -> Git 원격 커밋 -> Git 인덱스 동기화 (정기 Task 용)'
EXECUTE AS CALLER
AS '
DECLARE
    v_exp  VARCHAR;
    v_push VARCHAR;
    v_sync VARCHAR;
    res    RESULTSET;
BEGIN
    REMOVE @TBI.ML.STG_TBI_PROC/procedures/;

    res := (CALL TBI.ML.SP_EXPORT_PROCS(:P_DB, :P_SCHEMA));
    LET c1 CURSOR FOR res;
    OPEN c1; FETCH c1 INTO v_exp; CLOSE c1;
    IF (NOT STARTSWITH(v_exp, ''SUCCESS'')) THEN RETURN ''EXPORT '' || v_exp; END IF;

    -- 스키마 지정 시 해당 폴더만 비교/삭제
    res := (CALL TBI.ML.SP_GIT_PUSH(
                P_PROVIDER => :P_PROVIDER, P_REPO => :P_REPO,
                P_SRC_PATH => ''@TBI.ML.STG_TBI_PROC/procedures/'' || COALESCE(:P_SCHEMA || ''/'', ''''),
                P_DEST_DIR => ''procedures/'' || COALESCE(:P_SCHEMA || ''/'', ''''),
                P_MESSAGE  => :P_MESSAGE, P_BRANCH => :P_BRANCH, P_REGION => :P_REGION,
                P_DELETE_MISSING => TRUE));
    LET c2 CURSOR FOR res;
    OPEN c2; FETCH c2 INTO v_push; CLOSE c2;
    IF (STARTSWITH(v_push, ''FAILED'')) THEN RETURN ''PUSH '' || v_push; END IF;

    res := (CALL TBI.ML.SP_SYNC_GIT(:P_BRANCH));
    LET c3 CURSOR FOR res;
    OPEN c3; FETCH c3 INTO v_sync; CLOSE c3;

    RETURN v_exp || '' | '' || v_push || '' | git head '' || v_sync;
END;
';

-- ---------------------------------------------------------------------
-- 4. 배포 / 원복
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE "SP_DEPLOY_PROC"("P_DB" VARCHAR, "P_SCHEMA" VARCHAR, "P_FILE" VARCHAR, "P_VERSION" VARCHAR, "P_GIT_REF" VARCHAR DEFAULT 'main', "P_ARG_TYPES" VARCHAR DEFAULT null)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='Git(TBI.ML.SF_PROC) 파일 배포: FETCH -> 백업 -> 배포 -> COMMENT -> 이력 (실패 시 자동 원복)'
EXECUTE AS CALLER
AS '
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
    e_nofile   EXCEPTION (-20001, ''Git 파일을 찾을 수 없음'');
    e_commit   EXCEPTION (-20002, ''Git 브랜치를 찾을 수 없음'');
    e_sig      EXCEPTION (-20003, ''대상 프로시저가 여러 개(오버로드) - P_ARG_TYPES 지정 필요'');
BEGIN
    v_name := UPPER(SPLIT_PART(REPLACE(SPLIT_PART(P_FILE, ''/'', -1), ''.sql'', ''''), ''__'', 1));
    v_src  := ''@TBI.ML.SF_PROC/branches/'' || P_GIT_REF || ''/'' || P_FILE;

    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, PROC_NAME, SOURCE_PATH, GIT_REF, VERSION, STATUS)
    VALUES (:v_run_id, ''DEPLOY'', :P_DB, :P_SCHEMA, :v_name, :v_src, :P_GIT_REF, :P_VERSION, ''RUNNING'');

    -- 1) FETCH + Git 인덱스 갱신 + 커밋
    CALL TBI.ML.SP_SYNC_GIT(:P_GIT_REF);
    v_commit := (SELECT MAX(GIT_COMMIT) FROM TBI.ML.PROC_GIT_FILES WHERE GIT_REF = :P_GIT_REF);
    IF (v_commit IS NULL) THEN RAISE e_commit; END IF;
    v_hash := (SELECT GIT_SHA1 FROM TBI.ML.PROC_GIT_FILES WHERE GIT_REF = :P_GIT_REF AND FILE_PATH = :P_FILE);
    IF (v_hash IS NULL) THEN RAISE e_nofile; END IF;

    -- 2) Git 파일 읽기
    res := (EXECUTE IMMEDIATE ''SELECT $1 AS TXT FROM '' || v_src || '' (FILE_FORMAT => ''''TBI.ML.FF_RAW_TEXT'''')'');
    LET c1 CURSOR FOR res;
    OPEN c1;
    FETCH c1 INTO v_content;
    CLOSE c1;
    IF (v_content IS NULL) THEN RAISE e_nofile; END IF;

    -- 3) 기존 프로시저 확인 -> 백업
    EXECUTE IMMEDIATE ''SHOW PROCEDURES LIKE '''''' || v_name || '''''' IN SCHEMA '' || P_DB || ''.'' || P_SCHEMA;
    SELECT COUNT(*), MAX(:P_DB || ''.'' || :P_SCHEMA || ''.'' || SPLIT_PART("arguments", '' RETURN '', 1))
      INTO :v_cnt, :v_sig
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE :P_ARG_TYPES IS NULL OR SPLIT_PART("arguments", '' RETURN '', 1) = :v_name || :P_ARG_TYPES;
    IF (v_cnt > 1) THEN RAISE e_sig; END IF;
    IF (v_sig IS NOT NULL) THEN
        CALL TBI.ML.SP_BACKUP_PROC(:v_sig, ''PRE_DEPLOY'', :v_run_id);
        v_bk_id := (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP WHERE PROC_SIGNATURE = :v_sig);
    END IF;

    -- 4) 배포 (프로시저명을 대상 DB.SCHEMA 로 한정)
    v_content := REGEXP_REPLACE(v_content, ''PROCEDURE\\\\s+"?([A-Za-z0-9_$]+)"?\\\\s*\\\\('',
                                ''PROCEDURE '' || P_DB || ''.'' || P_SCHEMA || ''.\\\\1('', 1, 1, ''i'');
    v_deployed := TRUE;
    EXECUTE IMMEDIATE :v_content;

    -- 5) 배포 후 시그니처 확정 + COMMENT
    EXECUTE IMMEDIATE ''SHOW PROCEDURES LIKE '''''' || v_name || '''''' IN SCHEMA '' || P_DB || ''.'' || P_SCHEMA;
    SELECT COUNT(*), MAX(:P_DB || ''.'' || :P_SCHEMA || ''.'' || SPLIT_PART("arguments", '' RETURN '', 1))
      INTO :v_cnt, :v_sig
      FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
     WHERE :P_ARG_TYPES IS NULL OR SPLIT_PART("arguments", '' RETURN '', 1) = :v_name || :P_ARG_TYPES;
    IF (v_cnt > 1) THEN RAISE e_sig; END IF;

    EXECUTE IMMEDIATE ''ALTER PROCEDURE '' || v_sig || '' SET COMMENT = ''''''
        || P_VERSION || '' | git:'' || v_commit || '' | '' || TO_CHAR(CURRENT_TIMESTAMP(), ''YYYY-MM-DD HH24:MI'') || '''''''';

    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = ''SUCCESS'', PROC_SIGNATURE = :v_sig, GIT_COMMIT = :v_commit, FILE_HASH = :v_hash,
           BACKUP_ID = :v_bk_id, OBJ_CNT = 1, END_TS = CURRENT_TIMESTAMP(),
           MESSAGE = ''deployed '' || :P_VERSION || '' (git:'' || :v_commit || '')''
     WHERE RUN_ID = :v_run_id;
    RETURN ''SUCCESS: '' || v_sig || '' '' || P_VERSION || '' git:'' || v_commit || '' (backup_id='' || COALESCE(v_bk_id::VARCHAR, ''new'') || '')'';

EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        v_msg := ''no rollback'';
        IF (v_deployed AND v_bk_id IS NOT NULL) THEN
            BEGIN
                v_ddl := (SELECT DDL FROM TBI.ML.PROC_DDL_BACKUP WHERE BACKUP_ID = :v_bk_id);
                v_ddl := REGEXP_REPLACE(v_ddl, ''PROCEDURE\\\\s+"?([A-Za-z0-9_$]+)"?\\\\s*\\\\('',
                                        ''PROCEDURE '' || P_DB || ''.'' || P_SCHEMA || ''.\\\\1('', 1, 1, ''i'');
                EXECUTE IMMEDIATE :v_ddl;
                v_msg := ''auto-rollback to backup_id='' || v_bk_id;
            EXCEPTION
                WHEN OTHER THEN
                    v_msg := ''auto-rollback FAILED: '' || SQLERRM;
            END;
        END IF;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = ''FAILED'', GIT_COMMIT = :v_commit, FILE_HASH = :v_hash, BACKUP_ID = :v_bk_id,
               ERROR_MSG = :v_err, MESSAGE = :v_msg, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN ''FAILED: '' || v_err || '' / '' || v_msg;
END;
';

CREATE OR REPLACE PROCEDURE "SP_ROLLBACK_PROC"("P_SIG" VARCHAR, "P_BACKUP_ID" NUMBER(38,0) DEFAULT null)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT='백업 DDL 로 원복 (미지정 시 현재 DDL 과 다른 최신 백업)'
EXECUTE AS CALLER
AS '
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
    e_nobk    EXCEPTION (-20011, ''원복할 백업이 없음'');
BEGIN
    v_db     := SPLIT_PART(P_SIG, ''.'', 1);
    v_schema := SPLIT_PART(P_SIG, ''.'', 2);
    INSERT INTO TBI.ML.PROC_RUN_HIST (RUN_ID, RUN_TYPE, DB_NAME, SCHEMA_NAME, PROC_NAME, PROC_SIGNATURE, STATUS)
    VALUES (:v_run_id, ''ROLLBACK'', :v_db, :v_schema, SPLIT_PART(SPLIT_PART(:P_SIG, ''.'', 3), ''('', 1), :P_SIG, ''RUNNING'');

    v_cur   := (SELECT MD5(GET_DDL(''PROCEDURE'', :P_SIG)));
    v_bk_id := COALESCE(P_BACKUP_ID,
                 (SELECT MAX(BACKUP_ID) FROM TBI.ML.PROC_DDL_BACKUP
                   WHERE PROC_SIGNATURE = :P_SIG AND DDL_HASH <> :v_cur));
    IF (v_bk_id IS NULL) THEN RAISE e_nobk; END IF;

    SELECT DDL, BK_VERSION, BK_GIT_COMMIT INTO :v_ddl, :v_ver, :v_commit
      FROM TBI.ML.PROC_DDL_BACKUP WHERE BACKUP_ID = :v_bk_id;

    CALL TBI.ML.SP_BACKUP_PROC(:P_SIG, ''PRE_ROLLBACK'', :v_run_id);

    v_ddl := REGEXP_REPLACE(v_ddl, ''PROCEDURE\\\\s+"?([A-Za-z0-9_$]+)"?\\\\s*\\\\('',
                            ''PROCEDURE '' || v_db || ''.'' || v_schema || ''.\\\\1('', 1, 1, ''i'');
    EXECUTE IMMEDIATE :v_ddl;

    UPDATE TBI.ML.PROC_RUN_HIST
       SET STATUS = ''SUCCESS'', VERSION = :v_ver, GIT_COMMIT = :v_commit, BACKUP_ID = :v_bk_id,
           OBJ_CNT = 1, END_TS = CURRENT_TIMESTAMP(),
           MESSAGE = ''rolled back to backup_id='' || :v_bk_id || '' ('' || COALESCE(:v_ver, ''no version'') || '')''
     WHERE RUN_ID = :v_run_id;
    RETURN ''SUCCESS: '' || P_SIG || '' -> backup_id='' || v_bk_id || '' '' || COALESCE(v_ver, '''');
EXCEPTION
    WHEN OTHER THEN
        v_err := SQLERRM;
        UPDATE TBI.ML.PROC_RUN_HIST
           SET STATUS = ''FAILED'', ERROR_MSG = :v_err, BACKUP_ID = :v_bk_id, END_TS = CURRENT_TIMESTAMP()
         WHERE RUN_ID = :v_run_id;
        RETURN ''FAILED: '' || v_err;
END;
';

-- ---------------------------------------------------------------------
-- 5. 현황 뷰
-- ---------------------------------------------------------------------
create or replace view V_PROC_STATUS(
	NO,
	DB_NAME,
	SCHEMA_NAME,
	PROC_NAME,
	PROC_SIGNATURE,
	CUR_VERSION,
	CUR_GIT_COMMIT,
	DEPLOY_TS,
	DEPLOY_BY,
	LAST_ACTION,
	BK_VERSION,
	BK_GIT_COMMIT,
	BACKUP_TS,
	BACKUP_TYPE,
	BACKUP_ID,
	GIT_FILE,
	GIT_HEAD_COMMIT,
	GIT_STATUS,
	LAST_ALTERED,
	COMMENT
) COMMENT='프로시저 현황: 현재 적용 버전 / 최근 배포 / 최근 백업 / Git 동기화 상태 (Git 은 마지막 SP_SYNC_GIT 기준)'
 as
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
