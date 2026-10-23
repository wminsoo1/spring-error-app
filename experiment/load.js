// RQ2 실험 부하: 서버마다 정한 초당 요청을 일정하게 보낸다.
// 요청마다 결과가 CSV(http_req_failed)로 남아 배포 구간의 실패만 따로 셀 수 있다.
import http from 'k6/http';

export const options = {
  noConnectionReuse: true,           // 연결을 재사용하면 한 Pod로 몰려 Pod 비율로 나누는 카나리가 틀어짐
  discardResponseBodies: true,
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RPS),       // 테스트 5, 모델 10, 실배포 50
      timeUnit: '1s',
      duration: __ENV.DURATION || '30m',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
};

export default function () {
  http.get(__ENV.TARGET, { timeout: '5s' });
}
