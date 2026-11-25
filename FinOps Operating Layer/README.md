# FinOps operating layer: take-home pack

Everything here works with any cloud provider, any SQL warehouse, any dashboard tool and any AI model, or none.
The tables, jobs and numbers in the examples are invented. Replace them with your own.

## What is in the pack

| Asset | What it gives you | Use it when |
|-------|-------------------|-------------|
| **Start here** (workbook tab) | A one-page guide to the pack and the five-step start, with a "done when" line for each step | You are starting out |
| **Scorecard** (workbook tab) | Ten questions about your setup, each with a "show me" prompt and a "what a 2 looks like". Score 0, 1 or 2. The total (out of 20) tells you whether to start at crawl, walk or run | You want to know where you stand, or you are comparing FinOps platforms |
| **AI-ready check** (workbook tab) | Four questions to ask before an agent does a task: is it grounded, safe, checked and repeatable? Total out of 8 | You are about to give a task to an AI agent |
| **Table register** (workbook tab) | Every table with its class (source, derived, state, model output), owner, writer, refresh, check and lock status | You are writing down who owns what |
| **Runbook template** (workbook tab) | The fields to write a recurring job down once, with two worked examples | You are making a job repeatable and ownable by someone else |
| **Handover checklist** (workbook tab) | Twelve checks so jobs and tables can change owner without being rebuilt | Someone is leaving, or you are going on leave |
| **lock_and_check_pattern.sql** | A portable pattern: seal a closed month once, recompute it from the raw billing export on a schedule, and flag any drift | You are ready to lock last month's number |

## A sensible order

1. Score yourself on the **Scorecard**. It shows which of the five steps to do next.
2. List your tables in the **Table register** (steps 1 to 3).
3. Write each recurring job in the **Runbook template**.
4. Lock last month with the **SQL pattern** and put the check on a schedule (steps 4 and 5).
5. Before an agent touches a task, run the **AI-ready check**.
6. Work through the **Handover checklist** so the whole thing survives a change of owner.

## Adapting it to your setup

- **Your provider:** the SQL reads one view that maps your billing export to a date, a month, a service and a cost. If your export follows the FOCUS standard, that mapping is a few lines.
- **Your warehouse:** the SQL uses a plain subset of SQL. A short table at the end lists the few things that differ (month truncation, text type, how to schedule the check).
- **Testing:** the SQL core was run on DuckDB (PostgreSQL-style). It has not been run on other warehouses, so try it on a copy first.
