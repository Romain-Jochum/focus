# Focus science for a drift-detection and check-in app

Scope: evidence for interventions that restore and sustain focus, what backfires, concrete parameters, and ADHD-specific findings. Confidence labels: HIGH means a primary study or meta-analysis whose abstract was read, MED means a secondary summary of a primary study, LOW means blog, vendor, or unverified claim. Several key numbers below are from secondary sources and must be checked against the primary papers before they go into any public claim. The PNAS paper returned HTTP 403 when fetched, so this account of the "one sec" study relies on the developer's page and press coverage.

## 1. Interventions that restore and sustain focus

Implementation intentions ("if X happens, I will do Y") are the best-supported tool here. Gollwitzer and Sheeran's 2006 meta-analysis, "Implementation intentions and goal achievement," reports a medium-to-large effect on goal attainment, with Cohen's d around 0.65 (95% CI roughly 0.6 to 0.7). This figure was seen only through secondary summaries, such as the [Frontiers review summary](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2021.565202/full). The primary citation is doi 10.1016/S0065-2601(06)38002-1. Confidence: MED. Design implication: the check-in should ask the user to state their if-then plan for the next block, for example "If I open a new tab, I go back to the task card," rather than asking a generic "are you focused?"

Stating a concrete task before starting is the simplest and cheapest intervention. It is the precondition for implementation intentions and for any drift detection, since the app needs a baseline to judge "on task" against. Confidence: MED, based on the goal-setting literature in general; No specific trial was checked.

Self-monitoring and experience sampling prompts are the central mechanism of this app, and they have a known catch. Prompts make people more aware of the thing being measured, which is called reactivity. A 2025 paper by Viechtbauer and colleagues, [Investigating the effect of experience sampling](https://cris.maastrichtuniversity.nl/ws/files/262214670/Viechtbauer-2025-Investigating-the-effect-of-experience-sampling.pdf), reports that overly frequent prompts reduce the attention participants give to their reports, which lowers data quality. Design implication: sparse prompts keep the signal meaningful. Confidence: MED. No meta-analysis was found that directly tests self-monitoring prompts for attention; a search for the Kreitzer and Gollwitzer self-monitoring literature returned nothing.

Friction and pause interventions have the strongest recent field evidence. The "one sec" app inserts a short, deliberate pause before opening a targeted app. Its developers, working with the University of Heidelberg and Max Planck Institute, report a 57% reduction in targeted social media use over six weeks, with data collected from users before and after. The PNAS paper is reported as DOI 10.1073/pnas.2213114120, which could not be verified. Coverage is in [Fortune](https://fortune.com/well/2023/03/06/one-sec-app-can-help-cut-your-social-media-use) and the [developer's study page](https://one-sec.app/max-planck-study). Confidence: MED, with the caveat that the study was run by the product's developers and the methods could not be read. Note that the metric is contested: one competitor describes the 57% as fewer opens, not less time. Design implication: a short pause plus a typed intention before a drifting action is a plausible mechanism, and it is directly testable in this app.

Timeboxing versus flexible breaks: Pomodoro has very little trial evidence for ADHD. The Flowtime method (work until you lose focus, then take a break sized to the work) has one randomized online study that compared Flowtime, Pomodoro and self-selected breaks in a single two-hour session. Its results, reported by the vendor [Super Productivity](https://super-productivity.com/blog/flowtime-technique-pomodoro-alternative/), showed no significant overall differences in productivity or flow. Motivation fell faster under Pomodoro and Flowtime than with self-regulated breaks, but only the Pomodoro-versus-self-regulated comparison survived multiple-comparison correction. Outcomes were self-reported. Confidence: LOW to MED. Design implication: offer flexible breaks as the default, with an optional timer, and log which mode the user chooses.

Body doubling has promising but thin evidence. A 2025 virtual reality study with 12 participants found higher task continuation with a human or AI body double than alone ([arXiv 2509.12153](https://arxiv.org/pdf/2509.12153)). A small Drake University study found no significant effect on reading comprehension or focus. A self-report survey of 117 adults is run by a company that sells body doubling, so it cannot establish causation. Confidence: LOW. Design implication: a "working with someone" mode is a reasonable optional feature, not a core claim.

Accountability and commitment devices, reward, and streaks: No targeted search was run for these, so no numbers are given. Treat them as untested for this app until a source is checked.

## 2. What backfires

Alert fatigue is a documented effect in clinical settings. A 2024 AMCIS systematic review, [Digital Nudges in Healthcare Contexts](https://aisel.aisnet.org/amcis2024/health_it/health_it/13), covers both positive and negative outcomes of digital nudges, and a nursing study describes "nudge fatigue" as an extension of alarm fatigue. A large Swiss study found clinicians' compliance with lab alerts declined over time. These are not focus-app studies, but the mechanism transfers: repeated, unhelpful prompts get ignored and then disabled. Confidence: MED. The primary reactance study was not found, so no specific disable rate can be cited.

Interrupting genuine flow: the cost of interruptions is well documented. Altmann and Trafton's 2007 lab work ([PDF](https://interruptions.net/literature/Altmann-PBR07.pdf)) shows that the first seconds after an interruption are slow while the mind rebuilds context. Monk, Trafton and Boehm-Davis (2008) ([PDF](https://www.interruptions.net/literature/Monk-JEPA08.pdf)) show resumption cost grows with the length and demand of the interruption. Gloria Mark's 2005 field study, commonly summarized as "23 minutes," actually reports a mean return delay of about 25 minutes 26 seconds for same-day resumption, with a very large spread. The lab and field numbers measure different things, so do not merge them. Design implication: never interrupt during a block the user has just started, and make the check-in short so resumption is cheap. Confidence: HIGH for the direction of the effect, MED for the specific numbers.

Shame-based messaging, over-strict blocking that gets disabled, and reactance are the usual failure modes. No rigorous study was found that measures shame-based wording against neutral wording for focus apps. Treat wording guidance as design judgment, not evidence, until checked.

## 3. Concrete design parameters

Wait before nudging after drift: No trial was found that sets this number. A reasonable starting heuristic is a grace period of about 20 to 30 seconds before a check-in, so brief glances at a message are not treated as drift. Mark this as a heuristic, not evidence.

Check-in frequency: keep prompts sparse, because the Viechtbauer 2025 finding suggests high prompt rates degrade attention to the prompt itself. A starting heuristic is at most one check-in every 10 to 15 minutes, with a cooldown after the user dismisses one. This also avoids alert fatigue.

Break length and timing: the Flowtime evidence is weak, so use flexible breaks with an optional timer. A starting heuristic is to offer a break when the user chooses one, and to suggest one after roughly 25 to 50 minutes of sustained on-task time. Mark as heuristic.

Prompt wording: prefer neutral, curious prompts such as "Still working on X?" with a short free-text answer. Avoid guilt. The implementation-intention literature supports asking the user to restate their plan, which turns the check-in into a planning action rather than a judgment.

Typing a sentence: effortful responses plausibly help re-engagement because they force the user to retrieve the task. The mechanism is consistent with implementation-intention research, but no direct trial of typed responses versus one-click responses was found. Confidence: LOW to MED. Worth A/B testing inside the app.

End-of-session reflection: No targeted search was run for this, so no effect-size evidence is reported. It is consistent with self-monitoring theory, but treat it as untested.

## 4. ADHD-specific findings

Time blindness is widely described in clinical and popular sources as a perception problem, where time passing is not felt. The concept is attributed to Barkley's "temporal myopia" framing, but this was seen only through secondary summaries. A 2021 meta-analysis of 55 studies is reported to find timing impairments in ADHD, and this was not verified. Source for the framing: [Super Productivity on ADHD time blindness](https://super-productivity.com/blog/adhd-time-blindness-strategies/). Confidence: LOW to MED.

The practical consequence, which appears consistently across sources, is that time cues must be external, visible and concrete, and that internal timekeeping is unreliable. This supports showing the timer and the task on screen rather than relying on the user to notice time. Confidence: MED, as a consensus across secondary sources rather than a single trial.

Novelty and urgency are repeatedly reported as drivers of ADHD attention, under the "interest-based nervous system" framing. This framing is popular but is not an established research construct. Design implication: vary the check-in wording and visuals over time so it does not become invisible, but do not rely on novelty as a long-term mechanism. Confidence: LOW.

Pomodoro-style timers are often recommended for ADHD. No ADHD-specific randomized trial was found. A small uncontrolled study (11 students, four weeks, no control group) reported improvements in planning and concentration. Confidence: LOW.

## 5. Gaps and next steps

The PNAS one sec paper, the Gollwitzer and Sheeran 2006 abstract, and the 2021 ADHD timing meta-analysis all need to be read directly before any number is used in user-facing copy. The reactance and disable-rate study was not found. Accountability, commitment devices, rewards and streaks, and end-of-session reflection were not searched in depth. A follow-up pass on those, plus a direct search for "self-monitoring" and "attention" trials, would tighten the list.

## Sources

- Fortune on one sec: https://fortune.com/well/2023/03/06/one-sec-app-can-help-cut-your-social-media-use
- one sec Max Planck study page: https://one-sec.app/max-planck-study
- Gollwitzer and Sheeran 2006 summary (Frontiers): https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2021.565202/full
- Viechtbauer 2025, experience sampling: https://cris.maastrichtuniversity.nl/ws/files/262214670/Viechtbauer-2025-Investigating-the-effect-of-experience-sampling.pdf
- Altmann and Trafton 2007: https://interruptions.net/literature/Altmann-PBR07.pdf
- Monk, Trafton and Boehm-Davis 2008: https://www.interruptions.net/literature/Monk-JEPA08.pdf
- Mark 2005 resumption figure (secondary): https://scienceblog.com/t-23-minutes-return-focus-after-interruption/
- AMCIS 2024, digital nudges in healthcare: https://aisel.aisnet.org/amcis2024/health_it/health_it/13
- Flowtime vs Pomodoro (vendor summary): https://super-productivity.com/blog/flowtime-technique-pomodoro-alternative/
- Body doubling VR study: https://arxiv.org/pdf/2509.12153
- ADHD time blindness (secondary): https://super-productivity.com/blog/adhd-time-blindness-strategies/
