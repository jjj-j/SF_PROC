CREATE OR REPLACE PROCEDURE "SP_GIT_PUSH"("P_PROVIDER" VARCHAR, "P_REPO" VARCHAR, "P_SRC_PATH" VARCHAR DEFAULT '@TBI.ML.STG_TBI_PROC/procedures/', "P_DEST_DIR" VARCHAR DEFAULT 'procedures/', "P_MESSAGE" VARCHAR DEFAULT 'export procedures from Snowflake', "P_BRANCH" VARCHAR DEFAULT 'main', "P_REGION" VARCHAR DEFAULT null)
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


def _hist_start(session, run_id, src, repo, branch):
    session.sql(
        f"INSERT INTO {HIST} (RUN_ID, RUN_TYPE, SOURCE_PATH, GIT_REF, MESSAGE, STATUS) "
        "VALUES (?, ''PUSH'', ?, ?, ?, ''RUNNING'')",
        params=[run_id, src, branch, repo],
    ).collect()


def _hist_end(session, run_id, status, commit=None, cnt=None, msg=None, err=None):
    session.sql(
        f"UPDATE {HIST} SET STATUS = ?, GIT_COMMIT = ?, OBJ_CNT = ?, MESSAGE = ?, ERROR_MSG = ?, "
        "END_TS = CURRENT_TIMESTAMP() WHERE RUN_ID = ?",
        params=[status, commit, cnt, msg, err, run_id],
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
            files[dest_dir.rstrip("/") + "/" + rest] = f.read()
    return files


def _push_github(repo, branch, files, message):
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

    changed = []
    for path, data in files.items():
        blob_sha = hashlib.sha1(b"blob %d\\0" % len(data) + data).hexdigest()
        if remote.get(path) != blob_sha:
            changed.append(path)
    if not changed:
        return None, []

    tree = call("POST", f"{api}/git/trees", json={
        "base_tree": base_tree,
        "tree": [{"path": p, "mode": "100644", "type": "blob", "content": files[p].decode("utf-8")} for p in changed],
    })["sha"]
    commit = call("POST", f"{api}/git/commits", json={"message": message, "tree": tree, "parents": [head]})["sha"]
    call("PATCH", f"{api}/git/refs/heads/{branch}", json={"sha": commit})
    return commit, changed


def _push_codecommit(repo, branch, region, files, message):
    import boto3

    cred = _snowflake.get_username_password("git_cred")   # USERNAME=Access Key ID, PASSWORD=Secret Key
    cc = boto3.client("codecommit", region_name=region,
                      aws_access_key_id=cred.username, aws_secret_access_key=cred.password)
    head = cc.get_branch(repositoryName=repo, branchName=branch)["branch"]["commitId"]

    changed = []
    for path, data in files.items():
        try:
            cur = cc.get_file(repositoryName=repo, commitSpecifier=head, filePath=path)["fileContent"]
        except cc.exceptions.FileDoesNotExistException:
            cur = None
        if cur != data:
            changed.append(path)
    if not changed:
        return None, []

    res = cc.create_commit(
        repositoryName=repo, branchName=branch, parentCommitId=head,
        authorName="Snowflake", commitMessage=message,
        putFiles=[{"filePath": p, "fileMode": "NORMAL", "fileContent": files[p]} for p in changed],
    )
    return res["commitId"], changed


def run(session, p_provider, p_repo, p_src_path, p_dest_dir, p_message, p_branch, p_region):
    run_id = str(uuid.uuid4())
    provider = (p_provider or "").upper()
    _hist_start(session, run_id, p_src_path, f"{provider}:{p_repo}", p_branch)
    try:
        user = session.sql("SELECT CURRENT_USER()").collect()[0][0]
        message = f"{p_message}\\n\\n(pushed from Snowflake by {user}, run_id={run_id})"

        files = _read_stage_files(session, p_src_path, p_dest_dir)
        if not files:
            raise Exception(f"Stage 에 파일이 없음: {p_src_path}")

        if provider == "GITHUB":
            commit, changed = _push_github(p_repo, p_branch, files, message)
        elif provider == "CODECOMMIT":
            if not p_region:
                raise Exception("CODECOMMIT 은 P_REGION 필요")
            commit, changed = _push_codecommit(p_repo, p_branch, p_region, files, message)
        else:
            raise Exception(f"지원하지 않는 P_PROVIDER: {p_provider}")

        if commit is None:
            _hist_end(session, run_id, "SUCCESS", None, 0, f"NO_CHANGE ({len(files)} files compared)")
            return f"NO_CHANGE: {len(files)} files compared"

        short = commit[:7]
        _hist_end(session, run_id, "SUCCESS", short, len(changed), "pushed: " + ", ".join(changed))
        return f"SUCCESS: commit {short}, {len(changed)}/{len(files)} files -> {'', ''.join(changed)}"
    except Exception as e:
        _hist_end(session, run_id, "FAILED", err=str(e)[:4000])
        return f"FAILED: {e}"
';