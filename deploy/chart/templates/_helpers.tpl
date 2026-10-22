{{/* 분석 Job: 새 버전에 요청 N건을 보내 오류가 기준 % 이상이면 실패 */}}
{{- define "errorapp.analysisJob" -}}
provider:
  job:
    spec:
      backoffLimit: 0                  # 실패한 측정을 다시 돌리지 않는다
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: check
              image: curlimages/curl:8.10.1
              imagePullPolicy: IfNotPresent
              command: ["sh", "-c"]
              args:
                - |
                  n={{ .Values.analysis.requests }}
                  fail=0
                  for i in $(seq 1 $n); do
                    code=$(curl -s -o /dev/null -w '%{http_code}' http://{{ "{{args.service-name}}" }}/api/hello)
                    [ "$code" != "200" ] && fail=$((fail+1))
                  done
                  echo "errors=${fail}/${n}"
                  [ $((fail * 100)) -lt $((n * {{ .Values.analysis.maxErrorPercent }})) ]
{{- end }}
