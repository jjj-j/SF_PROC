CREATE OR REPLACE PROCEDURE "SP_ML011"("P_YM" VARCHAR, "P_FLAG" BOOLEAN)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
EXECUTE AS OWNER
AS '
def run(session, p_ym, p_flag):
    return f"SP_ML011 {p_ym} {p_flag}"
';