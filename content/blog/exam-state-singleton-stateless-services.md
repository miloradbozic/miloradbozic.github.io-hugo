+++
title = "The exam state that lived in a singleton"
description = "A proof-of-concept bug that taught me where state belongs in a service that will run as many instances, plus LTI launch and Keycloak tokens"
date = "2018-11-04T18:30:00+01:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "exam-state-singleton-stateless-services"
author = "Milorad Bozic"
tags = ["distributed-systems", "java", "spring-boot", "keycloak", "lti"]

+++

In the [last post](/blog/qti-21-java-jqtiplus/) I described a proof of concept that runs QTI tests
with JQTI+ behind a Spring Boot REST API. It worked great in the demo. Then two of us opened it in
two browsers at the same time, and we were both answering *the same* test. When I clicked "next",
my colleague's question changed.

## The bug

The controller looked roughly like this:

```java
@RestController
@RequestMapping("/api/runner")
public class RunnerController {

    private AssessmentTestWrapper test;      // <- here
    private int currentQuestion = 1;         // <- and here

    @GetMapping("/start")
    public ChoiceResponse start() {
        test = new AssessmentTestWrapper("assessment.xml");
        test.enterTest();
        currentQuestion = 1;
        return render(test.getCurrentItem());
    }

    @GetMapping("/next")
    public ChoiceResponse next() {
        test.advanceItemLinear(new Date());
        currentQuestion++;
        return render(test.getCurrentItem());
    }
}
```

Spring controllers are **singletons**. There is one `RunnerController` for the whole application, so
those fields are shared by every user. Everyone was in the same exam. Obvious once you see it, and
easy to miss when you're the only person testing.

## Fix 1: HTTP session (and why it's not enough)

The quick fix is to put the test in the `HttpSession`, one per user. I did that, and it works... on
one instance. But this service will run as several instances behind a load balancer, probably in
containers that come and go. An in-memory session means either sticky sessions (and losing all
in-progress exams when that instance restarts), or session replication (complicated, and now you
have a distributed cache problem).

For an exam, "the server restarted, please start again" is not acceptable. Especially if the person
is on a ship and the restart happened while their connection was down anyway.

## Fix 2: the attempt is a resource

The real fix is to stop thinking about "the session" and start thinking about **the attempt** as a
thing with an id, stored in the database:

```
POST /attempts                    -> 201, { "attemptId": "..." }
GET  /attempts/{id}               -> current state, current item
PUT  /attempts/{id}/responses/{item}
POST /attempts/{id}/finish
```

Every request says which attempt it's about. The service loads the attempt's state, applies the
action, saves the state, and forgets about it. Any instance can serve any request. An instance can
die between two answers and nobody notices.

JQTI+ makes this possible because the test session state is an explicit object you can serialize
(it has its own XML form). So "load state → controller → apply → save" is natural, not a hack.

It also fits what we need for ships. The client can send answers for an attempt whenever the
connection allows, and the attempt doesn't care which server instance, or which day, they arrive at.

## Getting in: LTI launch

Assessments are not a standalone app. Learners start them from an LMS. The standard way to do that is
**LTI**: the LMS does a signed form POST to our launch URL with who the user is, which course, which
resource. We verify it, create or find the attempt, and redirect into the assessment UI.

The first version of our launch endpoint was literally "print the parameters and redirect". Good
enough to prove the LMS can reach us. The real one has to verify the OAuth 1.0 signature on that POST
and reject replays, because otherwise anyone can launch an exam as anyone else.

## Who is this: Keycloak

Users and roles for the new platform live in **Keycloak**. For the browser app that's the standard
OpenID Connect flow: the JavaScript adapter redirects to Keycloak's login page, gets tokens back, and
refreshes them.

```js
var keycloak = Keycloak({
    url: 'https://auth.example.com/auth',
    realm: 'assessments',
    clientId: 'assessment-ui'
});

keycloak.init({ onLoad: 'login-required' }).success(function () {
    bootstrapApp();
});

// before each API call
keycloak.updateToken(30).success(function () {
    request.headers.Authorization = 'Bearer ' + keycloak.token;
});
```

On the service side, every request carries a bearer token, and the service validates it with
Keycloak's public key. No session, no call to Keycloak on every request. Which is the same lesson
again: the service doesn't remember who you are, the request tells it, in a way it can verify.

## The rule I'm taking away

A service instance should be able to die between any two requests without anyone noticing. If it
can't, there's state in the wrong place. In my case it was two innocent-looking fields in a
controller.
