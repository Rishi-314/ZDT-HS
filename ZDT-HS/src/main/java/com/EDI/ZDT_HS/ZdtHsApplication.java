package com.EDI.ZDT_HS;

import com.EDI.ZDT_HS.lifecycle.NaiveVersionManager;
import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class ZdtHsApplication {

    public static void main(String[] args) {
        SpringApplication.run(ZdtHsApplication.class, args);
    }

    @Bean
    CommandLineRunner init(NaiveVersionManager versionManager) {
        return args -> {
            versionManager.loadVersion("v1", "src/main/resources/models/model-v1.onnx");
            versionManager.swapTo("v1");
        };
    }
}