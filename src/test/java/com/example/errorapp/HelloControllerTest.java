package com.example.errorapp;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.web.servlet.MockMvc;

// 테스트가 실패하면 docker build가 멈춰 이미지·서명·배포가 일어나지 않는다
@WebMvcTest(controllers = HelloController.class, properties = {"ERROR_RATE=0", "APP_VERSION=test"})
class HelloControllerTest {

    @Autowired
    private MockMvc mvc;

    @Test
    void 에러율_0이면_200과_ok() throws Exception {
        mvc.perform(get("/api/hello"))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$.result").value("ok"))
           .andExpect(jsonPath("$.version").value("test"));
    }

    @Test
    void 에러율_1이면_500과_error() {
        var res = new HelloController(1.0, "test").hello();
        assertThat(res.getStatusCode().value()).isEqualTo(500);
        assertThat(res.getBody()).containsEntry("result", "error");
    }
}
