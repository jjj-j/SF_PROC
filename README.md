# SF_PROC

TBI DB의 Snowflake 프로시저 소스와, 이를 백업·버전관리·배포하는 관리 객체를 담은 저장소입니다.

```
procedures/<SCHEMA>/<PROC>.sql   업무 프로시저 (파일명 = 프로시저명)
mgmt/proc_mgmt_objects.sql       관리 객체 DDL (TBI.ML)
docs/DESIGN.md                   설계 / 흐름 / 운영 / 테스트 결과
```

- 현황 조회: `SELECT * FROM TBI.ML.V_PROC_STATUS;`
- 배포: `CALL TBI.ML.SP_DEPLOY_PROC('TBI', 'MGMT', 'procedures/MGMT/SP_CW001.sql', 'v0.0.2');`
- 원복: `CALL TBI.ML.SP_ROLLBACK_PROC('TBI.MGMT.SP_CW001(VARCHAR, NUMBER)');`

자세한 내용은 [docs/DESIGN.md](docs/DESIGN.md) 를 참고하세요.
