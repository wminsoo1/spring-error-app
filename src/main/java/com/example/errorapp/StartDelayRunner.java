package com.example.errorapp;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/** 모델 서버 흉내: 앱은 떴지만 모델을 불러오는 동안 요청을 받지 않는 상태를 만든다. */
@Component
public class StartDelayRunner implements ApplicationRunner {
    private static final Logger log = LoggerFactory.getLogger(StartDelayRunner.class);

    @Value("${START_DELAY_SECONDS:0}")
    private long delaySeconds;

    @Override
    public void run(ApplicationArguments args) throws InterruptedException {
        if (delaySeconds > 0) {
            log.info("모델 로딩 흉내: {}초 대기", delaySeconds);
            Thread.sleep(delaySeconds * 1000);
            log.info("대기 끝, 요청 받기 시작");
        }
    }
}
