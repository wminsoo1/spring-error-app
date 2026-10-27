# spring-error-app

GitOps 실습용 Spring 서버. `ERROR_RATE` 환경 변수 확률로 HTTP 500을 응답한다.

- `GET /api/hello` : `{"version": "...", "result": "ok" | "error"}`
- `GET /actuator/health/readiness` : Ready 판정
- 배포 설정은 `deploy/` (ArgoCD가 이 폴더를 배포)

