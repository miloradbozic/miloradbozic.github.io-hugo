+++
title = "Running QTI 2.1 assessments in Java with JQTI+"
description = "What the IMS QTI standard is, why we want it, and a small proof of concept that loads, runs and scores a test"
date = "2018-09-09T19:15:00+02:00"
menu = ""
draft = false
featured = false
share = true
comments = true
slug = "qti-21-java-jqtiplus"
author = "Milorad Bozic"
tags = ["java", "qti", "assessments", "standards"]

+++

For the new assessment platform we decided not to invent our own format for questions and tests.
There is a standard for this, **IMS QTI** (Question and Test Interoperability), and version 2.1 is
what most tools speak. Using it means authors can bring content from other tools, and our tests
are not locked into our own database schema.

The last few weeks I built a proof of concept: load a QTI test, step through it, submit answers,
get a score. Here's what I learned.

## What QTI looks like

A QTI **item** is one question, as XML. It says what the question is, what the correct response
is, and how to score it:

```xml
<assessmentItem identifier="choice" title="Fire safety" adaptive="false" timeDependent="false"
                xmlns="http://www.imsglobal.org/xsd/imsqti_v2p1">
  <responseDeclaration identifier="RESPONSE" cardinality="single" baseType="identifier">
    <correctResponse><value>c2</value></correctResponse>
  </responseDeclaration>
  <outcomeDeclaration identifier="SCORE" cardinality="single" baseType="float">
    <defaultValue><value>0.0</value></defaultValue>
  </outcomeDeclaration>
  <itemBody>
    <choiceInteraction responseIdentifier="RESPONSE" shuffle="false" maxChoices="1">
      <prompt>Which extinguisher should be used on an electrical fire?</prompt>
      <simpleChoice identifier="c1">Water</simpleChoice>
      <simpleChoice identifier="c2">CO2</simpleChoice>
      <simpleChoice identifier="c3">Foam</simpleChoice>
    </choiceInteraction>
  </itemBody>
  <responseProcessing
      template="http://www.imsglobal.org/question/qti_v2p1/rptemplates/match_correct"/>
</assessmentItem>
```

`match_correct` is a standard template: if the response matches the correct one, `SCORE` is 1,
otherwise 0. You can also write your own response processing in QTI's own expression language,
which is powerful and a bit scary.

An **assessment test** is a separate file that references items, groups them into sections and
test parts, and says how navigation works (linear or free), how outcomes are combined into a test
score, and so on.

## JQTI+

Writing a QTI engine yourself is a big job; the spec is large. The best Java option I found is
**JQTI+**, the library inside [QTIWorks](https://github.com/davemckain/qtiworks) from the University
of Edinburgh. It parses and validates QTI, and more importantly it *runs* it: it keeps the state of
a test session and executes the response and outcome processing.

The project is no longer actively developed, which made us think twice. But the standard isn't
moving fast either, the code is solid, and it's open source, so worst case we maintain our fork.
It isn't on Maven Central, so for now it lives in a local Maven repository inside the project.

## Running a test

The core object is a `TestSessionController`. Loading and resolving a test (the test XML plus all
the items it references) needs a bit of setup; I ended up borrowing the loading helper from JQTI+'s
own unit tests. After that, a test run looks like this:

```java
Date now = new Date();
TestSessionController controller = QtiLoader.loadTestForControl("assessment.xml");

controller.initialize(now);
controller.enterTest(now);
controller.enterNextAvailableTestPart(now);

// answer the current item
Map<Identifier, ResponseData> responses = new HashMap<>();
responses.put(Identifier.assumedLegal("RESPONSE"), new StringResponseData("c2"));
controller.handleResponsesToCurrentItem(now, responses);

// linear navigation: go to the next item
controller.advanceItemLinear(now);

// ... more items ...

controller.endCurrentTestPart(now);
TestSessionState state = controller.getTestSessionState();
String score = state.getOutcomeValue(Identifier.assumedLegal("TEST_SCORE")).toQtiString();
```

Two things I liked:

- **Every call takes a timestamp.** The engine doesn't read the clock itself. Time limits and
  durations are computed from the timestamps you pass. That's going to matter a lot for us, because
  on a ship the answer might *arrive* much later than it was *given*.
- **The state is an explicit object.** `TestSessionState` holds everything about the attempt: which
  item is current, responses, outcomes. It can be serialized. So the engine itself doesn't force you
  to keep a session in memory.

## What the proof of concept is

A small Spring Boot app with a REST API around this: start a test, get the current item rendered as
JSON (prompt and choices), submit an answer, move to the next item, finish and get a summary with
scores. Swagger on top so the frontend people can play with it.

It's deliberately ugly inside, and only supports single-choice interactions for now. The goal was to
answer one question: can we build our delivery engine on JQTI+ instead of writing our own? The
answer is yes.

Next step is making it something you could actually run for more than one user at a time, which, as
I'll write about soon, the first version very much wasn't.
