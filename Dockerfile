# 1단계: 빌드 (PC에 Java·Maven이 없어도 됨)
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

# 2단계: 실행 (빌드 도구를 빼서 이미지 크기를 줄임)
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/error-app.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
