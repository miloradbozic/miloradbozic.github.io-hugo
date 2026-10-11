+++
title = "Contract tests: how services stop breaking each other"
description = "Unit tests pass, integration environments are flaky, and a renamed field takes down another team's service. Consumer-driven contracts with Spring Cloud Contract"
date = "2020-02-09T18:30:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "consumer-driven-contract-tests"
author = "Milorad Bozic"
tags = ["microservices", "testing", "spring-boot", "java", "distributed-systems"]

+++

With one monolith, if you rename a field, the compiler tells you everywhere it's used. With twenty
services, nobody tells you. Your tests pass, your service deploys, and another service that reads that
field starts failing in production. The compiler's job is now yours.

The usual answers are not great:

- **Unit tests with mocks** test your service against *your idea* of the other service. If your idea
  is wrong, the tests are green and wrong.
- **End-to-end tests in a shared environment** test the real thing, but they're slow, flaky, and
  usually broken for some reason unrelated to your change. People learn to ignore them.

Contract tests sit in between.

## The idea

A **contract** is a small, explicit description of one interaction: "when I send this request, I expect
a response with this status and these fields". The important word in *consumer-driven* is who writes
it: the **consumer**, the service that calls the API. It describes what it actually uses, not
everything the API returns.

From that one contract, two things are generated:

1. **For the provider:** a test that runs against the real provider code and checks that it really
   responds like that. If the provider breaks the contract, *its own build* fails.
2. **For the consumer:** a stub server that responds exactly as the contract says, to test the
   consumer against, without running the provider.

Both sides test against the same file, so they can't drift apart without a build failing somewhere.

## With Spring Cloud Contract

The contract lives in the provider's repository (the consumer team opens a pull request to add it):

```groovy
Contract.make {
    description "assessment service returns the result of a finished attempt"
    request {
        method GET()
        url "/attempts/42/result"
        headers { accept(applicationJson()) }
    }
    response {
        status OK()
        headers { contentType(applicationJson()) }
        body(
            attemptId: "42",
            score: 85.0,
            passed: true
        )
    }
}
```

On the provider side the plugin generates a test from it. You give it a base class that sets up the
controller with the service layer mocked, so the test checks the HTTP contract, not the database:

```java
public abstract class ContractBase {

    @Before
    public void setup() {
        ResultService results = mock(ResultService.class);
        when(results.forAttempt("42")).thenReturn(new Result("42", 85.0, true));
        RestAssuredMockMvc.standaloneSetup(new ResultController(results));
    }
}
```

The build also publishes a stubs jar. On the consumer side:

```java
@RunWith(SpringRunner.class)
@SpringBootTest
@AutoConfigureStubRunner(
    ids = "com.example:assessment-service:+:stubs:8090",
    stubsMode = StubRunnerProperties.StubsMode.REMOTE)
public class ResultClientTest {

    @Autowired ResultClient client;

    @Test
    public void readsFinishedAttemptResult() {
        Result result = client.resultFor("42");
        assertThat(result.isPassed()).isTrue();
    }
}
```

The consumer's test talks to a WireMock server that behaves exactly as the contract says.

## What changes in practice

- **Breaking changes fail in the provider's build**, before merge, with a message that says which
  consumer depends on what. That turns "who uses this field?" from archaeology into a test result.
- **Removing unused fields becomes safe.** If no contract mentions a field, no consumer depends on it.
- **The contract is documentation** that can't be out of date, because it's executed.

## Where it doesn't help

- It checks **shape**, not **meaning**. If `score` changes from percent to points, the contract may still
  pass. Some semantic examples in contracts help, but not completely.
- Contracts only cover what consumers wrote down. A consumer that never added one is not protected.
- It's not free: someone has to own the contracts, and the stubs have to be published and versioned.

It also works for messaging, by the way: a contract can say "when this happens, this message is
published to that exchange with these fields", which for [our RabbitMQ events](/blog/rabbitmq-retries-dead-letters/)
is exactly the kind of interface nobody writes down otherwise.

## Why it's a distributed systems topic

Splitting a monolith into services doesn't remove the coupling between modules. It moves it from the
compiler, which checks it for free, to the network, which checks nothing. Contract tests are one way
to bring a bit of that checking back.
