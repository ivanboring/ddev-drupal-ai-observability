# ddev-drupal-ai-observability

A [DDEV](https://ddev.com) add-on that gives a Drupal project a complete,
pre-wired **AI observability stack**: Grafana, Tempo (traces), Mimir (metrics),
Loki (logs) and Alloy (OTLP collector), plus ready-made Grafana dashboards for
the Drupal [AI](https://www.drupal.org/project/ai) /
[AI Agents](https://www.drupal.org/project/ai_agents) modules — agent session
trees, prompt/response message flow, request-layer RED metrics, and
live-priced token cost.

This is a **self-contained fork** of
[MurzNN/ddev-grafana](https://github.com/MurzNN/ddev-grafana) (v0.4.0,
Apache-2.0) with fixes and Drupal-AI-specific additions baked in. Do **not**
install it alongside the upstream `grafana` add-on — they own the same files
(the installer refuses if it detects it; run `ddev add-on remove grafana`
first).

## Install

```bash
ddev add-on get ivanboring/ddev-drupal-ai-observability
ddev restart
ddev sync-model-prices     # optional but recommended: real model prices for the cost dashboard
```

Open Grafana at `https://<project>.ddev.site:3000` — anonymous viewing is
enabled; `admin` / `admin` to edit. Dashboards are in the **DDEV-grafana**
folder.

## Dashboards

| Dashboard | What it shows |
|-----------|---------------|
| **AI Agent Sessions** | Parent→subagent session tree (nested, expandable, token totals, trace drill-down) + a chronological **Message flow** transcript (prompt → response per call, parent/subagent colour-coded). Filter one interaction via the Session variable (paste a Family id). |
| **AI Requests — Overview (RED)** | Request rate, error rate, latency p50/p95/p99, breakdowns by model and operation type. |
| **AI Tokens & Cost** | Token throughput/split and **live-priced** estimated spend (prices synced from [models.dev](https://models.dev)). |
| **AI Latency & Explorer** | Latency heatmap, avg latency by model, live per-request table from Tempo. |

Panels populate from real AI traffic — run an agent or any AI call and refresh.

## Drupal side (required for AI telemetry)

The easiest way is the companion recipe
[`ivanboring/drupal-ai-observability-recipe`](https://github.com/ivanboring/drupal-ai-observability-recipe)
— it enables the modules below and wires the OTLP endpoint in one
`drush recipe:apply`. Manually, you need:

- Modules: `ai` (with `ai_observability` submodule), `opentelemetry` (with
  `opentelemetry_metrics` + `opentelemetry_logs` submodules), an AI provider
  (e.g. `ai_provider_openai`), and optionally `ai_agents` for the agent
  dashboards.
- `opentelemetry.settings`: `endpoint: http://grafana-alloy:4318`
  (`http/protobuf`).
- `ai_observability.settings`: `otel_enabled`, `otel_spans`, `otel_metrics`
  on. For the **Message flow** panel also enable `otel_spans_store_input` +
  `otel_spans_store_output` — ⚠️ this stores prompt/response text (truncated
  ~1 KB) in Tempo; dev-only trade-off, keep off for sensitive environments.
- For agent hierarchy: `ai_agents` ≥ 1.4.x (exposes parent/child runner tags
  that this add-on's Alloy config lifts into `agent.*` span attributes).

## Model price sync

`ddev sync-model-prices` fetches <https://models.dev/api.json> and pushes every
model's input/output/cache-read price into Mimir as gauges
(`ai_model_price_*_usd_per_mtok{provider,model}`). The cost dashboard joins
token counters × price on `(provider, model)`.

A background daemon (`config.model-prices.yaml`) re-syncs on `ddev start` and
every 24 h; the dashboards read prices with `last_over_time(...[7d])` so they
never go stale between syncs.

## Divergence from upstream ddev-grafana

| Change | Why |
|--------|-----|
| **All stack images pinned** (grafana 12.3.1, tempo 2.6.1, loki 3.6.7, mimir 2.17.7, alloy v1.13.2) | Upstream uses `:latest` for everything, which breaks over time: Tempo 2.10's new ingest architecture never opens the OTLP receiver (**all traces silently dropped**), and newer Grafana images removed the `grafana-server` binary the compose entrypoint calls (container won't start). The pins are the versions all configs/dashboards were verified against — bump them deliberately, with testing. |
| `opencensus` receiver removed from `tempo.yaml` | Removed in newer Tempo; crashes the container. |
| Tempo **span-metrics generator** enabled | Remote-writes RED metrics (`traces_spanmetrics_*`, dimensioned by model/operation/provider) to Mimir — powers the request-rate and latency dashboards. |
| Alloy **agent-span enrichment** | An `otelcol.processor.transform` lifts the `ai_agents` runner/caller tags into clean span attributes: `agent.name`, `agent.session_id`, `agent.parent_session_id`, `agent.family_id`, `agent.depth`, `agent.display_name`. This is what makes the nested session tree possible. |
| 4 Drupal-AI dashboards | See above. |
| `ddev sync-model-prices` + daily daemon | Live model pricing from models.dev. |

## Development

Test your working copy against a throwaway project without publishing:

```bash
cd some-scratch-project
ddev add-on get /path/to/ddev-drupal-ai-observability
ddev restart
```

Automated tests: [bats](https://bats-core.readthedocs.io) in `tests/`
(`bats tests`), run in CI by
[ddev/github-action-add-on-test](https://github.com/ddev/github-action-add-on-test).
Note: the "install from release" test only passes once a first GitHub release
exists.

## Credits & license

Derived from [MurzNN/ddev-grafana](https://github.com/MurzNN/ddev-grafana)
v0.4.0 by [MurzNN](https://github.com/MurzNN), Apache License 2.0 — thank you!
Modifications and additions © the contributors of this repository, also
licensed under the [Apache License 2.0](LICENSE).

**Maintained by [ivanboring](https://github.com/ivanboring)**
