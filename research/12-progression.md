# Progression: XP, 100 levels and the garden's pace

Date of research: 2026-10-13. Literature review (sources linked below, several through secondary summaries, as marked), then a pacing simulation (Python, 200 seeded runs per profile, three years each). The rules themselves are in `docs/design.md`, Progression.

## Why

The brief asked for a garden that grows with consistent focus, "points, levels, streaks, a multiplier and losses", inspired by Terra Nil. After the first plan (30 levels) the brief asked for "way more granularity ... kind of like a 100 level to complete the game so that it would last at least a year and take time to grow", accepting smaller XP gains per session.

## What the evidence says

- **Gamification is a small effect, and points can crowd out intrinsic motivation.** A 2023 meta-analysis of 35 gamified interventions (about 2,500 students) found a small significant effect and names a lack of perceived competence and autonomy as the obstacles ([Li and Hew](https://link.springer.com/doi/10.1007/s11423-023-10337-7)); a K-12 meta-analysis found a larger effect on extrinsic than intrinsic motivation; a 2023 review flags points and badges tipping motivation toward the extrinsic ([Dah et al., IJSG](https://doaj.org/article/f9c9ef1a863443c39bcf8cdbd4c0e398)). The one Habitica study found (Müssig and Ziegler 2019, IJHCS) reports counterproductive effects, including punishment during productive stretches ([LMU](https://epub.ub.uni-muenchen.de/77668)).
- **Losses weigh about twice as much as gains.** Tversky and Kahneman (1992) estimated λ = 2.25; a 2024 meta-analysis gives 1.955, 95% interval 1.82–2.10 ([summary](https://healthcare-economist.com/2024/06/26/empirical-estimates-of-loss-aversion)).
- **A broken streak invites giving up.** Polivy, Herman and Deo (2010, Appetite): the sense of having already failed drove more overeating, the "what-the-hell" effect ([U of Toronto](https://magazine.utoronto.ca/?p=16585)); transfer to focus is an inference. Duolingo's first-party experiments (no sample sizes): the Weekend Amulet gave +4% one-week return and 5% fewer lost streaks, the Streak Wager +14% day-7 retention ([Duolingo](https://blog.duolingo.com/how-streaks-keep-duolingo-learners-committed-to-their-language-goals)).
- **Habits take about two months and survive a missed day.** Lally et al. (2010, EJSP, [doi:10.1002/ejsp.674](https://doi.org/10.1002/ejsp.674)): 96 people, automaticity after 18 to 254 days, median about 66; missing one day did not stop habit formation (via [UCL News](https://www.ucl.ac.uk/news/2009/aug/how-long-does-it-take-form-habit)).
- **Early progress pulls people forward.** Nunes and Drèze (2006, JCR): loyalty cards with two stamps pre-filled were completed by 34% against 19% for empty cards needing the same eight purchases (secondary summary).
- **Fixed rewards for the core loop.** Hollerman and Schultz (1998): dopamine neurons code reward prediction errors and dip when an expected reward is withheld ([PubMed 10195164](https://pubmed.ncbi.nlm.nih.gov/10195164/)), which argues against slot-machine rewards for the main loop.
- **Fresh starts.** Dai, Milkman and Riis (2014, Management Science): goal pursuit rises after temporal landmarks such as Mondays and new months ([PDF](https://faculty.wharton.upenn.edu/wp-content/uploads/2014/06/Dai_Fresh_Start_2014_Mgmt_Sci.pdf)).
- **Precedents.** Forest-style apps (a plant dies when you leave) are popular but unstudied, and their punishment is abrupt. Pokémon Sleep rewards a consistent rhythm, deliberately not early or late bedtimes, and a missed night costs nothing ([Pokémon](https://corporate.pokemon.co.jp/en/topics/detail/t-9/)). Terra Nil restores barren land with no timers and no punishment ([Shacknews](https://shacknews.com/article/134777/terra-nil-review-nature-appreciation)).

## What the design took

| Evidence | Rule in Focus |
|---|---|
| Fixed rewards; competence | XP is the focused minutes of a perfect session times its bonuses: predictable, and it grows with real work. No random drops. |
| Loss aversion, what-the-hell effect | Losses are small (10% or 25% of the current level's span) and never drop a level. They take back garden growth, which withers, so a bad session costs something visible but recoverable in one or two good ones. |
| Habits survive a missed day; Weekend Amulet | Only work days can break the streak, and freezes (one per 5 kept days, 2 at most) cover a missed day automatically. A good session keeps the streak without earning XP. |
| Pokémon Sleep | The late bonus stops at 22:00, so sleep is never traded for XP. |
| Reward time, not count | The daily multiplier needs 3 perfect sessions and 4 h 30 focused, and then only applies to sessions of 90 min or more. |
| Endowed progress | Level 2 costs 150 XP (about three 50-minute perfect sessions), and the garden's growth is half level progress, so the first sessions already grow tiles. |
| Terra Nil | The garden is the reward and restoration is the goal; level 100 is "Restored". |

Not taken: the fresh-start effect (a weekly reset) and any variable reward. Losses were part of the brief; the evidence shaped their size and their target (the garden, never the level).

## From 30 to 100 levels

The first plan had 30 levels at `60 · (L − 1)^1.8` XP. Stretched to 100 levels that curve would cost 234,582 XP, and its last level alone 4,248 XP: in the simulation below even the intense profile needs 98 weeks for level 75 and does not reach level 100 within three years. A lower exponent with a larger scale keeps the early levels quick and the late ones reachable:

`xp(L) = 150 · (L − 1)^1.4` gives L2 150, L10 3,251, L50 34,863, L100 93,321 XP, and the last level costs 1,317 XP (about eighteen median perfect sessions for a consistent worker, ten for an intense one).

## Pacing simulation

Profiles, per work day: intense 3–5 sessions of 50/90/90 min (75% perfect, 18% good, 5% drifted, 2% abandoned), half the Saturdays; consistent 2–4 sessions of 50/50/90 min (70/22/6/2); average 4 days a week, 1–3 sessions of 25/50/50 min (45/32/17/6); erratic 3 days a week, 1–2 sessions of 25/50 min (22/30/30/18). The first session of the day starts early on 35%, 30%, 10% and 5% of days, and the last one late 12% of the time. Median of 200 runs:

| Profile | Median perfect | Level at 3 months | 6 months | 12 months | 24 months | Weeks to L10 | L25 | L50 | L75 | L100 |
|---|---|---|---|---|---|---|---|---|---|---|
| intense | +131 XP | 36 | 59 | 96 | 100 | 3 | 8 | 21 | 37 | 55 |
| consistent | +73 XP | 23 | 37 | 60 | 96 | 4 | 15 | 40 | 72 | 110 |
| average | +51 XP | 6 | 8 | 12 | 17 | 35 | — | — | — | — |
| erratic | +36 XP | 2 | 2 | 2 | 2 | — | — | — | — | — |

The old curve stretched to 100 levels, same runs: intense reaches L50 in 43 weeks and L75 in 98; consistent L50 in 89 weeks; neither reaches L100 in three years.

So the game lasts a year for the most intense schedule and about two for a consistent one. Erratic use stalls on purpose: its losses cancel its gains. `ProgressionTests.pacing` pins the curve deterministically: every session perfect on a heavy schedule (four sessions on weekdays, two on Saturdays) reaches level 100 in 40 to 70 weeks, and two 50-minute sessions a weekday take more than a year.

## The garden's pace

The island has 977 single-tile growth steps. Mapping growth to XP alone would leave the first weeks almost bare (level 10 is 3.5% of the XP to level 100), so growth is half the progress through the levels and half the XP toward level 100: about 5 steps at level 2, 60 at level 10, 420 at level 50, all 977 at level 100. `GardenTests` checks that a first 50-minute perfect session grows at least one step and that a long session at level 99 still grows one.
